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
  passed-through NVMe (disko, mounts by partlabel). Reachable at its LAN
  DHCP address (currently `192.168.8.107`) — the VM is **bridged onto the
  LAN via br0**; bam's own LAN address moved to br0 (was on enp8s0, now
  `192.168.8.150` — DHCP lease changed with the bridge MAC).

## Serving endpoint

OpenAI-compatible API: `http://<vm-lan-ip>:30000/v1`. Model ids:
`Qwen3-Coder-Next-FP8` (primary) and `default` (alias, kept so existing
client selections survive model swaps). omp discovers the catalog at
runtime (`discovery: openai-models-list`) — nothing to edit client-side
on model changes; run `omp models refresh` to bust its cache.

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

Supervision: `podman-vllm.service`, `Restart=always`, ordered after
`gpu-powercap.service` (which needs `nvidia-persistenced`).

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
2. **Phase-2 network lockdown dropped** (user decision): VM stays bridged
   on br0 with a LAN address until its config moves out of this clan.
   `machines/bam/inference-net.nix` contains only the bridge; the NAT
   segment + nftables isolation from the plan were reverted before deploy.
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

- **Yggdrasil from the guest is half-working:** the guest peers with bam
  (`tls://192.168.8.150:6446`, session establishes, byte counters move both
  ways) but end-to-end TCP/ICMP over ygg addresses times out
  (guest addr `200:9fde:424e:c7ef:7e8f:3293:1fb9:b580`). Not blocking while
  the VM is LAN-bridged; debug before any future lockdown that depends on it.
- **Guest sshd PerSourcePenalties (OpenSSH ≥9.8):** repeated failed auth
  (e.g. ssh-agent key spam) gets a source IP temporarily banned — looks like
  "valid key rejected". Use `IdentitiesOnly yes` (workstation has a
  `Host 192.168.8.107 inference-vm` block) or restart sshd in the guest.
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
# guest
ssh root@192.168.8.107                     # keys: ds@nintendo-ds, root@nintendo-ds, grmpf
journalctl -u podman-vllm -f
curl -s localhost:30000/v1/models
# deploy
nixos-rebuild switch --flake .#bam --target-host root@bam.d          # host
nixos-rebuild switch --flake ./guests/bam-inference#inference \
  --target-host root@192.168.8.107                                   # guest
```
