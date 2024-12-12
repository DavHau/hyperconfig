{
  description = "nas home server";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    nixpkgs.url = "git+https://github.com/nixos/nixpkgs?&shallow=1";
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-unstable.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    nil.url = "github:oxalica/nil";

    nix.url = "https://flakehub.com/f/NixOS/nix/2.23.*.tar.gz";
    nix-lazy.url = "github:edolstra/nix/lazy-trees";

    retiolum.url = "github:mic92/retiolum";

    clan-core.url = "git+https://git.clan.lol/clan/clan-core";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    nixos-images.url = "github:nix-community/nixos-images";
    nixos-images.flake = false;

    envfs.url = "github:Mic92/envfs";
    envfs.inputs.nixpkgs.follows = "nixpkgs";

    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";

    nix-heuristic-gc.url = "github:risicle/nix-heuristic-gc";
    # nix-heuristic-gc.inputs.nixpkgs.follows = "nixpkgs";

    srvos.url = "github:nix-community/srvos";
    srvos.inputs.nixpkgs.follows = "nixpkgs";

    nether.url = "github:Lassulus/nether";
    nether.inputs.nixpkgs.follows = "nixpkgs";

    lassulus.url = "github:Lassulus/superconfig";
    lassulus.inputs.nixpkgs.follows = "nixpkgs";

    hyprspace.url = "github:hyprspace/hyprspace";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {

      systems = [
        "x86_64-linux"
      ];

      imports = [
        ./modules/flake-parts/all-modules.nix
      ];
    };
}
