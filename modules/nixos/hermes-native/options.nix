# Options of the native agents and the host-wide defaults every agent's
# config.yaml carries.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };
  isLoopback = addr: lib.hasPrefix "127.0.0.1:" addr || lib.hasPrefix "[::1]:" addr;
in
{
  options.services.hermes-native = with lib; {
    enable = mkEnableOption "per-user Hermes agents running natively on the host";

    initialModel = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            provider = mkOption {
              type = types.str;
              description = "Provider name of the model.";
            };
            base_url = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "OpenAI-compatible endpoint of the provider. Null omits the base_url key.";
            };
            default = mkOption {
              type = types.str;
              description = "Model id inside that provider.";
            };
          };
        }
      );
      default = null;
      description = ''
        Seed-once model. preStart writes it into config.yaml only when no
        model is configured there, so the user's runtime /model switches
        persist. NEVER set settings.model (asserted): it is re-merged on
        every start and would clobber the choice.
      '';
    };

    settings = mkOption {
      inherit ((pkgs.formats.yaml { })) type;
      default = { };
      description = "Hermes settings, the managed (locked) keys of every agent's config.yaml.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Non-secret env vars, the managed (locked) keys of every agent's
        .env. Integrations define their entries with lib.mkDefault;
        operator definitions win.
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Packages on the agent's PATH, in addition to the built-in toolset.";
    };

    users = mkOption {
      default = { };
      description = ''
        Users whose agent runs unsandboxed on the host, as the user's own
        account: it reaches the whole home directory, the session bus and
        every host tool. Each account must exist in users.users.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            environment = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Per-user non-secret env vars, managed keys of the agent's .env.";
            };
            secretEnv = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = ''
                Env var name -> host file path (raw secret value, no KEY=
                prefix). Each entry rides a systemd credential into
                hermes-agent-<user> and is rewritten into the owner's
                0600 $HERMES_HOME/.env before the agent starts. It never
                enters the store.
              '';
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    services.hermes-native.settings = {
      # The spaces integration gateway carries its own Signal integration.
      # Two Signal surfaces confuse the user, so the Hermes signal-cli
      # channel is pinned off. The explicit `enabled: false` survives
      # upstream's env-override pass (gateway/config.py,
      # `_enabled_explicit`).
      platforms.signal.enabled = lib.mkDefault false;

      # hermes copies its bundled skills into ~/.hermes/skills on every
      # start; productivity/maps declares `name: maps`, and the spaces
      # skill root ships `osm-maps` for the same job. Two skills of one
      # name make skill_view refuse both ("Ambiguous skill name",
      # tools/skills_tool.py), so the bundled copy is disabled. The list
      # CONCATENATES with an operator's entries; re-enabling needs
      # lib.mkForce.
      skills.disabled = [ "maps" ];

      # The agent snapshots its tool registry when it is built, and MCP
      # discovery only gets a bounded head start (1.5s interactive, 15s
      # for a single query, hermes_cli/config_defaults.py). The spaces
      # gateway can take longer, and the first turn then carries no
      # mcp__spaces__* tool at all. `thread.join(timeout)` returns the
      # instant discovery finishes, so a wider bound costs a fast host
      # nothing.
      mcp_discovery_timeout = lib.mkDefault 30;
      mcp_single_query_discovery_timeout = lib.mkDefault 30;
    };

    assertions = [
      {
        assertion = !(cfg.settings ? model);
        message = "services.hermes-native.settings.model is re-merged into config.yaml on EVERY start and would clobber the user's runtime model choice. Use services.hermes-native.initialModel (seed-once) instead.";
      }
      {
        # spaces' microVM module defines the same hermes-firewall unit.
        assertion = !(config.services.hermes-microvm.enable or false);
        message = "services.hermes-native and spaces' services.hermes-microvm both define the hermes-firewall unit; set services.hermes-microvm.enable = false.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (user: _: [
        {
          assertion = config.users.users ? ${user};
          message = "services.hermes-native.users.${user}: no users.users.${user} account to run the agent as.";
        }
        {
          assertion =
            lib.count (u: hlib.dashboardPortFor u == hlib.dashboardPortFor user) (lib.attrNames cfg.users) == 1;
          message = "services.hermes-native: the dashboard port of ${user} (${toString (hlib.dashboardPortFor user)}) collides with another agent's in its 1000-port window; widen the window in lib.nix.";
        }
        {
          # The forward lands on the dashboard's loopback bind, which
          # serves anyone who reaches it. A non-loopback listener would
          # publish an unauthenticated agent dashboard.
          assertion = lib.all isLoopback config.systemd.sockets."hermes-dashboard-fwd-${user}".listenStreams;
          message = "services.hermes-native: socket hermes-dashboard-fwd-${user} must listen on 127.0.0.1 only.";
        }
      ]) cfg.users
    );
  };
}
