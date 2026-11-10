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
    - And on this host only root and the forwarders: whatever this host
      sends into the veth comes from its veth addresses, which the guest
      admits, so the same table's output chain refuses every other uid
      (users, agents, services) on every port and address of the guest,
      link-local included. Passing: root, the sshd socket proxy (its own
      uid, below) to port 22, nginx to the dashboard's and
      clan-secret-prompt's ports (som, ./dashboard.nix); packets of the
      guest's own connections (replies of this host's resolved) and
      socketless ones (the kernel's: ND, resets).
    - /home/infra in the guest is /var/lib/infra-space/home here,
      read-write, so the checkout and the agents' state survive container
      rebuilds. A plain directory, on som too: som's entity storage
      (../entity-storage) manages /home/<user> of host users only, and
      /var/lib lies on som's snapshotted root dataset anyway.
    - This host's TPM, for the guest's age identity (below): its resource
      manager /dev/tpmrm0 is bound into the guest and allowed in its device
      cgroup. Access is a POSIX ACL for the guest's `infra` uid on the node,
      set by the container unit every time it starts (below); the ACL lives
      on the node itself, so it holds inside the guest too. Not the tss
      group: its gid is dynamic (970 on amy, 986 on som) and would have to
      match the guest's. No host user has that uid, so no one here gains
      the TPM.
    - The identities below, as clan vars. Their secrets reach the guest
      only as systemd credentials (nspawn --load-credential, read by root
      on this host), never through a bind mount. Inside, every entry of
      `credentials` is a system credential guest units take with
      LoadCredential=<name>, and a root oneshot also installs it at
      /run/infra-space/secrets/<name> (owner infra, 0400) for the
      interactive user and the tools it runs (./guest.nix). The guest's
      ssh host key goes in as credential `ssh-host-key`, for its sshd
      only. nspawn copies them in at container start only: each var below
      (and the p0, TeamClaude and dashboard OIDC ones) restarts
      container@infra-space on a rotation.
    - Where hyper.infraSpace.hermes is set (som), the guest runs the
      always-on hermes agent (./hermes.nix, with the p0 and TeamClaude
      keys as credentials), and its dashboard is published by this host's
      nginx (./dashboard.nix); other members are the plain backup.
    - Where hyper.infraSpace.buildOnHost is set (som), every `clan
      machines update` in the guest builds here: its `clan` wrapper
      (./guest.nix) adds `--build-host localhost` unless the caller names a
      build host, and the guest's builds are this host's nix-daemon's, so
      the closures are built on this host and uploaded to the targets
      (not built on each target, clan's default). This host must not
      offload them in turn (som: no nix.buildMachines; it is the fleet's
      remote builder itself).

  Teardown (disabling infra-space, or `nixos-container destroy
  infra-space`): hermes' locked config pins entries of the agent's home
  immutable (hyperhermes' modules/core/locked-config.nix), so deleting the
  container's root fails until root here clears the flag first:
    chattr -i /var/lib/nixos-containers/infra-space/var/lib/hermes/infra/home/{.env,.op.env,config.yaml,active_profile,gateway.json,plugins,hooks,profiles,lib,patches}
  /var/lib/infra-space (the guest's /home/infra) is separate and stays.

  Identities (clan vars, and one TPM key; manual steps once, noted per
  entry):
    infra-space-ssh      shared: root on every clan machine
                         (./fleet-access.nix), `infra` in every member's
                         container; credential `ssh`
    infra-space-github   shared: GitHub deploy key of DavHau/hyperconfig;
                         credential `github`. Manual: add its public
                         value on GitHub as a deploy key with write access.
    infra-space-secrets-github
                         shared: GitHub deploy key of
                         DavHau/hyperconfig-secrets, the clan vars' encrypted
                         store (the guest's ~/clan-secrets, ./guest.nix;
                         deploy keys are per repository, so not the one
                         above); credential `secrets-github`. Manual: add
                         its public value on that repository as a deploy key
                         with write access.
    infra-space-hostkey  per member: the guest's ssh host key, pinned by
                         the other members and Dave's launcher from its
                         public value
    TPM age identity     per member, not a clan var: made in the guest and
                         sealed to this host's TPM, it never leaves either;
                         the clan vars' only decrypting identities (clan
                         finds it at ~/.config/age/identities).
                         /home/infra/.config/age/identities in the guest
                         (here under /var/lib/infra-space/home, 0700 infra).
                         Manual, as infra in the container, no PIN:
                           mkdir -p ~/.config/age
                           age-plugin-tpm --generate -o ~/.config/age/identities
                         and add `age-plugin-tpm -y ~/.config/age/identities`
                         (its recipient) to ./age-recipients.nix, then
                         `clan vars fix`.
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

  spaceHost = import ../spaces/host.nix { inherit config lib pkgs; };

  name = "infra-space";
  containerUnit = "container@${name}.service";
  hostAddress = "10.235.0.1";
  localAddress = "10.235.0.2";
  hostAddress6 = "fd23:5ace::1";
  localAddress6 = "fd23:5ace::2";
  # The guest's `infra`; owns the state directory here. Id ladder in
  # ../vault-ids.nix; no host user has it.
  uid = 1203;
  stateDir = "/var/lib/infra-space";
  homeDir = "${stateDir}/home";
  # The guest's sshd forwarder's uid here, the one the output gate admits
  # to port 22 (id ladder in ../vault-ids.nix).
  sshProxyUser = "infra-space-ssh";
  sshProxyUid = 1204;

  # Credential carrying the guest's ssh host key; not in `credentials`, so
  # never copied out for `infra`.
  hostKeyCredential = "ssh-host-key";

  publicMembers = import ./public-members.nix {
    inherit lib;
    inherit (inputs.clan-core) clanLib;
    flake = config.clan.core.settings.directory;
  };

  self = cfg.members.${cfg.member};

  sshKeygen = comment: ''
    ssh-keygen -q -t ed25519 -N "" -C ${lib.escapeShellArg comment} -f "$out"/id_ed25519
  '';
in
{
  # afk for Dave's sessions in the guest (a guest module); the hermes
  # dashboard (som only).
  imports = [
    ./afk.nix
    ./dashboard.nix
    ./gcroots.nix
  ];

  options.hyper.infraSpace = {
    enable = lib.mkEnableOption "the infra-space container";

    hermes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run the always-on hermes infra agent in the guest (./hermes.nix). On som only; other members are a plain backup of the same environment (afk, tools, identities).";
    };

    buildOnHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Make every `clan machines update` in the guest build on this host (`--build-host localhost` through the guest's nix-daemon socket, i.e. this host's daemon) and upload the closures to the targets, unless the caller passes `--build-host`. On som only, the fleet's builder.";
    };

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

  config = lib.mkIf cfg.enable (lib.mkMerge [
  {
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

    # nspawn reads --load-credential only when the container starts: every
    # var the guest consumes restarts it when it changes (a rotation).
    clan.core.vars.generators = {
      inference-api-key.files.token.restartUnits = [ containerUnit ];
      teamclaude-api-key.files.key.restartUnits = [ containerUnit ];
      infra-space-ssh = {
        share = true;
        files.id_ed25519.restartUnits = [ containerUnit ];
        files."id_ed25519.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = sshKeygen "infra-space";
      };
      infra-space-github = {
        share = true;
        files.id_ed25519.restartUnits = [ containerUnit ];
        files."id_ed25519.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = sshKeygen "infra-space@DavHau/hyperconfig";
      };
      infra-space-secrets-github = {
        share = true;
        files.id_ed25519.restartUnits = [ containerUnit ];
        files."id_ed25519.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = sshKeygen "infra-space@DavHau/hyperconfig-secrets";
      };
      infra-space-hostkey = {
        files.ssh_host_ed25519_key.restartUnits = [ containerUnit ];
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
      secrets-github = vars.infra-space-secrets-github.files.id_ed25519.path;
      # Inference for the guest's hermes (./hermes.nix) and afk (./afk.nix):
      # p0's token (../inference-api-key.nix) and the TeamClaude client key
      # (../teamclaude-api-key.nix), both shared vars of every member.
      p0-api-key = vars.inference-api-key.files.token.path;
      teamclaude-api-key = vars.teamclaude-api-key.files.key.path;
    };
    # The always-on agent, where enabled (som); its dashboard: ./dashboard.nix.
    hyper.infraSpace.guestModules = lib.optional cfg.hermes ./hermes.nix;

    }
    # The container itself, its network, isolation and sshd forward: the
    # host side shared with the named spaces (../spaces/host.nix).
    (spaceHost {
      inherit
        name
        uid
        hostAddress
        localAddress
        hostAddress6
        localAddress6
        stateDir
        homeDir
        ;
      proxyUser = sshProxyUser;
      proxyUid = sshProxyUid;
      guestHome = "/home/infra";
      inherit (self) address sshPort;
      inherit (cfg) meshInterface;
      tpm = true;
      credentials = cfg.credentials // {
        ${hostKeyCredential} = vars.infra-space-hostkey.files.ssh_host_ed25519_key.path;
      };
      specialArgs = { inherit inputs; };
      guestConfig = {
        imports = [ ./guest.nix ] ++ cfg.guestModules;
        infraSpace = {
          inherit uid hostKeyCredential;
          inherit (cfg)
            member
            sshPublicKey
            fleetCertAuthority
            buildOnHost
            ;
          members = lib.mapAttrs (_: m: { inherit (m) address sshPort hostKey; }) cfg.members;
          credentials = lib.attrNames cfg.credentials;
          adminKeys = lib.attrValues cfg.adminKeys;
          resolver = hostAddress;
          inherit hostAddress hostAddress6;
          # minus the named spaces' `<name>.containers` lines (the
          # containers module adds one per container): nothing of theirs
          # is infra-space's business, nor reachable from it
          extraHosts = lib.concatStringsSep "\n" (
            lib.filter (
              line:
              !lib.any (space: lib.hasSuffix " ${space}.containers" line) (
                lib.attrNames (import ../spaces/registry.nix)
              )
            ) (lib.splitString "\n" config.networking.extraHosts)
          );
        };
      };
      # som's nginx to the dashboard port (./dashboard.nix)
      # and to clan-secret-prompt's page (./secret-prompt)
      toGuestRules = lib.optionalString cfg.dashboard.enable "meta skuid ${toString config.users.users.${config.services.nginx.user}.uid} tcp dport { ${toString cfg.dashboard.port}, ${toString cfg.dashboard.secretPromptPort} } return";
    })
  ]);
}
