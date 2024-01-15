{
  description = "nas home server";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    agenix.url = "github:ryantm/agenix/0.13.0";
    devshell.url = "github:numtide/devshell";
    # nixpkgs.url = "git+https://github.com/DavHau/nixpkgs.git?ref=dave";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-unstable.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";

    nil.url = "github:oxalica/nil";

    nix.url = "github:nixos/nix/2.19.2";
    nix-lazy.url = "github:edolstra/nix/lazy-trees";

    retiolum.url = "github:mic92/retiolum";

    clan-core.url = "git+https://git.clan.lol/clan/clan-core";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    nixos-images.url = "github:nix-community/nixos-images";
    nixos-images.flake = false;

    envfs.url = "github:Mic92/envfs";
    envfs.inputs.nixpkgs.follows = "nixpkgs";

    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";

    nix-heuristic-gc.url = "github:risicle/nix-heuristic-gc";
    nix-heuristic-gc.inputs.nixpkgs.follows = "nixpkgs";

    srvos.url = "github:nix-community/srvos";
    srvos.inputs.nixpkgs.follows = "nixpkgs";
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
