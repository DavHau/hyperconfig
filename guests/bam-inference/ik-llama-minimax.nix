# MiniMax-M2.7 UD-IQ4_XS on ik_llama.cpp — A/B against mainline
# llama.cpp (llama-minimax.nix). Same model, same offload split; ik's
# fused-MoE + run-time repack should lift the CPU-side expert math.
#
# This unit takes the autostart; llama-minimax (mainline) and
# podman-vllm (Qwen) stay installed. Switch: `systemctl start
# llama-minimax` or `systemctl start podman-vllm` (Conflicts= stops
# this unit); permanent switch = move the wantedBy forces.
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
  ik-llama-cpp = pkgsCuda.callPackage ./ik-llama-cpp.nix {};
  modelDir = "/var/lib/models/MiniMax-M2.7-GGUF/UD-IQ4_XS";
in {
  # Benchmarked 2026-07-26 (same model/offload): prefill parity
  # (1873 vs 1888 t/s), gen @31K ctx 28.4 vs 31.2 t/s — mainline keeps
  # the autostart; this unit stays for manual A/B (`systemctl start
  # ik-llama-minimax`, Conflicts= handles the swap).

  systemd.services.ik-llama-minimax = {
    wantedBy = [];
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    conflicts = ["podman-vllm.service" "llama-minimax.service"];
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
      OOMScoreAdjust = -900;
    };
    script = ''
      exec ${ik-llama-cpp}/bin/llama-server \
        --model ${modelDir}/MiniMax-M2.7-UD-IQ4_XS-00001-of-00004.gguf \
        --alias MiniMax-M2.7-IQ4_XS \
        -ngl 999 --n-cpu-moe 20 \
        -c 131072 -fa on -ctk q8_0 -ctv q8_0 \
        -b 4096 -ub 2048 \
        --no-mmap \
        --threads 26 \
        --jinja \
        --temp 1.0 --top-p 0.95 --top-k 40 \
        --host 0.0.0.0 --port 30000
    '';
    # Differences from the mainline unit (see llama-minimax.nix for the
    # shared flag rationale):
    # -fa on     same syntax as mainline (on|off|auto)
    # -rtr       NOT used: run-time repack to _R4 speeds CPU gen a bit,
    #            but CUDA has no kernels for repacked quants, so the
    #            CPU-resident experts can no longer be batch-offloaded
    #            to the GPU during prefill (measured: 488 vs ~1900 t/s)
    # -fmoe      fused MoE up/gate — default-on in ik, nothing to pass
  };
}
