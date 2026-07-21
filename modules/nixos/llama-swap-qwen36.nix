# Qwen3.6-35B-A3B Uncensored (HauhauCS "Aggressive" finetune) for llama-swap.
#
# Local brain for the hermes agent. Tuned for a 16 GB Blackwell GPU +
# 64 GB system RAM (machine: vit). Do NOT import on machines without
# that much memory; the model download alone is ~17.5 GiB.
#
#   - Weights: attention/dense layers on GPU, part of the routed MoE
#     experts parked in system RAM (--n-cpu-moe). Only 3B of 35B params
#     are active per token, so expert streaming stays interactive.
#     Decode speed is bound by RAM-streamed expert bytes/token.
#   - 200K context fits in VRAM because only 10 of 40 layers are full
#     attention (2 KV heads x 256 head dim, rest is Gated DeltaNet):
#     KV cache is ~20 KB/token fp16 -> ~2 GiB at 200K with q8_0 KV.
#   - Unlike the previous unsloth MTP-GGUF export, this repo carries no
#     multi-token-prediction head, so no speculative decode flags.
#
# pkgs.fetchurl (fixed-output derivation), not builtins.fetchurl like the
# small gemma4 models: a 17 GiB eval-time fetch would stall every
# `nix flake check` / CI eval; this way it downloads only when vit builds.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.llama-swap;
  llama-server = lib.getExe' cfg.llama-server-package "llama-server";

  hfRepo = "https://huggingface.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive/resolve/main";

  iq4xs = pkgs.fetchurl {
    url = "${hfRepo}/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf";
    hash = "sha256-wmcIp3om1sBBZQKDKiAN5BNeka+CebXpPGf+Tk4IGq4=";
  };

  # Vision projector (Qwen3.6 is natively multimodal); F16 suffices on CUDA.
  mmproj = pkgs.fetchurl {
    url = "${hfRepo}/mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf";
    hash = "sha256-yOcCNEqB+MImqRSqmA7W4fYEvOk3Tx/tjmXIlpCK9BQ=";
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
    "qwen3.6:35b-uncensored-iq4_xs" = {
      cmd = mkCmd { model = iq4xs; nCpuMoe = 16; };
    };
  };
}
