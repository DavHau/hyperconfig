# MiniMax-M2.7 (230B-A10B MoE) as unsloth Dynamic 2.0 UD-IQ3_XXS GGUF
# (74.6GiB) served by llama.cpp fully GPU-resident. Successor to the
# UD-IQ4_XS expert-offload setup (kept on disk): the 3-bit dynamic quant
# trades ~2.5 Aider points vs the 4-bit (~93% vs ~97% of full precision,
# DeepSeek-V3.1 UD ladder) for full-VRAM speed — no --n-cpu-moe, no
# PCIe expert streaming, all 62 layers + 128K q8_0 KV in 96GiB.
#
# One GPU = one model: this unit Conflicts= podman-vllm (Qwen3-Coder).
# Switch back to Qwen: drop the autoStart force below and rebuild, or
# ad hoc `systemctl start podman-vllm` (the conflict stops this unit).
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Same nixpkgs, re-imported with CUDA scoped to this one package —
  # global cudaSupport=true would rebuild a large part of the closure.
  # sm_120 = RTX PRO 6000 Blackwell. cudaPackages here is CUDA 12.9;
  # do NOT move to 13.2 (known gibberish-output bug with llama.cpp).
  pkgsCuda = import pkgs.path {
    inherit (pkgs) system;
    config = {
      allowUnfree = true;
      cudaSupport = true;
      cudaCapabilities = ["12.0"];
    };
  };
  llama-cpp = pkgsCuda.llama-cpp;
  modelDir = "/var/lib/models/MiniMax-M2.7-GGUF/UD-IQ3_XXS";
in {
  virtualisation.oci-containers.containers.vllm.autoStart = lib.mkForce false;

  systemd.services.llama-minimax = {
    # PARKED since swap #4 (2026-07-26): vllm-qwen36-27b owns the GPU
    # autostart. Manual A/B: `systemctl start llama-minimax`.
    # (Leaving multi-user.target here made every nixos-rebuild switch
    # start this unit, Conflicts=-killing the active vLLM engine.)
    wantedBy = [];
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    conflicts = ["podman-vllm.service"];
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
      OOMScoreAdjust = -900;
    };
    script = ''
      exec ${llama-cpp}/bin/llama-server \
        --model ${modelDir}/MiniMax-M2.7-UD-IQ3_XXS-00001-of-00003.gguf \
        --alias MiniMax-M2.7-IQ3_XXS \
        -ngl 999 \
        -c 147456 -fa on -ctk q8_0 -ctv q8_0 \
        -b 4096 -ub 2048 \
        --cache-ram 32768 \
        --threads 26 \
        --jinja \
        --temp 1.0 --top-p 0.95 --top-k 40 \
        --host 0.0.0.0 --port 30000
    '';
    # Flag notes:
    # -ngl 999            everything on the GPU; ~74.6G weights + ~18.5G KV
    #                     (q8_0 @ 144K) + compute buffers ≈ 96.9G of 97.9G
    # -c 147456           144K ctx (196608 native); max that fits with q8_0
    #                     KV — 152K needs +3.3GiB we don't have. Unified KV:
    #                     one request may use the full 144K. Full 196K needs
    #                     --n-cpu-moe 6-8 or lower KV quant (research in
    #                     handoff doc / agent://CtxOptionsTask).
    # -fa on              required for quantized V cache
    # --cache-ram 32768   host-RAM prompt cache (PR #16391): evicted/idle
    #                     slot KV is copied GPU->RAM and restored over
    #                     PCIe on prefix match instead of re-prefilling
    #                     (~1-2s vs ~12s at 31K ctx). 32GiB ≈ 256K tokens
    #                     of parked sessions at ~128KB/token (q8_0 KV);
    #                     guest RAM is idle now that weights live in VRAM.
    #                     --cache-idle-slots is default-on and completes it.
    # --threads 26        28 vCPUs, leave 2 for the server/OS
    # --jinja             use the GGUF-embedded chat template => native
    #                     MiniMax tool-call format on /v1/chat/completions
    # sampling            official MiniMax recommendation
  };
}
