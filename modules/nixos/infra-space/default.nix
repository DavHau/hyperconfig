/*
  infra-space: a NixOS container on every member machine (./members.nix),
  identical on each, from which the fleet is managed (guest side in
  ./guest.nix).

  Host side:
    - containers.infra-space: private veth, v4 10.235.0.2 and v6
      fd23:5ace::2, its gateway this host (10.235.0.1, fd23:5ace::1).
      Everything the guest sends out is masqueraded (networking.nat, v4
      and v6, any outgoing interface): to the internet, and over
      yggdrasil with this host's own mesh address, which the other clan
      machines' yggdrasil filters admit. No bridge, so it works on wifi.
    - DNS: the guest asks this host's resolved, through an extra stub on
      10.235.0.1, so it gets the host's (encrypted) DNS, and `<machine>.d`
      from this host's /etc/hosts lines (networking.extraHosts, where the
      clan yggdrasil service puts them), copied into the guest.
    - The guest's sshd is reached at [<this host's mesh address>]:<sshPort
      from ./members.nix> only: a socket-activated systemd-socket-proxyd
      bound to that one address (FreeBind: yggdrasil may come up later),
      opened in the firewall on the mesh interface only. A proxy, not a
      DNAT: it needs no v6 NAT rules and nothing listens anywhere else;
      the guest sees connections from 10.235.0.1.
    - Nothing but this host opens a connection into the guest. The NAT
      turns on v4 and v6 forwarding host-wide and the NixOS firewall does
      not filter forwarded traffic, so a LAN peer routing 10.235.0.0/30 or
      fd23:5ace::/64 through this host would reach the guest: the
      infra-space nftables table drops every new forwarded connection out
      of the veth, and the guest's firewall admits this host's veth
      addresses only (./guest.nix), on any port. Guest services for this
      host only (a dashboard behind this host's nginx) need no opening.
    - /home/infra in the guest is /var/lib/infra-space/home here,
      read-write, so the checkout and the agents' state survive container
      rebuilds. A plain directory, on som too: som's entity storage
      (../entity-storage) manages /home/<user> of host users only, and
      /var/lib lies on som's snapshotted root dataset anyway.
    - The identities below, as clan vars. Their secrets reach the guest
      only as systemd credentials (nspawn --load-credential, read by root
      on this host), never through a bind mount. Inside, every entry of
      `credentials` is a system credential guest units take with
      LoadCredential=<name>, and a root oneshot also installs it at
      /run/infra-space/secrets/<name> (owner infra, 0400) for the
      interactive user and the tools it runs (./guest.nix). The guest's
      ssh host key goes in as credential `ssh-host-key`, for its sshd
      only.
    - The guest runs the always-on hermes agent (./hermes.nix, with the
      p0 and TeamClaude keys as credentials); on som its dashboard is
      published by this host's nginx (./dashboard.nix).

  Identities (clan vars; two manual steps once, noted per var):
    infra-space-ssh      shared: root on every clan machine
                         (./fleet-access.nix), `infra` in every member's
                         container; credential `ssh`
    infra-space-github   shared: GitHub deploy key of DavHau/hyperconfig;
                         credential `github`. Manual: add its public
                         value on GitHub as a deploy key with write access.
    infra-space-age      shared: age key; credential `sops-age`. Manual:
                         `clan secrets users add infra-space <its pub>`,
                         add it to group admins, `clan vars fix`.
    infra-space-hostkey  per member: the guest's ssh host key, pinned by
                         the other members and Dave's launcher from its
                         public value
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.infraSpace;
  vars = config.clan.core.vars.generators;

  name = "infra-space";
  # nspawn's host-side veth: ve-<name>, at most 15 characters.
  veth = "ve-${name}";
  hostAddress = "10.235.0.1";
  localAddress = "10.235.0.2";
  hostAddress6 = "fd23:5ace::1";
  localAddress6 = "fd23:5ace::2";
  # The guest's `infra`; owns the state directory here. Id ladder in
  # ../vault-ids.nix; no host user has it.
  uid = 1203;
  stateDir = "/var/lib/infra-space";
  homeDir = "${stateDir}/home";

  # Credential carrying the guest's ssh host key; not in `credentials`, so
  # never copied out for `infra`.
  hostKeyCredential = "ssh-host-key";

  publicMembers = import ./public-members.nix {
    inherit lib;
    inherit (inputs.clan-core) clanLib;
    flake = config.clan.core.settings.directory;
  };

  self = cfg.members.${cfg.member};
  bracket = address: if lib.hasInfix ":" address then "[${address}]" else address;

  sshKeygen = comment: ''
    ssh-keygen -q -t ed25519 -N "" -C ${lib.escapeShellArg comment} -f "$out"/id_ed25519
  '';
in
{
  # afk for Dave's sessions in the guest (credentials + a guest module);
  # the hermes dashboard (som only).
  imports = [
    ./afk.nix
    ./dashboard.nix
  ];

  options.hyper.infraSpace = {
    enable = lib.mkEnableOption "the infra-space container";

    guestModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Extra modules of the container's system (its config.imports; specialArgs carry the flake's `inputs`).";
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''{ p0-token = config.clan.core.vars.generators.inference-api-key.files.token.path; }'';
      description = ''
        Credential name -> path of a secret file on this host. Each is
        passed into the container as a system credential (guest units:
        LoadCredential=<name>) and installed at
        /run/infra-space/secrets/<name> (owner infra, mode 0400).
      '';
    };

    member = lib.mkOption {
      type = lib.types.str;
      default = config.clan.core.settings.machine.name;
      defaultText = lib.literalExpression "config.clan.core.settings.machine.name";
      description = "This machine's name in `members`.";
    };

    members = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.str;
              description = "The member's mesh address.";
            };
            sshPort = lib.mkOption {
              type = lib.types.port;
              description = "Port on that address that reaches the member's container sshd.";
            };
            hostKey = lib.mkOption {
              type = lib.types.str;
              description = "Public ssh host key of the member's container.";
            };
          };
        }
      );
      default = publicMembers;
      defaultText = lib.literalMD "./members.nix, with each member's yggdrasil address and `infra-space-hostkey` public value";
      description = "Every infra-space member.";
    };

    meshInterface = lib.mkOption {
      type = lib.types.str;
      default = "ygg";
      description = "Interface the members' addresses live on (firewall opening for the sshd port).";
    };

    sshPublicKey = lib.mkOption {
      type = lib.types.str;
      default = vars.infra-space-ssh.files."id_ed25519.pub".value;
      defaultText = lib.literalMD "the `infra-space-ssh` public value";
      description = "The shared infra-space identity; authorized for `infra` in the container.";
    };

    adminKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = import ../../admin-ssh-keys.nix;
      defaultText = lib.literalExpression "import modules/admin-ssh-keys.nix";
      description = "Dave's keys, authorized for `infra` in the container.";
    };

    fleetCertAuthority = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = config.programs.ssh.knownHosts.ssh-ca.publicKey;
        defaultText = lib.literalExpression "config.programs.ssh.knownHosts.ssh-ca.publicKey";
        description = "CA that certifies the fleet's ssh host keys (the clan sshd instance's).";
      };
      hostNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        # unique: the clan sshd server and client roles both define it.
        default = lib.unique config.programs.ssh.knownHosts.ssh-ca.extraHostNames;
        defaultText = lib.literalExpression "lib.unique config.programs.ssh.knownHosts.ssh-ca.extraHostNames";
        description = "ssh host patterns of the fleet: the CA's names, and where the guest uses the infra-space key as root.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.members ? ${cfg.member};
        message = "hyper.infraSpace: ${cfg.member} is not in hyper.infraSpace.members (./members.nix)";
      }
      {
        assertion = !(cfg.credentials ? ${hostKeyCredential});
        message = "hyper.infraSpace.credentials: `${hostKeyCredential}` is the guest's ssh host key";
      }
    ];

    clan.core.vars.generators = {
      infra-space-ssh = {
        share = true;
        files.id_ed25519 = { };
        files."id_ed25519.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = sshKeygen "infra-space";
      };
      infra-space-github = {
        share = true;
        files.id_ed25519 = { };
        files."id_ed25519.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = sshKeygen "infra-space@DavHau/hyperconfig";
      };
      infra-space-age = {
        share = true;
        files."key.txt" = { };
        files.pub.secret = false;
        runtimeInputs = [ pkgs.age ];
        script = ''
          age-keygen -o "$out"/key.txt 2>/dev/null
          age-keygen -y "$out"/key.txt > "$out"/pub
        '';
      };
      infra-space-hostkey = {
        files.ssh_host_ed25519_key = { };
        files."ssh_host_ed25519_key.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = ''
          ssh-keygen -q -t ed25519 -N "" -C "" -f "$out"/ssh_host_ed25519_key
        '';
      };
    };

    hyper.infraSpace.credentials = {
      ssh = vars.infra-space-ssh.files.id_ed25519.path;
      github = vars.infra-space-github.files.id_ed25519.path;
      sops-age = vars.infra-space-age.files."key.txt".path;
      # Inference for the guest's hermes (./hermes.nix): p0's token
      # (../inference-api-key.nix) and the TeamClaude client key
      # (../teamclaude-api-key.nix), both shared vars of every member.
      p0-api-key = vars.inference-api-key.files.token.path;
      teamclaude-api-key = vars.teamclaude-api-key.files.key.path;
    };
    # The always-on agent; its dashboard on som: ./dashboard.nix.
    hyper.infraSpace.guestModules = [ ./hermes.nix ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${homeDir} 0700 ${toString uid} ${toString uid} -"
    ];

    containers.${name} = {
      autoStart = true;
      privateNetwork = true;
      inherit
        hostAddress
        localAddress
        hostAddress6
        localAddress6
        ;
      bindMounts."/home/infra" = {
        hostPath = homeDir;
        isReadOnly = false;
      };
      extraFlags = lib.mapAttrsToList (n: path: "--load-credential=${n}:${path}") (
        cfg.credentials // { ${hostKeyCredential} = vars.infra-space-hostkey.files.ssh_host_ed25519_key.path; }
      );
      specialArgs = { inherit inputs; };
      config = {
        imports = [ ./guest.nix ] ++ cfg.guestModules;
        infraSpace = {
          inherit uid hostKeyCredential;
          inherit (cfg)
            member
            sshPublicKey
            fleetCertAuthority
            ;
          members = lib.mapAttrs (_: m: { inherit (m) address sshPort hostKey; }) cfg.members;
          credentials = lib.attrNames cfg.credentials;
          adminKeys = lib.attrValues cfg.adminKeys;
          resolver = hostAddress;
          inherit hostAddress hostAddress6;
          inherit (config.networking) extraHosts;
        };
      };
    };

    networking.nat = {
      enable = true;
      enableIPv6 = true;
      internalInterfaces = [ veth ];
    };

    # The veth is up the moment it exists, whatever runs this host's
    # network: the containers module brings it up only after the guest has
    # booted, and the guest's boot waits for its carrier. systemd-networkd
    # (som and amy) keeps out of it: its 80-container-ve.network would add
    # a link-local and a /28 address, a DHCP server and masquerading, so
    # the forward's source would no longer be hostAddress, the one source
    # the guest admits (./guest.nix); and a networkd restart could drop the
    # guest's route as foreign. NetworkManager leaves ve-* alone already
    # (the containers module), which sets the addresses and the routes;
    # those take this host's veth addresses as their source.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="${veth}", RUN+="${pkgs.iproute2}/bin/ip link set dev $name up"
    '';
    systemd.network.networks."10-${veth}" = lib.mkIf config.systemd.network.enable {
      matchConfig.Name = veth;
      linkConfig.Unmanaged = true;
    };
    systemd.services."container@${name}".postStart = lib.mkAfter ''
      ip route replace ${localAddress} dev ${veth} src ${hostAddress}
      # a source only once its duplicate address detection is over
      for _ in {1..100}; do
        [ -z "$(ip -6 addr show dev ${veth} to ${hostAddress6} tentative)" ] && break
        sleep 0.1
      done
      ip -6 route replace ${localAddress6} dev ${veth} src ${hostAddress6}
    '';

    # Only this host opens connections into the guest; the guest's own
    # connections and their replies pass (see the header).
    networking.nftables.enable = true;
    networking.nftables.tables.infra-space = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter; policy accept;
          oifname "${veth}" ct state new drop
        }
      '';
    };

    services.resolved.settings.Resolve.DNSStubListenerExtra = lib.mkIf config.services.resolved.enable [
      hostAddress
    ];
    networking.firewall.interfaces.${veth} = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };

    systemd.sockets.infra-space-ssh = {
      description = "infra-space sshd on the mesh address";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${bracket self.address}:${toString self.sshPort}" ];
      socketConfig.FreeBind = true;
    };
    systemd.services.infra-space-ssh = {
      description = "Forward to the infra-space container's sshd";
      requires = [ "container@${name}.service" ];
      after = [ "container@${name}.service" ];
      serviceConfig = {
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${localAddress}:22";
        DynamicUser = true;
        PrivateTmp = true;
      };
    };
    networking.firewall.interfaces.${cfg.meshInterface}.allowedTCPPorts = [ self.sshPort ];
  };
}
