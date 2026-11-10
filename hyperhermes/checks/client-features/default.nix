# Evaluation-only check of teamclaude, claude-auth, desktop, rea, the
# browser's per-agent opt-out and core's shared-metrics answer and
# OpenRouter catalog setting: each
# module evaluates on a plain NixOS system (no clan; nixosModules.clan
# imported anyway, where it must do nothing) with its secrets as runtime
# path strings, and produces what its header promises. A Nix path literal
# or a store path as a secret is refused. Fails at evaluation, naming
# every expectation that does not hold.
{ pkgs, self }:
let
  inherit (pkgs) lib;

  base = {
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
  };

  evalWith =
    modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        base
        self.nixosModules.clan
      ]
      ++ modules;
    };

  failedAssertions = sys: map (a: a.message) (lib.filter (a: !a.assertion) sys.config.assertions);
  # Forces the whole system without building it: unmet assertions throw.
  evaluates = sys: lib.isString (builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath);
  # The option's value, or false if its definition is refused.
  refused = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  agentsKey = "/run/keys/alice-teamclaude";
  gateway = "https://teamclaude.example.org";

  agents = {
    alice.uid = 1001;
    bob.uid = 1002;
  };
  withAgents.services.hyperhermes.agents = agents;

  teamclaude = evalWith [
    self.nixosModules.core
    withAgents
    self.nixosModules.teamclaude
    {
      services.hyperhermes = {
        teamclaude.gatewayUrl = gateway;
        agents.alice.teamclaude = {
          enable = true;
          keyFile = agentsKey;
        };
      };
    }
  ];
  teamclaudeNoKey = evalWith [
    self.nixosModules.core
    withAgents
    self.nixosModules.teamclaude
    {
      services.hyperhermes = {
        agents.alice.teamclaude.enable = true;
      };
    }
  ];
  teamclaudePathKey = evalWith [
    self.nixosModules.core
    withAgents
    self.nixosModules.teamclaude
    {
      services.hyperhermes = {
        teamclaude.gatewayUrl = gateway;
        agents.alice.teamclaude = {
          enable = true;
          keyFile = ./default.nix;
        };
      };
    }
  ];

  claudeAuth = evalWith [
    self.nixosModules.core
    withAgents
    self.nixosModules.claude-auth
    {
      services.hyperhermes = {
        claudeAuth.enable = true;
      };
    }
  ];

  desktopConfig = {
    enable = true;
    host = "agents.example.org";
    hostLabel = "agents";
    hostKeyAlias = "agents.internal";
    domain = "example.org";
    agents = {
      alice = "Alice";
      bob = "Bob";
    };
    primary = "alice";
  };
  desktop = evalWith [
    self.nixosModules.desktop
    { services.hyperhermes.desktop = desktopConfig; }
  ];
  desktopLauncher = lib.findFirst (
    p: (p.name or "") == "hermes-desktop"
  ) null desktop.config.environment.systemPackages;
  desktopSpec = builtins.fromJSON desktopLauncher.spec.text;

  rea = evalWith [
    self.nixosModules.core
    withAgents
    self.nixosModules.rea
    { services.hyperhermes.agents.alice.rea.enable = true; }
  ];
  reaPackage = rea.config.services.hyperhermes.rea.package;
  reaServer = (agentCfg rea "alice").settings.mcp_servers.rea;

  # bob opts out of the web tools; alice keeps them.
  browser = evalWith [
    self.nixosModules.core
    withAgents
    self.nixosModules.browser
    {
      services.hyperhermes = {
        browser = {
          enable = true;
          ocr.baseUrl = "http://ocr.example.org:8098";
        };
        agents.bob.browser.enable = false;
      };
    }
  ];
  browserUnits = sys: name: [
    (sys.config.systemd.services ? "hermes-camofox-${name}")
    (sys.config.systemd.sockets ? "hermes-camofox-fwd-${name}")
  ];

  # The settings core writes to each agent's config.yaml (the managed one
  # and the merged one, or the pinned one of a lockedConfig agent): bob is
  # locked and has settings of his own.
  telemetry = evalWith [
    self.nixosModules.core
    withAgents
    {
      services.hyperhermes.agents.bob = {
        lockedConfig = true;
        settings.terminal.timeout = 60;
      };
    }
  ];
  agentSettingsOf =
    sys: name:
    (import ../../modules/core/agent-config.nix {
      inherit lib pkgs;
      hlib = import ../../lib/core.nix { inherit lib; };
      cfg = sys.config.services.hyperhermes;
    }).agentSettings
      name
      (agentCfg sys name);

  # Everything imported, nothing enabled: no agent, no launcher.
  idle = evalWith [ self.nixosModules.default ];

  hasPackageNamed =
    sys: name: lib.any (p: (p.pname or p.name or "") == name) sys.config.environment.systemPackages;
  agentCfg = sys: name: sys.config.services.hyperhermes.agents.${name};

  expectations = {
    teamclaude-evaluates = evaluates teamclaude && failedAssertions teamclaude == [ ];
    teamclaude-token-from-keyFile = (agentCfg teamclaude "alice").secretEnv.ANTHROPIC_TOKEN == agentsKey;
    teamclaude-base-url = (agentCfg teamclaude "alice").environment.ANTHROPIC_BASE_URL == gateway;
    teamclaude-other-agent-untouched =
      !((agentCfg teamclaude "bob").secretEnv ? ANTHROPIC_TOKEN)
      && !((agentCfg teamclaude "bob").environment ? ANTHROPIC_BASE_URL);
    teamclaude-needs-key-and-gateway = lib.length (failedAssertions teamclaudeNoKey) == 2;
    teamclaude-refuses-path-literal = refused (agentCfg teamclaudePathKey "alice").teamclaude.keyFile;

    claude-auth-evaluates = evaluates claudeAuth && failedAssertions claudeAuth == [ ];
    claude-auth-pythonpath =
      lib.all (
        unit:
        lib.hasSuffix "-hermes-claude-auth-site" claudeAuth.config.systemd.services.${unit}.environment.PYTHONPATH
      ) (lib.concatMap (u: [ "hermes-agent-${u}" "hermes-dashboard-${u}" ]) (lib.attrNames agents));
    claude-auth-claude-stub-on-agent-path = lib.any (
      p: p.name == "claude"
    ) claudeAuth.config.services.hyperhermes.extraPackages;
    # Exactly one profile more than the same system without claude-auth:
    # the hooked `hermes` wrapper (NixOS fills the list on its own).
    claude-auth-host-shim =
      let
        added = lib.subtractLists (evalWith [
          self.nixosModules.core
          withAgents
        ]).config.environment.profiles claudeAuth.config.environment.profiles;
      in
      lib.length added == 1 && lib.hasSuffix "-hermes" (lib.head added);

    desktop-evaluates = evaluates desktop && failedAssertions desktop == [ ];
    desktop-launchers =
      hasPackageNamed desktop "hermes-desktop"
      && hasPackageNamed desktop "hermes-desktop.desktop"
      && hasPackageNamed desktop "hermes-tui-alice.desktop"
      && hasPackageNamed desktop "hermes-tui-bob.desktop";
    # The app dials each agent's hosted dashboard with OAuth.
    desktop-dashboard-urls = desktopSpec == {
      primary = "alice";
      remotes = {
        alice = {
          label = "Alice";
          url = "https://alice.example.org";
        };
        bob = {
          label = "Bob";
          url = "https://bob.example.org";
        };
      };
    };
    # No ssh plumbing for the app: no key copy, no alias.
    desktop-no-app-ssh =
      !(desktop.config.system.activationScripts ? hermes-desktop-ssh)
      && !(lib.hasInfix "hermes-desktop-" desktop.config.programs.ssh.extraConfig);

    rea-evaluates = evaluates rea && failedAssertions rea == [ ];
    # node on REA's entry script; every tool setting is a store path.
    rea-mcp-server =
      lib.hasSuffix "/bin/node" reaServer.command
      && reaServer.args == [
        reaPackage.entrypoint
        "mcp"
      ]
      && reaServer.env.GHIDRA_INSTALL_DIR == "${pkgs.ghidra}/lib/ghidra"
      && lib.all (lib.hasPrefix builtins.storeDir) (
        lib.attrValues (removeAttrs reaServer.env [ "REA_ANALYSIS_PROVIDER" ])
      );
    rea-skill-and-cli =
      lib.any (d: lib.hasSuffix "-agent-skill-reverse-engineer-anything/share/skills" d) (agentCfg rea "alice").skillDirs
      && lib.any (p: p.name == "rea-${reaPackage.version}") (agentCfg rea "alice").extraPackages;
    rea-other-agent-untouched =
      !((agentCfg rea "bob").settings ? mcp_servers) && (agentCfg rea "bob").skillDirs == [ ];

    browser-evaluates = evaluates browser && failedAssertions browser == [ ];
    browser-agent-gets-the-tools =
      let
        a = agentCfg browser "alice";
      in
      a.settings.browser.cloud_provider == "camofox"
      && a.settings.web.search_backend == "searxng"
      && lib.sort lib.lessThan a.settings.plugins.enabled == [
        "camofox"
        "web-local-extract"
      ]
      && a.settings.plugins.auto_apply == false
      && a.settings.webapp.enabled == false
      && a.settings.agent.disabled_toolsets == [
        "browser-use"
        "browser-cdp"
      ]
      && a.settings.file_tools.hosted_ocr_url == "http://ocr.example.org:8098"
      && a.environment ? SEARXNG_URL
      && lib.length a.skillDirs == 2
      && lib.any (p: p.name == "ocr") a.extraPackages
      && browserUnits browser "alice" == [
        true
        true
      ];
    browser-opted-out-agent-gets-none =
      let
        b = agentCfg browser "bob";
      in
      lib.all (k: !(b.settings ? ${k})) [
        "browser"
        "web"
        "plugins"
        "file_tools"
        "agent"
      ]
      && !(b.environment ? SEARXNG_URL)
      && b.skillDirs == [ ]
      && b.extraPackages == [ ]
      && browserUnits browser "bob" == [
        false
        false
      ];

    telemetry-evaluates = evaluates telemetry && failedAssertions telemetry == [ ];
    # Shared metrics off and the offer answered "No thanks" at the current
    # offer_version, so no surface asks (core's options.nix).
    telemetry-answered-no = lib.all (
      name:
      (agentSettingsOf telemetry name).telemetry.shared_metrics == {
        enabled = false;
        send = false;
        offer_version = 2;
      }
    ) (lib.attrNames agents);

    # The OpenRouter picker lists every tool-capable model, curated
    # first (core's options.nix, patches/hermes-openrouter-all-models.patch).
    openrouter-all-models = lib.all (
      name: (agentSettingsOf telemetry name).model_catalog.openrouter_all_models == true
    ) (lib.attrNames agents);

    idle-evaluates = evaluates idle && failedAssertions idle == [ ];
    idle-adds-nothing =
      !(hasPackageNamed idle "hermes-desktop")
      && !(idle.config.system.activationScripts ? hermes-desktop-ssh)
      && idle.config.environment.profiles == (evalWith [ ]).config.environment.profiles;
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) expectations);
in
if failed != [ ] then
  throw "hyperhermes client-features: failed expectations: ${lib.concatStringsSep ", " failed}"
else
  pkgs.runCommand "hyperhermes-client-features" { } ''
    echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames expectations))} > $out
  ''
