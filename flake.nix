{
  description = "nas home server";

  inputs = {
    systems.url = "path:./flake.systems.nix";
    systems.flake = false;
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    nixpkgs.follows = "spaces/nixpkgs";
    # nixpkgs.url = "git+https://github.com/nixos/nixpkgs?ref=nixpkgs-unstable&shallow=1";
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
    nix-eval-cache.url = "github:roberth/nix/eval-cache-next";
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

    nix-heuristic-gc.url = "github:risicle/nix-heuristic-gc";
    nix-heuristic-gc.inputs.nixpkgs.follows = "nixpkgs";

    srvos.url = "github:nix-community/srvos";
    srvos.inputs.nixpkgs.follows = "nixpkgs";

    vibepn.url = "git+file:///home/grmpf/projects/VibePN";
    vibepn.inputs.nixpkgs.follows = "nixpkgs";
    vibepn.inputs.clan-core.follows = "clan-core";

    # nether.url = "github:Lassulus/nether";
    # nether.inputs.nixpkgs.follows = "nixpkgs";

    # lassulus.url = "github:Lassulus/superconfig";
    # lassulus.inputs.nixpkgs.follows = "nixpkgs";

    hyprspace.url = "github:hyprspace/hyprspace";
    hyprspace.inputs.nixpkgs.follows = "nixpkgs";
    hyprspace.inputs.flake-parts.follows = "flake-parts";

    clan-community.url = "git+https://git.clan.lol/clan/clan-community?ref=feat/hyprspace&shallow=1";
    clan-community.inputs.clan-core.follows = "clan-core";
    clan-community.inputs.nixpkgs.follows = "nixpkgs";

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

    nixvirt.url = "github:AshleyYakeley/NixVirt";
    nixvirt.inputs.nixpkgs.follows = "nixpkgs";

    easytier.url = "github:EasyTier/EasyTier";
    easytier.flake = false;

    # external clan services
    ncps.url = "git+https://git.clan.lol/TakodaS/clan-core.git?shallow=1&ref=ncps";
    ncps.flake = false;

    sbox.url = "github:DavHau/sbox";

    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.inputs.flake-parts.follows = "flake-parts";
    llm-agents.inputs.systems.follows = "systems";

    # Same flake, but with NOTHING deduplicated: it keeps its own nixpkgs, so
    # its derivations hash-match what numtide's CI pushed to cache.numtide.com
    # and substitute instead of building. Use this for machines that must
    # update fast and take the packages as-is (joy); `llm-agents` above stays
    # nixpkgs-follows so it shares one nixpkgs closure with the rest of the
    # fleet. Nothing here patches omp any more — the omp harness is afk, which
    # carries its own patch set against its own pinned llm-agents (see below);
    # this input now only supplies `pi` (pi-agent.nix) and claude-code.
    llm-agents-cached.url = "github:numtide/llm-agents.nix";

    # afk: locally checked-out omp harness wrapper (jj patches + Superpowers).
    # Absolute path input: machines need this checkout at the same path to
    # re-lock/rebuild (vit: create it or symlink). llm-agents/superpowers stay
    # pinned by afk's own lock — its patches are validated against those exact
    # revs; only nixpkgs is deduplicated.
    # Real path: ~/projects is a symlink to ~/synced/projects and current
    # nix refuses symlinked path-input parents on re-lock.
    afk.url = "path:/home/grmpf/synced/projects/afk";
    afk.inputs.nixpkgs.follows = "nixpkgs";

    mics-skills.url = "github:Mic92/mics-skills";
    mics-skills.inputs.nixpkgs.follows = "nixpkgs";
    mics-skills.inputs.flake-parts.follows = "flake-parts";

    wrappers.url = "github:lassulus/wrappers";
    wrappers.inputs.nixpkgs.follows = "nixpkgs";

    spaces.url = "github:generational-infrastructure/distro";
    spaces.inputs.llm-agents.follows = "llm-agents";

    cctl.url = "github:allouis/cctl";
    cctl.inputs.nixpkgs.follows = "nixpkgs";

    nixos-example.url = "github:DavHau/nixos-example";
    nixos-example.inputs.nixpkgs.follows = "nixpkgs";
    nixos-example.inputs.disko.follows = "disko";
    nixos-example.inputs.nixos-hardware.follows = "nixos-hardware";
    nixos-example.inputs.llm-agents.follows = "llm-agents";
    nixos-example.inputs.sbox.follows = "sbox";
    nixos-example.inputs.wrappers.follows = "wrappers";
    # hermes-agent moved into the spaces flake (nixosModules.hermes); no
    # root-level hermes-agent input anymore. nixos-example's hermes.nix
    # still references inputs.hermes-agent via OUR specialArgs (path
    # imports) — specialArgs aliases spaces' pin (nixosConfigurations.nix).
    messaging-daemon.url = "github:vbuterin/messaging-daemon";
    messaging-daemon.flake = false;

    nix-housing.url = "github:decentstates/nix-housing";
    nix-housing.inputs.nixpkgs.follows = "nixpkgs";
    nix-housing.inputs.home-manager.follows = "home-manager";


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
        "aarch64-darwin"
      ];

      imports = [
        ./modules/flake-parts/all-modules.nix
      ];

      flake.inputs = inputs;

      flake.packages.x86_64-linux.amy-vm = self.nixosConfigurations.amy.config.system.build.vm;
      flake.packages.x86_64-linux.vit-vm = self.nixosConfigurations.vit.config.system.build.vm;
      flake.packages.x86_64-linux.nas-vm = self.nixosConfigurations.nas.config.system.build.vm;

      flake.packages.x86_64-linux.ssh-tpm-agent =
        import ./modules/nixos/ssh-tpm-agent-package.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };
      flake.packages.x86_64-linux.ssh-tpm-confirm-dialog =
        import ./modules/nixos/ssh-tpm-confirm-dialog.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };
      flake.packages.x86_64-linux.fabro =
        import ./modules/nixos/fabro/package.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };

      flake.checks.x86_64-linux = (genAttrs
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
        )) // {
        ssh-tpm-confirm-cache =
          import ./modules/nixos/ssh-tpm-agent-confirm-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # Sandboxed GTK dialog test; its $out also holds the screenshots.
        ssh-tpm-confirm-dialog =
          import ./modules/nixos/ssh-tpm-confirm-dialog-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        niri-terminal-cwd =
          import ./modules/nixos/niri-terminal-cwd-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        noctalia-anthropic-usage =
          import ./modules/nixos/noctalia-anthropic-usage/test.nix {
            # amy's pkgs carry the spaces overlay (noctalia-shell,
            # quickshell) the plugin QML lints against.
            pkgs = self.nixosConfigurations.amy.pkgs;
            spaces = inputs.spaces;
          };
      };
    };
}
