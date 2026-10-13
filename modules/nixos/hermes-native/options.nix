# Options of the native agents and the host-wide defaults every agent's
# config.yaml carries. Vendored from spaces 6d744780
# modules/nixos/hermes/options.nix (native subset: no VM sizing, GPU,
# hostPorts, remote keys or auto-provisioning; every user is declared).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };
  # spaces' provider modules; `or` keeps a host without them evaluating.
  orCfg = config.spaces.openrouter or { enable = false; };
  infCfg = config.spaces.inference or { enable = false; };
  llamaOn = config.services.llama-swap.enable or false;
  llamaPort = config.services.llama-swap.port or 8012;
  microvmOn = config.services.hermes-microvm.enable or false;

  # Repos the agent may APPLY, declared system-wide by spaces
  # modules/nixos/spaces-integrations/nixos-apply.nix. `or { }` because a
  # host may run agents without spaces-integrations.
  applyRepos = config.services.spaces-integrations.nixos.repos or { };

  # One user's config repos. A repo the agent may activate is a repo the
  # agent must be able to read and edit, so an apply repo inside this
  # user's home counts like `nixosConfigDir`. The home check keeps one
  # user's repo away from another user's agent.
  configReposFor =
    user: ucfg:
    let
      apply = lib.mapAttrs (_: r: r.path) (lib.filterAttrs (_: r: hlib.inHomeOf user r.path) applyRepos);
      explicit = lib.optional (ucfg.nixosConfigDir != null) (hlib.configRepoDir user ucfg.nixosConfigDir);
    in
    {
      inherit apply;
      dirs = lib.unique (explicit ++ lib.attrValues apply);
      # The repo `$NIXOS_CONFIG_DIR` names: an explicit `nixosConfigDir`
      # wins, else the first apply repo by name.
      primary = lib.head (explicit ++ lib.attrValues apply ++ [ null ]);
    };
  dashboardSockets = lib.filterAttrs (
    name: _: lib.hasPrefix "hermes-dashboard-fwd-" name
  ) config.systemd.sockets;
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
      defaultText = literalExpression ''
        spaces.inference when enabled, else the local llama-swap endpoint
        when services.llama-swap.enable, else null.
      '';
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

    extraPlugins = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Hermes plugin packages (each with a plugin.yaml), linked into every agent's plugins dir.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Packages on the agent's PATH, in addition to the built-in toolset.";
    };

    pythonPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      description = "Python libraries in every agent's writable venv.";
      default =
        ps: with ps; [
          numpy
          scipy
          sympy
          pandas
          polars
          pyarrow
          duckdb
          matplotlib
          seaborn
          scikit-learn
          statsmodels
          networkx
          numba
          pillow
          tqdm
          torch
          transformers
          pypdf
          openpyxl
          python-docx
          # nixpkgs `arxiv` currently fails its runtime-deps check. The
          # agent can `pip install arxiv` into the venv when needed.
          wikipedia
          requests
          httpx
          aiohttp
          beautifulsoup4
          lxml
          html5lib
          feedparser
          trafilatura
          scrapy
          pyyaml
          rich
          ipython
        ];
    };

    simplex = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Control the agent over SimpleX Chat. Every agent runs its own
          simplex-chat daemon and SimpleX profile, and the hermes gateway
          loads its simplex platform plugin from SIMPLEX_WS_URL.

          The profile has no contacts on the first start. Its address
          lands in ~/hermes/simplex-address.txt (`hermes-simplex-qr`
          shows it). Connect to that address, send the agent a message,
          and approve the pairing code it answers with:
          `hermes pairing approve simplex <CODE>`. Avoid
          `SIMPLEX_ALLOWED_USERS`: a display-name entry is spoofable by
          any contact (upstream #44729), and a contactId entry dies on
          every re-pair.
        '';
      };

      displayName = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = literalExpression ''"hermes-<user>"'';
        description = ''
          Profile name that SimpleX contacts see. The daemon writes it
          once, when it creates the profile.
        '';
      };
    };

    users = mkOption {
      default = { };
      description = ''
        Users whose agent runs unsandboxed on the host, as the user's own
        account: it reaches the whole home directory, the session bus and
        every host tool. Each account must exist in users.users.
      '';
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Whether this user's agent runs.";
              };
              dashboardPort = mkOption {
                type = types.port;
                default = hlib.dashboardPortFor name;
                defaultText = literalExpression "22100 + lib.mod (identityHash name) 1000";
                description = ''
                  Root-held 127.0.0.1 port forwarded to the user's dashboard
                  (hash-derived; override on the rare window collision,
                  which the eval assertion names).
                '';
              };
              simplexPort = mkOption {
                type = types.port;
                default = hlib.simplexPortFor name;
                defaultText = literalExpression "24100 + lib.mod (identityHash name) 1000";
                description = ''
                  Root-held 127.0.0.1 port of this user's SimpleX websocket.
                  A root socket unit holds it and forwards to the user's
                  own daemon. Hash-derived; override on the rare window
                  collision, which the eval assertion names.
                '';
              };
              environment = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Per-user non-secret env vars, managed keys of the agent's .env.";
              };
              secretEnv = mkOption {
                type = types.attrsOf types.str;
                default =
                  lib.optionalAttrs (orCfg.enable && orCfg.apiKeyFile != null) {
                    OPENROUTER_API_KEY = toString orCfg.apiKeyFile;
                  }
                  // lib.optionalAttrs (infCfg.enable && infCfg.apiKeyFile != null) {
                    ${infCfg.keyEnv} = toString infCfg.apiKeyFile;
                  };
                defaultText = literalExpression "The key files of the enabled providers: { OPENROUTER_API_KEY = spaces.openrouter.apiKeyFile; \${spaces.inference.keyEnv} = spaces.inference.apiKeyFile; }";
                description = ''
                  Env var name -> host file path (raw secret value, no KEY=
                  prefix). Each entry rides a systemd credential into
                  hermes-agent-<user> and is rewritten into the owner's
                  0600 $HERMES_HOME/.env before the agent starts. It never
                  enters the store. Defining this replaces the provider
                  defaults.
                '';
              };
              spacesGateway.enable = mkOption {
                type = types.bool;
                default = config.services.spaces-integrations.enable or false;
                defaultText = literalExpression "config.services.spaces-integrations.enable";
                description = ''
                  Hand the agent the user's spaces integration gateway (the
                  per-user socket /run/user/<uid>/spaces-integration-gateway.sock)
                  as the `spaces` MCP server, and linger the user so the
                  socket exists from boot.
                '';
              };
              nixosConfigDir = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Path of this user's NixOS configuration repo, relative to
                  the home directory. The agent edits it in place
                  ($NIXOS_CONFIG_DIR). To let the agent also check and
                  apply it, declare the repo in
                  `services.spaces-integrations.nixos.repos` instead. The
                  directory must exist before the agent starts.
                '';
              };
            };
          }
        )
      );
    };

    enabledUsers = mkOption {
      internal = true;
      readOnly = true;
      type = types.attrsOf types.raw;
      description = "users filtered to enabled entries. Every per-user loop iterates this.";
    };

    managedDirs = mkOption {
      internal = true;
      readOnly = true;
      type = types.attrsOf types.package;
      description = ''
        Per user, the Hermes managed-scope directory (config.yaml and
        .env) that HERMES_MANAGED_DIR names. `passthru.settings` is the
        settings JSON, `passthru.envText` the .env text.
      '';
    };

    configRepos = mkOption {
      internal = true;
      readOnly = true;
      type = types.attrsOf types.raw;
      description = ''
        Per user, the NixOS configuration repos the agent edits:
        `{ dirs = [ <abs> ]; apply = { <repo> = <abs>; }; primary = <abs> | null; }`.
        `users.<u>.nixosConfigDir` and every
        `services.spaces-integrations.nixos.repos.<name>` inside that
        user's home feed it; only the latter appear in `apply`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.hermes-native.enabledUsers = lib.filterAttrs (_: u: u.enable) cfg.users;
    services.hermes-native.configRepos = lib.mapAttrs configReposFor cfg.users;

    # The configured remote provider wins the seed. A desktop also runs
    # llama-swap, and the local g9v3:3b is the fallback, not the choice.
    services.hermes-native.initialModel = lib.mkDefault (
      if infCfg.enable then
        {
          provider = infCfg.name;
          base_url = infCfg.baseUrl;
          default = infCfg.model;
        }
      else if llamaOn then
        {
          provider = "custom";
          base_url = "http://127.0.0.1:${toString llamaPort}/v1";
          default = "g9v3:3b";
        }
      else
        null
    );

    # mkIf wraps the whole definition; a leaf-level mkIf false leaves
    # empty providers.llama-swap parents behind.
    services.hermes-native.settings = lib.mkMerge [
      (lib.mkIf llamaOn {
        providers.llama-swap.base_url = lib.mkDefault "http://127.0.0.1:${toString llamaPort}/v1";
      })
      (lib.mkIf infCfg.enable {
        # hermes resolves the key from the env var named here, then dials
        # base_url (hermes_cli/runtime_provider.py,
        # `_get_named_custom_provider`). The key itself never enters the
        # store: secretEnv rides the file in as a credential.
        providers.${infCfg.name} = {
          base_url = lib.mkDefault infCfg.baseUrl;
          key_env = lib.mkDefault infCfg.keyEnv;
          default_model = lib.mkDefault infCfg.model;
        };
      })
      {
        # spaces ships its own Signal integration (reached through the
        # spaces gateway MCP bridge). Two Signal surfaces confuse the user,
        # so the Hermes signal-cli channel is pinned off. The explicit
        # `enabled: false` survives upstream's env-override pass
        # (gateway/config.py, `_enabled_explicit`).
        platforms.signal.enabled = lib.mkDefault false;

        # hermes copies its bundled skills into ~/.hermes/skills on every
        # start; productivity/maps declares `name: maps`, and spaces ships
        # `osm-maps` for the same job. Two skills of one name make
        # skill_view refuse both ("Ambiguous skill name",
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
      }
    ];

    assertions = [
      {
        assertion = !(cfg.settings ? model);
        message = "services.hermes-native.settings.model is re-merged into config.yaml on EVERY start and would clobber the user's runtime model choice. Use services.hermes-native.initialModel (seed-once) instead.";
      }
      {
        # Both modules own the hermes-firewall unit and its hermes-microvm
        # chain (the second flush would drop the first module's rules), the
        # hermes-dashboard-fwd-<user> sockets and the state vaults.
        assertion = !microvmOn;
        message = "services.hermes-native and services.hermes-microvm (spaces) are both enabled. They share the hermes-firewall unit, the dashboard forward sockets and the state vaults under /var/lib/hermes-microvm; enable one of them per host.";
      }
    ]
    ++ lib.mapAttrsToList (user: _: {
      assertion = config.users.users ? ${user};
      message = "services.hermes-native.users.${user}: no users.users.${user} account to run the agent as.";
    }) cfg.enabledUsers
    ++ lib.mapAttrsToList (name: sock: {
      assertion = lib.all isLoopback sock.listenStreams;
      message = ''
        services.hermes-native: socket ${name} listens on ${lib.concatStringsSep " " sock.listenStreams}. It must stay on 127.0.0.1.
        The forward lands on the dashboard's loopback bind, whose only check is a local uid match. That check means nothing to a remote peer, so a non-loopback listener publishes an unauthenticated agent dashboard.
      '';
    }) dashboardSockets
    ++ lib.mapAttrsToList (user: ucfg: {
      assertion =
        !ucfg.enable
        || lib.count (u: u.enable && u.dashboardPort == ucfg.dashboardPort) (lib.attrValues cfg.users) == 1;
      message = "services.hermes-native: duplicate dashboardPort ${toString ucfg.dashboardPort} (${user}) — the hash-derived default collided in its 1000-port window; set services.hermes-native.users.<name>.dashboardPort explicitly on one of them.";
    }) cfg.users
    ++ lib.mapAttrsToList (user: ucfg: {
      assertion =
        ucfg.nixosConfigDir == null
        || (
          builtins.match "[A-Za-z0-9._][A-Za-z0-9._/-]*" ucfg.nixosConfigDir != null
          && !(lib.hasInfix ".." ucfg.nixosConfigDir)
          && !(lib.elem "." (lib.splitString "/" ucfg.nixosConfigDir))
        );
      message = "services.hermes-native.users.${user}.nixosConfigDir = \"${toString ucfg.nixosConfigDir}\": must name a relative path to a directory INSIDE the home directory, never the home itself. The value reaches a shell script, so it must not be empty or absolute, and it must hold no \"..\", no space and no shell metacharacter.";
    }) cfg.users
    # The simplex websockets share the host loopback, so their ports must
    # differ.
    ++ lib.mapAttrsToList (user: ucfg: {
      assertion =
        !ucfg.enable
        || lib.count (u: u.enable && u.simplexPort == ucfg.simplexPort) (lib.attrValues cfg.users) == 1;
      message = "services.hermes-native: duplicate simplexPort ${toString ucfg.simplexPort} (${user}) — the hash-derived default collided in its 1000-port window; set services.hermes-native.users.<name>.simplexPort explicitly on one of them.";
    }) cfg.users;
  };
}
