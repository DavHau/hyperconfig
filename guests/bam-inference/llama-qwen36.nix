# Qwen3.6-27B (dense, hybrid Gated DeltaNet, 262K native ctx) as
# unsloth UD-Q8_K_XL GGUF (~35G) on mainline llama.cpp — near-lossless
# 8-bit, trivially fits 96G VRAM with the full 256K context (DeltaNet
# linear-attention layers keep constant state; only the sparse
# full-attention layers pay per-token KV).
#
# PARKED unit (wantedBy = []): llama-minimax (MiniMax-M2.7) keeps the
# autostart. A/B swap: `systemctl start llama-qwen36` (Conflicts= stops
# whatever engine holds the GPU); permanent switch = move the wantedBy.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Same scoped-CUDA nixpkgs import as llama-minimax.nix (see rationale
  # there; CUDA 12.9, NOT the llama.cpp-breaking 13.2).
  pkgsCuda = import pkgs.path {
    inherit (pkgs) system;
    config = {
      allowUnfree = true;
      cudaSupport = true;
      cudaCapabilities = ["12.0"];
    };
  };
  llama-cpp = pkgsCuda.llama-cpp;
  modelDir = "/var/lib/models/Qwen3.6-27B-GGUF";
in {
  systemd.services.llama-qwen36 = {
    wantedBy = [];
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    conflicts = [
      "llama-minimax.service"
      "ik-llama-minimax.service"
      "podman-vllm.service"
      "podman-vllm-minimax.service"
    ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
      OOMScoreAdjust = -900;
    };
    script = ''
      exec ${llama-cpp}/bin/llama-server \
        --model ${modelDir}/Qwen3.6-27B-UD-Q8_K_XL.gguf \
        --mmproj ${modelDir}/mmproj-BF16.gguf \
        --alias Qwen3.6-27B-Q8 \
        -ngl 999 \
        --spec-type draft-mtp \
        -md ${modelDir}/mtp-Qwen3.6-27B-Q8_0.gguf \
        -ngld 999 \
        -c 262144 -fa on -ctk q8_0 -ctv q8_0 \
        -b 4096 -ub 2048 \
        --threads 26 \
        --jinja \
        --temp 1.0 --top-p 0.95 --top-k 20 \
        --host 0.0.0.0 --port 30000
    '';
    # Flag notes (shared rationale in llama-minimax.nix):
    # --mmproj            BF16 vision projector — model is multimodal;
    #                     drop the flag to save a little VRAM if unused
    # --spec-type draft-mtp + -md
    #                     multi-token prediction head as speculative
    #                     draft (supported for hybrid Qwen3.5/3.6 since
    #                     < b10035; our binary is b10063). Head is
    #                     ggml-org's standalone mtp- export (3.2G Q8_0)
    #                     paired with the unsloth trunk — same base
    #                     vocab; head quant only affects acceptance
    #                     rate. -ngld keeps the head on-GPU.
    # -c 262144           full native context; hybrid arch = cheap KV
    #                     (q8_0 only on the full-attention layers)
    # --temp 1.0 --top-p 0.95 --top-k 20
    #                     Qwen's recommended thinking-mode sampling
    #                     (generation_config.json / unsloth README);
    #                     precise-coding alternative: temp 0.6
    # no --cache-ram      host-RAM prompt cache untested with recurrent
    #                     DeltaNet state; revisit after first benchmark
  };
}
