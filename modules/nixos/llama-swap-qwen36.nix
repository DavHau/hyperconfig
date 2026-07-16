# Qwen3.6-35B-A3B (unsloth dynamic quants, MTP variant) for llama-swap.
#
# Local brain for the hermes agent. Tuned for a 16 GB Blackwell GPU +
# 64 GB system RAM (machine: vit). Do NOT import on machines without
# that much memory; the model downloads alone are ~16-21 GiB each.
#
#   - Weights: attention/dense layers on GPU, part of the routed MoE
#     experts parked in system RAM (--n-cpu-moe). Only 3B of 35B params
#     are active per token, so expert streaming stays interactive.
#     Decode speed is bound by RAM-streamed expert bytes/token, hence
#     the smaller quants below: less offloaded -> faster.
#   - 200K context fits in VRAM because only 10 of 40 layers are full
#     attention (2 KV heads x 256 head dim, rest is Gated DeltaNet):
#     KV cache is ~20 KB/token fp16 -> ~2 GiB at 200K with q8_0 KV.
#   - MTP GGUF: multi-token-prediction speculative decode, 1.4-2.2x
#     faster generation for ~1 GiB extra memory.
#
# Quant ladder (quality loss vs BF16 estimated from unsloth Dynamic 2.0
# benchmarks; speed estimated from expert-offload bandwidth math):
#   UD-Q4_K_XL  21.3 GiB  ~lossless      baseline speed
#   UD-IQ4_XS   17.0 GiB  ~0.5-1% loss   ~1.7x decode
#   UD-Q3_K_XL  16.0 GiB  ~1-2% loss     ~2.1x decode
#
# pkgs.fetchurl (fixed-output derivation), not builtins.fetchurl like the
# small gemma4 models: a 21 GiB eval-time fetch would stall every
# `nix flake check` / CI eval; this way it downloads only when vit builds.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.llama-swap;
  llama-server = lib.getExe' cfg.llama-server-package "llama-server";

  hfRepo = "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main";

  fetchQwen36 = { quant, hash }: pkgs.fetchurl {
    url = "${hfRepo}/Qwen3.6-35B-A3B-UD-${quant}.gguf";
    inherit hash;
  };

  q4kxl = fetchQwen36 {
    quant = "Q4_K_XL";
    hash = "sha256-VZg8WnWhq5aYJAd7O7PeQUboKpI0BytIrU6Pkq0/6fE=";
  };
  iq4xs = fetchQwen36 {
    quant = "IQ4_XS";
    hash = "sha256-3yengENbe0XCWXU2ES6jywkfhUTD0MMxjZ9CWLMfet8=";
  };
  q3kxl = fetchQwen36 {
    quant = "Q3_K_XL";
    hash = "sha256-P7qatXKQs0cmg3UhM1v5JoOXF0891mKIDi0MUmTRe4E=";
  };

  # Vision projector (Qwen3.6 is natively multimodal); F16 suffices on CUDA.
  mmproj = pkgs.fetchurl {
    url = "${hfRepo}/mmproj-F16.gguf";
    hash = "sha256-cfPLwffMDzDQnUHPqSTABggn68M78VrOfoZmHoVvAWA=";
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
    # context degrades, unsloth suggests bf16 KV cache instead.
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
    "qwen3.6:35b" = {
      cmd = mkCmd { model = q4kxl; nCpuMoe = 24; };
    };
    # Name is referenced by amy's hermes VMs (vit.d:8012) -- keep stable.
    "qwen3.6:35b-iq4_xs" = {
      cmd = mkCmd { model = iq4xs; nCpuMoe = 16; };
    };
    "qwen3.6:35b-q3_k_xl" = {
      cmd = mkCmd { model = q3kxl; nCpuMoe = 14; };
    };
  };
}
