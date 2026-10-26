# The agent registry `services.hyperhermes.agents` and the host-wide
# collection points every agent's config.yaml, .env and PATH carry.
# Feature modules extend the per-agent submodule by redeclaring `agents`
# with options of their own, and contribute through the collection points
# (settings, environment, extraPackages, skillDirs, forwards).
{ hermes-agent }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  hlib = import ../../lib/core.nix { inherit lib; };
  isLoopback = addr: lib.hasPrefix "127.0.0.1:" addr || lib.hasPrefix "[::1]:" addr;
  inStore = path: lib.hasPrefix builtins.storeDir (toString path);
  yaml = pkgs.formats.yaml { };

  # Keys that are both host-wide and per agent.
  sharedOptions = with lib; {
    settings = mkOption {
      inherit (yaml) type;
      default = { };
      description = "Hermes settings, managed (locked) keys of the agent's config.yaml.";
    };
    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Non-secret env vars, managed (locked) keys of the agent's .env.
        Features define their entries with lib.mkDefault; operator
        definitions win.
      '';
    };
    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Packages on the agent's PATH, in addition to the built-in toolset.";
    };
    skillDirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = lib.literalExpression ''[ "''${mySkill}/share/skills" ]'';
      description = ''
        Skill roots (directories of <name>/SKILL.md) the agent reads, as
        hermes' skills.external_dirs. A skill's name must be unique across
        every root, hermes' bundled skills included, or skill_view refuses
        both copies as ambiguous.
      '';
    };
  };
in
{
  options.services.hyperhermes =
    with lib;
    {
      package = mkOption {
        type = types.package;
        default = import ./package.nix {
          inherit lib hermes-agent;
          inherit (pkgs.stdenv.hostPlatform) system;
        };
        defaultText = literalMD "hermes-agent from this flake's input, with the wheel patches in modules/core/patches";
        description = "The hermes package every agent runs.";
      };

      pythonPackages = mkOption {
        type = types.functionTo (types.listOf types.package);
        default = import ../../lib/python-packages.nix;
        defaultText = literalExpression "hyperhermes.lib.pythonPackages";
        description = ''
          Python libraries in every agent's writable venv
          (<stateDir>/.venv), as a `python.withPackages` argument. The agent
          pip-installs anything else on top.
        '';
      };

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

      perUserTmp = mkOption {
        type = types.bool;
        default = false;
        description = ''
          The host gives every user a private /tmp and /var/tmp instance at
          /tmp/.inst/<user> and /var/tmp/.inst/<user> (as pam_namespace
          does). The agent units then bind the owner's instances, so the
          agent sees the /tmp of the owner's own sessions. A missing
          instance stops the unit instead of quietly putting it on the
          shared /tmp.
        '';
      };

      sshKeyHosts = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "gpu.example" ];
        description = ''
          ssh_config host patterns an agent reaches with its own key
          (agents.<name>.sshKeyFile), and only that key.
        '';
      };

      forwards = mkOption {
        internal = true;
        default = { };
        description = ''
          Root-held loopback ports per agent, each bridged per connection to
          a backend the owner binds at backendBase + uid, and owner-only in
          the firewall. Core declares the dashboard's; features add theirs.
        '';
        type = types.attrsOf (
          types.submodule {
            options = {
              label = mkOption {
                type = types.str;
                description = "Name in the unit descriptions.";
              };
              portFor = mkOption {
                type = types.functionTo types.port;
                description = "Agent name -> its root-held port.";
              };
              backendBase = mkOption {
                type = types.port;
                description = "The owner's backend listens on backendBase + uid.";
              };
            };
          }
        );
      };

      tcpOwnerBridge = mkOption {
        type = types.package;
        readOnly = true;
        default = import ../../pkgs/tcp-owner-bridge { inherit pkgs; };
        defaultText = literalExpression "hyperhermes.packages.<system>.tcp-owner-bridge";
        description = "The owner-checking per-connection bridge, for features that publish more owner-bound ports.";
      };

      agents = mkOption {
        default = { };
        description = ''
          Hermes agents on this host, by account name. Each runs natively as
          a login account of its own: it reaches the whole home directory,
          the session bus and every host tool of that account.
        '';
        type = types.attrsOf (
          types.submodule {
            options = sharedOptions // {
              uid = mkOption {
                type = types.int;
                description = ''
                  The agent account's uid. Backend ports derive from it, and
                  a host the agents ssh into gives the agent the same uid.
                '';
              };
              description = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Account description; null leaves it to another module.";
              };
              sshKeys = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "SSH keys that log in as the agent account (hermes CLI, hermes-desktop).";
              };
              secretEnv = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = ''
                  Env var name -> host file path (raw secret value, no KEY=
                  prefix), read at runtime. Each entry rides a systemd
                  credential into hermes-agent-<name> and is rewritten into
                  the owner's $HERMES_HOME/.env before the agent starts. It
                  never enters the store; restart the unit after a rotation.
                '';
              };
              dashboardDropEnv = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [ "HERMES_DESKTOP" ];
                description = ''
                  Keys removed from the owner's $HERMES_HOME/.env before
                  every start of hermes-dashboard-<name>, as Python regular
                  expressions matched against the whole key. The agent can
                  write its .env, so a key that must never reach the dashboard
                  goes here; HERMES_MANAGED and HERMES_MANAGED_DIR always go.
                '';
              };
              sshKeyFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Runtime path of the agent's own ssh private key, readable by
                  the agent only. Used for the hosts in
                  services.hyperhermes.sshKeyHosts.
                '';
              };
            };
          }
        );
      };
    }
    // sharedOptions;

  config = lib.mkIf (cfg.agents != { }) {
    services.hyperhermes = {
      settings = {
        # hermes copies its bundled skills into ~/.hermes/skills on every
        # start; productivity/maps declares `name: maps`, and host skill
        # roots ship their own maps skill for the same job. Two skills of
        # one name make skill_view refuse both ("Ambiguous skill name",
        # tools/skills_tool.py), so the bundled copy is disabled. The list
        # CONCATENATES with an operator's entries; re-enabling needs
        # lib.mkForce.
        skills.disabled = [ "maps" ];

        # No approval gate. Cron runs and subagents have nobody to answer
        # it: a flagged command ended BLOCKED or parked as pending_approval.
        # Every command gate (tools/approval.py: check_all_command_guards,
        # check_execute_code_guard, _run_approval_gate) returns approved for
        # `off` before any prompt, LLM check or queue; the hardline floor
        # (rm -rf /, mkfs, reboot, ...) still refuses.
        approvals.mode = lib.mkDefault "off";
      };

      forwards.dashboard = {
        label = "Dashboard";
        portFor = hlib.dashboardPortFor;
        backendBase = hlib.dashboardBackendBase;
      };
    };

    assertions = [
      {
        assertion = lib.allUnique (lib.mapAttrsToList (_: a: a.uid) cfg.agents);
        message = "services.hyperhermes.agents: two agents share a uid.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: a:
        [
          {
            assertion = !(cfg.settings ? model) && !(a.settings ? model);
            message = "services.hyperhermes.agents.${user}: settings.model is re-merged into config.yaml on EVERY start and would clobber the user's runtime model choice. Use services.hyperhermes.initialModel (seed-once) instead.";
          }
          {
            assertion =
              !lib.any inStore (lib.attrValues a.secretEnv ++ lib.optional (a.sshKeyFile != null) a.sshKeyFile);
            message = "services.hyperhermes.agents.${user}: secretEnv and sshKeyFile must be runtime paths outside the Nix store; the store is world-readable.";
          }
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (name: fwd: [
            {
              assertion = lib.count (u: fwd.portFor u == fwd.portFor user) (lib.attrNames cfg.agents) == 1;
              message = "services.hyperhermes: the ${name} port of ${user} (${toString (fwd.portFor user)}) collides with another agent's in its 1000-port window; widen the window in lib/core.nix.";
            }
            {
              # The forward lands on the backend's loopback bind. A
              # non-loopback listener would publish the agent's dashboard
              # or browser to the network.
              assertion = lib.all isLoopback config.systemd.sockets."hermes-${name}-fwd-${user}".listenStreams;
              message = "services.hyperhermes: socket hermes-${name}-fwd-${user} must listen on 127.0.0.1 only.";
            }
            {
              # The bridge would accept a self-connect inside the
              # ephemeral range (lib/core.nix: ephemeralPortLow).
              assertion = fwd.backendBase + a.uid < hlib.ephemeralPortLow config.boot.kernel.sysctl;
              message = "services.hyperhermes: the ${name} backend of ${user} (${toString fwd.backendBase} + uid) must stay below the ephemeral port range (${toString (hlib.ephemeralPortLow config.boot.kernel.sysctl)}+); pick a lower uid or move the window in lib/core.nix.";
            }
          ]) cfg.forwards
        )
      ) cfg.agents
    );
  };
}
