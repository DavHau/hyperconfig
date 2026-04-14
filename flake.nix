{
  description = "nas home server";

  inputs = {
    # systems.url = "path:./flake.systems.nix";
    # systems.flake = false;
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    nixpkgs.url = "git+https://github.com/nixos/nixpkgs?&ref=nixos-unstable&shallow=1";
    # nixpkgs.url = "git+https://github.com/DavHau/nixpkgs?&ref=dave&shallow=1";
    # nixpkgs-riscv.url = "git+https://github.com/davhau/nixpkgs?&ref=riscv&shallow=1";
    # nixpkgs-riscv.url = "git+https://github.com/DavHau/nixpkgs?&ref=dave&shallow=1";
    nixpkgs-riscv.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    nixos-hardware.url = "github:nixos/nixos-hardware";

    nil.url = "github:oxalica/nil";
    nil.inputs.nixpkgs.follows = "nixpkgs";

    nix.url = "https://flakehub.com/f/NixOS/nix/2.*.*.tar.gz";
    nix-lazy.url = "github:nixos/nix/lazy-trees-v2";
    retiolum.url = "github:mic92/retiolum";

    clan-core.url = "git+https://git.clan.lol/clan/clan-core";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";
    clan-core.inputs.disko.follows = "disko";
    clan-core.inputs.flake-parts.follows = "flake-parts";
    # clan-core.inputs.systems.follows = "systems";
    clan-core-monitoring.url = "git+https://git.clan.lol/friedow/clan-core?ref=feat/monitoring-service&shallow=1";
    clan-core-monitoring.inputs.disko.follows = "disko";
    clan-core-monitoring.inputs.flake-parts.follows = "flake-parts";
    clan-core-monitoring.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    nixos-images.url = "github:nix-community/nixos-images";

    envfs.url = "github:Mic92/envfs";
    envfs.inputs.nixpkgs.follows = "nixpkgs";
    envfs.inputs.flake-parts.follows = "flake-parts";

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
    hyprspace.inputs.flake-parts.follows = "flake-parts";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";
    nixvim.inputs.flake-parts.follows = "flake-parts";

    # buildbot-nix.url = "github:nix-community/buildbot-nix";
    buildbot-nix.url = "github:nix-community/buildbot-nix";
    buildbot-nix.inputs.nixpkgs.follows = "nixpkgs";
    buildbot-nix.inputs.flake-parts.follows = "flake-parts";

    stylix.url = "github:nix-community/stylix";
    stylix.inputs.nixpkgs.follows = "nixpkgs";
    stylix.inputs.flake-parts.follows = "flake-parts";

    easytier.url = "github:EasyTier/EasyTier";
    easytier.flake = false;

    # external clan services
    ncps.url = "git+https://git.clan.lol/TakodaS/clan-core.git?shallow=1&ref=ncps";
    ncps.flake = false;

    sbox.url = "github:DavHau/sbox";

    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.inputs.flake-parts.follows = "flake-parts";

    mics-skills.url = "github:Mic92/mics-skills";
    mics-skills.inputs.nixpkgs.follows = "nixpkgs";
    mics-skills.inputs.flake-parts.follows = "flake-parts";

    wrappers.url = "github:lassulus/wrappers";
    wrappers.inputs.nixpkgs.follows = "nixpkgs";

    noctalia.url = "github:noctalia-dev/noctalia-shell";
    noctalia.inputs.nixpkgs.follows = "nixpkgs";

  };

  outputs = inputs@{ self, flake-parts, nixpkgs, ... }:
    let
      inherit (nixpkgs.lib)
        genAttrs;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "riscv64-linux"
      ];

      imports = [
        ./modules/flake-parts/all-modules.nix
      ];

      flake.inputs = inputs;

      flake.packages.x86_64-linux.amy-vm = self.nixosConfigurations.amy.config.system.build.vm;
      flake.packages.x86_64-linux.vit-vm = self.nixosConfigurations.vit.config.system.build.vm;

      flake.checks.x86_64-linux = genAttrs
        [
          "amy"
          "bam"
          "cat"
          "dom"
          "cm-pi"
          "nas"
        ]
        (
          host: self.nixosConfigurations.${host}.config.system.build.toplevel
        );
    };
}
