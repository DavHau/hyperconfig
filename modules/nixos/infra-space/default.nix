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
      cgroup. Access is a POSIX ACL for the guest's `infra` uid (as this
      host sees it: the guest has its own user namespace) on the node,
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
    - Its own user namespace (../spaces/host.nix, privateUsers): the
      guest's root is an unprivileged uid here, an untrusted client of
      this host's nix-daemon like infra (builds, substitution from the
      configured caches, signed `nix copy`; no unsigned imports, no
      daemon settings, no `--option`). What needs host root goes through
      root-run interfaces (./gcroots.nix) or ssh to this host as root (the
      infra-space key is in root's authorized_keys on the fleet).
    - Where hyper.infraSpace.hermes is set (som), the guest runs the
      always-on hermes agent (./hermes.nix, with the p0 and TeamClaude
      keys as credentials), and its dashboard is published by this host's
      nginx (./dashboard.nix); other members are the plain backup.
    - On som, ./agent-tools.nix (imported by machines/som/hermes-agents.nix) gives
      the agent a mailbox, a browser and the shared wallet, served here
      and offered on this host's veth address to the guest only.
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
  container's root fails until root here clears the flag first (the
  guest's root cannot, in its user namespace: it asks this host's helper,
  ../spaces/host.nix immutableHelper):
    chattr -i /var/lib/nixos-containers/infra-space/var/lib/hermes/{infra,infra-jobs}/home/{.env,.op.env,config.yaml,active_profile,gateway.json,plugins,hooks,profiles,lib,patches}
  (/var/lib/containers/infra-space/... where the containers' directory has
  no `nixos-` prefix, amy: by stateVersion, ../spaces/host.nix).
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
    agave-geninf-ro      shared: read-only ssh key for agave's repositories
                         on git.geninf.io (agave, agave-vm-host,
                         agave-marketplace, tranquil-pds; granted by
                         gi-infra, never write); credential
                         `agave-geninf-ro`, ssh's key for git.geninf.io
                         (./guest.nix: hyperconfig's flake input `agave`).
                         The agave-host space has it too
                         (../spaces/agave-host.nix).
    infra-space-brief    shared, made and used on the hermes member only:
                         the morning brief's key to edi, a forced command
                         for an unprivileged user (../telegram-send);
                         credential `brief-ssh`
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

  spaceInstance = import ../spaces/instance.nix { inherit config lib pkgs inputs; };

  name = "infra-space";
  containerUnit = "container@${name}.service";
  # veth slot 0 (10.235.0.1/.2, fd23:5ace::1/::2; ../spaces/registry.nix)
  hostAddress = "10.235.0.1";
  # The guest's `infra`; owns the state directory here. Id ladder in
  # ../vault-ids.nix; no host user has it.
  uid = 1203;

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
  # the hermes dashboard (som only)
  imports = [
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

    privateUsers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the guest in its own user namespace (../spaces/host.nix, privateUsers); false is the rollback.";
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

    extraToGuestRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "meta skuid 1209 tcp dport 9123 return" ];
      description = "More nftables rules of the output gate into the guest (another host uid admitted to one guest port, e.g. ../voice-gateway).";
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
    ];

    # nspawn reads --load-credential only when the container starts: every
    # var the guest consumes restarts it when it changes (a rotation).
    # The host key and the afk keys: ../spaces/instance.nix.
    clan.core.vars.generators = {
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
      agave-geninf-ro = {
        share = true;
        files.id_ed25519.restartUnits = [ containerUnit ];
        files."id_ed25519.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = sshKeygen "agave-geninf-ro";
      };
    };

    hyper.infraSpace.credentials = {
      ssh = vars.infra-space-ssh.files.id_ed25519.path;
      github = vars.infra-space-github.files.id_ed25519.path;
      secrets-github = vars.infra-space-secrets-github.files.id_ed25519.path;
      agave-geninf-ro = vars.agave-geninf-ro.files.id_ed25519.path;
      # p0-api-key, teamclaude-api-key, openrouter-api-key (also the
      # guest's hermes', ./hermes.nix): ../spaces/instance.nix.
    };
    # The always-on agent, where enabled (som); its dashboard: ./dashboard.nix.
    hyper.infraSpace.guestModules = lib.optional cfg.hermes ./hermes.nix;
  }
  (lib.mkIf cfg.hermes {
    # The morning brief's key to edi (./decisions.nix): only the agent's
    # member has it; edi authorizes its public half for an unprivileged
    # user with a forced command (../telegram-send).
    clan.core.vars.generators.infra-space-brief = {
      share = true;
      files.id_ed25519.restartUnits = [ containerUnit ];
      files."id_ed25519.pub".secret = false;
      runtimeInputs = [ pkgs.openssh ];
      script = sshKeygen "infra-space-brief";
    };
    hyper.infraSpace.credentials.brief-ssh = vars.infra-space-brief.files.id_ed25519.path;
  })
    # The container, its network, isolation, sshd forward, host key,
    # afk and herdr: the core every space shares (../spaces/instance.nix).
    (spaceInstance {
      inherit name uid;
      user = "infra";
      index = 0;
      description = "infra-space";
      proxyUser = "infra-space-ssh";
      # the guest's sshd forwarder (id ladder in ../vault-ids.nix)
      proxyUid = 1204;
      stateDir = "/var/lib/infra-space";
      guestHome = "/home/infra";
      inherit (self) address sshPort;
      inherit (cfg) meshInterface privateUsers credentials;
      tpm = true;
      hostKeyGenerator = "infra-space-hostkey";
      authorizedKeys = [ cfg.sshPublicKey ] ++ lib.attrValues cfg.adminKeys;
      # every member (this one too), as `ssh infra-space-<member>` with
      # the shared key
      siblings = lib.mapAttrsToList (machine: m: {
        inherit machine;
        inherit (m) address sshPort hostKey;
        user = "infra";
      }) cfg.members;
      siblingIdentity = "ssh";
      # hermes' lockedConfig pins (./hermes.nix): the entries of its two
      # agents' locked homes only (infra, and the security jobs' infra-jobs)
      immutableHelper =
        if cfg.hermes then
          map inputs.hyperhermes.lib.lockedHermesHome [
            "infra"
            "infra-jobs"
          ]
        else
          null;
      guest = ./guest.nix;
      inherit (cfg) guestModules;
      guestSpace = {
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
      # som's nginx to the dashboard port (./dashboard.nix)
      # and to clan-secret-prompt's page (./secret-prompt)
      toGuestRules = lib.concatStringsSep "\n" (
        lib.optional cfg.dashboard.enable "meta skuid ${toString config.users.users.${config.services.nginx.user}.uid} tcp dport { ${toString cfg.dashboard.port}, ${toString cfg.dashboard.secretPromptPort} } return"
        ++ cfg.extraToGuestRules
      );
    })
    {
      containers.${name}.config.infraSpace = {
        inherit (cfg)
          member
          fleetCertAuthority
          buildOnHost
          ;
        members = lib.mapAttrs (_: m: { inherit (m) address sshPort hostKey; }) cfg.members;
      };
    }
  ]);
}
