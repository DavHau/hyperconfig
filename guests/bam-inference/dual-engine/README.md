# Parked: dual-engine co-hosting (Qwen3.6-27B-FP8 + 35B-A3B NVFP4)

Ran co-hosted 2026-07-27, parked the same day: the VRAM carve left too
little KV for many concurrent sessions (27B 475K tokens + 35B 157K
@131K/req vs 891K @262K solo). Full story, benchmarks and the OOM
post-mortem: machines/bam/inference-handoff.md swap #5.

The 35B was a monster when it ran: 284.6 t/s single-stream, 2,219 t/s
aggregate @16u, MTP acceptance 67.9%. Weights remain on the guest at
/var/lib/models/Qwen3.6-35B-A3B-NVFP4-Fast (23.7G).

## To re-enable

1. Import ./dual-engine/vllm-qwen36-35b.nix in configuration.nix.
2. vllm-qwen36-27b.nix: shrink `--kv-cache-memory` (30GiB = 32212254720
   worked) and ADD `--gpu-memory-utilization 0.66` — the 0.90 default
   crash-loops next to a resident co-tenant (init free-VRAM check).
   Both engines' claims must fit under the free VRAM left by the WARM
   co-tenant.
3. Keep >=3.5GiB card-wide free: FlashInfer sm_120 fused-MoE workspace
   (~534MiB, vllm#49476) + ViT activations allocate at request time,
   invisible to boot profiling.
4. Host: add 30001 to the inbound multiport rule in
   machines/bam/inference-net.nix.
5. omp: re-add the bam-vm-35b provider in modules/nixos/omp-common.nix
   and the live ~/.omp/profiles/afk/agent/models.yml, then
   `env -u PI_CODING_AGENT_DIR OMP_PROFILE=afk omp models refresh`.
6. Note: the 35B checkpoint embeds fp8 KV (vllm#40756 risk with
   MTP+GDN; accepted for a secondary engine — blast radius is that
   engine restarting).
