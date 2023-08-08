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
    nixpkgs.url = "nixpkgs/nixos-23.05";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/release-23.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";

    nil.url = "github:oxalica/nil";

    nix.url = "github:nixos/nix/2.17.0";
    nix-lazy.url = "github:edolstra/nix/lazy-trees";

    retiolum.url = "github:mic92/retiolum";

    clan-core.url = "git+https://git.clan.lol/clan/clan-core";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
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
