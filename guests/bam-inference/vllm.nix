{config, lib, ...}: {
  # 450W power cap, applied after persistenced holds the GPU.
  systemd.services.gpu-powercap = {
    wantedBy = ["multi-user.target"];
    after = ["nvidia-persistenced.service"];
    requires = ["nvidia-persistenced.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${config.hardware.nvidia.package.bin}/bin/nvidia-smi -pm 1
      ${config.hardware.nvidia.package.bin}/bin/nvidia-smi -pl 450
    '';
  };

  # Model choice (2026-07-25): Qwen3-Coder-Next-FP8 (80B-A3B MoE, official
  # Qwen FP8 quant) replaces MiniMax-M2.7-REAP-NVFP4. The MiniMax M2 family
  # has unbounded thinking (official repo issues #25/#52/#77; no off
  # switch) and the REAP quant additionally produced syntax-broken code.
  # Qwen3-Coder-Next: 74.2% SWE-bench Verified, non-reasoning by design,
  # 256K native context, hybrid Gated-DeltaNet attention (only 12 of 48
  # layers keep KV -> tiny cache). FP8 W8A8 path works on SM120; known
  # perf-risk: missing fused-MoE tuning configs (vllm#44688) — benchmark.
  # Old MiniMax checkpoint kept on disk for rollback.
  hardware.nvidia-container-toolkit.enable = true;
  virtualisation.podman.enable = true;
  virtualisation.oci-containers = {
    backend = "podman";
    containers.vllm = {
      image = "docker.io/vllm/vllm-openai:v0.26.0";
      autoStart = true;
      # NOTE: PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True is
      # REJECTED by vLLM when a KV OffloadingConnector is active; no
      # offload tier configured for this model (hybrid-attention KV is
      # small enough not to need one).
      extraOptions = [
        "--device=nvidia.com/gpu=all"
        "--network=host"
        # host IPC: container shares the guest's /dev/shm (~54G on 108G
        # RAM); --shm-size is rejected together with --ipc=host by podman.
        "--ipc=host"
      ];
      volumes = ["/var/lib/models:/models"];
      # image entrypoint is `vllm serve`; first arg = model path
      cmd = [
        "/models/Qwen3-Coder-Next-FP8"
        # Primary id = real model name so API clients (omp discovery)
        # display what is actually served; "default" kept as alias for
        # continuity of existing client selections.
        "--served-model-name" "Qwen3-Coder-Next-FP8" "default"
        "--host" "0.0.0.0"
        "--port" "30000"
        # Agent/tool-calling support: without these, any request carrying
        # `tools` is rejected 400. qwen3_coder is the card-documented
        # parser. Non-reasoning model: NO reasoning parser.
        "--enable-auto-tool-choice"
        "--tool-call-parser" "qwen3_coder"
        # HF card "Best Practices" sampling, as server-side defaults
        # (explicit per-request params still win).
        "--override-generation-config"
        ''{"temperature": 1.0, "top_p": 0.95, "top_k": 40}''
        # 256K native. Weights ~75GiB; KV is tiny (12 full-attention
        # layers x 2 KV heads x 256 dim): ~6.5GiB bf16 for 256K tokens.
        "--max-model-len" "262144"
        "--gpu-memory-utilization" "0.92"
        "--max-num-seqs" "4"
      ];
    };
  };
  # Supervision: oci-containers generates podman-vllm.service; harden it.
  systemd.services.podman-vllm = {
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 10;
    };
  };
  systemd.tmpfiles.rules = ["d /var/lib/models 0755 root root -"];
  networking.firewall.allowedTCPPorts = [30000];
}
