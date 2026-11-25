# The vault broker: an agent's hermes vault (saved logins, cards,
# addresses) out of the agent's own reach (docs/hermes-vault-broker.md in
# hyperconfig).
#
# hermes keeps the vault in <HERMES_HOME>/vault/ (vault.json.enc, Fernet,
# its key in vault.key beside it), owned by the agent's uid, which every
# terminal command and script the model runs has too: the vault kept values
# out of the model's context only by convention. Here, per agent with
# vaultBroker.enable (default: every agent):
#   - hermes-vault-<agent>.socket, /run/hermes-vault/<agent>.sock: root's
#     socket (0666) in root's 0755 directory, so the agent can neither
#     replace nor chmod it; the broker checks the caller on every request.
#   - hermes-vault-<agent>.service (./vault-broker.py): a dynamic user of
#     its own, the store in /var/lib/private/hermes-vault/<agent> (root's
#     0700 parent: the agent cannot even traverse it), hermes' own
#     VaultStore per home (the agent's, each profiles/<name>). Metadata,
#     adds and removes for any process of the agent's uid; the values
#     (resolve_secret) only for the main process of the agent's gateway or
#     dashboard unit, the processes that fill (browser_vault), checked
#     against systemd's MainPID and pinned by a pidfd. A terminal command,
#     execute_code, a kernel, an MCP server, a cron worker is refused.
#     Every resolve is logged (item, kind, label, unit; never a value) and
#     capped per hour.
#   - patches/hermes-vault-broker-client.patch: hermes' VaultStore talks to
#     the broker whenever root's marker /run/hermes-vault/<agent>.on exists
#     (no environment switch the agent's .env could flip; the client also
#     refuses a server running as its own uid, and never falls back to the
#     files: a broker that is down fails the vault).
#   - hermes-vault-migrate-<agent>.service (./vault-migrate.py), root,
#     before every start of the agent's units: legacy vault files of the
#     home and its profiles are read without following links, backed up to
#     /root/hermes-vault-backup/<agent>/ (0600), merged into the broker
#     (ids kept), and removed once the broker holds every id; anything
#     doubtful stays where it was.
#   - `hermes-vault <agent> [--profile P] list|show <label-or-id>`
#     (./vault-cli.py), root only: the items of a vault, read from the
#     broker's store with the broker's code; `show` prints a login's name
#     and password, of a card its brand and last 4 digits only, and writes
#     the owner page's audit line (journalctl -t hermes-vault-<agent>
#     _UID=0).
#   - the owner's vault page (../vault-request/owner.nix) gets owner_list,
#     owner_reveal, owner_remove from the broker, for its own unit's main
#     process only (BROKER_OWNER_UNIT), never for the agent's uid.
#   - LimitCORE=0 on the gateway and dashboard units: systemd-coredump gives
#     the owner a read ACL on its processes' cores, and the agent could
#     SIGSEGV its own gateway right after a fill.
#
# What it does not close (docs/hermes-vault-broker.md, Residual): code the
# agent loads into its own gateway (plugins/, hooks/ of an agent without
# lockedConfig), and reading a filled field back from its own browser; the
# old key stays in ZFS snapshots of the host until they expire.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  enabled = lib.filterAttrs (_: a: a.vaultBroker.enable) cfg.agents;
  socketOf = user: "/run/hermes-vault/${user}.sock";
  markerOf = user: "/run/hermes-vault/${user}.on";
  # the agent units' HERMES_HOME (./agent-config.nix, runtime)
  homeOf = user: config.systemd.services."hermes-agent-${user}".environment.HERMES_HOME;
  python = "${cfg.package.hermesVenv}/bin/python3";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./vault-broker.py
      ./vault_items.py
      ./vault-cli.py
    ];
  };
  # Root's look into an agent's vault (./vault-cli.py): the broker's own
  # store read with the broker's python, audited like the owner page.
  cli = pkgs.writeShellScriptBin "hermes-vault" ''
    if [ "$(${pkgs.coreutils}/bin/id -u)" != 0 ]; then
      echo "hermes-vault: root only" >&2
      exit 77
    fi
    exec ${python} ${src}/vault-cli.py "$@"
  '';
  agentUnits = user: [
    "hermes-agent-${user}"
    "hermes-dashboard-${user}"
  ];
in
{
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.vaultBroker = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Keep this agent's hermes vault in a broker of its own, out of
              the agent account's reach: only the agent's gateway and
              dashboard processes get secret values, for a fill. Existing
              vault files are moved in (backed up to root's
              /root/hermes-vault-backup first).
            '';
          };
          fillUnits = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            internal = true;
            description = ''
              Further units (full names) whose main process may resolve
              values, besides the agent's gateway and dashboard. For checks
              that fill from a driver unit.
            '';
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg.agents != { }) {
    environment.systemPackages = lib.optional (enabled != { }) cli;

    systemd.tmpfiles.rules = [
      "d /run/hermes-vault 0755 root root - -"
    ]
    ++ lib.optional (enabled != { }) "d /root/hermes-vault-backup 0700 root root - -"
    ++ map (user: "f ${markerOf user} 0644 root root - -") (lib.attrNames enabled)
    # turned off again: the marker goes (hermes would otherwise wait for a
    # broker that is gone, failing closed)
    ++ map (user: "r ${markerOf user}") (
      lib.attrNames (lib.filterAttrs (_: a: !a.vaultBroker.enable) cfg.agents)
    );

    systemd.sockets = lib.mapAttrs' (
      user: _:
      lib.nameValuePair "hermes-vault-${user}" {
        description = "Vault broker of ${user}";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ (socketOf user) ];
        socketConfig = {
          SocketUser = "root";
          SocketGroup = "root";
          # Any uid may connect; the broker answers only the agent's.
          SocketMode = "0666";
          DirectoryMode = "0755";
        };
      }
    ) enabled;

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (user: a: {
        "hermes-vault-${user}" = {
          description = "Vault broker of ${user}";
          requires = [ "hermes-vault-${user}.socket" ];
          # A changed broker is restarted alone at a switch. Stopped and
          # started (the default), the switch would stop its socket too, and
          # with it every unit that requires the socket: the agent's gateway
          # and dashboard.
          stopIfChanged = false;
          environment = {
            BROKER_AGENT = user;
            BROKER_AGENT_UID = toString a.uid;
            BROKER_AGENT_HOME = homeOf user;
            BROKER_FILL_UNITS = lib.concatStringsSep " " a.vaultBroker.fillUnits;
            BROKER_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";
            PYTHONDONTWRITEBYTECODE = "1";
            PYTHONUNBUFFERED = "1";
          };
          serviceConfig = {
            ExecStart = "${python} ${src}/vault-broker.py";
            # the audit lines of the owner page (journalctl -u
            # hermes-vault-<agent>) and of root's hermes-vault CLI
            # (journalctl -t hermes-vault-<agent> _UID=0: any uid may log
            # under a tag, the _UID field is the kernel's)
            SyslogIdentifier = "hermes-vault-${user}";
            DynamicUser = true;
            StateDirectory = "hermes-vault/${user}";
            StateDirectoryMode = "0700";
            UMask = "0077";
            # no core dump of a process holding the vault
            LimitCORE = 0;
            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateNetwork = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            RestrictNamespaces = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            SystemCallFilter = [ "@system-service" ];
            SystemCallErrorNumber = "EPERM";
            CapabilityBoundingSet = "";
            Restart = "on-failure";
          };
        };

        "hermes-vault-migrate-${user}" = {
          description = "Move legacy vault files of ${user} into its vault broker";
          requires = [ "hermes-vault-${user}.socket" ];
          after = [ "hermes-vault-${user}.socket" ];
          unitConfig.RequiresMountsFor = [ (homeOf user) ];
          serviceConfig = {
            Type = "oneshot";
            # hermes' client uses the broker exactly when this root-owned
            # marker exists (patches/hermes-vault-broker-client.patch); set
            # before the agent's units start, as they wait for this unit.
            # "+": outside the sandbox below (/run is read-only in it)
            ExecStartPre = "+${pkgs.coreutils}/bin/install -m 0644 -o root -g root /dev/null ${markerOf user}";
            ExecStart = "${python} ${./vault-migrate.py} ${user} ${toString a.uid} ${homeOf user} ${socketOf user}";
            # Bounded: the agent's units wait for it (Wants, so a failure
            # or timeout does not keep them down); the script's own lock
            # wait is 10 s.
            TimeoutStartSec = 60;
            UMask = "0077";
            LimitCORE = 0;
            # root parsing the agent's bytes: only what it needs
            NoNewPrivileges = true;
            PrivateNetwork = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ReadWritePaths = [
              "-/root/hermes-vault-backup"
              # "-": a new agent's home is made by its gateway's preStart.
              # (A link the agent makes of it is writable in here; the
              # script's O_NOFOLLOW walk refuses it all the same.)
              "-${homeOf user}"
            ];
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictNamespaces = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [ "@system-service" ];
            CapabilityBoundingSet = [
              "CAP_DAC_OVERRIDE"
              "CAP_DAC_READ_SEARCH"
              "CAP_FOWNER"
              "CAP_CHOWN"
            ];
          };
        };
      }
      // lib.genAttrs (agentUnits user) (_: {
        # the owner can read its processes' cores (systemd-coredump's ACL)
        serviceConfig.LimitCORE = 0;
        requires = [ "hermes-vault-${user}.socket" ];
        wants = [ "hermes-vault-migrate-${user}.service" ];
        after = [
          "hermes-vault-${user}.socket"
          "hermes-vault-migrate-${user}.service"
        ];
      })
      ) enabled
    );
  };
}
