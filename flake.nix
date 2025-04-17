{
  description = "nas home server";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    # nixpkgs.url = "git+https://github.com/nixos/nixpkgs?&ref=nixos-unstable&shallow=1";
    nixpkgs.url = "git+https://github.com/davhau/nixpkgs?&ref=dave&shallow=1";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    nixos-hardware.url = "github:nixos/nixos-hardware";

    nil.url = "github:oxalica/nil";

    nix.url = "https://flakehub.com/f/NixOS/nix/2.*.*.tar.gz";
    nix-lazy.url = "github:edolstra/nix/lazy-trees";
    nix-multi.url = "git+https://github.com/DeterminateSystems/nix-src?&ref=multithreaded-eval&shallow=1";

    retiolum.url = "github:mic92/retiolum";

    clan-core.url = "git+https://git.clan.lol/clan/clan-core";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    nixos-images.url = "github:nix-community/nixos-images";
    nixos-images.flake = false;

    envfs.url = "github:Mic92/envfs";
    envfs.inputs.nixpkgs.follows = "nixpkgs";

    # devenv.url = "github:cachix/devenv";
    # devenv.inputs.nixpkgs.follows = "nixpkgs";

    nix-heuristic-gc.url = "github:risicle/nix-heuristic-gc";
    nix-heuristic-gc.inputs.nixpkgs.follows = "nixpkgs";

    srvos.url = "github:nix-community/srvos";
    srvos.inputs.nixpkgs.follows = "nixpkgs";

    # nether.url = "github:Lassulus/nether";
    # nether.inputs.nixpkgs.follows = "nixpkgs";

    # lassulus.url = "github:Lassulus/superconfig";
    # lassulus.inputs.nixpkgs.follows = "nixpkgs";

    hyprspace.url = "github:hyprspace/hyprspace";
    hyprspace.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {

      systems = [
        "x86_64-linux"
      ];

      imports = [
        ./modules/flake-parts/all-modules.nix
      ];

      flake.inputs = inputs;

      flake.checks.x86_64-linux = {
        amy = self.nixosConfigurations.amy.config.system.build.toplevel;
        grmpf-nix = self.nixosConfigurations.grmpf-nix.config.system.build.toplevel;
        cm-pi = self.nixosConfigurations.cm-pi.config.system.build.toplevel;
      };
    };
}
