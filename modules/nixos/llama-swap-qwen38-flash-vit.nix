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
# Measured on vit (2026-09-10, the wiki's exact 158-token request, 1024
# tokens out, temp 0): decode 34.8 tok/s, prefill 68.5 tok/s, cold load
# ~55 s; moe-grouped-decode registered=48 covered=48 fallback=0 rollback=0
# (identical to the reference counters); 14304 MiB VRAM; llama-server RSS
# 53.8 GiB, MemAvailable floor 5.4 GiB. The gap to the reference 47 tok/s
# is the laptop GPU/link, per the wiki's "why another machine may run
# slower" list.
#
#   - Engine: fork commit b46f7f7a4 (base b10845) built through the
#     nixpkgs-llama-cpp `llama-cpp` derivation (v0.4.0 = b10809; same UI
#     lock file, so npmDepsHash carries over). CUDA only, sm_120 only
#     (nixpkgs has no `120a` capability; ggml uses no 120a-only PTX).
#     GGML_BACKEND_DL off: the MoE cache at this commit assumes the CUDA
#     backend is linked statically (dynamic-backend support landed later,
#     at 12a4d1d). No -march=native: the build may run on another host,
#     and decode here is memory-latency bound, not CPU bound.
#   - Weights: three fixed-output fetches joined by linkFarm so llama-server
#     finds the -0000N-of-00003 siblings next to shard 1. Hashes are HF's
#     LFS sha256 for revision 38bb39ee (sizes match the wiki byte for byte).
#   - Launch flags = the wiki run minus its benchmark-only knobs
#     (--reasoning-budget*, -n, --alias, --offline, -lv). Reproduce first,
#     tune later; the spec lists the follow-ups (MTP draft module, fusion
#     off + bigger cache, ngram-map-k, IQ3_XXS).
#       --load-mode none --lazy-mode on: ordinary tensors in RAM, the
#         27 GiB per-layer-token-embedding table stays file-backed on NVMe.
#         Whole-model mmap loses grouped decode (fork wiki).
#       --moe-expert-cache-size 80: 80 of 512 experts per routed group
#         resident on GPU (~13.9 GiB loaded, 14.4 GiB peak on the reference
#         run). Cache >= 10 routed experts is required for grouped decode.
#       -fit off: the fork's fit logic does not account for the cache.
#       -ctk/-ctv q8_0 + LLAMA_ATTN_ROT_DISABLE=1: q8_0 KV asserts on
#         qwen4exp unless the KV Hadamard rotation is disabled (upstream
#         #27742 thread). Quality cost unmeasured; f16 KV is the escape
#         hatch (only 12/48 layers carry KV, ~6.75 KiB/token).
#       --cache-ram 0 / --no-warmup: RAM is the cliff (reference run
#         bottomed at 2.2 GiB available on 64 GB); no prompt cache, no
#         warmup pass touching every expert.
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
    }).overrideAttrs (old: {
      pname = "llama-cpp-moe-cache";
      version = "b10845-${builtins.substring 0 7 forkRev}";
      src = pkgs.fetchFromGitHub {
        owner = "GenerelSchwerz";
        repo = "llama.cpp";
        rev = forkRev;
        hash = "sha256-v/pZ3DWH8P0LGoxgz3+WidcllocuXaK4191y9RFFc70=";
      };
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
    env = [ "LLAMA_ATTN_ROT_DISABLE=1" ];
    cmd = lib.concatStringsSep " " [
      (lib.getExe' llama-cpp-moe-cache "llama-server")
      "-m ${weights}/${shardName 1}"
      "--port \${PORT}"
      "--jinja"
      "-c 12288"
      "-b 4096"
      "-ub 512"
      "-np 1"
      "-t 12"
      "-ngl all"
      "-fa on"
      "-fit off"
      "--load-mode none"
      "--lazy-mode on"
      "--moe-expert-cache-size 80"
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
