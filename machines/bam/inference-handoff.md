# bam Inference VM — Handoff (2026-07-25)

Plan: `docs/superpowers/plans/2026-07-25-bam-inference-vm.md`
Spec: `docs/superpowers/specs/2026-07-25-bam-inference-vm-design.md`

## What runs where

- **Host (bam):** thin NixOS host. Keeps CPUs 0,16 (`system.slice`/`user.slice`
  AllowedCPUs), nextcloud + vikunja (:8083) + jackett (:9117), overlays.
  108× 1G hugepages reserved for the VM; GPU (01:00.0/.1) and 1TB NVMe
  (0a:00.0) vfio-bound from initrd; root NVMe 02:00.0 stays on `nvme`.
- **VM `inference`:** libvirt/KVM domain (NixVirt-declared, autostarts),
  28 vCPUs pinned 1:1 (cores 1-7 + 9-15, SMT sibling = +16), emulator on
  8,24; 108GiB locked 1G-hugepage RAM; GPU + NVMe passthrough; q35 + OVMF
  with 256GiB 64-bit MMIO aperture (`opt/ovmf/X-PciMmio64Mb=262144`).
- **Guest OS:** standalone flake `guests/bam-inference` (NOT part of the
  clan inventory). NixOS 26.11pre (nixos-unstable e2587ca), root xfs on the
  passed-through NVMe (disko, mounts by partlabel). Reachable ONLY at
  its public IPv6 `2405:9800:b901:94e3::feed:da7a` (routed via bam's
  br-inf since 2026-07-26; formerly bridged on br0 as 192.168.8.107).
  bam's own LAN address stays `192.168.8.150` on br0.

## Serving endpoint

OpenAI-compatible API: `http://[2405:9800:b901:94e3::feed:da7a]:30000/v1`
— the VM's public IPv6 is its ONLY address since the routed-isolation
change (2026-07-26, see below); the old LAN address 192.168.8.107 is
gone. Active model ids: `Qwen3.6-27B-FP8` + `default` (vLLM, swap #4).
(A second co-hosted engine on :30001 ran briefly — swap #5, parked;
re-enable kit in guests/bam-inference/dual-engine/.) omp discovers
the catalog at runtime (`discovery: openai-models-list`, provider
source: modules/nixos/omp-common.nix) — run `omp models refresh`
after every engine swap or address change.

**Final launch command** (podman container `vllm`, image
`docker.io/vllm/vllm-openai:v0.26.0`, entrypoint `vllm serve`):

```
vllm serve /models/Qwen3-Coder-Next-FP8 \
  --served-model-name Qwen3-Coder-Next-FP8 default \
  --host 0.0.0.0 --port 30000 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --override-generation-config '{"temperature": 1.0, "top_p": 0.95, "top_k": 40}' \
  --max-model-len 262144 --gpu-memory-utilization 0.92 \
  --max-num-seqs 4
```

Supervision (currently **stopped**, kept for one-flip rollback):
`podman-vllm.service`, `Restart=always`, ordered after
`gpu-powercap.service` (which needs `nvidia-persistenced`). The active
unit is `llama-minimax.service` (Conflicts= podman-vllm, holds the
autostart) — see "Model swap #2" below.

## Versions

| Component | Version |
|---|---|
| Guest NixOS | 26.11pre (nixos-unstable e2587caef70c, 2026-07-23) |
| NVIDIA driver (guest, open modules) | **610.43.03** (`nvidiaPackages.latest`) |
| Engine | **vLLM v0.26.0** (released 2026-07-25), official image |
| Container CUDA | 13.0 runtime in image; host driver CUDA-13 capable |
| Model | `Qwen/Qwen3-Coder-Next-FP8` (80B-A3B MoE, official FP8 block-128, ~75GiB, 256K native ctx, non-reasoning) |
| Retired model | `dervig/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4` — kept on disk for rollback; see Deviations |
| libvirt topology | `dies="2"` → guest shows **2 L3 domains** (verified lstopo) |

## Benchmarks (measured 2026-07-25, 450W cap, Qwen3-Coder-Next-FP8)

- **Decode:** 500 tokens in 3.04s → **164 tok/s** (single stream).
- **Tool calling:** clean `tool_calls` via `qwen3_coder` parser.
- **Codegen sanity:** 3/3 JS generations `finish=stop`, all pass
  `node --check` — the same prompts that sent the retired MiniMax into
  30-60K-char runaway thinking with zero output.
- Historical (MiniMax, retired): 129 tok/s decode; 32K prefill 35,047 tok
  in 6.66s (~5.4K tok/s).

## BIOS / BAR state

Above-4G Decoding + Resizable BAR: **effectively ON** — verified from Linux
(host saw GPU BAR1 = 128G at 0x8000000000 pre-passthrough; guest sees BAR1
128G at 0x380000000000, link Gen5 x16). No firmware-setup visit was needed.

## Model swap (2026-07-25, post-handoff): Qwen3-Coder-Next-FP8

The spec'd MiniMax checkpoint was retired the same day: the M2 family has
unbounded thinking (official MiniMax-M2 issues #25/#52/#77; vLLM #36778 —
no off switch), and the REAP quant additionally emitted syntax-broken
code (mid-string quote mismatches). Replaced with Qwen3-Coder-Next-FP8
(80B-A3B, official Qwen FP8, 74.2% SWE-bench Verified, non-reasoning,
256K ctx, hybrid DeltaNet attention → tiny KV). Old weights kept at
`/var/lib/models/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4` for rollback
(config flip in `guests/bam-inference/vllm.nix`). NVFP4 quants of the
Qwen model exist (RedHatAI/GadflyII) but run slower than FP8 on SM120
until vLLM ships native FP4 kernels — revisit then. The deviations list
below is the historical record of the original MiniMax bring-up.

## Model swap #2 (2026-07-26): MiniMax-M2.7 UD-IQ4_XS via llama.cpp

Experiment: the **full** MiniMax-M2.7 (230B-A10B, not the REAP prune that
failed above) at unsloth Dynamic 2.0 4-bit (`UD-IQ4_XS`, 101GiB GGUF).
Model > 96GiB VRAM, so llama.cpp with expert offload: `--n-cpu-moe 20`
keeps the expert tensors of 20 layers (~31GiB) in guest RAM; attention,
shared weights and 128K q8_0 KV stay on GPU (89.8GiB used). Config:
`guests/bam-inference/llama-minimax.nix` (native nixpkgs `llama-cpp`
b10063, CUDA 12.9, sm_120 only).

Measured (2026-07-26): **gen 40 t/s** short ctx / **31 t/s @ 31K ctx**;
**prefill 1888 t/s** (31.5K tok in 16.7s) after `-ub 2048 --no-mmap`
(default ubatch gave 495 t/s — the CPU-resident expert set streams over
PCIe once per ubatch, and mmap'd CPU tensors page-fault single-core).
Bounded thinking (~2K chars, unlike the REAP runaway), clean tool_calls
via `--jinja` + GGUF-embedded template, correct 31.5K-ctx recall.
Model load: 24s. Serves one alias only — the `default` id is gone until
vllm returns.

Rollback to Qwen: remove the `autoStart = lib.mkForce false` in
llama-minimax.nix (or drop the import) and redeploy; ad hoc:
`systemctl start podman-vllm` (conflict stops llama-minimax).

**Quant swap to UD-IQ3_XXS (2026-07-26, current):** the IQ4_XS offload
setup was too slow in practice (esp. multi-user). Swapped to unsloth
**UD-IQ3_XXS** (74.6GiB) — fully GPU-resident, no --n-cpu-moe, 128K
q8_0 KV, 94.6GiB VRAM used. Measured: **short gen 140 t/s** (3.5x),
**65 t/s @ 31K ctx**, **prefill 2596 t/s** (31.5K in 12.2s);
concurrency now GPU-bound and scales: 2 users 115 t/s each, 4 users
76 t/s each (~304 aggregate). Quality gate: 3/3 codegen node --check,
clean tool_calls, correct 31.5K recall; thinking longer than IQ4
(~4.7K vs ~2K chars on the same prompt) — expected 3-bit behavior.
Quant ladder context: UD-IQ3_XXS ≈ 93% of full precision vs ≈97% for
IQ4_XS (DeepSeek-V3.1 UD Aider ladder). IQ4_XS weights kept on disk;
flip back = model path + alias + `--n-cpu-moe 20` in llama-minimax.nix.
Client id changes to `MiniMax-M2.7-IQ3_XXS`.

**vLLM GGUF route — tried and rejected (2026-07-26):**
`guests/bam-inference/vllm-minimax-gguf.nix` (parked; `systemctl start
podman-vllm-minimax` to re-test). The stack works functionally —
vllm-openai:v0.25.1-x86_64-cu129 + vllm-gguf-plugin 0.0.4 wheel +
startup shim for the `hf_config` plugin-API skew, minimax_m2
tool/reasoning parsers, prefetched tokenizer at
/var/lib/models/MiniMax-M2.7-hf-meta, 96K ctx fp8 KV (128K needs
15.5GiB KV, only 12.8 free) — but decodes at **9.4 t/s** vs
llama.cpp's 140. Root-caused in-container: the wheel's CUDA extension
fails to import (torch ABI, `undefined symbol: torch_exception*`) and
the plugin silently Triton-JITs every GGUF op; independently, the
wheel ships no sm_120 SASS and no PTX (cuobjdump), so its CUDA
kernels can't run on Blackwell regardless. Upstream calls vLLM GGUF
"highly experimental and under-optimized" (vllm#35987 matches).
Revive only when upstream ships sm_120 wheels (or source-build with
TORCH_CUDA_ARCH_LIST=12.0 against the exact container torch).

**ik_llama.cpp A/B (2026-07-26):** packaged in
`guests/bam-inference/ik-llama-cpp.nix` (+ parked unit
`ik-llama-minimax`, manual `systemctl start` for A/B; Conflicts=
swaps engines). Result: prefill parity (1873 vs 1888 t/s), gen @31K
ctx 28.4 vs 31.2 t/s — mainline llama.cpp keeps the autostart. ik's
`-rtr` repack is a prefill killer here (488 t/s: CUDA has no kernels
for `_R4` repacked quants, so CPU experts can't batch-offload to the
GPU). Build notes: needs `NIX_ENFORCE_NO_NATIVE = false` (its iqk
kernels don't compile without `-march=native`) and a static build
(no upstream install rules; shared libs leave /build/ RPATHs).

## Model swap #3 (2026-07-26): Qwen3.6-27B dense via llama.cpp

`guests/bam-inference/llama-qwen36.nix`. Qwen3.6-27B (dense, hybrid
Gated DeltaNet, multimodal, 262K native ctx) as unsloth UD-Q8_K_XL
(35.3G, near-lossless) + BF16 mmproj, plus **MTP speculative decoding**:
ggml-org's standalone `mtp-Qwen3.6-27B-Q8_0.gguf` head (3.2G) via
`--spec-type draft-mtp -md ... -ngld 999` (cross-publisher trunk/head
pairing works; llama.cpp b10063 has the Qwen3.5/3.6 hybrid MTP path).
Serves alias `Qwen3.6-27B-Q8` on :30000, full 256K ctx, 50.5G VRAM
(~45G free). MiniMax IQ3_XXS unit stays installed; swap back:
`systemctl start llama-minimax`.

Benchmarks (2026-07-26, MTP on, thinking mode):

- Short gen: **107 t/s** (code probe: 97 t/s, draft acceptance 65%
  — 611 drafted / 395 accepted; prose drafts accept worse: ~83 t/s).
- Long ctx: 41.7K-token prompt prefills at **3025 t/s** (TTFT 13.8s),
  then gen **99 t/s @41K** — near-zero decay vs short (DeltaNet linear
  attention; only sparse full-attn layers pay per-token KV).
- Concurrency (per-stream / aggregate): 1u 82.6; 2u ~81 / **161.8**;
  4u ~66 / **262.8**.
- vs MiniMax-M2.7 IQ3_XXS: slower short-gen (107 vs 140) but *faster*
  at long ctx (99 vs 65 @31-41K), comparable 4-user aggregate (263 vs
  304), 2.7× native ctx headroom (262K vs 144K), and dense-27B
  quality per token is a different tradeoff vs 230B-A10B MoE at 3-bit.

No `--cache-ram` on this unit yet (recurrent DeltaNet state vs host-RAM
prompt-cache interaction untested).

## Model swap #4 (2026-07-26): Qwen3.6-27B-FP8 via vLLM — ACTIVE

`guests/bam-inference/vllm-qwen36-27b.nix` (container `vllm-qwen36-27b`,
image `vllm-openai:v0.26.0-cu129-ubuntu2404` — cu129 tag mandatory on
the 12.9 driver). Official `Qwen/Qwen3.6-27B-FP8` (29G) at
`/var/lib/models/Qwen3.6-27B-FP8`, serving `Qwen3.6-27B-FP8` +
`default` on :30000. Chosen for multi-user throughput per research
(`agent://QwenServeResearch`); config deviates from the official
recipe deliberately: **bf16 KV (NOT fp8)** and **MTP n=2 (not 3)** —
fp8 KV + MTP + GDN + concurrency is the open crash bug vllm#40756
(sm_120 repro; fix PR #48475 unmerged). 86.5G VRAM, **KV pool
807,249 tokens** (bf16!), 262K max per request, 8 seqs.

Benchmarks (warm; cold first request ~34-55 t/s while graphs capture).
vLLM columns: auto-selected FA2 first, then with
`--attention-backend FLASHINFER` (the shipped config):

| | llama.cpp Q8+MTP | vLLM FP8+MTP2 FA2 | vLLM +FlashInfer |
|---|---|---|---|
| short gen 1u | 107 t/s | 101.5 | 98.8 |
| gen @41K ctx | 99 | 53.2 | 90.7 |
| gen @76K ctx | — | 39 | 83.3 |
| prefill 41-76K | 3025 t/s | 2783 | **5331-6595** |
| repeat prompt | ~1-2s (cache-ram) | **TTFT 0.3s** (prefix cache) | same |
| 2u agg | 161.8 | 189.6 | 139-190 (noisy) |
| 4u agg | 262.8 | 374.3 | **333.7** |
| 8u agg | — (4 slots) | 704.5 | **695.1** |

**FA2 depth-decay debug (2026-07-26):** auto-selection picked
FlashAttention v2 — no sm_120-tuned decode path. Decode cost grew
~14x steeper with context than KV-bandwidth math allows (100→53→39
t/s at 0/41K/76K); MTP acceptance was healthy (74.9%: pos0 83%,
pos1 67%) and prefix caching was ruled out (fresh vs cached decode
identical), isolating the attention kernel. FlashInfer restores a
near-flat depth curve AND ~2.2x prefill. Gotcha: the
`VLLM_ATTENTION_BACKEND` env var is silently ignored in 0.26 —
only the `--attention-backend` CLI flag works (env absent from
envs.py; selection in platforms/cuda.py get_attn_backend_cls). The
`cuda.py:482 Using FLASH_ATTN` line still appearing at startup is a
SUBCOMPONENT selector (MTP draft head / ViT); the main model logs
`cuda.py:422 Using AttentionBackendEnum.FLASHINFER backend.`

Read: vLLM wins everything multi-user (~2.6x llama.cpp @4u+, per-
stream stays ~83-90 t/s at 8 users), 2x prefill, prefix caching;
llama.cpp keeps a small single-stream edge (107/99 vs 99/91) —
parked as rollback (`systemctl start llama-qwen36`).

**Tuning round (2026-07-26, research: `agent://VllmTuneResearch`):**
applied in one restart: (1) drafter attention forced to FlashInfer
via `"attention_backend":"FLASHINFER"` INSIDE --speculative-config —
the MTP head deliberately ignores the CLI flag and was still on FA2;
(2) `--kv-cache-memory 60GiB` replaces --gpu-memory-utilization →
KV pool 808K → 891,289 tokens; (3) --max-num-seqs 16; (4) compile/
JIT caches persisted at /var/lib/vllm-cache; (5) --stream-interval 4
+ --api-server-count 2. Result: **16u ~1,140 t/s aggregate**
(per-stream 68-75), 8u unchanged 693, TTFT @41.7K 13.7s → 6.7s,
92.4G VRAM, 0 preemptions. Declined: dynamic MTP schedule (crossover
guess, upstream MTP support caveat — revisit if 9-16u acceptance
decays), --language-model-only (keeps vision), fp8 KV (#40756 still
open; builder-clamp workaround trades crash for silent state
corruption). **CPU KV offload research 2026-07-27
(machines/bam/kv-offload-research-2026-07-27.md) — corrected
picture:** #46972 (MTP
chunk-boundary store) IS already in v0.26.0; #49071 is
Simple-connector-only and #49671 tiering-only — neither blocks the
default OffloadingConnector path. The REAL v0.26.0 blockers: #49118
queued-abort EngineCore kill (enabling change #48596 is in-tag, fix
#49146 main-only — one client disconnect kills the engine, fatal for
agent traffic) and OPEN #49127 (native offload + prefix caching on
Qwen3.6 silently restores a wrong prefix under cache pressure;
reproduces on main 2026-07-23, NO fix anywhere). Adopt only on a tag
with #49146+#49671+#49052+#49226 (v0.26.1/v0.27) AND after a local
A->B->A determinism probe for #49127. When adopting: 27B
--kv-offloading-size 36 / 35B 12 (pinned RAM, 48 of ~60GiB),
offload_prompt_only:false (default true skips decode blocks =
halves agent hit rates), keep expandable_segments but add
--enable-cumem-allocator (hard startup reject otherwise), never
extra-config block_size with MTP (#48919), never
VLLM_USE_SIMPLE_KV_OFFLOAD (#47282) or lmcache backend (#45407).
fp8 KV: STILL blocked — #48475 open/needs-rebase, clamp = silent
cross-request corruption (brasrox 2026-07-19 on #40756); bf16 KV is
the only stable Blackwell+MTP config. Also watch: #49476/#49115
(FlashInfer sm_120 MoE workspace unaccounted in profiling — keep the
35B VRAM cushion), #47602 (MTP acceptance decays with ctx depth).
Full validation checklist in kv-offload-research-2026-07-27.md. Other next-image
pickups: #44700 GDN split batches, NVFP4 27B A/B.

Gotchas:
- vLLM 0.26 returns thinking as `message.reasoning` (llama.cpp uses
  `reasoning_content`) — check omp parses it.
- `--generation-config vllm` = greedy defaults server-side (MTP
  acceptance); clients set their own sampling per request.
- 1M ctx variant possible (YaRN factor 4 + NVFP4 weights + fp8 KV)
  but fp8 KV re-enters the #40756 crash zone: needs MTP off or the
  clamp patch. Not built.
- After every engine swap: `env -u PI_CODING_AGENT_DIR
  OMP_PROFILE=afk omp models refresh` (omp persists discovery cache;
  harness restarts do NOT re-probe).

## Model swap #5 (2026-07-27): + Qwen3.6-35B-A3B NVFP4 — CO-HOSTED, then PARKED

**PARKED same day (user call):** the VRAM carve starved multi-session
KV (27B 475K tokens + 35B 157K @131K/req vs 891K @262K solo — see
the OOM post-mortem below for why the cushion cannot shrink). The
27B is back to its solo config (60GiB pool, 891,289 tokens, no
utilization flag). The whole dual-engine setup is preserved,
unimported, in `guests/bam-inference/dual-engine/` — README there
has the exact re-enable steps (27B flag changes, firewall 30001,
omp provider). 35B weights remain on disk. Section kept for the
benchmarks and hard-won co-tenancy lessons:

`guests/bam-inference/dual-engine/vllm-qwen36-35b.nix` (container
`vllm-qwen36-35b`, same v0.26.0-cu129 image), port 30001, serving
`unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` (23.7G weights at
`/var/lib/models/Qwen3.6-35B-A3B-NVFP4-Fast`). NOT a swap — runs NEXT
TO the 27B on the same GPU; the 27B keeps `default`.

**Why co-hosting is cheap:** the A3B is MoE (256 experts, 8+1 active,
3B active params) with only 10 full-attention layers (2 KV heads x
256 dim) — measured ~12.2KiB/token KV vs the 27B's ~70.6KiB/t.

**KV split (final, after the 04:26 OOM — see post-mortem below):**
27B 32GiB pool = **474,943 tokens**, 262K/request; 35B 2GiB pool =
**157,640 tokens**, capped **131K/request** (pool must hold >= one
max-len request). ~632K tokens of live context total. The 35B runs
**fp8 KV** — NOT set by us: the unsloth NVFP4 checkpoint embeds an
fp8 KV scheme and vLLM applies it silently (that's why its KV is
~12.2KiB/t; bf16 would be ~24.4). Deliberately accepted despite the
#40756 fp8-KV+MTP+GDN risk: blast radius = the secondary engine
restarting. The 27B stays bf16 KV. Resize = one --kv-cache-memory
number + matching --gpu-memory-utilization claim per unit, redeploy.

**VRAM ledger (97,887 MiB card, measured warm):** 27B ~65.5GiB
resident (33.5 non-KV + 32GiB KV) + 35B ~27.2GiB (22.1 weights +
runtime + 2GiB KV) = ~93.9GiB used, **~3.9GiB free — this cushion is
load-bearing, do NOT shrink it** (see post-mortem).

**OOM post-mortem (2026-07-27 04:26):** with the cushion trimmed to
~2.6GiB (then eaten to ~1GiB by 27B warm growth), the first real
multimodal request on the 35B (54.8K-token prompt, 3 images) died:
`FusedMoeRunner::getWorkspaceInfo` OOM allocating a 534MiB FlashInfer
CUTLASS fused-MoE workspace. This workspace + ViT activations
allocate at REQUEST time and are invisible to vLLM's boot profiling
— exactly vllm#49476/#49115 (sm_120 MoE workspace unaccounted).
Worse, the engine then CRASH-LOOPED on restart: the warm 27B left
30.1GiB free, just under the 35B's then-0.32 claim (30.4GiB). Both
lessons applied: 35B pool 4->2GiB + claim 0.30 (re-enters cleanly
next to the warm 27B), request cap 131K. Rule of thumb: keep >=3.5GiB
card-wide free, and every engine's claim must fit under the free VRAM
left by its WARM co-tenant, not the cold one.

**The co-tenancy trap (hit three times, fixed):** vLLM validates
free-VRAM >= `--gpu-memory-utilization` x total at init even when
`--kv-cache-memory` pins the pool absolutely. The 0.90 default can
never pass next to a resident co-tenant => `Restart=always` crash
loop. BOTH units therefore carry BOTH flags: 27B = util 0.68 +
32GiB KV; 35B = util 0.30 + 2GiB KV. The util claim is NOT a usage
cap — it gates only the init free-check and the profile-time KV
bound. Resize = edit one number, redeploy; only that engine restarts.

**Perf levers (all on, mirroring the 27B):** MTP n=2 with FlashInfer
drafter inside --speculative-config, --attention-backend FLASHINFER,
chunked prefill, prefix caching, async scheduling, greedy
--generation-config vllm, stream-interval 4, api-server-count 2.
MoE path auto-selected FlashInfer trtllm::fused_moe kernels — the
unsloth card warns the Marlin fallback is 2x slower; check the boot
log for `fused_moe` autotuning after every image bump.

**Benchmarks (2026-07-27, guest-local, 27B idle-resident):**

- short single-stream: **284.6 t/s** (27B: ~100)
- @41,699 ctx: prefill **25,347 t/s** (TTFT 1.6s), decode **272.7 t/s**
  (27B: 6,215 t/s / 6.7s / 89.1)
- concurrency (300-tok bursts): 4u **795** agg, 8u **1,434** agg,
  16u **2,219** agg (per-stream still 132-150 t/s at 16u)
- MTP acceptance 67.9% (6,851/10,090); answer correctness sanity pass
- 2u run measured an anomalous 240 agg (per-stream halved) — one-off
  scheduler/graph warmup artifact; 4u+ shows no trace of it. Re-check
  if it reproduces.
- 27B co-tenancy cost: **none once warm** (short 95.8 vs ~100 solo =
  noise; deep-ctx 92.1 vs 90.7 solo). Early "88.4" readings are
  warm-up bias — first ~5min after an engine restart run slow (JIT +
  graph re-warm). Both engines restarting simultaneously is safe:
  Restart=always absorbs the init-check race. Bench scripts:
  /root/qv36bench.py (27B), /root/qv36b35bench.py (35B).

**NVFP4 quality (unsloth card):** MMLU-Pro 85.58 / GPQA 87.75 /
AIME25 91.67 vs BF16 85.75/86.36/92.50 — within noise. The planned
27B-NVFP4 A/B (swap #4 next steps) may be moot: for raw speed the
35B-A3B already delivers 3x, with better benchmark scores than the
27B dense on most coding suites.

## Deviations from plan/spec (all deliberate, in order of importance)

1. **Engine: vLLM v0.26.0 instead of SGLang.** The checkpoint is
   **NVFP4A16** (compressed-tensors `nvfp4-pack-quantized`, weights 4-bit
   float, `input_activations: null`). SGLang cannot load it: v0.5.8.post1
   and v0.5.16-cu130 both crash in compressed-tensors scheme detection
   (`AttributeError: 'NoneType' object has no attribute 'num_bits'`), and
   sglang **master** (checked 2026-07-25) still has only a W4A4-NVFP4
   branch. Patching = porting vLLM's W4A16-FP4 linear+fused-MoE methods and
   kernels (days-weeks; SM120 grouped GEMM still open upstream, sglang#19637).
   vLLM v0.26.0 dispatches this format to
   `CompressedTensorsW4A4Fp4(use_a16=True)` for Linear AND MoE (Marlin
   W4A16 route — per SM120 field reports the only reliable NVFP4 path;
   native W4A4 kernels are broken on SM120 in both engines:
   flashinfer#2577, sglang#18954). User pre-approved fallback; GGUF
   (llama.cpp) was the alternate fallback but vLLM keeps the preferred
   NVFP4 checkpoint. `guests/bam-inference/sglang.nix` kept (unimported)
   for reference.
   The "Marlin weight-only" startup warning is expected, not a bug: the
   checkpoint has FP16 activations by construction.
2. **Phase-2 network lockdown: dropped 2026-07-25, REVISED 2026-07-26 —
   now ROUTED + isolated.** The VM moved off br0 onto a port-less
   internal bridge `br-inf` (bam routes; `machines/bam/inference-net.nix`).
   No prefix delegation: bam answers LAN NDP for the single public
   address `2405:9800:b901:94e3::feed:da7a` (networkd IPv6ProxyNDP, no
   daemon) and routes the /128 to the VM (static config in
   `guests/bam-inference/network.nix`; guest gw = 10.42.0.1/fe80::1).
   Policy (iptables chain `inf-fwd` on bam): VM->LAN dropped both
   families (hairpin-proof — LAN dsts die on bam), VM->internet free
   (v4 masqueraded), inbound to the VM = tcp 22/30000 + ICMPv6 to the
   public v6 only; no inbound v4. LAN clients reach the VM exclusively
   via the public address through bam. VM->bam itself (10.42.0.1,
   192.168.8.150) is INPUT, not FORWARD — ssh-jump fallback. vLLM
   binds `--host ::` (dual-stack) — 0.0.0.0 would be unreachable
   from outside. Deploys now target `root@[2405:...::feed:da7a]`.
3. **Context length 139264 (was 98304, spec said 131072).** Measured VRAM
   (torch-visible 95.01 GiB): weights 74.98 + activations 1.30 + non-torch
   0.23 leaves 17.71 GiB physical KV ceiling — but that ceiling is only
   nominal. The failure ladder: 17.71 GiB budget OOMed in FlashInfer
   warmup; 17.44 (147456) OOMed in cudagraph capture; 17.0 (143360)
   booted but OOMed on the first real request (Marlin MoE runtime buffers
   exceed the profiled activation peak). Deployed: explicit
   `--kv-cache-memory-bytes` 16.5 GiB → 139264 max len, 1.21 GiB runtime
   slack, verified with real chat + tool-call requests. Model native
   max_position_embeddings is 196608, so no RoPE scaling/quality cost.
   Multi-user overflow spills to the 64GiB CPU tier via
   `--kv-offloading-backend native`. omp clients discover the
   context window at runtime via /v1/models (`max_model_len`).
4. **KV dtype fp8_e4m3 (spec said e5m2):** e4m3 is the
   documented-recommended, more accurate KV dtype; same size.
5. **Guest install method:** installer-ISO + nixos-anywhere replaced by
   image-style install from the host (user suggestion): NVMe temporarily
   flipped vfio→nvme on bam, formatted with a disko script built from the
   `inference-hostformat` flake variant (device forced to
   `/dev/disk/by-path/pci-0000:0a:00.0-nvme-1`; guest mounts by partlabel so
   the path never matters at runtime), `nixos-install --system`, flip back.
   Consequently `boot.loader.efi.canTouchEfiVariables = false` (OVMF boots
   the fallback `EFI/BOOT/BOOTX64.EFI`; avoids writing guest boot entries
   into bam's NVRAM). disko's `diskoImages` VM builder is broken against
   current nixpkgs (vmTools `kernel`-argument API change) — that's why the
   plain image build was abandoned.
6. **Host kernel cmdline gained `default_hugepagesz=1G`:** without it
   libvirt found no usable 1G hugetlbfs mount ("Unable to find any usable
   hugetlbfs mount") because `/dev/hugepages` defaults to 2M pages.
7. **nixpkgs API drift vs plan snippets:**
   `virtualisation.libvirtd.qemu.ovmf` was removed upstream (OVMF images
   ship by default now), and `boot.initrd.preDeviceCommands` is unsupported
   under systemd stage-1 — replaced by initrd systemd service
   `vfio-nvme-override` (runs before modules-load/udev, writes
   `driver_override=vfio-pci` for 0000:0a:00.0 only).
8. **SGLang flags never exercised:** `--hicache-size` unit was verified
   anyway (gigabytes, sglang v0.5.8.post1 `server_args.py`) before the
   engine switch. vLLM equivalent: `--kv-offloading-size` (GiB).
9. **`--shm-size` dropped:** podman rejects it together with `--ipc=host`;
   host-IPC gives the container the guest's /dev/shm (~54G) anyway.
10. **`dies="2"` worked on the first try** (2 L3 domains in guest lstopo);
    the `clusters="2"` fallback was not needed.
11. **Image reference needs registry prefix:** podman requires
    `docker.io/...` (short-name resolution is off on NixOS).

## Known issues / notes

- **Guest sshd PerSourcePenalties (OpenSSH ≥9.8):** repeated failed auth
  (e.g. ssh-agent key spam) gets a source IP temporarily banned — looks like
  "valid key rejected". Use `IdentitiesOnly yes` (workstation had a
  `Host 192.168.8.107 inference-vm` block — update it to the v6
  address) or restart sshd in the guest.
- The domain XML's stale SATA/SCSI controllers from the bootstrap ISO era
  disappear whenever NixVirt reapplies the canonical XML.
- Host `/proc/meminfo HugePages_Total` only counts the default page size —
  with `default_hugepagesz=1G` it correctly reports 108.
- bam's LAN IP changed to 192.168.8.150 (bridge MAC got a new DHCP lease).
  Overlay names (`bam.d`) were never affected.
- Full-stack reboot test passed 2026-07-25: host reboots → VM autostarts →
  vLLM serving in ~2min total; zero failed units on host and guest;
  nextcloud/vikunja/jackett healthy.

## Operations crib

```sh
# host
virsh list; virsh console inference        # serial console (root pw set)
systemctl status nixvirt libvirtd
# guest (public v6 only; from bam also: ssh root@10.42.0.2)
ssh root@2405:9800:b901:94e3::feed:da7a   # keys: ds@nintendo-ds, root@nintendo-ds, grmpf
journalctl -u podman-vllm-qwen36-27b -f
curl -s "http://[2405:9800:b901:94e3::feed:da7a]:30000/v1/models"
# deploy
nixos-rebuild switch --flake .#bam --target-host root@bam.d          # host
nixos-rebuild switch --flake ./guests/bam-inference#inference \
  --target-host "root@[2405:9800:b901:94e3::feed:da7a]"              # guest
```
