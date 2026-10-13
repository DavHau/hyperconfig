# The agent units: the gateway and the web dashboard run on the host, as
# the owner, with no systemd sandboxing. One set of units per enabled
# user. Vendored from spaces 6d744780 modules/nixos/hermes/native.nix.
#
# Loopback ports: a port belongs to whoever binds it first, and
# netfilter gates connect(2), never bind(2). So the owner's daemons bind
# BACKEND ports (base + uid, lib.nix) and clients dial PUBLIC ports that
# root socket units in sockets.nix hold for the whole uptime. The
# per-connection bridge (tcp-owner-bridge.rs) runs as the owner and
# refuses a backend another uid bound.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib) baseDir;
  ac = import ./agent-config.nix {
    inherit
      lib
      pkgs
      inputs
      hlib
      cfg
      ;
    inherit (config.networking) hostName;
  };
  scripts = import ./scripts.nix { inherit lib pkgs hlib; };
  pythonVenv = import ./python-venv.nix { inherit lib pkgs; };
  mkSimplex = import ./simplex.nix { inherit lib pkgs; };

  # Upstream's deep merge: Nix keys win, keys the user added through the
  # dashboard survive.
  configMergeScript = pkgs.callPackage "${inputs.hermes-agent}/nix/configMergeScript.nix" { };

  # The gateway socket is per user under /run/user/<uid>. The uid is
  # runtime-allocated, so the wrapper resolves it when the agent dials.
  spacesMcp = pkgs.writeShellScript "hermes-spaces-mcp" ''
    exec ${pkgs.socat}/bin/socat STDIO "UNIX-CONNECT:/run/user/$(${pkgs.coreutils}/bin/id -u)/spaces-integration-gateway.sock"
  '';

  settingsFor =
    user: ucfg:
    pkgs.writeText "hermes-settings-${user}.json" (
      builtins.toJSON (
        lib.recursiveUpdate {
          terminal.cwd = hlib.workspace user;
        } ac.settings
        // lib.optionalAttrs ucfg.spacesGateway.enable {
          mcp_servers = (ac.settings.mcp_servers or { }) // {
            spaces = {
              command = "${spacesMcp}";
              args = [ ];
            };
          };
        }
      )
    );

  # Non-secret .env entries, plus the mode marker: hermes loads .env with
  # override=True, so the marker must live in a .env, not only in the
  # unit environment.
  agentEnvFor =
    user: ucfg:
    let
      rt = ac.nativeRuntime user config.users.users.${user}.home;
    in
    ac.configRepoEnv user
    // ac.simplexEnv {
      inherit (rt) stateDir;
      port = ucfg.simplexPort;
    }
    // cfg.environment
    // ucfg.environment
    // {
      HERMES_SANDBOX = rt.env.HERMES_SANDBOX;
    };
  envBlockFor =
    user: ucfg:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") (agentEnvFor user ucfg));

  # Hermes' managed scope (hermes_cli/managed_scope.py) for one agent:
  # config.yaml and .env in a directory the owner cannot write. Hermes
  # overlays both on the user's files and refuses a dashboard or CLI
  # write to a key they pin. So exactly the Nix-declared keys are
  # locked, and every other key stays the user's. Each agent gets its
  # own directory through HERMES_MANAGED_DIR, because /etc/hermes would
  # pin one set of values for every agent on the host.
  #
  # The store is world-readable, and so is this directory. It holds no
  # secret: the secretEnv credentials stay in the owner's 0600 .env
  # (ac.envRewriteScript).
  managedDirFor =
    user: ucfg:
    let
      envText = envBlockFor user ucfg + "\n";
      settings = settingsFor user ucfg;
    in
    pkgs.runCommand "hermes-managed-${user}"
      {
        passthru = { inherit envText settings; };
        inherit envText;
        passAsFile = [ "envText" ];
      }
      ''
        mkdir $out
        # JSON is YAML, so the settings file is the managed config.yaml.
        cp ${settings} $out/config.yaml
        cp "$envTextPath" $out/.env
      '';

  # One state vault has one runner. A host that ran this user's agent in
  # a spaces microVM may still have that instance up after a switch (a
  # switch does not stop a running microvm@), so the units refuse to start
  # beside it. spaces' VM side holds the mirror check.
  vmRunningGuard =
    user:
    pkgs.writeShellScript "hermes-native-guard-${user}" ''
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@${hlib.vmName user}.service"; then
        echo "microvm@${hlib.vmName user} is running. A native agent must not open the same state vault. Stop the VM first: systemctl stop microvm@${hlib.vmName user}" >&2
        exit 1
      fi
    '';

  perUser =
    user: ucfg:
    let
      home = config.users.users.${user}.home;
      rt = ac.nativeRuntime user home;
      inherit (rt) stateDir;
      hermesHome = "${stateDir}/.hermes";
      workspace = hlib.workspace user;
      repos = ac.configReposOf user;
      venv = pythonVenv.mkUnit {
        suffix = "-${user}";
        inherit user stateDir;
        group = "users";
        python = pkgs.python3;
        packages = cfg.pythonPackages;
      };
      simplex = mkSimplex {
        suffix = "-${user}";
        inherit user;
        group = "users";
        package = ac.simplexPackage;
        wsUrl = "ws://127.0.0.1:${toString ucfg.simplexPort}";
        displayName = if cfg.simplex.displayName != null then cfg.simplex.displayName else "hermes-${user}";
        stateDir = "${stateDir}/simplex";
        addressFile = hlib.simplexAddressFile user;
        after = [ "hermes-firewall.service" ];
      };
      agentEnv = agentEnvFor user ucfg;
      envBlock = envBlockFor user ucfg;
      # A spaces microVM's activation writes the same keys as unmarked
      # lines. After a VM-to-native flip they would still be in the file
      # and, with override=True, could shadow this block. So drop every
      # managed key first, wherever it sits. HERMES_MANAGED in .env would
      # lock the whole install again, and HERMES_MANAGED_DIR would move
      # the managed scope, so they go too.
      dropManagedKeys =
        lib.concatMapStrings
          (k: ''
            ${pkgs.gnused}/bin/sed -i -E '/^(export[[:space:]]+)?${k}=/d' "$env_file"
          '')
          (
            lib.attrNames agentEnv
            ++ [
              "HERMES_MANAGED"
              "HERMES_MANAGED_DIR"
            ]
          );
      unitEnv = rt.env // {
        HERMES_MANAGED_DIR = "${managedDirFor user ucfg}";
      };
      unitPath = rt.path ++ lib.optional rt.hasConfigRepos config.nix.package;
      mounts = [
        stateDir
        home
      ]
      ++ repos.dirs;
      # The session bus and XDG runtime dir of the owner. A system unit
      # gets neither from systemd, and the uid is runtime-allocated, so
      # the wrapper resolves them. Linger (sockets.nix) keeps the user
      # manager, and so /run/user/<uid>, up from boot.
      withSession = pkgs.writeShellScript "hermes-native-session-env" ''
        uid=$(${pkgs.coreutils}/bin/id -u)
        export XDG_RUNTIME_DIR="/run/user/$uid"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus"
        exec "$@"
      '';
      # Upstream's activation for one state dir, run as the owner before
      # every start. The state dir is owner-owned, so no root is needed.
      # It is not a system activation script: that would run as root and
      # would have to chown every file it touches.
      pluginLinks = lib.concatMapStrings (
        plugin:
        let
          name = lib.getName plugin;
        in
        ''
          if [ ! -f "${plugin}/plugin.yaml" ]; then
            echo "extraPlugins entry '${plugin}' has no plugin.yaml" >&2
            exit 1
          fi
          ln -sfn ${plugin} ${hermesHome}/plugins/nix-managed-${name}
        ''
      ) cfg.extraPlugins;
      # The BEGIN/END markers keep spaces' names, so a block written under
      # the spaces module is replaced, not duplicated.
      agentPreStart = ''
        umask 0077
        mkdir -p ${hermesHome}/cron ${hermesHome}/sessions ${hermesHome}/logs \
          ${hermesHome}/memories ${hermesHome}/plugins ${workspace}
        # The managed scope pins these keys and wins over this file. The
        # merge keeps them in the file the dashboard's raw editor shows.
        ${configMergeScript} ${settingsFor user ucfg} ${hermesHome}/config.yaml
        # Bug fix: a .managed marker makes hermes_cli/config.py
        # (get_managed_system) lock the whole install. The dashboard then
        # dropped every write, a Telegram bot token too, with "this Hermes
        # installation is managed by nixos". The managed scope locks only
        # the Nix keys. Earlier starts, and the microVM path's activation
        # after a mode flip, leave a marker, so remove it on every start.
        rm -f ${hermesHome}/.managed
        # The same keys as the managed .env. Hermes loads that file after
        # this one, so the managed values win; this copy lets the
        # dashboard list them. Strip, then append, like the credential
        # block below. Keys the user or the agent added stay.
        env_file=${hermesHome}/.env
        touch "$env_file"
        ${pkgs.gnused}/bin/sed -i \
          '/^# BEGIN hermes-microvm environment$/,/^# END hermes-microvm environment$/d' \
          "$env_file"
        ${dropManagedKeys}
        {
          echo "# BEGIN hermes-microvm environment"
          cat <<'HERMES_NIX_ENV_EOF'
        ${envBlock}
        HERMES_NIX_ENV_EOF
          echo "# END hermes-microvm environment"
        } >> "$env_file"
        ${ac.envRewriteScript stateDir}
        find ${hermesHome}/plugins -maxdepth 1 -type l -name 'nix-managed-*' -delete
        ${pluginLinks}
        ${ac.modelSeedScript stateDir}
      '';
    in
    {
      tmpfiles = lib.optionals cfg.simplex.enable simplex.tmpfiles;
      # Hermes' terminal tool runs every command in one snapshot of
      # `bash -l`. On NixOS /etc/profile rebuilds PATH, so the unit's
      # PATH and LD_LIBRARY_PATH do not reach that shell. Export them
      # again for the owner's login shells only. The uid is
      # runtime-allocated, so the guard compares it at shell start.
      loginInit = ''
        if [ "$(${pkgs.coreutils}/bin/id -u)" = "$(${pkgs.coreutils}/bin/id -u ${user} 2>/dev/null)" ]; then
          export PATH="${venv.venv}/bin:$PATH"
          export LD_LIBRARY_PATH="${pythonVenv.wheelLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
      '';
      services =
        venv.services
        // lib.optionalAttrs cfg.simplex.enable simplex.services
        // {
          "hermes-agent-${user}" = {
            description = "Hermes Agent gateway for ${user} (native)";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "hermes-firewall.service"
              "${venv.unitName}.service"
            ]
            ++ lib.optional cfg.simplex.enable "${simplex.daemonUnit}.service";
            wants = [
              "network-online.target"
              "${venv.unitName}.service"
            ];
            unitConfig.RequiresMountsFor = mounts;
            environment = unitEnv;
            path = unitPath;
            preStart = agentPreStart;
            serviceConfig = {
              User = user;
              Group = "users";
              WorkingDirectory = workspace;
              # Root steps. mkBefore puts them ahead of the owner's
              # preStart (NixOS lists the preStart wrapper first). The
              # token must exist even when preStart fails: the dashboard
              # unit loads it as a credential and would otherwise loop.
              ExecStartPre = lib.mkBefore (
                [
                  "+${vmRunningGuard user}"
                  "+${scripts.desktopTokenScript user}"
                ]
                ++ lib.optional (repos.dirs != [ ]) "+${scripts.configRepoCheckScript user repos.dirs}"
              );
              LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") ucfg.secretEnv;
              ExecStart = "${withSession} ${ac.hermesPackage}/bin/hermes gateway";
              # `hermes gateway restart` SIGUSR1s this main process
              # (patches/hermes-gateway-restart-foreign-unit.patch). The
              # gateway drains and exits 75 (gateway/restart.py,
              # GATEWAY_SERVICE_RESTART_EXIT_CODE); `always` relaunches it.
              Restart = "always";
              RestartSec = 5;
              UMask = "0007";
            };
          };

          # Web dashboard. Upstream design makes it a separate process. It
          # shares state through HERMES_HOME. It binds its BACKEND port on
          # loopback; the root-held public port in sockets.nix forwards to
          # it through the owner-checking bridge. A non-loopback bind would
          # engage the cookie-only auth gate that the desktop's static
          # token cannot pass.
          "hermes-dashboard-${user}" = {
            description = "Hermes Agent web dashboard for ${user} (native)";
            wantedBy = [ "multi-user.target" ];
            # The dashboard reads the .env the agent's preStart refreshes,
            # and the agent's root ExecStartPre mints the token this unit
            # loads. Wants, not Requires: an agent restart must not take the
            # dashboard down.
            after = [
              "network-online.target"
              "hermes-firewall.service"
              "${venv.unitName}.service"
              "hermes-agent-${user}.service"
            ];
            wants = [
              "network-online.target"
              "hermes-agent-${user}.service"
            ];
            unitConfig.RequiresMountsFor = mounts;
            environment = unitEnv;
            path = unitPath;
            script = ''
              HERMES_DASHBOARD_SESSION_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/dashboard_token")
              export HERMES_DASHBOARD_SESSION_TOKEN
              exec ${withSession} ${ac.hermesPackage}/bin/hermes dashboard \
                --no-open --host 127.0.0.1 \
                --port $((${toString hlib.nativeDashboardBase} + $(id -u)))
            '';
            serviceConfig = {
              User = user;
              Group = "users";
              ExecStartPre = [ "+${vmRunningGuard user}" ];
              # LoadCredential resolves BEFORE this unit's own ExecStartPre,
              # so the token cannot be minted here (observed: 243/CREDENTIALS
              # restart loop on first boot). hermes-agent-<user> mints it.
              LoadCredential = [ "dashboard_token:${baseDir user}/desktop-token" ];
              WorkingDirectory = workspace;
              Restart = "always";
              RestartSec = 5;
              UMask = "0007";
            };
          };
        };
    };
  # Static top-level option keys only. A config-dependent mkMerge list at
  # the config root would make option-key resolution depend on
  # cfg.enabledUsers, and that is infinite recursion.
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.enabledUsers);
  anyUser = cfg.enabledUsers != { };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = forEachUser (user: ucfg: (perUser user ucfg).services);
    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList (user: ucfg: (perUser user ucfg).tmpfiles) cfg.enabledUsers
    );
    services.hermes-native.managedDirs = lib.mapAttrs managedDirFor cfg.enabledUsers;
    environment.extraInit = lib.mkIf anyUser (
      lib.concatStrings (lib.mapAttrsToList (user: ucfg: (perUser user ucfg).loginInit) cfg.enabledUsers)
    );
    # The venv's manylinux wheels dlopen host libraries; nix-ld serves the
    # standalone executables pip installs.
    programs.nix-ld.enable = lib.mkIf anyUser true;
    programs.nix-ld.libraries = lib.mkIf anyUser pythonVenv.nixLdLibraries;
  };
}
