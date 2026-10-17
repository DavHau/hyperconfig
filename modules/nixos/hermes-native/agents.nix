# The agent units and the `hermes` shim. Per user, the gateway and the web
# dashboard run on the host as the owner, with no systemd sandboxing.
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
  ac = import ./agent-config.nix {
    inherit
      lib
      pkgs
      inputs
      hlib
      cfg
      ;
  };
  pythonVenv = import ./python-venv.nix { inherit lib pkgs; };
  spacesIntegrations = config.services.spaces-integrations.enable or false;

  # Upstream's deep merge: Nix keys win, keys the user added through the
  # dashboard survive.
  configMergeScript = pkgs.callPackage "${inputs.hermes-agent}/nix/configMergeScript.nix" { };

  # The spaces integration gateway is a per-user socket under
  # /run/user/<uid>. The uid is runtime-allocated, so the wrapper
  # resolves it when the agent dials.
  spacesMcp = pkgs.writeShellScript "hermes-spaces-mcp" ''
    exec ${pkgs.socat}/bin/socat STDIO "UNIX-CONNECT:/run/user/$(${pkgs.coreutils}/bin/id -u)/spaces-integration-gateway.sock"
  '';

  settingsFor =
    user:
    pkgs.writeText "hermes-settings-${user}.json" (
      builtins.toJSON (
        lib.recursiveUpdate {
          terminal.cwd = hlib.workspace user;
        } ac.settings
        // lib.optionalAttrs spacesIntegrations {
          mcp_servers = (ac.settings.mcp_servers or { }) // {
            spaces = {
              command = "${spacesMcp}";
              args = [ ];
            };
          };
        }
      )
    );

  # Non-secret .env entries. HERMES_SANDBOX rides here too: hermes loads
  # .env with override=True, so the unit environment alone would not hold.
  agentEnvFor =
    user: ucfg:
    cfg.environment
    // ucfg.environment
    // {
      HERMES_SANDBOX = (ac.runtime user config.users.users.${user}.home).env.HERMES_SANDBOX;
    };

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
    pkgs.runCommand "hermes-managed-${user}"
      {
        envText = envBlockFor user ucfg + "\n";
        passAsFile = [ "envText" ];
      }
      ''
        mkdir $out
        # JSON is YAML, so the settings file is the managed config.yaml.
        cp ${settingsFor user} $out/config.yaml
        cp "$envTextPath" $out/.env
      '';
  envBlockFor =
    user: ucfg:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") (agentEnvFor user ucfg));

  # The session bus and XDG runtime dir of the owner. A system unit gets
  # neither from systemd, and the uid is runtime-allocated, so the wrapper
  # resolves them. The owner's account lingers, so its user manager, and
  # /run/user/<uid> with it, is up from boot.
  withSession = pkgs.writeShellScript "hermes-session-env" ''
    uid=$(${pkgs.coreutils}/bin/id -u)
    export XDG_RUNTIME_DIR="/run/user/$uid"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus"
    exec "$@"
  '';

  # Hermes copies its bundled skills from the store into
  # $HERMES_HOME/skills/<category>/<name> and keeps the store's
  # read-only modes. When upstream moves a skill to another category,
  # hermes renames the old copy (tools/skills_sync.py,
  # _recover_renamed_skill), but renaming a directory to another parent
  # needs write access to the directory itself, for its "..". The rename
  # fails, shutil.move falls back to copy-then-delete, the delete fails
  # too, and both copies stay. Two skills of one name make skill_view
  # refuse with "Ambiguous skill name". Hermes never retries: the new
  # copy exists from then on.
  #
  # So before every start, once the new copy is in place, drop the old
  # one if it is still hermes' own: its name is in .bundled_manifest and
  # no entry under it carries a write bit. A byte comparison would not
  # do, as the old copy holds the old release's text. Hermes copies
  # bundled skills read-only, and an edit by the user or the agent needs
  # a write bit. A skill the user wrote or touched is therefore never
  # removed. While the new copy is missing, the old one stays, because
  # hermes takes a skill in its manifest but missing on disk as deleted
  # by the user and would not install it again.
  pruneMovedBundledSkills = pkgs.writeShellScript "hermes-prune-moved-bundled-skills" ''
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.gnugrep ]}
    bundled=$1
    skills=$2
    manifest=$skills/.bundled_manifest
    [ -d "$bundled" ] && [ -f "$manifest" ] || exit 0
    for md in "$bundled"/*/*/SKILL.md; do
      [ -e "$md" ] || continue
      src=''${md%/SKILL.md}
      name=''${src##*/}
      category=''${src%/*}
      category=''${category##*/}
      [ -d "$skills/$category/$name" ] || continue
      cut -d: -f1 "$manifest" | grep -qxF -- "$name" || continue
      for old in "$skills"/*/"$name"; do
        [ "$old" != "$skills/$category/$name" ] && [ -d "$old" ] && [ ! -L "$old" ] || continue
        [ -z "$(find "$old" -perm /222 -print -quit)" ] || continue
        if chmod -R u+w "$old" && rm -rf "$old"; then
          echo "removed stale copy $old of bundled skill $category/$name"
        else
          echo "could not remove stale copy $old of bundled skill $category/$name" >&2
        fi
      done
    done
    exit 0
  '';

  # Drops .env keys before a dashboard start (./drop-env-keys.py, which
  # reads the file the way hermes does).
  dropEnvKeys = pkgs.writers.writePython3 "hermes-drop-env-keys" {
    libraries = [ pkgs.python3Packages.python-dotenv ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./drop-env-keys.py);

  perUser =
    user: ucfg:
    let
      home = config.users.users.${user}.home;
      rt = ac.runtime user home;
      inherit (rt) stateDir;
      hermesHome = "${stateDir}/.hermes";
      workspace = hlib.workspace user;
      venv = pythonVenv.mkUnit {
        suffix = "-${user}";
        inherit user stateDir;
        group = "users";
        python = pkgs.python3;
        packages = import ./python-packages.nix;
      };
      # HERMES_MANAGED in .env would lock the whole install, and
      # HERMES_MANAGED_DIR would move the managed scope away from the Nix
      # keys. The agent can write its .env, so both go before every start.
      dropManagedKeys = ''
        ${pkgs.gnused}/bin/sed -i -E '/^(export[[:space:]]+)?HERMES_MANAGED(_DIR)?=/d' "$env_file"
      '';
      unitEnv = rt.env // {
        HERMES_MANAGED_DIR = "${managedDirFor user ucfg}";
      };
      mounts = [
        stateDir
        home
      ];
      # The user's private /tmp, as in their own sessions (../per-user-tmp).
      # No "-": with per-user tmp on, a missing instance must stop the unit,
      # not quietly put it on the shared /tmp.
      userTmpBinds = lib.optionals (config.hyper.perUserTmp.enable or false) [
        "/tmp/.inst/${user}:/tmp"
        "/var/tmp/.inst/${user}:/var/tmp"
      ];
      # Upstream's activation for one state dir, run as the owner before
      # every start. The state dir is owner-owned, so no root is needed.
      agentPreStart = ''
        umask 0077
        mkdir -p ${hermesHome}/cron ${hermesHome}/sessions ${hermesHome}/logs \
          ${hermesHome}/memories ${hermesHome}/plugins ${workspace}
        # The managed scope pins these keys and wins over this file. The
        # merge keeps them in the file the dashboard's raw editor shows.
        ${configMergeScript} ${settingsFor user} ${hermesHome}/config.yaml
        # The same keys as the managed .env. Hermes loads that file after
        # this one, so the managed values win; this copy lets the
        # dashboard list them. Strip, then append, like the credential
        # block. Keys the user or the agent added stay.
        env_file=${hermesHome}/.env
        touch "$env_file"
        ${pkgs.gnused}/bin/sed -i \
          '/^# BEGIN hermes-native environment$/,/^# END hermes-native environment$/d' \
          "$env_file"
        ${dropManagedKeys}
        {
          echo "# BEGIN hermes-native environment"
          cat <<'HERMES_NIX_ENV_EOF'
        ${envBlockFor user ucfg}
        HERMES_NIX_ENV_EOF
          echo "# END hermes-native environment"
        } >> "$env_file"
        ${ac.envRewriteScript stateDir}
        ${ac.modelSeedScript stateDir}
        ${pruneMovedBundledSkills} ${ac.hermesPackage}/share/hermes-agent/skills ${hermesHome}/skills
      '';
    in
    {
      # The parent is root's, 0711, so the owner's units can traverse it
      # and no other uid can list it.
      tmpfiles = [
        "d ${hlib.baseDir user} 0711 root root - -"
        "d ${stateDir} 0700 ${user} users - -"
        "d ${hlib.hermesDir user} 0755 ${user} users - -"
        "d ${workspace} 0755 ${user} users - -"
      ];

      # Hermes' terminal tool runs every command in one snapshot of
      # `bash -l`. On NixOS /etc/profile rebuilds PATH, so the unit's
      # PATH and LD_LIBRARY_PATH do not reach that shell. Export them
      # again for the owner's login shells only. The uid is
      # runtime-allocated, so the guard compares it at shell start.
      # The bare hermes package stays out: an ssh login must reach the
      # `hermes` shim, which sets HERMES_HOME.
      loginInit = ''
        if [ "$(${pkgs.coreutils}/bin/id -u)" = "$(${pkgs.coreutils}/bin/id -u ${user} 2>/dev/null)" ]; then
          export PATH="${lib.makeBinPath (lib.remove ac.hermesPackage rt.path)}:$PATH"
          export LD_LIBRARY_PATH="${pythonVenv.wheelLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
      '';

      # The CLI runs the agent package with the environment and PATH of
      # the gateway unit: same HERMES_HOME, venv first on PATH, skill
      # CLIs, HOME and per-setting locks. HOME is the account home, so the
      # shim enters the workspace by path. LD_LIBRARY_PATH prepends rather
      # than replaces the caller's.
      shimCaseArm =
        let
          env = lib.filterAttrs (n: _: n != "LD_LIBRARY_PATH") unitEnv;
        in
        ''
          ${user})
            ${lib.concatStringsSep "\n    " (
              lib.mapAttrsToList (n: v: "export ${n}=${lib.escapeShellArg v}") env
            )}
            export PATH=${lib.escapeShellArg (lib.makeBinPath rt.path)}:"$PATH"
            export LD_LIBRARY_PATH=${lib.escapeShellArg rt.env.LD_LIBRARY_PATH}"''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            cd ${lib.escapeShellArg workspace}
            ;;
        '';

      services = venv.services // {
        "hermes-agent-${user}" = {
          description = "Hermes Agent gateway for ${user}";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "hermes-firewall.service"
            "${venv.unitName}.service"
          ];
          wants = [
            "network-online.target"
            "${venv.unitName}.service"
          ];
          unitConfig.RequiresMountsFor = mounts;
          environment = unitEnv;
          path = rt.path;
          preStart = agentPreStart;
          serviceConfig = {
            User = user;
            Group = "users";
            WorkingDirectory = workspace;
            LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") ucfg.secretEnv;
            ExecStart = "${withSession} ${ac.hermesPackage}/bin/hermes gateway";
            # `hermes gateway restart` SIGUSR1s this main process
            # (patches/hermes-gateway-restart-foreign-unit.patch). The
            # gateway drains and exits 75 (gateway/restart.py,
            # GATEWAY_SERVICE_RESTART_EXIT_CODE); `always` relaunches it.
            Restart = "always";
            RestartSec = 5;
            UMask = "0007";
            BindPaths = userTmpBinds;
          };
        };

        # Web dashboard, a separate process upstream; it shares state
        # through HERMES_HOME. It binds its backend on loopback; the
        # root-held port (forwards.nix) bridges to it. Whether it asks for
        # a login is the managed environment's business
        # (../hermes-dashboard-public.nix turns hermes' OIDC gate on).
        "hermes-dashboard-${user}" = {
          description = "Hermes Agent web dashboard for ${user}";
          wantedBy = [ "multi-user.target" ];
          # The dashboard reads the .env the agent's preStart refreshes.
          # Wants, not Requires: an agent restart must not take the
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
          path = rt.path;
          # The agent may have written keys the dashboard must not see
          # since the agent's preStart ran (options.nix, dashboardDropEnv);
          # killing the dashboard restarts it through here. Both files
          # hermes reads keys from (hermes_cli/env_loader.py): .env, and
          # .op.env, the 1Password bootstrap it loads after .env without
          # override, so a key missing from .env would come from there.
          preStart = lib.concatMapStrings (file: ''
            ${dropEnvKeys} ${hermesHome}/${file} ${
              lib.escapeShellArg (
                lib.concatMapStringsSep "|" (k: "(?:${k})") ([ "HERMES_MANAGED(_DIR)?" ] ++ ucfg.dashboardDropEnv)
              )
            }
          '') [ ".env" ".op.env" ];
          script = ''
            exec ${withSession} ${ac.hermesPackage}/bin/hermes dashboard \
              --no-open --host 127.0.0.1 \
              --port $((${toString hlib.dashboardBackendBase} + $(id -u)))
          '';
          serviceConfig = {
            User = user;
            Group = "users";
            WorkingDirectory = workspace;
            Restart = "always";
            RestartSec = 5;
            UMask = "0007";
            BindPaths = userTmpBinds;
          };
        };
      };
    };
  users = lib.mapAttrs perUser cfg.users;
  # Static top-level option keys only. A config-dependent mkMerge list at
  # the config root would make option-key resolution depend on cfg.users,
  # and that is infinite recursion.
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList (user: _: f users.${user}) cfg.users);
  anyUser = cfg.users != { };

  hermesShim = pkgs.writeShellScriptBin "hermes" ''
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${lib.concatMapStrings (u: u.shimCaseArm) (lib.attrValues users)}
    *)
      echo "hermes: no hermes agent configured for user $u" >&2
      exit 1
      ;;
    esac
    ${pkgs.systemd}/bin/systemctl is-active --quiet "hermes-agent-$u.service" || {
      echo "hermes: hermes-agent-$u is not running (systemctl status hermes-agent-$u)" >&2
      exit 1
    }
    exec ${ac.hermesPackage}/bin/hermes "$@"
  '';
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = forEachUser (u: u.services);
    systemd.tmpfiles.rules = [
      "d ${hlib.stateRoot} 0755 root root - -"
    ]
    ++ lib.concatMap (u: u.tmpfiles) (lib.attrValues users);
    environment.systemPackages = [ hermesShim ];
    environment.extraInit = lib.mkIf anyUser (
      lib.concatMapStrings (u: u.loginInit) (lib.attrValues users)
    );
    # The venv's manylinux wheels dlopen host libraries; nix-ld serves the
    # standalone executables pip installs.
    programs.nix-ld.enable = lib.mkIf anyUser true;
    programs.nix-ld.libraries = lib.mkIf anyUser pythonVenv.nixLdLibraries;
  };
}
