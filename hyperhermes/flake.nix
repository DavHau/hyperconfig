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
        core = ./modules/core.nix;
        exposure = ./modules/exposure.nix;
        sso = ./modules/sso.nix;
        default = {
          imports = [
            self.nixosModules.core
            self.nixosModules.exposure
            self.nixosModules.sso
          ];
        };
      };

      lib = {
        mkAgentSkill = import ./lib/agent-skill.nix;
        sso = import ./lib/sso.nix { inherit lib; };
      };

      checks.${system}.local-sso = import ./checks/local-sso {
        inherit pkgs self;
        hermesPackage = hermes-agent.packages.${system}.minimal;
      };
    };
}
