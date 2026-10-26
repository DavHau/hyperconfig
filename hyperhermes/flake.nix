{
  description = "hyperhermes: NixOS modules that run hermes-agent for several agents on one host";

  inputs = {
    # Pinned to the same nixpkgs rev as hyperconfig's, so a consumer that
    # makes this follow its own nixpkgs changes nothing.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    hermes-agent.url = "github:NousResearch/hermes-agent/v2026.9.14";
    hermes-agent.inputs.nixpkgs.follows = "nixpkgs";
    # hermes-agent uses home-manager only for its own checks (its flake.nix
    # says so); pointing the input at this flake keeps home-manager out of
    # the lock file.
    hermes-agent.inputs.home-manager.follows = "";

    # Keeps its own nixpkgs on purpose: its derivations then hash-match what
    # numtide's CI pushed to cache.numtide.com and substitute.
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      llm-agents,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # core's default package (upstream with the wheel patches), which the
      # checks run: the dashboards' group check is one of the patches.
      hermesPackage = import ./modules/core/package.nix {
        inherit lib system hermes-agent;
      };
    in
    {
      # One module per feature; `default` imports all of them, each off
      # until enabled.
      nixosModules = {
        core = import ./modules/core { inherit hermes-agent; };
        exposure = ./modules/exposure.nix;
        sso = ./modules/sso.nix;
        browser = ./modules/browser;
        wallet = ./modules/wallet;
        teamclaude = ./modules/teamclaude.nix;
        # Not lib.modules.importApply: its wrapper module moves these
        # modules' definitions within list-typed options (PATH order,
        # ssh_config blocks) on every importer; each module names its own
        # file (`_file`) for error messages instead.
        claude-auth = import ./modules/claude-auth { inherit llm-agents; };
        desktop = import ./modules/desktop { inherit hermes-agent; };
        dashboards = ./modules/dashboards;
        publish = ./modules/publish;
        mail = ./modules/mail;
        # Agent slots (a NixOS container per agent) on container-slots,
        # which is generic (not hermes-specific) and also usable alone;
        # slots imports it.
        container-slots = ./modules/container-slots.nix;
        slots = ./modules/slots;
        default = {
          imports = [
            self.nixosModules.core
            self.nixosModules.exposure
            self.nixosModules.sso
            self.nixosModules.browser
            self.nixosModules.wallet
            self.nixosModules.teamclaude
            self.nixosModules.claude-auth
            self.nixosModules.desktop
            self.nixosModules.dashboards
            self.nixosModules.publish
            self.nixosModules.mail
            self.nixosModules.slots
          ];
        };
        # Not a feature, so not in `default`: fills core's and the
        # features' secret paths from clan vars when the importing system
        # is a clan machine.
        clan = ./modules/clan.nix;
        # The local deployment on a workstation: hyperhermes (default) in a
        # NixOS container, forwarded to the host's loopback.
        local-container = lib.modules.importApply ./modules/local-container {
          hyperhermes = self.nixosModules.default;
        };
      };

      # A workstation with the local deployment (./example).
      nixosConfigurations.example = lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.local-container
          ./example/configuration.nix
        ];
      };

      packages.${system} = {
        tcp-owner-bridge = import ./pkgs/tcp-owner-bridge { inherit pkgs; };
        # The browser feature's own builds (the module calls them with the
        # host's pkgs): Camoufox, camofox-browser with its captcha plugin,
        # and the two Python libraries a consumer's own browser tooling
        # needs, built for pkgs.python3.
        camoufox = pkgs.callPackage ./pkgs/camoufox/browser.nix { };
        camofox-browser = pkgs.callPackage ./pkgs/camofox-browser { };
        camoufox-python = pkgs.python3Packages.callPackage ./pkgs/camoufox/python.nix { };
        captchakraken-python = pkgs.python3Packages.callPackage ./pkgs/captchakraken/python.nix { };
        hermes-desktop = import ./pkgs/hermes-desktop { inherit pkgs hermes-agent; };
      };

      # For consumers that must name an agent's paths, ports or units
      # without evaluating the host that runs it (lib/core.nix: stateDir,
      # workspace, agentUnits, chain, dashboardPortFor, ...), plus:
      #   mkAgentSkill pkgs { name; src; packages; }  one skill package,
      #   pythonVenv pkgs   the agents' writable venv unit factory, and
      #   pythonPackages    its default library set, for a host the agents
      #                     ssh into (e.g. built against CUDA there).
      lib = import ./lib/core.nix { inherit lib; } // {
        mkAgentSkill = import ./lib/agent-skill.nix;
        sso = import ./lib/sso.nix { inherit lib; };
        # Generator names of nixosModules.clan (teamclaudeGenerator, ...).
        clan = import ./lib/clan.nix;
        pythonVenv =
          pkgs:
          import ./lib/python-venv.nix {
            inherit (pkgs) lib;
            inherit pkgs;
          };
        pythonPackages = import ./lib/python-packages.nix;
      };

      checks.${system} = {
        core = import ./checks/core { inherit pkgs self; };

        local-sso = import ./checks/local-sso {
          inherit pkgs self hermesPackage;
        };

        public = import ./checks/public {
          inherit pkgs self hermesPackage;
        };

        # Local mode: published ports behind the local dex, end to end.
        publish = import ./checks/publish { inherit pkgs self; };

        browser = import ./checks/browser { inherit pkgs self; };
        wallet = import ./checks/wallet { inherit pkgs self; };
        mail = import ./checks/mail { inherit pkgs self; };
        slots = import ./checks/slots { inherit pkgs self; };
        slots-local = import ./checks/slots/local.nix { inherit pkgs self; };
        # Evaluation only: teamclaude, claude-auth and desktop on a system
        # without clan, secrets as runtime paths.
        client-features = import ./checks/client-features { inherit pkgs self; };
        # Evaluation only: nixosModules.clan's generator names and the
        # secret paths they fill, against a stub clan.core.vars.
        clan-eval = import ./checks/clan-eval { inherit pkgs self; };
        # nixosModules.local-container with the example's config, from the
        # host: dashboard sign-in, a published port, the agent's slot.
        local-deployment = import ./checks/local-deployment { inherit pkgs self; };
      };
    };
}
