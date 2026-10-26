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
      ...
    }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # One module per feature; `default` imports all of them, each off
      # until enabled.
      nixosModules = {
        core = import ./modules/core { inherit hermes-agent; };
        exposure = ./modules/exposure.nix;
        sso = ./modules/sso.nix;
        browser = ./modules/browser;
        default = {
          imports = [
            self.nixosModules.core
            self.nixosModules.exposure
            self.nixosModules.sso
            self.nixosModules.browser
          ];
        };
        # Not a feature, so not in `default`: fills core's secret paths
        # from clan vars when the importing system is a clan machine.
        clan = ./modules/clan.nix;
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
          inherit pkgs self;
          hermesPackage = hermes-agent.packages.${system}.minimal;
        };

        browser = import ./checks/browser { inherit pkgs self; };
      };
    };
}
