# Qwen3.8-Flash-Next on vit via GenerelSchwerz `moe-cache` — design

Date: 2026-09-10. Approved by dave in session.

## Goal

Serve `unsloth/Qwen3.8-Flash-Next-GGUF` UD-Q3_K_XL (rev `38bb39ee`) from
llama-swap on vit (RTX 5080 Mobile 16 GB, sm_120; Core Ultra 9 285H, 16
threads; 62 GiB RAM + 62 GiB zram; NVMe) using the GenerelSchwerz
llama.cpp fork's CUDA MoE expert cache, reproducing the wiki's 47.00 tok/s
"Notable run" exactly before any tuning.

Reference: https://github.com/GenerelSchwerz/llama.cpp/wiki/Notable-Runs
(fork commit `b46f7f7a436f990932d3da3ec53380e2b9effc89`).
Research report: `agent://FlashNextResearch/architecture` (session-local).

## Decisions

| Question | Decision |
| --- | --- |
| Engine packaging | Override `inputs.nixpkgs-llama-cpp`'s `llama-cpp` (b10809 derivation) with `src` = fork @ `b46f7f7a4`. Pinned commit, not branch tip. |
| Role | Second llama-swap model next to `qwen3.6:35b-iq4_xs`; qwen3.6 stays hermes' default. |
| Budget | Reproduce the recipe: `-c 12288`, cache 80, `-np 1`. Tune later. |
| Deploy | `clan machines update vit` with `deploy.buildHost = deploy.targetHost = root@vit.d`; weights and CUDA build happen on vit only. |
| RAM relief | Disable ollama and docker on vit (hermes-microvm already off). |
| Reboot | Agent reboots vit as needed; dave unlocks LUKS. |

## Components

One new file `modules/nixos/llama-swap-qwen38-flash-vit.nix`, imported from
`machines/vit/configuration.nix`.

### Engine: `llama-cpp-moe-cache`

- Base: `inputs.nixpkgs-llama-cpp.legacyPackages.<system>.llama-cpp.override
  { cudaSupport = true; vulkanSupport = false; rocmSupport = false;
  blasSupport = false; }`.
- `overrideAttrs`: `src = fetchFromGitHub GenerelSchwerz/llama.cpp @
  b46f7f7a4`; version string `moe-cache-b10845-b46f7f7`.
- cmake: `GGML_BACKEND_DL=OFF` (the MoE cache at this commit assumes a
  statically linked CUDA backend; dynamic-backend support only landed at
  `12a4d1d`), `GGML_CPU_ALL_VARIANTS=OFF` (implied by BACKEND_DL off),
  `CMAKE_CUDA_ARCHITECTURES=120` (sm_120; nixpkgs has no `120a` capability
  and ggml uses no 120a-only PTX), `LLAMA_BUILD_NUMBER=10845`,
  `GGML_CUDA_FA=ON`, `GGML_CUDA_GRAPHS=ON` (fork defaults).
- Not `GGML_NATIVE=ON`: builder CPU may differ from vit's; decode is
  memory-latency bound (measured by solarkyle on sm_120/16 GB), CPU ISA is
  irrelevant.
- Web UI: not embedded (the fork's UI provisioner needs network; it falls
  back to "no UI" with a warning). API only.

### Weights

Three `pkgs.fetchurl` with the HF LFS sha256 (from the HF tree API,
sizes match the wiki byte-for-byte):

| Shard | Bytes | sha256 |
| --- | ---: | --- |
| `…-00001-of-00003.gguf` | 10,946,624 | `f2ef4328929d8b8c8930e2856eef52128dd4ce3425302f04bc3c657431cc4c49` |
| `…-00002-of-00003.gguf` | 49,983,253,824 | `7d230e7c9421d868b89eebaf23033af0ea1a4e046956df00fb156814fb62346e` |
| `…-00003-of-00003.gguf` | 39,992,153,376 | `21d4f90f9cd7b7c3a1582667c20cb22f7b03de895b88a23bb20aaeaa44f2c199` |

Joined with `pkgs.linkFarm` into one directory so `-m …-00001-of-00003.gguf`
resolves its siblings. `bigFetchCurlOpts` as in the other model modules.

### llama-swap entry `qwen3.8:flash-next-ud-q3_k_xl`

- `env = [ "LLAMA_ATTN_ROT_DISABLE=1" ]` — required for q8_0 KV on
  qwen4exp; disables the KV Hadamard rotation (quality cost unmeasured;
  part of the reference recipe).
- cmd = wiki launch minus benchmark-only flags (`--reasoning-budget*`,
  `-n`, `--alias`, `--offline`, `-lv 3`):
  `-c 12288 -b 4096 -ub 512 -np 1 -t 12 -ngl all -fa on -fit off
  --load-mode none --lazy-mode on --moe-expert-cache-size 80
  -ctk q8_0 -ctv q8_0 -kvo --cache-ram 0 --jinja --no-warmup
  --experimental-logs --spec-type none`
  plus Qwen thinking sampling defaults `--temp 1.0 --top-p 0.95 --top-k 20
  --min-p 0.0`.
- `--experimental-logs` stays on: it prints the `moe-grouped-decode`
  counters used for verification.

### vit changes

- `machines/vit/configuration.nix`: import the module.
- `modules/nixos/llama-swap-qwen38-flash-vit.nix` also sets
  `services.ollama.enable = mkForce false`,
  `virtualisation.docker.enable = mkForce false`.
- `modules/flake-parts/nixosConfigurations.nix`: `vit.deploy.targetHost`
  and `vit.deploy.buildHost` = `root@vit.d`.

## Risks

- RAM: the reference run bottomed at 2.2 GiB available on 64 GB. vit has
  62 GiB, ~5 GB resident before this change (less after ollama/docker go).
  `--lazy-mode on` keeps the 27 GiB PLE table file-backed; `--cache-ram 0`
  disables the prompt cache. Kernel already panics-and-reboots on hung
  tasks (freeze history). Fallback if it OOMs: UD-IQ3_XXS (-8 GB host).
- Driver: vit currently has userspace 595.91 vs an older loaded kernel
  module (NVML mismatch). The switch needs a reboot before any CUDA test.
- Build: full fork CUDA compile on vit, no binary-cache hit; 30–60 min.
- Disk: ~84 GiB of weights into vit's store (385 GB free after today's
  cleanup: 335 GiB of stale ollama/llama-swap caches and dead store paths
  removed).

## Verification

1. `clan machines update vit` succeeds; reboot; `nvidia-smi` works.
2. POST the wiki's `request.json` (model name swapped) to
   `http://vit.d:8012/v1/chat/completions`. Pass: `completion_tokens=1024`,
   `finish_reason=length`, llama-swap log shows
   `moe-grouped-decode: registered=48 covered=48 … fallback=0 rollback=0
   prepare_error=0 finish_error=0`, decode tok/s recorded next to the
   47.00 reference, `MemAvailable` floor recorded during the run.
3. `qwen3.6:35b-iq4_xs` still loads after a swap back.

## Out of scope (follow-up tuning, ranked by the research report)

1. MTP draft `MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` (needs
   `moe-cache-drafting`; no Flash-Next MTP measurement exists at 16 GB).
2. `GGML_CUDA_DISABLE_FUSION=1` and cache 80 → 96 (fork issue #80).
3. `--spec-type ngram-map-k` (+45 % on code, prose neutral, sm_120 measured).
4. UD-IQ3_XXS for host-RAM headroom.
5. Larger `-c` for hermes use.
