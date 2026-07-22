# Qwen3.6-35B-A3B uncensored (heretic abliteration, native MTP head
# preserved) for llama-swap. imatrix IQ4_XS quant by mradermacher.
#
# Local brain for the hermes agent. Tuned for a 16 GB Blackwell GPU +
# 64 GB system RAM (machine: vit). Do NOT import on machines without
# that much memory; the model download alone is ~18 GiB.
#
#   - Weights: attention/dense layers on GPU, part of the routed MoE
#     experts parked in system RAM (--n-cpu-moe). Only 3B of 35B params
#     are active per token, so expert streaming stays interactive.
#     Decode speed is bound by RAM-streamed expert bytes/token.
#   - 200K context fits in VRAM because only 10 of 40 layers are full
#     attention (2 KV heads x 256 head dim, rest is Gated DeltaNet):
#     KV cache is ~20 KB/token fp16 -> ~2 GiB at 200K with q8_0 KV.
#   - MTP head preserved (unlike the HauhauCS-Aggressive export used
#     before): multi-token-prediction speculative decode, 1.4-2.2x
#     faster generation for ~1 GiB extra memory.
#   - mmproj comes from the SOURCE repo (llmfan46): mradermacher's i1
#     repos ship no vision projector, and abliteration does not touch
#     the vision tower, so the source model's own projector is correct.
#
# pkgs.fetchurl (fixed-output derivation), not builtins.fetchurl like the
# small gemma4 models: an 18 GiB eval-time fetch would stall every
# `nix flake check` / CI eval; this way it downloads only when vit builds.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.llama-swap;
  llama-server = lib.getExe' cfg.llama-server-package "llama-server";

  baseName = "Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved";
  quantRepo = "https://huggingface.co/mradermacher/${baseName}-i1-GGUF/resolve/main";
  sourceRepo = "https://huggingface.co/llmfan46/${baseName}-GGUF/resolve/main";

  iq4xs = pkgs.fetchurl {
    url = "${quantRepo}/${baseName}.i1-IQ4_XS.gguf";
    hash = "sha256-OwEjyNGpAdes5uaznvdJVsIiffJtqPyTM6WiqXYLnW0=";
  };

  # Vision projector (Qwen3.6 is natively multimodal); BF16 suffices on CUDA.
  mmproj = pkgs.fetchurl {
    url = "${sourceRepo}/${baseName}-mmproj-BF16.gguf";
    hash = "sha256-1gULuCoBh+GwZV8cXa72DJR5Jz+9dAL/JdMTffLgcc4=";
  };

  # nCpuMoe: MoE expert blocks (of 40 layers) streamed from system RAM.
  # Sized so GPU-resident weights + ~2 GiB KV (200K, q8_0) + compute
  # buffers stay under 16 GiB. Lower to fill VRAM once measured on the
  # real card (watch nvidia-smi at full context).
  mkCmd = { model, nCpuMoe }: lib.concatStringsSep " " [
    llama-server
    "-m ${model}"
    "--mmproj ${mmproj}"
    "--port \${PORT}"
    "--jinja"
    # 200K context. q8_0 KV halves the (already small) cache; if long
    # context degrades, switch to bf16 KV cache instead.
    "-c 204800"
    "--cache-type-k q8_0"
    "--cache-type-v q8_0"
    "-ngl 99"
    "--n-cpu-moe ${toString nCpuMoe}"
    # MTP speculative decode; unsloth found 2 best on most hardware,
    # but it is hardware-dependent -- try 1..6.
    "--spec-draft-n-max 2"
    # Recommended thinking-mode sampling for general/agentic tasks.
    "--temp 1.0"
    "--top-p 0.95"
    "--top-k 20"
    "--min-p 0.0"
  ];
in
{
  services.llama-swap.settings.models = {
    # Name is referenced by amy's hermes VMs (vit.d:8012) -- keep in sync
    # with modules/nixos/hermes-agent.nix settings.model.default.
    "qwen3.6:35b-heretic-iq4_xs" = {
      cmd = mkCmd { model = iq4xs; nCpuMoe = 16; };
    };
  };
}
