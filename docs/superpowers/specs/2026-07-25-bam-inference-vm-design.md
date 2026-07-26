# bam Inference VM — Design

Date: 2026-07-25
Status: approved pending final spec review

## Goal

Dedicate bam (Ryzen 9 9950X, 128GB RAM, RTX PRO 6000 Blackwell 96GB) almost
entirely to an LLM inference VM. The VM gets the GPU and a 1TB NVMe via PCI
passthrough, 14 of 16 cores, and 108GB RAM. The host keeps 1 core, ~8GB
effective RAM, and its remaining light services. The VM is managed as a
foreign machine (own config, later own repo/admins); bam only provisions the
bare VM.

## Measured hardware facts (2026-07-25)

| Component | Fact |
|---|---|
| CPU | 9950X, 16C/32T, 1 NUMA node, 2 CCDs (cores 0–7 CCD0, 8–15 CCD1); SMT sibling of CPU N is N+16 (verify `lscpu -e` before pinning) |
| RAM | 128GB (123.4Gi usable) |
| GPU | 01:00.0 `10de:2bb1` + audio 01:00.1 `10de:22e8`, **alone in IOMMU group 13**, LnkCap Gen5 x16, LnkSta x16 |
| iGPU | Granite Ridge Radeon 71:00.0 — host display/console |
| 1TB NVMe | WD SN7100, 0a:00.0 `15b7:5045`, **alone in IOMMU group 21**, chipset-attached Gen4 x4 |
| 2TB NVMe | WD SN7100, 02:00.0 `15b7:5045`, CPU-direct, host root (xfs) |
| HDDs | 4× 4TB SAS, leftover `zfs_member` (vault pool, not imported) — stay host-side, untouched |
| IOMMU | AMD-Vi active; no ACS override needed (never use it) |

**Trap:** both NVMe controllers share PCI ID `15b7:5045` — the 1TB drive MUST
be bound to vfio-pci by address (`0000:0a:00.0`), never by ID.

## Section 1: Host resource partitioning

### CPU — 7+7 symmetric

- Guest: 14 cores / 28 vCPUs. Cluster 0 = physical cores 1–7 (CCD0, CPUs
  1–7,17–23); cluster 1 = cores 9–15 (CCD1, CPUs 9–15,25–31).
- Guest topology exposes **two L3 domains** (libvirt `clusters=2` or `dies=2`
  × `cores=7` × `threads=2` — whichever renders 2 L3 domains in guest
  `lstopo`; decide at implementation, verify in guest).
- `vcpupin` 1:1, vCPU SMT pairs mapped to physical SMT siblings; clusters
  never span CCDs.
- Host OS: core 0 (CPUs 0,16). Emulator + vhost-net: core 8 (CPUs 8,24) —
  QEMU emulates almost nothing (GPU and NVMe are passthrough; no virtio-blk),
  but core 8 is free under 7+7 so it hosts emulatorpin and vhost threads.
- Containment via systemd cgroup partitioning, NOT `isolcpus`:
  - `system.slice` / `user.slice`: `AllowedCPUs=0,16`
  - `machine.slice` (VM): `AllowedCPUs=1-7,9-15,17-23,25-31`
  - emulator threads pinned to 8,24 via libvirt `emulatorpin`.

### Memory — static 1G hugepages

- `hugepagesz=1G hugepages=108` + `hugetlb_free_vmemmap=on` (HVO, ~1.7GB
  struct-page savings). **No CMA** (`hugetlb_cma` rejected: VM holds pages
  24/7, CMA adds a boot-order failure mode for zero benefit).
- Guest RAM = 108GiB (covers SGLang ~64GB hierarchical host-KV cache +
  headroom; weights live in VRAM, safetensors load streams via evictable
  guest page cache).
- Host: ~15GB real → ~8GB services + ~3GB QEMU non-hugepage overhead (VFIO
  pinning bookkeeping, vhost) + slack. zram swap stays.
- libvirt: `<memoryBacking><hugepages/><locked/><nosharepages/></memoryBacking>`,
  memlock limit raised in qemu.conf to cover full guest allocation.
  `memballoon none` (ballooning + hugepages + VFIO don't mix).

### Kernel / scheduling

- Cmdline: `iommu=pt hugepagesz=1G hugepages=108 hugetlb_free_vmemmap=on
  nohz_full=1-7,9-15,17-23,25-31 rcu_nocbs=1-7,9-15,17-23,25-31`
- Unbound workqueues steered to host CPUs via
  `/sys/devices/virtual/workqueue/cpumask`.
- `kvm_amd avic=1` — Zen 5 has x2AVIC, so x2APIC guests are fine (the
  "AVIC requires xAPIC" caveat is Zen 3 era). Verify `dmesg | grep -i avic`.
- vfio-pci MSI-X host-side IRQ vectors pinned to guest CPUs via post-start
  hook (per-IRQ `smp_affinity` writes; `default_smp_affinity` only affects
  new IRQs). irqbalance is not enabled on NixOS — keep it that way.
- CPU governor `performance`. C-state limiting on host core: deferred —
  measure p99 first, add only if needed.

## Section 2: VFIO passthrough

- GPU 01:00.0 + 01:00.1 passed together (one slot, one group).
  Bind: `vfio-pci.ids=10de:2bb1,10de:22e8`; blacklist nouveau/nvidia on host.
  Host display remains on iGPU (amdgpu).
- 1TB NVMe 0a:00.0 passed as whole controller (bare-metal disk perf, no
  virtio, no host I/O path). Bind by ADDRESS via initrd
  `driver_override=vfio-pci` for `0000:0a:00.0` before nvme probes
  (`boot.initrd.preDeviceCommands` or equivalent).

### BAR / MMIO aperture (highest-risk step)

- Host BIOS: Above-4G Decoding + Resizable BAR ON (verify).
- Guest q35 + OVMF; 64-bit MMIO window must exceed the 96GB BAR1:
  OVMF fw_cfg `opt/ovmf/X-PciMmio64Mb` (e.g. 262144 = 256G) or verified
  OVMF auto-sizing.
- Guest checks: `lspci -vv` BAR1 = 96G prefetchable;
  `nvidia-smi -q | grep -A3 BAR1`.

## Section 3: VM definition

- `virtualisation.libvirtd.enable` + NixVirt flake module; domain XML
  declarative in new module `machines/bam/inference-vm.nix`.
- q35, OVMF (UEFI, no secure boot), headless: serial console
  (`console=ttyS0`) for bootstrap/debug, no emulated VGA after install.
- CPU `host-passthrough`, `topoext`, `invtsc` exposed (guest clocksource
  tsc); `kvm hint-dedicated=on`.
- 28 vCPUs pinned per Section 1; minimal device model (no USB/tablet/sound).
- Autostart on host boot.

## Section 4: Storage

- VM's only disk = passed-through 1TB NVMe. Guest partitions it: ESP + root;
  model weights at `/var/lib/models` (~100GB budget, fits easily).
- Tradeoff accepted: chipset Gen4 x4 (~7GB/s) → cold 80GB model load ~12s,
  once per service start. Swapping SSD roles would require host reinstall —
  not worth it.
- Host 2TB root untouched. HDDs stay host-side for future vault
  (if vault pool returns, add ZFS ARC cap then — currently no ZFS on host).

## Section 5: Networking — two phases

**Phase 1 (bootstrap):** host bridge `br0` on the LAN NIC; VM virtio-net
(vhost, 2 queues, static MAC) on br0, LAN DHCP → install + ssh over LAN.

**Phase 2 (lockdown, host-enforced):**
- VM NIC moves to routed/NAT libvirt network `virbr-inf` (10.77.0.0/24).
- Host nftables: VM → WAN masqueraded/allowed; VM → RFC1918 and VM → host
  services dropped (only DNS/DHCP on virbr-inf allowed). No inbound
  forwarding from LAN.
- Guest stays reachable via a LAN-independent path (public IPv6 routed
  through the host, or an overlay); users reach :30000 and ssh over
  that path only. VM admins cannot undo host-side isolation.
- Switch = redefine interface in NixVirt domain + VM reboot; guest is DHCP
  in both phases.

## Section 6: Guest system

**Bootstrap:** minimal NixOS installed once (nixos-anywhere or ISO, over
LAN/serial): sshd + admin keys + flakes. bam's repo does NOT import guest
config; guest config is a standalone flake applied over ssh (later moved to
its own repo with different admins).

**Guest config:**
- NVIDIA proprietary driver, open kernel modules (required on Blackwell),
  ≥570 series; CUDA 13.x, NOT 13.2 (MoE quantization bug).
- `nvidia-persistenced`; systemd oneshot after it:
  `nvidia-smi -pm 1 && nvidia-smi -pl 450` → **450W power cap**.
- SGLang ≥0.5.8.post1 serving
  `dervig/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4` (~80GB NVFP4) from
  `/var/lib/models`, OpenAI-compatible API on port 30000, 2–3 users.
- Launch flags: `--model-path
  /var/lib/models/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4
  --trust-remote-code --tp 1
  --kv-cache-dtype fp8_e5m2 --mem-fraction-static 0.92
  --max-running-requests 4 --chunked-prefill-size 8192
  --context-length 131072 --enable-hierarchical-cache` with ~64GB host KV
  cache in system RAM. If hierarchical cache is unstable: disable flag and
  note the deviation in the handoff.
- Supervised systemd service: `Restart=always`, ordered after network +
  power-cap oneshot, enabled at boot.
- Headless; nothing else uses the GPU.

**Acceptance:**
1. Chat completion on `http://localhost:30000/v1/chat/completions` returns
   coherent text.
2. Report tokens/sec from a ~500-token generation.
3. 32K-token prompt prefills without OOM.
4. Deliverables: NixOS config changes, exact final launch command, all
   deviations (versions, dropped flags, driver version).

## Section 7: Host cleanup + verification

Remove from bam: `ollama.nix`, docker + docker rootless, `./buildbot`,
`nix.settings.max-jobs = 16` (→ 1). Keep: nextcloud, vikunja, jackett,
overlays, ssh.

Host verification checklist:
- `HugePages_Total` = 108, free before VM start.
- `system.slice`/`user.slice` confined to CPUs 0,16; machine.slice to guest
  CPUs; emulator on 8,24.
- vfio-pci bound: 01:00.0, 01:00.1, 0a:00.0 — and NOT 02:00.0.
- AVIC active in dmesg.
- Full host reboot → VM autostarts, SGLang serves, host services healthy
  within 2 threads / ~8GB.

## Rejected alternatives

- **Proxmox / other hypervisor:** performance-equivalent (same QEMU/KVM);
  would discard declarative NixOS host management. Rejected.
- **Raw QEMU systemd service:** fully declarative but re-implements libvirt
  lifecycle/VFIO tooling for zero perf gain. Rejected.
- **CMA-backed hugepages:** benefit only when hugepages are released at
  runtime; this VM never releases them. Rejected.
- **vfio-pci by ID for NVMe:** would capture the host root SSD (identical
  IDs). Rejected — bind by address.
- **15 flat cores for guest:** more threads but blind cross-CCD scheduling;
  symmetric 7+7 with visible L3 domains preferred.
- **vLLM:** crashes on this checkpoint on SM120 — SGLang mandated.
