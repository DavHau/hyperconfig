# Qwen3.6-27B official FP8 on vLLM — the multi-user engine for this
# model. Research (2026-07-26, agent://QwenServeResearch): vLLM has an
# official recipe with a dedicated RTX Pro 6000 section; measured on
# this GPU class: 1429 t/s aggregate @40 users (FP8+MTP2, vllm PR
# #42603 validator table) vs llama.cpp's 262.8 @4u. Continuous
# batching + ~0.5-1M-token KV pool vs llama.cpp's single 262K unified
# pool. FP8 checkpoint is Qwen-calibrated, quality ≈ our UD-Q8_K_XL.
#
# CRASH CAVEAT (why this deviates from the recipe): open vllm#40756 —
# MTP + hybrid-GDN + concurrency + **fp8 KV cache** → CUDA illegal
# memory access (repro'd on sm_120; fix PR #48475 open). Community-
# confirmed stable combo = MTP on + DEFAULT bf16 KV, so NO
# --kv-cache-dtype fp8 here even though the recipe ships it. MTP n=2
# not 3: under high concurrency n=2 beat n=3 by 23% on this GPU
# (#42603); acceptance decays per draft position with batch size.
#
# ACTIVE production engine (autoStart). Other engines are parked with
# wantedBy=[]; swap via `systemctl start <unit>` (Conflicts= stops
# whichever engine holds the GPU).
{
  config,
  lib,
  ...
}: {
  virtualisation.oci-containers.containers.vllm-qwen36 = {
    # cu129 variant REQUIRED: guest driver is CUDA 12.9; the plain
    # v0.26.0 tag is built for cu13 / r580+ drivers.
    image = "docker.io/vllm/vllm-openai:v0.26.0-cu129-ubuntu2404";
    autoStart = true; # production engine since swap #4 (2026-07-26)
    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--network=host"
      "--ipc=host"
    ];
    environment.PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
    volumes = [
      "/var/lib/models:/models"
      # persist torch.compile / FlashInfer / Triton JIT caches across
      # restarts (Restart=always): saves ~50s of the 111s init and the
      # ~10 first-request JIT stalls. Config-hash-keyed, safe.
      "/var/lib/vllm-cache:/root/.cache"
    ];
    # image entrypoint is `vllm serve`; first arg = model path
    cmd = [
      "/models/Qwen3.6-27B-FP8"
      "--served-model-name" "Qwen3.6-27B-FP8" "default"
      "--host" "0.0.0.0"
      "--port" "30000"
      # full native context; hybrid GDN = only 16 full-attn layers pay
      # per-token KV, bf16 KV for 262K is cheap on 96G with 31G weights
      "--max-model-len" "262144"
      # 16 seqs: 1->8u scaling measured near-linear (695 t/s agg @8u,
      # BW-bound model predicts ~1.1-1.3K agg @16u); KV pool covers
      # 16 x ~55K ctx. Watch vllm:num_preemptions_total (0 so far);
      # add --watermark 0.02 if it moves.
      "--max-num-seqs" "16"
      # 60GiB KV pool (~890K tokens), replaces --gpu-memory-utilization
      # 0.90 (gave 54.4G): vLLM's own boot accounting says 63.2G is
      # usable; 60G leaves ~3.2G for runtime Triton JIT. If OOM: 58G.
      "--kv-cache-memory" "64424509440"
      "--enable-chunked-prefill"
      # GDN prefix caching is "align"-mode experimental: only the
      # full-attn layers get hits, GDN layers re-prefill. Still a win
      # for agent loops per the recipe.
      "--enable-prefix-caching"
      "--async-scheduling"
      # MTP head is baked into the official checkpoint; MTP ⊂ Eagle
      # family in vLLM config so async-scheduling is compatible.
      # drafter attention: the MTP head deliberately does NOT inherit
      # --attention-backend (llm_base_proposer.py) and auto-picked the
      # sm_120-pathological FA2 — force FlashInfer via spec config.
      "--speculative-config" ''{"method":"mtp","num_speculative_tokens":2,"attention_backend":"FLASHINFER"}''
      "--reasoning-parser" "qwen3"
      "--tool-call-parser" "qwen3_coder"
      "--enable-auto-tool-choice"
      # vLLM defaults instead of the model's temp=1.0 generation
      # config: stochastic sampling tanks MTP acceptance; agent
      # clients set their own sampling per request anyway.
      "--generation-config" "vllm"
      # Auto-selection picks FlashAttention v2 — no tuned sm_120
      # decode path; measured 100/53/39 t/s at 0/41K/76K ctx depth
      # (~14x steeper than KV-bandwidth math; MTP acceptance healthy
      # 75%, prefix cache ruled out). FlashInfer is Blackwell-tuned.
      # NOTE: VLLM_ATTENTION_BACKEND env is dead in 0.26 — CLI only.
      "--attention-backend" "FLASHINFER"
      # frontend CPU: flush SSE every 4 tokens instead of every token
      # (~700 flush cycles/s at 8u x 90 t/s), and 2 API processes in
      # front of the one engine (chat-template rendering + tool-call
      # parsing are GIL-bound; 28 vCPUs mostly idle).
      "--stream-interval" "4"
      "--api-server-count" "2"
    ];
    # Deliberately NOT set:
    # --kv-cache-dtype fp8      the vllm#40756 crash combo (see header)
    # --max-num-batched-tokens  default 8192 measured best (theogravity
    #                           sweep: 16-64K all lose 2-3%)
    # mamba cache dtypes        never fp8 — wrong outputs (same sweep)
  };

  systemd.services.podman-vllm-qwen36 = {
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
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

  systemd.tmpfiles.rules = ["d /var/lib/vllm-cache 0755 root root -"];
}
