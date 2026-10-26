# Evaluation-only check of teamclaude, claude-auth and desktop: each
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
  desktopKey = "/run/keys/hermes-desktop";

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
    agents = {
      alice = "Alice";
      bob = "Bob";
    };
    primary = "alice";
    users = [ "carol" ];
    sshKeyFile = desktopKey;
  };
  desktopWith =
    extra:
    evalWith [
      self.nixosModules.desktop
      {
        users.users.carol.isNormalUser = true;
        services.hyperhermes.desktop = desktopConfig // extra;
      }
    ];
  desktop = desktopWith { };
  desktopStoreKey = desktopWith { sshKeyFile = "${pkgs.writeText "key" ""}"; };
  desktopPathKey = desktopWith { sshKeyFile = ./default.nix; };

  # Everything imported, nothing enabled: no agent, no launcher.
  idle = evalWith [ self.nixosModules.default ];

  hasPackageNamed =
    sys: name: lib.any (p: (p.pname or p.name or "") == name) sys.config.environment.systemPackages;
  agentCfg = sys: name: sys.config.services.hyperhermes.agents.${name};
  activation = desktop.config.system.activationScripts.hermes-desktop-ssh.text;

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
    claude-auth-claude-on-agent-path = lib.any (
      p: p.pname or "" == "claude-code"
    ) claudeAuth.config.services.hyperhermes.extraPackages;
    claude-auth-host-shim = lib.length claudeAuth.config.environment.profiles > 0;

    desktop-evaluates = evaluates desktop && failedAssertions desktop == [ ];
    desktop-launchers =
      hasPackageNamed desktop "hermes-desktop"
      && hasPackageNamed desktop "hermes-desktop.desktop"
      && hasPackageNamed desktop "hermes-tui-alice.desktop"
      && hasPackageNamed desktop "hermes-tui-bob.desktop";
    desktop-ssh-alias =
      lib.hasInfix "Host hermes-desktop-agents\n  HostName agents.example.org\n" desktop.config.programs.ssh.extraConfig
      && lib.hasInfix "  HostKeyAlias agents.internal\n" desktop.config.programs.ssh.extraConfig;
    desktop-key-copied = lib.hasInfix "install -m 0400 -o carol -g root ${desktopKey} /run/hermes-desktop-ssh/carol" activation;
    desktop-refuses-store-key = failedAssertions desktopStoreKey != [ ];
    desktop-refuses-path-literal = refused desktopPathKey.config.services.hyperhermes.desktop.sshKeyFile;

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
