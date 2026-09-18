# Qwen3.8-Flash-Next (unsloth UD-Q3_K_XL, ~84 GiB, 3 shards) for llama-swap
# on vit (RTX 5080 Mobile 16 GB sm_120, Core Ultra 9 285H, 62 GiB RAM).
#
# 512-expert/10-routed MoE whose weights do not fit VRAM+RAM comfortably:
# stock llama.cpp with --n-cpu-moe lands at 15-20 tok/s on 16 GB cards.
# GenerelSchwerz's `moe-cache` fork keeps an LRU cache of expert slabs on
# the GPU (cold experts in pinned host memory) and runs grouped decode
# against it; the fork owner measured 47.00 tok/s decode / 95 tok/s prefill
# on a 5070 Ti 16 GB + 64 GB RAM with this exact revision, model and flag
# set:
#   https://github.com/GenerelSchwerz/llama.cpp/wiki/Notable-Runs
# Design/rationale: docs/superpowers/specs/2026-09-10-qwen38-flash-next-vit-design.md
#
# Reference reproduction on vit (2026-09-10, the wiki's exact config and
# 158-token request, -c 12288, cache 80): decode 34.8 tok/s, prefill 68.5
# tok/s, cold load ~55 s; moe-grouped-decode registered=48 covered=48
# fallback=0 rollback=0 (identical to the reference counters); 14304 MiB
# VRAM; llama-server RSS 53.8 GiB, MemAvailable floor 5.4 GiB. The gap to
# the reference 47 tok/s is the laptop GPU/link, per the wiki's "why
# another machine may run slower" list. The deployed flags below trade
# some of that decode speed for a 128K context; see "Launch flags".
#
#   - Engine: fork commit b46f7f7a4 (base b10845) built through the
#     nixpkgs-llama-cpp `llama-cpp` derivation (v0.4.1 = b10964; same UI
#     lock file, so npmDepsHash carries over). CUDA only, sm_120 only
#     (nixpkgs has no `120a` capability; ggml uses no 120a-only PTX).
#     GGML_BACKEND_DL off: the MoE cache at this commit assumes the CUDA
#     backend is linked statically (dynamic-backend support landed later,
#     at 12a4d1d). No -march=native: the build may run on another host,
#     and decode here is memory-latency bound, not CPU bound.
#   - Weights: three fixed-output fetches joined by linkFarm so llama-server
#     finds the -0000N-of-00003 siblings next to shard 1. Hashes are HF's
#     LFS sha256 for revision 38bb39ee (sizes match the wiki byte for byte).
#   - Launch flags: the wiki run's engine flags, re-budgeted for a 128K
#     context (tuned 2026-09-10 on vit, one knob at a time, harness in
#     the session notes; every row below had covered=48 fallback=0).
#     VRAM at 128K, measured from the loader log (MiB): dense weights
#     4460 + expert cache 133/slot-per-layer x 48 layers (48 slots = 6400,
#     80 = 8000) + KV 2244 (two caches, ~17.5 KiB/token at q8_0) +
#     recurrent 113 + compute 976 at -ub 512 / ~2000 at -ub 1024, plus
#     up to 32 context checkpoints x 113 and the cache's prefill staging
#     that grows with the batch. The reference config (cache 80, -c 12288)
#     therefore cannot reach 128K on 16 GiB: 80 and 64 slots both OOM.
#       -c 131072 / --moe-expert-cache-size 48 / -ub 1024: 48 slots is
#         what fits next to the 128K KV and the -ub 1024 workspace.
#         Prefill here is PCIe-bound, not compute-bound: every micro-
#         batch re-streams the whole 53 GB expert set host->GPU (Gen5 x8,
#         ~25 GB/s), so it scales with -ub and nothing else (raising the
#         GPU power budget from 85 W/1.9 GHz to 105 W/2.4 GHz changed
#         nothing). Measured at a 32K prompt, 128K ctx:
#           -ub  512, cache 48: prefill 186 tok/s, decode 22.3
#           -ub 1024, cache 48: prefill 258 tok/s, decode 22.3  <- chosen
#           -ub 2048, cache 16: prefill 331 tok/s, decode 18.6
#           -ub 2048, cache 40 / -ub 4096, cache 16: OOM (prefill staging)
#         Depth curve (chosen, lazy-mode on; on-direct adds ~+38 % cold):
#         prefill 258 -> 236 tok/s from 32K to 122K
#         (a cold 122K prompt is 8.6 min); decode 26.6 tok/s at 8K depth,
#         22.3 at 32K, 15.2 at 96K, 13.6 at 120K (attention-bound decay).
#         Turn 2 of a 32K chat reuses the KV prefix: 0.9 s prefill.
#         Peak 15.2 GiB of 16.3.
#       --ctx-checkpoints 4: recurrent-state checkpoints for prompt
#         rollback, 113 MiB each; the default 32 was the first OOM at
#         128K. 4 keeps rollback for edited prompts at spacing 8192.
#       GGML_CUDA_DISABLE_FUSION=1: fork issue #80 -- the fused MoE
#         weighted reduction reserves ~512 MiB of workspace it never uses.
#       --load-mode none --lazy-mode on-direct: ordinary tensors in RAM,
#         the 27 GiB per-layer-token-embedding table stays on NVMe and is
#         read per row with threaded pread() (patch #28136 below) instead
#         of demand-faulted mmap. With 62 GiB RAM the table can never be
#         page-cache resident, so `on` pays the fault cost on every
#         prompt: measured 32K prompt, prompt cache off, cold/warm:
#           --lazy-mode on:        258 / 361 tok/s
#           --lazy-mode on-direct: 357 / 361 tok/s   <- chosen (+38 % cold)
#         Decode and RAM floor unchanged. Whole-model mmap loses grouped
#         decode (fork wiki).
#       -fit off: the fork's fit logic does not account for the cache.
#       -ctk/-ctv q8_0 + LLAMA_ATTN_ROT_DISABLE=1: q8_0 KV asserts on
#         qwen4exp unless the KV Hadamard rotation is disabled (upstream
#         #27742 thread). Quality cost unmeasured; f16 KV would cost
#         another 2.2 GiB here, i.e. 16 cache slots.
#       --spec-type none: ngram-map-k measured -40 % decode on a
#         copy-heavy prompt here (multi-token verification through the
#         expert cache); neutral on prose. The fork's --live-context-
#         workspace / --phase-aware-workspace (the designed fix for the
#         full-context workspace reservation) segfault on this model at
#         b46f7f7a4 AND at the branch tip 12a4d1d (2026-09-10); the tip's
#         --decode-overlap measured +3 % (noise) with open issue #82, so
#         the pin stays.
#       --cache-ram 0 / --no-warmup: RAM is the cliff (reference run
#         bottomed at 2.2 GiB available on 64 GB; 4.1 GiB floor here);
#         no host prompt cache, no warmup pass touching every expert.
#       --experimental-logs: prints the per-request `moe-grouped-decode`
#         counters (want covered=48 fallback=0 rollback=0).
#   - Sampling: Qwen's thinking-mode defaults (temp 1.0, top_p 0.95,
#     top_k 20, min_p 0), same as the qwen3.6 entry.
#   - RAM relief on vit: ollama (dave.nix) and docker (spaces profile) are
#     forced off here; hermes-microvm is already off in vit's config.
{ config, lib, pkgs, inputs, ... }:
let
  # See llama-swap-qwen36.nix: HF's CDN resets long-lived h2 streams on
  # slow links; http1.1 + big retry budget keeps the resumed fixed-output
  # fetch monotone to completion.
  bigFetchCurlOpts = [ "--http1.1" "--retry" "99" "--retry-delay" "2" ];

  hfRev = "38bb39ee97821de2c9009abb7e93950eec396e66";
  hfRepo = "https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/${hfRev}/UD-Q3_K_XL";
  shardName = n: "Qwen3.8-Flash-Next-UD-Q3_K_XL-0000${toString n}-of-00003.gguf";
  shard = n: hash: pkgs.fetchurl {
    url = "${hfRepo}/${shardName n}";
    name = shardName n;
    inherit hash;
    curlOptsList = bigFetchCurlOpts;
  };

  weights = pkgs.linkFarm "Qwen3.8-Flash-Next-UD-Q3_K_XL" [
    { name = shardName 1; path = shard 1 "sha256:f2ef4328929d8b8c8930e2856eef52128dd4ce3425302f04bc3c657431cc4c49"; }
    { name = shardName 2; path = shard 2 "sha256:7d230e7c9421d868b89eebaf23033af0ea1a4e046956df00fb156814fb62346e"; }
    { name = shardName 3; path = shard 3 "sha256:21d4f90f9cd7b7c3a1582667c20cb22f7b03de895b88a23bb20aaeaa44f2c199"; }
  ];

  forkRev = "b46f7f7a436f990932d3da3ec53380e2b9effc89";
  # Own nixpkgs instance: legacyPackages carries no allowUnfree, and CUDA
  # is unfree. config.cudaSupport keeps the cudaPackages set consistent
  # with the derivation's cudaSupport override.
  pkgsLlama = import inputs.nixpkgs-llama-cpp {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = { allowUnfree = true; cudaSupport = true; };
  };
  llama-cpp-moe-cache =
    (pkgsLlama.llama-cpp.override {
      cudaSupport = true;
      vulkanSupport = false;
      rocmSupport = false;
      blasSupport = false;
      cpuArchDynamicDispatch = false;
      # See llama-swap-ling30-tiny-amy.nix: nodejs_latest 26.9.0 uncached.
      nodejs_latest = pkgsLlama.nodejs;
    }).overrideAttrs (old: {
      pname = "llama-cpp-moe-cache";
      version = "b10845-${builtins.substring 0 7 forkRev}";
      src = pkgs.fetchFromGitHub {
        owner = "GenerelSchwerz";
        repo = "llama.cpp";
        rev = forkRev;
        hash = "sha256-v/pZ3DWH8P0LGoxgz3+WidcllocuXaK4191y9RFFc70=";
      };
      # ggml-org/llama.cpp#28136 (coder543, unmerged 2026-09-10): `--lazy-mode
      # on-direct` reads the lazy PLE table with threaded pread() instead of
      # demand-faulting the mmap. Our 62 GiB of RAM can never keep the
      # 27 GiB table page-cache resident next to 84 GiB of weights, so
      # every prompt runs cold; measured here cold 260 vs warm 361 tok/s
      # prefill on a 32K prompt (same server, prompt cache off), i.e.
      # the faults cost 28 %. The PR's two commits apply cleanly on the
      # fork pin.
      patches = (old.patches or [ ]) ++ [ ./patches/llama-cpp-pr28136-lazy-on-direct.patch ];
      cmakeFlags = old.cmakeFlags ++ [
        (lib.cmakeFeature "LLAMA_BUILD_NUMBER" "10845")
        (lib.cmakeFeature "LLAMA_BUILD_COMMIT" (builtins.substring 0 7 forkRev))
        (lib.cmakeBool "GGML_CPU_ALL_VARIANTS" false)
        (lib.cmakeBool "GGML_BACKEND_DL" false)
        (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "120")
      ];
    });
in
{
  services.ollama.enable = lib.mkForce false;
  virtualisation.docker.enable = lib.mkForce false;

  services.llama-swap.settings.models."qwen3.8:flash-next-ud-q3_k_xl" = {
    env = [ "LLAMA_ATTN_ROT_DISABLE=1" "GGML_CUDA_DISABLE_FUSION=1" ];
    cmd = lib.concatStringsSep " " [
      (lib.getExe' llama-cpp-moe-cache "llama-server")
      "-m ${weights}/${shardName 1}"
      "--port \${PORT}"
      "--jinja"
      "-c 131072"
      "-b 4096"
      "-ub 1024"
      "--ctx-checkpoints 4"
      "-np 1"
      "-t 12"
      "-ngl all"
      "-fa on"
      "-fit off"
      "--load-mode none"
      "--lazy-mode on-direct"
      "--moe-expert-cache-size 48"
      "-ctk q8_0"
      "-ctv q8_0"
      "-kvo"
      "--cache-ram 0"
      "--no-warmup"
      "--experimental-logs"
      "--spec-type none"
      "--temp 1.0"
      "--top-p 0.95"
      "--top-k 20"
      "--min-p 0.0"
    ];
  };
}
