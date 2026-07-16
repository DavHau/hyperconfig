# Qwen3.6-35B-A3B (unsloth dynamic UD-Q4_K_XL, MTP variant) for llama-swap.
#
# Local brain for the hermes agent. Tuned for a 16 GB Blackwell GPU +
# 64 GB system RAM (machine: vit). Do NOT import on machines without
# that much memory; the model download alone is ~21.3 GiB.
#
#   - Weights: attention/dense layers on GPU, part of the routed MoE
#     experts parked in system RAM (--n-cpu-moe). Only 3B of 35B params
#     are active per token, so expert streaming stays interactive.
#   - 200K context fits in VRAM because only 10 of 40 layers are full
#     attention (2 KV heads x 256 head dim, rest is Gated DeltaNet):
#     KV cache is ~20 KB/token fp16 -> ~2 GiB at 200K with q8_0 KV.
#   - MTP GGUF: multi-token-prediction speculative decode, 1.4-2.2x
#     faster generation for ~1 GiB extra memory.
#
# pkgs.fetchurl (fixed-output derivation), not builtins.fetchurl like the
# small gemma4 models: a 21 GiB eval-time fetch would stall every
# `nix flake check` / CI eval; this way it downloads only when vit builds.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.llama-swap;
  llama-server = lib.getExe' cfg.llama-server-package "llama-server";

  hfRepo = "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main";

  model = pkgs.fetchurl {
    url = "${hfRepo}/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
    hash = "sha256-VZg8WnWhq5aYJAd7O7PeQUboKpI0BytIrU6Pkq0/6fE=";
  };

  # Vision projector (Qwen3.6 is natively multimodal); F16 suffices on CUDA.
  mmproj = pkgs.fetchurl {
    url = "${hfRepo}/mmproj-F16.gguf";
    hash = "sha256-cfPLwffMDzDQnUHPqSTABggn68M78VrOfoZmHoVvAWA=";
  };
in
{
  services.llama-swap.settings.models."qwen3.6:35b" = {
    cmd = lib.concatStringsSep " " [
      llama-server
      "-m ${model}"
      "--mmproj ${mmproj}"
      "--port \${PORT}"
      "--jinja"
      # 200K context. q8_0 KV halves the (already small) cache; if long
      # context degrades, unsloth suggests bf16 KV cache instead.
      "-c 204800"
      "--cache-type-k q8_0"
      "--cache-type-v q8_0"
      # Everything on GPU except N MoE expert blocks streamed from RAM.
      # 24 leaves several GiB VRAM headroom; lower to fill VRAM once
      # measured on the real card (watch nvidia-smi at full context).
      "-ngl 99"
      "--n-cpu-moe 24"
      # MTP speculative decode; unsloth found 2 best on most hardware,
      # but it is hardware-dependent -- try 1..6.
      "--spec-draft-n-max 2"
      # Recommended thinking-mode sampling for general/agentic tasks.
      "--temp 1.0"
      "--top-p 0.95"
      "--top-k 20"
      "--min-p 0.0"
    ];
  };
}
