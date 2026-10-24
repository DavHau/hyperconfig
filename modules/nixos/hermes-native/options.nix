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

    captchaSolver = {
      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://vit.d:8096/v1";
        description = ''
          OpenAI-compatible endpoint of the CaptchaKraken model behind the
          agents' browser_solve_captcha (the captcha plugin of their
          camofox-browser). Null: the tool answers that this browser has no
          captcha model.
        '';
      };
      model = mkOption {
        type = types.str;
        default = "CaptchaKraken/CaptchaKraken-v1.2-GGUF";
        description = ''
          Served model name. A name registered in CaptchaKraken's
          models.json also picks the prompts and pixel budget of those
          weights.
        '';
      };
    };

    ocr.baseUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://vit.d:8098";
      description = ''
        Firecrawl-Parse-compatible OCR endpoint on our own hardware
        (../ocr-server). read_file sends scanned PDFs there, and the
        agents get an `ocr` CLI and skill for images and page ranges.
        Never point this at a third-party service: documents go there
        whole. Null: read_file reports scanned pages as needing OCR.
      '';
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
            dashboardDropEnv = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "HERMES_DESKTOP" ];
              description = ''
                Keys removed from the owner's $HERMES_HOME/.env before
                every start of hermes-dashboard-<user>, as Python regular
                expressions matched against the whole key. The agent can
                write its .env, so a key that must never reach the dashboard
                goes here; HERMES_MANAGED and HERMES_MANAGED_DIR always go.
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

      # No approval gate. Cron runs and subagents have nobody to answer
      # it: a flagged command ended BLOCKED or parked as pending_approval.
      # Every command gate (tools/approval.py: check_all_command_guards,
      # check_execute_code_guard, _run_approval_gate) returns approved for
      # `off` before any prompt, LLM check or queue; the hardline floor
      # (rm -rf /, mkfs, reboot, ...) still refuses.
      approvals.mode = lib.mkDefault "off";
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
      lib.mapAttrsToList (
        user: _:
        [
          {
            assertion = config.users.users ? ${user};
            message = "services.hermes-native.users.${user}: no users.users.${user} account to run the agent as.";
          }
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (name: fwd: [
            {
              assertion = lib.count (u: fwd.portFor u == fwd.portFor user) (lib.attrNames cfg.users) == 1;
              message = "services.hermes-native: the ${name} port of ${user} (${toString (fwd.portFor user)}) collides with another agent's in its 1000-port window; widen the window in lib.nix.";
            }
            {
              # The forward lands on the backend's loopback bind. A
              # non-loopback listener would publish the agent's dashboard
              # or browser to the network.
              assertion = lib.all isLoopback config.systemd.sockets."hermes-${name}-fwd-${user}".listenStreams;
              message = "services.hermes-native: socket hermes-${name}-fwd-${user} must listen on 127.0.0.1 only.";
            }
            {
              # The bridge would accept a self-connect inside the
              # ephemeral range (lib.nix: ephemeralPortLow). An unpinned
              # uid cannot be checked here.
              assertion =
                let
                  uid = config.users.users.${user}.uid or null;
                in
                uid == null || fwd.backendBase + uid < hlib.ephemeralPortLow config.boot.kernel.sysctl;
              message = "services.hermes-native: the ${name} backend of ${user} (${toString fwd.backendBase} + uid) must stay below the ephemeral port range (${toString (hlib.ephemeralPortLow config.boot.kernel.sysctl)}+); pick a lower uid or move the window in lib.nix.";
            }
          ]) hlib.forwards
        )
      ) cfg.users
    );
  };
}
