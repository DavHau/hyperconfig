# lockedConfig (services.hyperhermes.agents.<name>.lockedConfig): what
# hermes reads as its configuration is root's, generated from Nix, and
# nothing running as the agent's uid can change it, even with code
# execution. Without it the agent owns $HERMES_HOME and every file in it:
# it can rewrite its .env between the dashboard's key drop and hermes
# reading it, plant and enable a dashboard_auth plugin, or set a secret
# source (secrets.command) that emits gate-weakening keys (the trust note
# in ../dashboards/default.nix).
#
# What hermes (v0.22.5) reads, and what it finds here: root-owned
# entries in $HERMES_HOME with the immutable flag, written by
# hermes-locked-<name> (./locked-pins.py) before the gateway and the
# dashboard start:
#   - .env, loaded with override over the process env by the gateway, the
#     dashboard and the CLI (hermes_cli/env_loader.py): the Nix
#     environment and the secretEnv credentials, which reach the root
#     unit as systemd credentials and never sit in a file the agent can
#     write. 0444 inside the owner's 0700 home.
#   - config.yaml, all of it (secrets.*, plugins.*, dashboard.*, and every
#     key Nix does not declare): the Nix settings with initialModel as
#     `model`. The managed scope (HERMES_MANAGED_DIR) stays as in core, a
#     store path in the unit environment, now with no agent-written .env
#     to move it.
#   - .op.env (the 1Password bootstrap, loaded after .env), empty;
#     active_profile (re-homes the dashboard and the CLI into
#     profiles/<x>), empty; gateway.json (legacy gateway config below
#     config.yaml), `{}`.
#   - plugins/ (user plugins, dashboard_auth providers among them),
#     hooks/ (gateway hooks: Python run in the gateway), profiles/ (each a
#     home of its own, with its own .env and config.yaml), lib/ (the FTS5
#     tokenizer hermes loads into whatever opens state.db, the dashboard
#     too) and patches/ (claude-auth's bootstrap imports from the dir
#     HERMES_PATCHES_DIR names, this one): empty directories nothing can
#     be created in.
# The rest of hermes' inputs are out of the agent's reach already: the
# unit environment is systemd's, core's `hermes` shim runs a locked
# agent with the gateway unit's environment and not the caller's
# (agents.nix), project plugins (./.hermes/plugins of the cwd) need
# HERMES_ENABLE_PROJECT_PLUGINS from that environment, the sealed
# package's venv has no user site, HERMES_DEV makes hermes ignore a
# .container-mode file, and HERMES_PATCHES_DIR keeps claude-auth's
# bootstrap off ~/.hermes/patches (agent-config.nix).
#
# Why immutable entries in the owner's directory: hermes insists that
# its home is owned by the user running it, group-writable at most by
# that user's private group (hermes_cli/gateway_runtime_discovery.py,
# before the CLI reaches the gateway), and it writes dozens of its own
# files at the top of the home (state databases with their journals,
# auth.json, locks, sockets, caches), many through write-then-rename.
# So the directory stays the agent's, and the owner of a directory can
# remove or rename any entry in it; only the immutable flag, which needs
# CAP_LINUX_IMMUTABLE to clear, stops that. The home itself sits directly
# in root's 0711 /var/lib/hermes/<name> (hlib.lockedHermesHome), so the
# agent cannot rename it away and make another. Read-only bind mounts
# would hold too, but would have to be set up over paths the agent
# controls (a symlink planted at a mount point moves the mount) and stay
# mounted after the option is gone.
#
# Attacks this closes, as the agent's uid with code execution:
#   - writing, truncating, chmod-ing, deleting, renaming or replacing a
#     pinned entry, or creating anything in a pinned directory: EPERM or
#     EACCES (immutable, root's);
#   - racing a preStart: no unit of the agent writes any of them, and
#     root writes them only while the agent's units are down;
#   - names taken first and symlink tricks: ./locked-pins.py builds each
#     entry under a fresh name, swaps it in atomically, never follows a
#     link, and checks the pinned name is its inode once it is immutable;
#     whatever the agent put there before is removed, and an agent that
#     keeps racing it fails hermes-locked-<name> and with it the gateway
#     and the dashboard;
#   - environment relocation (HERMES_HOME, HERMES_MANAGED_DIR,
#     HERMES_BUNDLED_PLUGINS, HERMES_ENABLE_PROJECT_PLUGINS, PYTHONPATH,
#     the gate keys, ...): see above.
#
# Not closed, and not configuration: the agent can still stop its own
# dashboard and serve something else on the backend port (same uid), or
# publish itself through an outbound tunnel; auth.json (hermes' own OAuth
# token pool, which hermes writes), skills, memories and cron jobs stay
# the agent's. An account whose shell startup files the agent writes can
# still replace `hermes` in an interactive session before the shim runs.
# The state filesystem must support the immutable flag (ext4, btrfs, xfs,
# ZFS do) and root must hold CAP_LINUX_IMMUTABLE (NixOS containers keep
# it).
#
# Removing an agent: the pinned entries stay immutable after the option
# or the agent is gone, so deleting the home (an rm -rf, or on the host
# `nixos-container destroy` or an rm of /var/lib/nixos-containers/<c>,
# for an agent in a container) fails until root clears the flag:
#   chattr -i /var/lib/hermes/<name>/home/{.env,.op.env,config.yaml,active_profile,gateway.json,plugins,hooks,profiles,lib,patches}
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  hlib = import ../../lib/core.nix { inherit lib; };
  ac = import ./agent-config.nix {
    inherit
      lib
      pkgs
      hlib
      cfg
      ;
  };
  lockedAgents = lib.filterAttrs (_: a: a.lockedConfig) cfg.agents;

  pinScript = pkgs.writers.writePython3 "hermes-locked-pins" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./locked-pins.py);

  perUser =
    user: ucfg:
    let
      home = config.users.users.${user}.home;
      hermesHome = hlib.lockedHermesHome user;
      settings =
        ac.agentSettings user ucfg
        // lib.optionalAttrs (cfg.initialModel != null) { model = ac.initialModelSettings; };
      # JSON is YAML.
      files = pkgs.runCommand "hermes-locked-${user}" {
        configText = builtins.toJSON settings;
        envText = ac.envBlock user home ucfg + "\n";
        passAsFile = [
          "configText"
          "envText"
        ];
      } ''
        mkdir $out
        cp "$configTextPath" $out/config.yaml
        cp "$envTextPath" $out/env
        : > $out/empty
        echo '{}' > $out/gateway.json
      '';
      file = source: {
        type = "file";
        mode = 292; # 0444
        inherit source;
      };
      dir = {
        type = "dir";
        mode = 365; # 0555
      };
      spec = pkgs.writeText "hermes-locked-${user}.json" (
        builtins.toJSON {
          home = hermesHome;
          owner = ucfg.uid;
          entries = {
            ".env" = file null;
            "config.yaml" = file "${files}/config.yaml";
            ".op.env" = file "${files}/empty";
            "active_profile" = file "${files}/empty";
            "gateway.json" = file "${files}/gateway.json";
          }
          // lib.genAttrs [ "plugins" "hooks" "profiles" "lib" "patches" ] (_: dir);
        }
      );
      unitDeps = {
        requires = [ "hermes-locked-${user}.service" ];
        after = [ "hermes-locked-${user}.service" ];
      };
    in
    {
      tmpfiles = [ "d ${hermesHome} 0700 ${user} users - -" ];

      services = {
        "hermes-agent-${user}" = unitDeps;
        "hermes-dashboard-${user}" = unitDeps;
        # Restarting it (a secret rotation, a config change) restarts the
        # gateway and the dashboard too (Requires=), so the pins change
        # while neither runs.
        "hermes-locked-${user}" = {
          description = "Root-owned hermes configuration of ${user}";
          wantedBy = [ "multi-user.target" ];
          before = [
            "hermes-agent-${user}.service"
            "hermes-dashboard-${user}.service"
          ];
          unitConfig.RequiresMountsFor = [ hermesHome ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") ucfg.secretEnv;
            # The home, should activation not have run tmpfiles yet.
            ExecStartPre = "${pkgs.systemd}/bin/systemd-tmpfiles --create --prefix=${hlib.baseDir user}";
            ExecStart = "${pinScript} ${spec} ${files}/env";
          };
        };
      };
    };
  users = lib.mapAttrs perUser lockedAgents;
  # Static top-level option keys only (as in ./agents.nix).
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList (user: _: f users.${user}) lockedAgents);

  # The dashboard reads the same pinned .env as the gateway; nothing drops
  # keys from it before the dashboard starts (./agents.nix). So a key Nix
  # puts there that dashboardDropEnv (or the managed-scope keys core always
  # drops) names would reach the dashboard: refuse it instead.
  droppedKeysIn =
    user: ucfg:
    let
      keys = lib.attrNames (
        ac.agentEnv user config.users.users.${user}.home ucfg // ucfg.secretEnv
      );
      patterns = [ "HERMES_MANAGED(_DIR)?" ] ++ ucfg.dashboardDropEnv;
    in
    lib.filter (k: lib.any (p: builtins.match p k != null) patterns) keys;
in
{
  config = lib.mkIf (lockedAgents != { }) {
    assertions = lib.mapAttrsToList (user: ucfg: {
      assertion = droppedKeysIn user ucfg == [ ];
      message = "services.hyperhermes.agents.${user}: lockedConfig pins one .env for the gateway and the dashboard, and it would carry ${lib.concatStringsSep ", " (droppedKeysIn user ucfg)}, which dashboardDropEnv (or core, for HERMES_MANAGED*) keeps from the dashboard. Drop them from environment/secretEnv.";
    }) lockedAgents;
    systemd.services = forEachUser (u: u.services);
    systemd.tmpfiles.rules = lib.concatMap (u: u.tmpfiles) (lib.attrValues users);
  };
}
