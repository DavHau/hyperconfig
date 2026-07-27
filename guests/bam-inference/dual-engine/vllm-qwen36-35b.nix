# Qwen3.6-35B-A3B (MoE, 3B active) unsloth NVFP4-Fast — CO-HOSTED
# next to the 27B FP8 engine on the same GPU (port 30001 vs 30000).
# Cheap co-tenant: 23.7GB NVFP4 weights, and only 10 full-attention
# layers (2 KV heads x 256 dim) pay per-token KV (~12.2KiB/t
# measured); the 30 GDN layers keep constant per-seq state. VRAM
# split + benchmarks: handoff swap #5.
#
# unsloth card (huggingface.co/unsloth/Qwen3.6-35B-A3B-NVFP4-Fast):
# - MTP module included => same spec-config lever as the 27B.
# - NEVER let the MoE backend fall back to Marlin (2x slower than
#   cute-DSL/CUTLASS/flashinfer_trtllm); check the boot log for
#   trtllm fused_moe autotuning after every image bump.
# - accuracy within noise of BF16 (MMLU-Pro 85.58 vs 85.75).
#
# NOT "default"-aliased: the 27B stays the default coding model.
{
  config,
  lib,
  ...
}: {
  virtualisation.oci-containers.containers.vllm-qwen36-35b = {
    # cu129 variant REQUIRED: guest driver is CUDA 12.9 (see
    # vllm-qwen36-27b.nix).
    image = "docker.io/vllm/vllm-openai:v0.26.0-cu129-ubuntu2404";
    autoStart = true; # co-hosted with vllm-qwen36-27b since 2026-07-27
    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--network=host"
      "--ipc=host"
    ];
    environment.PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
    volumes = [
      "/var/lib/models:/models"
      # JIT caches are config-hash-keyed => safe to share the volume
      # with the 27B container.
      "/var/lib/vllm-cache:/root/.cache"
    ];
    # image entrypoint is `vllm serve`; first arg = model path
    cmd = [
      "/models/Qwen3.6-35B-A3B-NVFP4-Fast"
      "--served-model-name" "Qwen3.6-35B-A3B-NVFP4"
      # dual-stack; inbound is public-v6 only (routed isolation)
      "--host" "::"
      "--port" "30001"
      # 131K cap (was 262K): the pool must hold >= one max-len request,
      # so the 2GiB pool (below) forces the cap. The 27B keeps 262K.
      "--max-model-len" "131072"
      "--max-num-seqs" "16"
      # 2GiB KV ≈ 172K tokens at ~12.2KiB/t — the checkpoint embeds an
      # fp8 KV scheme (kv_cache_dtype=fp8 auto-applied; bf16 would be
      # ~24.4KiB/t). Deliberately accepted (2026-07-27) despite the
      # vllm#40756 fp8-KV+MTP+GDN risk: blast radius = this secondary
      # engine restarting. Shrunk 4->2GiB after the 04:26 OOM crash:
      # the FlashInfer sm_120 fused-MoE workspace (~534MiB, vllm#49476)
      # + ViT activations allocate at REQUEST time and are invisible to
      # boot profiling — the card needs real free VRAM at all times.
      # Claim 0.30 (28.5GiB) also re-enters cleanly next to the warm
      # 27B (~30.1GiB free), ending the post-OOM restart crash-loop.
      "--gpu-memory-utilization" "0.30"
      "--kv-cache-memory" "2147483648"
      "--enable-chunked-prefill"
      "--enable-prefix-caching"
      "--async-scheduling"
      # MTP head baked into the checkpoint; drafter does NOT inherit
      # --attention-backend (llm_base_proposer.py) => force FlashInfer
      # inside the spec config, same as the 27B.
      "--speculative-config" ''{"method":"mtp","num_speculative_tokens":2,"attention_backend":"FLASHINFER"}''
      "--reasoning-parser" "qwen3"
      "--tool-call-parser" "qwen3_coder"
      "--enable-auto-tool-choice"
      # greedy server defaults; stochastic sampling tanks MTP acceptance
      "--generation-config" "vllm"
      # FlashAttention v2 has no tuned sm_120 decode path (measured on
      # the 27B); FlashInfer is the Blackwell-tuned backend.
      "--attention-backend" "FLASHINFER"
      "--stream-interval" "4"
      "--api-server-count" "2"
    ];
  };

  systemd.services.podman-vllm-qwen36-35b = {
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    # conflicts with every SOLO engine that assumes it owns the whole
    # GPU — but NOT with podman-vllm-qwen36-27b: co-hosting is the point.
    conflicts = [
      "podman-vllm.service"
      "podman-vllm-minimax.service"
      "llama-minimax.service"
      "ik-llama-minimax.service"
      "llama-qwen36.service"
    ];
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 10;
    };
  };

  networking.firewall.allowedTCPPorts = [30001];
}
