# PARKED — BENCHED AND REJECTED (2026-07-26): MiniMax-M2.7 UD-IQ3_XXS
# GGUF on vLLM via the out-of-tree vllm-gguf-plugin (in-tree GGUF was
# deprecated, vllm#39583). The stack loads and serves (arch mapping,
# shard discovery, minimax_m2 parsers all work), but decodes at
# ~9.4 t/s vs llama.cpp's 140 t/s on the same weights. Root cause,
# established by in-container probe:
#   1. The plugin's CUDA extension never loads: the +cu129 wheel is
#      built against a different torch — `_C_gguf` import dies with
#      `undefined symbol: torch_exception*` and the plugin SILENTLY
#      falls back to Triton JIT for every GGUF op (ops.py catches the
#      ImportError; `_CUDA_ENABLED: False` at runtime).
#   2. Even with the ABI fixed, the wheel carries SASS for sm_75..sm_100
#      only — NO sm_120, NO PTX (cuobjdump-verified) — so the CUDA
#      kernels cannot run on this Blackwell GPU at all.
# Upstream docs concur: "GGUF support in vLLM is highly experimental
# and under-optimized" (+ vllm#35987, same symptom). Reviving this
# route requires a source build against the container torch with
# TORCH_CUDA_ARCH_LIST=12.0 — only worth it once upstream ships
# sm_120 wheels or nixpkgs vllm (0.16.0 today) reaches 0.25+.
#
# Unit stays parked (no autostart): `systemctl start podman-vllm-minimax`
# to re-test; Conflicts= swaps engines.
{
  config,
  lib,
  ...
}: {
  virtualisation.oci-containers.containers.vllm-minimax = {
    # v0.25.1, NOT v0.26.0: plugin 0.0.4 (released 2026-07-12) predates
    # vLLM 0.26's override_quantization_method(hf_config=...) API change
    # and crashes on it (verified). The cu129 image variant matches the
    # plugin's +cu129 wheel. Nix-native vLLM was evaluated and rejected
    # for now: nixpkgs ships vllm 0.16.0, far below the plugin's 0.25+
    # plugin-hook requirement. Revisit when nixpkgs catches up or the
    # plugin releases a 0.26-compatible wheel.
    image = "docker.io/vllm/vllm-openai:v0.25.1-x86_64-cu129";
    autoStart = false;
    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--network=host"
      "--ipc=host"
    ];
    volumes = [
      "/var/lib/models:/models"
      # pip wheel cache so the plugin install is a no-op after first start
      "/var/lib/vllm-pip-cache:/root/.cache/pip"
    ];
    # The vllm-openai image is a runtime image (no nvcc), so the plugin
    # MUST come as a prebuilt wheel; the GitHub release carries the
    # +cu129 build. Installed at start (wheel cached), then exec.
    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      ''
        pip install "vllm-gguf-plugin @ https://github.com/vllm-project/vllm-gguf-plugin/releases/download/v0.0.4/vllm_gguf_plugin-0.0.4%2Bcu129-cp310-abi3-manylinux_2_28_x86_64.whl" && \
        python3 -c 'import pathlib; p = pathlib.Path("/usr/local/lib/python3.12/dist-packages/vllm_gguf_plugin/quantization/config.py"); s = p.read_text(); old = "cls, hf_quant_cfg: dict[str, Any], user_quant: str | None\n"; assert s.count(old) == 1, "compat shim: unexpected plugin source"; p.write_text(s.replace(old, "cls, hf_quant_cfg: dict[str, Any], user_quant: str | None, **_compat\n")); print("gguf-plugin hf_config compat shim applied")' && \
        exec vllm serve /models/MiniMax-M2.7-GGUF/UD-IQ3_XXS/MiniMax-M2.7-UD-IQ3_XXS-00001-of-00003.gguf \
          --served-model-name MiniMax-M2.7-IQ3_XXS default \
          --tokenizer /models/MiniMax-M2.7-hf-meta \
          --host 0.0.0.0 --port 30000 \
          --enable-auto-tool-choice \
          --tool-call-parser minimax_m2 \
          --reasoning-parser minimax_m2 \
          --override-generation-config '{"temperature": 1.0, "top_p": 0.95, "top_k": 40}' \
          --max-model-len 98304 \
          --kv-cache-dtype fp8 \
          --gpu-memory-utilization 0.95 \
          --max-num-seqs 4
      ''
    ];
    # Sizing (measured on first activation, 2026-07-26): weights load at
    # 75.9GiB; with --gpu-memory-utilization 0.95 vLLM has 12.8GiB left
    # for KV — fp8 KV @131072 needs 15.5GiB (engine aborts; its own
    # estimate caps at ~108K). 96K fits with headroom for prefix caching.
    # llama.cpp (llama-minimax.nix) still serves the full 128K if needed.
    # - tokenizer/config prefetched to /var/lib/models/MiniMax-M2.7-hf-meta
    #   (hf-dl-minimax-meta unit) so the container needs no HF network.
    # - parsers: in-tree vLLM names, verified in source (tool_parsers/
    #   __init__.py and reasoning/__init__.py both register "minimax_m2").
  };

  systemd.services.podman-vllm-minimax = {
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    conflicts = [
      "podman-vllm.service"
      "llama-minimax.service"
      "ik-llama-minimax.service"
    ];
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 10;
    };
  };

  systemd.tmpfiles.rules = ["d /var/lib/vllm-pip-cache 0755 root root -"];
}
