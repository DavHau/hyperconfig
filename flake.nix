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
    # Newer nixpkgs ONLY for llama-cpp: the fleet nixpkgs (via spaces) lags
    # the llama.cpp release train, and inference modules that need a recent
    # arch/spec-decode fix pull their engine from here instead of forcing a
    # fleet-wide bump. Consumers: llama-swap-nanbeige42-amy.nix,
    # llama-swap-ling30-tiny-amy.nix, llama-swap-qwen38-flash-vit.nix.
    # Lock: llama-cpp 0.4.1 (b10964); ling needs >= 0.4.1 for its
    # vendored parser patch.
    nixpkgs-llama-cpp.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";

    nil.url = "github:oxalica/nil";
    nil.inputs.nixpkgs.follows = "nixpkgs";

    # Local nix build with parallel chunked substituter downloads
    # (parallel-downloads bookmark; see modules/nixos/nix-parallel-downloads.nix).
    # nix.url = "https://flakehub.com/f/NixOS/nix/2.*.*.tar.gz";
    nix.url = "git+file:///home/grmpf/projects/nix?ref=parallel-downloads&shallow=1";
    # nix builds on its own pinned nixpkgs: against nixpkgs 2026-09-22
    # (boost 1.91) its URL-parsing unit tests fail (IPv6 cases).
    nix.inputs.nixpkgs-23-11.follows = "nixpkgs";
    nix.inputs.nixpkgs-regression.follows = "nixpkgs";
    # nix-lazy stays on its own nixpkgs: nix 2.30pre (2025-05) no longer
    # builds against current nixpkgs (mdbook-linkcheck was removed).
    nix-lazy.url = "github:nixos/nix/lazy-trees-v2";
    retiolum.url = "github:mic92/retiolum";

    clan-core.url = "git+https://git.clan.lol/clan/clan-core";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";
    clan-core.inputs.disko.follows = "disko";
    clan-core.inputs.flake-parts.follows = "flake-parts";
    # clan-core.inputs.systems.follows = "systems";

    # Upstream, pinned here so clan-core's sops-nix follows our nixpkgs.
    # Without https://github.com/Mic92/sops-nix/pull/973 (still open), one
    # secret whose owner does not resolve to an existing user aborts the whole
    # activation and leaves the machine with zero secrets (vit, 2026-08-08).
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    clan-core.inputs.sops-nix.follows = "sops-nix";

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

    ncro.url = "github:manic-systems/ncro";
    ncro.inputs.nixpkgs.follows = "nixpkgs";

    # external clan services
    ncps.url = "git+https://git.clan.lol/TakodaS/clan-core.git?shallow=1&ref=ncps";
    ncps.flake = false;

    sbox.url = "github:DavHau/sbox";

    # llm-agents keeps its OWN nixpkgs on purpose: its derivations then
    # hash-match what numtide's CI pushed to cache.numtide.com and substitute
    # instead of building, and upstream tracks nixpkgs faster than spaces
    # does (2026-09: omp 18.2.10 needs bun >= 1.3.14, t3code electron_44;
    # spaces' pin has neither). Following our nixpkgs would rebuild every
    # agent from source on each bump and currently cannot build at all.
    # afk (the omp harness) shares this pin so its patch set and omp agree.
    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.flake-parts.follows = "flake-parts";
    llm-agents.inputs.systems.follows = "systems";

    afk.url = "git+file:///home/grmpf/synced/projects/afk?rev=e3d373fdd4dbc36ccf8e1017c5365240b67e9a02";
    afk.inputs.nixpkgs.follows = "nixpkgs";
    afk.inputs.llm-agents.follows = "llm-agents";

    # ntop: nix-native htop (live builds, transfers, store, remotes) from the
    # local checkout. git+file: rather than path: — the worktree carries a
    # ~520M cargo target/ that a path: input would copy into the store on
    # every eval, while git+file honours .gitignore and still picks up
    # uncommitted work. Price: while that checkout is dirty nix refuses to
    # write a lock entry for it (and thus to rewrite flake.lock at all), so
    # commit there before re-locking here.
    ntop.url = "git+file:///home/grmpf/synced/projects/ntop";
    ntop.inputs.nixpkgs.follows = "nixpkgs";

    mics-skills.url = "github:Mic92/mics-skills";
    mics-skills.inputs.nixpkgs.follows = "nixpkgs";
    mics-skills.inputs.flake-parts.follows = "flake-parts";

    wrappers.url = "github:lassulus/wrappers";
    wrappers.inputs.nixpkgs.follows = "nixpkgs";

    spaces.url = "git+https://git.geninf.io/spaces/spaces-os";

    cctl.url = "github:allouis/cctl";
    cctl.inputs.nixpkgs.follows = "nixpkgs";

    nixos-example.url = "github:DavHau/nixos-example";
    nixos-example.inputs.nixpkgs.follows = "nixpkgs";
    nixos-example.inputs.disko.follows = "disko";
    nixos-example.inputs.nixos-hardware.follows = "nixos-hardware";
    nixos-example.inputs.llm-agents.follows = "llm-agents";
    nixos-example.inputs.sbox.follows = "sbox";
    nixos-example.inputs.wrappers.follows = "wrappers";
    # nixos-example's hermes.nix takes inputs.hermes-agent from OUR specialArgs
    # (spaces' pin, see nixosConfigurations.nix); its own copy is dead weight
    # and dragged a third nixpkgs along. aztec-packages likewise.
    nixos-example.inputs.hermes-agent.follows = "spaces/hermes-agent";
    nixos-example.inputs.aztec-packages.inputs.nixpkgs.follows = "nixpkgs";
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
