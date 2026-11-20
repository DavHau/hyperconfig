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
    # Our own nixpkgs, not spaces': fleet updates (security fixes) land on
    # our schedule. spaces keeps its own pin for its own outputs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-riscv.follows = "nixpkgs";
    # Newer nixpkgs ONLY for llama-cpp: the fleet nixpkgs lags
    # the llama.cpp release train, and inference modules that need a recent
    # arch/spec-decode fix pull their engine from here instead of forcing a
    # fleet-wide bump. Consumers: llama-swap-nanbeige42-amy.nix,
    # llama-swap-ling30-tiny-amy.nix, llama-swap-qwen38-flash-vit.nix.
    # Lock: llama-cpp 0.4.1 (b10964); ling needs >= 0.4.1 for its
    # vendored parser patch.
    nixpkgs-llama-cpp.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # PHP ONLY for bam's Nextcloud: php2shell (CVE-2026-109618/109619,
    # unauthenticated RCE) is fixed in php84 8.4.27, which reached
    # nixos-unstable-small before the fleet nixpkgs. Consumer:
    # machines/bam/nextcloud.nix. Drop once the fleet pkgs.php84 >= 8.4.27.
    nixpkgs-php.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";

    nil.url = "github:oxalica/nil";
    nil.inputs.nixpkgs.follows = "nixpkgs";

    # Nix with parallel chunked substituter downloads (DavHau/nix branch
    # parallel-downloads; see modules/nixos/nix-parallel-downloads.nix).
    nix.url = "github:DavHau/nix/parallel-downloads";
    # nix builds on its own pinned nixpkgs: against nixpkgs 2026-09-22
    # (boost 1.91) its URL-parsing unit tests fail (IPv6 cases).
    nix.inputs.nixpkgs-23-11.follows = "nixpkgs";
    nix.inputs.nixpkgs-regression.follows = "nixpkgs";
    # nix-lazy stays on its own nixpkgs: nix 2.30pre (2025-05) no longer
    # builds against current nixpkgs (mdbook-linkcheck was removed).
    nix-lazy.url = "github:nixos/nix/lazy-trees-v2";
    retiolum.url = "github:mic92/retiolum";

    # Hotfix for #8245 (switch survives an SSH drop); back to main once merged.
    clan-core.url = "git+https://git.clan.lol/clan/clan-core?ref=hotfix/8245-ssh-drop-switch";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";
    clan-core.inputs.disko.follows = "disko";
    clan-core.inputs.flake-parts.follows = "flake-parts";

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

    hyprspace.url = "github:hyprspace/hyprspace";
    hyprspace.inputs.nixpkgs.follows = "nixpkgs";
    hyprspace.inputs.flake-parts.follows = "flake-parts";

    clan-community.url = "git+https://git.clan.lol/clan/clan-community?ref=feat/hyprspace&shallow=1";
    clan-community.inputs.clan-core.follows = "clan-core";
    clan-community.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";
    nixvim.inputs.flake-parts.follows = "flake-parts";

    buildbot-nix.url = "github:nix-community/buildbot-nix";
    buildbot-nix.inputs.nixpkgs.follows = "nixpkgs";
    buildbot-nix.inputs.flake-parts.follows = "flake-parts";

    stylix.url = "github:nix-community/stylix";
    stylix.inputs.nixpkgs.follows = "nixpkgs";
    stylix.inputs.flake-parts.follows = "flake-parts";

    nixvirt.url = "github:AshleyYakeley/NixVirt";
    nixvirt.inputs.nixpkgs.follows = "nixpkgs";

    ncro.url = "github:manic-systems/ncro";
    ncro.inputs.nixpkgs.follows = "nixpkgs";

    # external clan services
    ncps.url = "git+https://git.clan.lol/TakodaS/clan-core.git?shallow=1&ref=ncps";
    ncps.flake = false;

    sbox.url = "github:DavHau/sbox";

    # DavHau's fork (branch prune-stale-auto-roots).
    fast-nix-gc.url = "github:DavHau/fast-nix-gc/prune-stale-auto-roots";
    fast-nix-gc.inputs.nixpkgs.follows = "nixpkgs";

    # afk (the omp harness) owns the llm-agents pin, with afk's own lock
    # exactly as Dave tests it: its patch set is written against the omp of
    # ITS llm-agents and nixpkgs. hyperconfig takes llm-agents from afk
    # (herdr, pi and omp-joy too), so an afk bump is one line here. afk's
    # nixpkgs is deliberately not ours: agents track nixpkgs faster than we
    # do (2026-09: omp 18.2.10 needs bun >= 1.3.14).
    afk.url = "github:DavHau/afk/7ea1b673843de2f5d401a5fc2afe6b9126f9aaa0";
    llm-agents.follows = "afk/llm-agents";

    # ntop: nix-native htop (live builds, transfers, store, remotes).
    # Every input is fetchable (no git+file:): som's nightly nixpkgs bump
    # (machines/som) evaluates the fleet from GitHub; local work goes in
    # with --override-input.
    ntop.url = "github:DavHau/ntop";
    ntop.inputs.nixpkgs.follows = "nixpkgs";

    wrappers.url = "github:lassulus/wrappers";
    wrappers.inputs.nixpkgs.follows = "nixpkgs";

    # TeamClaude: pooled Claude subscription gateway on som
    # (modules/nixos/teamclaude-gateway). Versioned here, independently of
    # any other deployment: `nix flake update teamclaude`.
    teamclaude.url = "github:KarpelesLab/teamclaude";
    teamclaude.inputs.nixpkgs.follows = "nixpkgs";

    spaces.url = "git+https://git.geninf.io/spaces/spaces-os";
    # voxtype loads the system's Vulkan ICD (mesa via /run/opengl-driver),
    # which is built against OUR glibc. Built against spaces' older glibc,
    # mesa's libLLVM fails to load (`GLIBC_2.44' not found), ggml-vulkan
    # finds no GPU and whisper falls back to CPU (~90 s per utterance).
    spaces.inputs.voxtype.inputs.nixpkgs.follows = "nixpkgs";

    # The hermes agents (NousResearch hermes-agent) as a library flake of
    # their own (./hyperhermes); som supplies the site data and secrets.
    # Its hermes-agent input builds the agents' package against our
    # nixpkgs. Anything else built from hermes' source takes that same
    # input (inputs.hyperhermes.inputs.hermes-agent).
    hyperhermes.url = "path:./hyperhermes";
    hyperhermes.inputs.nixpkgs.follows = "nixpkgs";

    # SearXNG, the agents' web_search backend, at upstream master instead of
    # nixpkgs' snapshot (weeks behind; engines break against live sites
    # faster than that). Source only: nixpkgs' package builds it
    # (hyperhermes/modules/browser/searxng-package.nix).
    searxng.url = "github:searxng/searxng";
    searxng.flake = false;

    # nbo, the CLI of nixbot (the CI at https://ci.geninf.io), for
    # geninf-space (modules/nixos/spaces/geninf-space.nix).
    nixbot.url = "github:Mic92/nixbot";
    nixbot.inputs.nixpkgs.follows = "nixpkgs";
    nixbot.inputs.treefmt-nix.follows = "buildbot-nix/treefmt-nix";

    cctl.url = "github:allouis/cctl";
    cctl.inputs.nixpkgs.follows = "nixpkgs";

    nix-housing.url = "git+https://codeberg.org/decentstates/nix-housing?ref=latest";
    nix-housing.inputs.nixpkgs.follows = "nixpkgs";

    # Dave's self-hosted Agave (docs/agave-self-hosted.md): the server in
    # the agave-host space on som (modules/nixos/spaces/agave-host.nix) and
    # the tunnel on every machine (modules/nixos/agave-tunnel.nix). Pinned to
    # the integration branch (agave main + the open self-hosting PRs); Dave
    # moves it: `nix flake update agave`, reviewing the diff of agave's
    # module.nix and template/modules each time (its fleet module runs as
    # root on every machine). A private repository over ssh, so every
    # evaluator of a machine needs a key with read access: Dave's own on
    # his machines (git.geninf.io pinned in modules/nixos/git.nix), the
    # shared read-only key agave-geninf-ro in infra-space (deploys, both
    # bumps: modules/nixos/infra-space/guest.nix) and in the agave-host
    # tenant, davhau-gi-bot's in geninf-space. Anyone else (joy's clone,
    # a fresh checkout without a key) evaluates no machine. nixpkgs and
    # clan-core stay agave's own (its template lock re-roots them, agave's
    # flake.nix). Its marketplace and VM host inputs serve its checks only
    # and point at this flake instead (`follows = ""`), so nothing fetches
    # those private repositories.
    agave.url = "git+ssh://gitea@git.geninf.io/generational-infrastructure/agave?ref=davhau/self-hosted";
    agave.inputs.agave-marketplace.follows = "";
    agave.inputs.agave-vm-host.follows = "";


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

      flake.checks.x86_64-linux = (genAttrs
        [
          "amy"
          "bam"
          "cm-pi"
          "nas"
        ]
        (
          host: self.nixosConfigurations.${host}.config.system.build.toplevel
        ))
      # The other machines: evaluated, not built (`nix flake check
      # --no-build` and the check itself fail on any eval error; the
      # deploy builds them). The drvPath's context is discarded, so building
      # the check builds nothing of the machine.
      // nixpkgs.lib.mapAttrs' (host: _: nixpkgs.lib.nameValuePair "eval-${host}" (
        nixpkgs.legacyPackages.x86_64-linux.writeText "eval-${host}"
          (builtins.unsafeDiscardStringContext
            self.nixosConfigurations.${host}.config.system.build.toplevel.drvPath)
      )) (genAttrs [ "som" "vit" "edi" "sgp" "joy" "installer" ] (_: null))
      // {
        ssh-tpm-confirm-cache =
          import ./modules/nixos/ssh-tpm-agent-confirm-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # Sandboxed GTK dialog test; its $out also holds the screenshots.
        ssh-tpm-confirm-dialog =
          import ./modules/nixos/ssh-tpm-confirm-dialog-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # greetd's idle restart decision against mocked systemctl/loginctl.
        greetd-idle-restart =
          import ./modules/nixos/greetd-idle-restart-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit (self.nixosConfigurations.amy.config.systemd) units;
          };
        niri-terminal-cwd =
          import ./modules/nixos/niri-terminal-cwd-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        mullvad-egress =
          import ./modules/nixos/mullvad-egress/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # som's residential proxy gateway (Evomi) behind Mullvad.
        residential-proxy =
          import ./modules/nixos/residential-proxy/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # som's agents kept off Roman's site LANs.
        zt-eu-lan-guard =
          import ./modules/nixos/zt-eu-lan-guard/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        porkbun-records =
          import ./modules/nixos/porkbun-records/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # Dave's PDS on som: accounts, did:web, password var, port gate.
        atproto-pds =
          import ./modules/nixos/atproto-pds/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        per-user-tmp =
          import ./modules/nixos/per-user-tmp/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # LAN scan page (eSCL pull, OCR deu+eng+tha, vault delivery) and
        # the shared USB print queue, against a fake ipp-usb device.
        scan-trigger =
          import ./modules/nixos/scan-trigger/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        entity-storage =
          import ./modules/nixos/entity-storage/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # Space containers' GUI apps on a Wayland session.
        space-gui =
          import ./modules/nixos/space-gui/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # A live switch that cuts the machine off is restored, then rolled
        # back with a reboot (systemd-boot VM); good switches confirmed.
        self-heal-deploy-guard =
          import ./modules/nixos/self-heal/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # A hung PID 1 gets the VM reset by its (virtual) hardware watchdog.
        self-heal-hardware-watchdog =
          import ./modules/nixos/self-heal/hardware-watchdog-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        user-manager-restart =
          import ./modules/nixos/user-manager-restart/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        zfs-keylocation-sync =
          import ./modules/nixos/zfs-keylocation-sync/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # nas: clevis/tang unlock of pool11/enc and rpool/enc, and nothing
        # writes under them unless mounted (machines/nas/automount).
        nas-enc-guard =
          import ./machines/nas/automount/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # nas' real zfs-tang generator binds offline, without a
        # prompt, against the pinned advertisement of the casa tang.
        nas-zfs-tang-bind =
          let
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            gen = self.nixosConfigurations.nas.config.clan.core.vars.generators.zfs-tang;
          in
          pkgs.runCommand "nas-zfs-tang-bind" { nativeBuildInputs = gen.runtimeInputs; } ''
            export in=$PWD/in out=$PWD/gen
            mkdir -p $in/zfs-key $out
            printf %s not-the-passphrase > $in/zfs-key/passphrase
            (${gen.script}) < /dev/null
            test -s $out/zfs-key.jwe
            touch ${placeholder "out"}
          '';
        # The fleet's mirror of the clan secrets repo.
        clan-secrets-mirror =
          import ./modules/nixos/clan-secrets-mirror-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # restartUnits of clan vars with the age backend, in real switches.
        clan-vars-restart-units =
          import ./modules/nixos/clan-vars-restart-units-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        noctalia-anthropic-usage =
          import ./modules/nixos/noctalia-anthropic-usage/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # Recurring tasks' freshness exporter (host + nspawn guest) and
        # the alert rule's PromQL against a local Prometheus.
        recurring-tasks =
          import ./modules/nixos/recurring-tasks/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # bam's storagebox automount errors out instead of hanging.
        storagebox =
          import ./modules/nixos/storagebox-test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        # ipv4-forward's return path into hyperhermes' container slots.
        ipv4-forward-slots =
          import ./modules/nixos/ipv4-forward-slots-test {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit (inputs) hyperhermes;
          };
        # som's agents see images whatever the model: hyperhermes' vision
        # check on som's hermes package and its p0/auxiliary settings
        # (machines/som/hermes-inference.nix).
        hermes-vision =
          let
            hyperhermes = self.nixosConfigurations.som.config.services.hyperhermes;
          in
          import "${inputs.hyperhermes}/checks/vision" {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            hermesPackage = hyperhermes.package;
            settings = { inherit (hyperhermes.settings) providers auxiliary; };
          };
        # Only the agent's unit runs its gateway: hyperhermes' managed-unit
        # check on som's hermes package, so a hermes bump that moves the
        # patch's code paths fails here.
        hermes-managed-unit = import "${inputs.hyperhermes}/checks/managed-unit" {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          hermesPackage = self.nixosConfigurations.som.config.services.hyperhermes.package;
        };
        # hyperhermes' wheel-libs container check with som's own nix
        # (input `nix`, its own nixpkgs): an agent's terminal runs it,
        # which the venv's wheel libraries in the environment broke.
        hermes-wheel-libs = import "${inputs.hyperhermes}/checks/wheel-libs" {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          self = inputs.hyperhermes;
          nixPackage = self.nixosConfigurations.som.config.nix.package;
        };
        # infra-space's containers on two members, root on a third machine.
        infra-space =
          import ./modules/nixos/infra-space/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit inputs;
          };
        # The infra agent's mailbox, browser and wallet on som's host side.
        infra-space-agent-tools = import ./modules/nixos/infra-space/agent-tools-test.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit inputs;
        };
        # The named agent spaces beside infra-space on one host (amy), and
        # Dave's herdr machines for them.
        spaces =
          import ./modules/nixos/spaces/test.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit inputs;
          };
        # The search canary's verdict on a recorded junk and good SearXNG
        # answer (no network).
        searxng-canary = import ./modules/nixos/searxng-canary/test.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };
        # The nightly bump's pre-push guard in a scratch repo, with stubs
        # for GitHub and the prefetch (no network).
        nixpkgs-bump-guard = import ./modules/nixos/infra-space/nixpkgs-bump/guard-test.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          # the review parts' read check runs the hermes infra-space runs
          inherit (self.nixosConfigurations.som.config.containers.infra-space.config.services.hyperhermes.package)
            hermesVenv
            ;
        };
        # The bump's workspace helper: create and remove twice, overlap,
        # self-cleanup on a failed create (local origin, no network).
        nixpkgs-bump-workspace = import ./modules/nixos/infra-space/nixpkgs-bump/workspace-test.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };
        # The deterministic bump (branch-only): a toy flake with a good and
        # a bad job, local bare repos, red/green/error, lock, GC roots.
        fleet-bump = import ./modules/nixos/infra-space/fleet-bump/test.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };
        # The security jobs' pre-push guard and decision inbox CLI
        # (scratch repo with a local origin, no network).
        sec-job-guard = import ./modules/nixos/infra-space/security-jobs/guard-test.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        };
      };
    };
}
