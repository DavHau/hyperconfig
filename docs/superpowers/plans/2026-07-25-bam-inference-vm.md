# bam Inference VM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn bam into a thin NixOS host running one KVM VM that owns the RTX PRO 6000 (VFIO), the 1TB NVMe (VFIO), 14 of 16 cores, and 108GB RAM, serving MiniMax-M2.7-REAP via SGLang on port 30000.

**Architecture:** NixOS host + libvirt/QEMU with declarative domain XML (NixVirt). Host confined to core 0 / ~8GB via systemd cgroup slices + static 1G hugepages. Guest is a foreign NixOS machine (own standalone flake, applied over ssh), bootstrapped from installer ISO + nixos-anywhere. Two-phase networking: LAN bridge for bootstrap, host-enforced NAT isolation afterwards.

**Tech Stack:** NixOS (clan-core repo), libvirt/QEMU/OVMF, NixVirt, VFIO, systemd-networkd bridge, nftables, nixos-anywhere + disko, NVIDIA open kernel modules ≥570 / CUDA 13.x (≠13.2), SGLang ≥0.5.8.post1 via podman + nvidia-container-toolkit.

Spec: `docs/superpowers/specs/2026-07-25-bam-inference-vm-design.md` — read it first; it contains measured hardware facts (PCI addresses, IOMMU groups) that this plan uses verbatim.

## Global Constraints

- GPU: 01:00.0 `10de:2bb1` + 01:00.1 `10de:22e8` (IOMMU group 13). NVMe to pass: `0000:0a:00.0` (group 21). NVMe to NEVER touch: `0000:02:00.0` (host root; same PCI ID `15b7:5045` → never bind vfio by ID for NVMe).
- Host keeps CPUs 0,16 (core 0). Emulator/vhost: CPUs 8,24 (core 8). Guest vCPUs: CPUs 1-7,9-15,17-23,25-31 (7+7 across CCDs, verify `lscpu -e` sibling layout first).
- Guest RAM 108GiB from static 1G hugepages. No CMA. memballoon none.
- GPU power cap in guest: 450W.
- SGLang ≥0.5.8.post1; CUDA 13.x but NOT 13.2; NVIDIA open kernel modules ≥570.
- Model: `dervig/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4` at `/var/lib/models/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4` in guest.
- bam's flake must NOT import the guest's NixOS config (guest = foreign machine).
- LAN NIC on bam: `enp8s0` (192.168.8.189/24, systemd-networkd).
- Deploy host config with `clan machines update bam` (fallback: `nixos-rebuild switch --flake .#bam --target-host root@bam.d`).
- No ACS override, ever.
- Repo rule: new NixOS features = separate module files, imported from `machines/bam/configuration.nix`.

## Dependency Map

- Task 1 (host cleanup + imports): no dependencies
- Task 2 (partitioning/VFIO module): no dependencies
- Task 3 (bridge module): no dependencies
- Task 4 (NixVirt input + domain module): no dependencies
- Task 5 (deploy + host verification): depends on 1,2,3,4
- Task 6 (guest bootstrap install): depends on 5
- Task 7 (guest flake: driver, 450W, SGLang): no dependencies (authored any time; applied after 6)
- Task 8 (apply guest config + acceptance tests): depends on 6,7
- Task 9 (phase-2 network lockdown): depends on 8
- Task 10 (final reboot verification + handoff): depends on 9

Waves:
1. Tasks 1, 2, 3, 4, 7
2. Task 5
3. Task 6
4. Task 8
5. Task 9
6. Task 10

---

### Task 1: Host cleanup + module imports

**Files:**
- Modify: `machines/bam/configuration.nix`
- Delete: `machines/bam/ollama.nix`

**Interfaces:**
- Produces: imports of `./inference-host.nix`, `./inference-net.nix`, `./inference-vm.nix` (created by Tasks 2–4).

**Depends on:** none

- [ ] **Step 1: Edit `machines/bam/configuration.nix`**

Remove: `./ollama.nix` import, `./buildbot` import, `virtualisation.docker.enable`, `virtualisation.docker.rootless.enable`, the four `9933..9966` buildbot firewall ports. Change `nix.settings.max-jobs = 16;` → `1`. Add the three new imports:

```nix
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/sbox.nix
    ../../modules/nixos/nix-caches.nix
    ./disko-xfs.nix
    ./nextcloud.nix
    ./vikunja.nix
    ./inference-host.nix
    ./inference-net.nix
    ./inference-vm.nix
    ../../modules/nixos/vibepn.nix
  ];
```

Keep: hostId, nextcloud, vikunja, jackett, ssh keys, vibepn.

- [ ] **Step 2: Delete `machines/bam/ollama.nix`** (leave `machines/bam/buildbot/` directory in tree only if other machines reference it — grep first; if unreferenced, delete it too).

- [ ] **Step 3: Verify evaluation**

Run: `nix build .#checks.x86_64-linux.bam --no-link` — expected: fails ONLY on missing `inference-*.nix` files (created by Tasks 2–4; in the wave merge this passes). If it fails for any other reason, fix.

### Task 2: Host partitioning + VFIO module

**Files:**
- Create: `machines/bam/inference-host.nix`

**Interfaces:**
- Produces: kernel cmdline (hugepages/nohz/vfio), `system.slice`/`user.slice` = CPUs 0,16, machine.slice = guest CPUs, libvirtd enabled with OVMF, vfio IRQ-affinity qemu hook.

**Depends on:** none

- [ ] **Step 1: Write `machines/bam/inference-host.nix`**

```nix
# Dedicates bam's hardware to the inference VM.
# CPU plan (9950X, SMT sibling of CPU n is n+16 — verified via lscpu -e):
#   core 0  (CPUs 0,16)  -> host OS
#   core 8  (CPUs 8,24)  -> QEMU emulator + vhost threads
#   cores 1-7,9-15       -> guest vCPUs (7 per CCD, symmetric)
{pkgs, lib, ...}: {
  boot.kernelParams = [
    "iommu=pt"
    "hugepagesz=1G"
    "hugepages=108"
    "hugetlb_free_vmemmap=on"
    "nohz_full=1-7,9-15,17-23,25-31"
    "rcu_nocbs=1-7,9-15,17-23,25-31"
    # GPU (unique IDs, safe to bind by ID). NVMe is NOT here: both SSDs
    # share 15b7:5045 — the 1TB one is bound by address in initrd below.
    "vfio-pci.ids=10de:2bb1,10de:22e8"
  ];
  boot.blacklistedKernelModules = ["nouveau" "nvidia"];
  boot.initrd.kernelModules = ["vfio_pci" "vfio" "vfio_iommu_type1"];

  # Bind ONLY the 1TB NVMe (0000:0a:00.0) to vfio-pci, by address, before
  # the nvme driver probes it. 0000:02:00.0 is the host root disk.
  boot.initrd.preDeviceCommands = ''
    if [ -e /sys/bus/pci/devices/0000:0a:00.0 ]; then
      echo vfio-pci > /sys/bus/pci/devices/0000:0a:00.0/driver_override
    fi
  '';

  # x2AVIC (Zen 5): hardware interrupt injection into the guest.
  boot.extraModprobeConfig = ''
    options kvm-amd avic=1
  '';

  powerManagement.cpuFreqGovernor = "performance";

  # Confine host to core 0; VM slice gets everything else
  # (8,24 included: emulator threads are pinned there via emulatorpin).
  systemd.slices.system.sliceConfig.AllowedCPUs = "0,16";
  systemd.slices.user.sliceConfig.AllowedCPUs = "0,16";
  systemd.slices.machine.sliceConfig.AllowedCPUs = "1-15,17-31";

  # Unbound kernel workqueues -> host CPUs only (mask for CPUs 0,16).
  systemd.services.workqueue-affinity = {
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "oneshot";
    script = ''
      echo 00010001 > /sys/devices/virtual/workqueue/cpumask
    '';
  };

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true; # simplest for VFIO + hugepages; single-VM host
      ovmf.enable = true;
      ovmf.packages = [pkgs.OVMFFull.fd];
    };
    onBoot = "start";
    onShutdown = "shutdown";
    # After VM start: move host-side vfio MSI-X vectors onto guest CPUs.
    # (VFIO IRQs are real host IRQs; default affinity would put GPU
    # interrupt handling on the host core.)
    hooks.qemu.vfio-irq-affinity = pkgs.writeShellScript "vfio-irq-affinity" ''
      [ "$2" = "started" ] || exit 0
      sleep 5
      for irq in $(grep vfio /proc/interrupts | cut -d: -f1 | tr -d ' '); do
        echo "1-7,9-15,17-23,25-31" > /proc/irq/$irq/smp_affinity_list 2>/dev/null || true
      done
    '';
  };
}
```

- [ ] **Step 2: Verify module evaluates**

Run: `nix-instantiate --parse machines/bam/inference-host.nix` — expected: prints parsed expression, no error. (Full eval happens in Task 5.)

### Task 3: Phase-1 bridge module

**Files:**
- Create: `machines/bam/inference-net.nix`

**Interfaces:**
- Produces: bridge `br0` enslaving `enp8s0`, host LAN address moves to `br0`. Consumed by Task 4's domain XML (`<interface type='bridge'><source bridge='br0'/>`).

**Depends on:** none

- [ ] **Step 1: Write `machines/bam/inference-net.nix`**

```nix
# Phase 1: LAN bridge so the guest can be installed/managed over the LAN.
# Phase 2 (Task 9) replaces the guest's bridge NIC with an isolated NAT
# network; br0 itself stays (harmless).
{
  systemd.network = {
    netdevs."20-br0".netdevConfig = {
      Kind = "bridge";
      Name = "br0";
    };
    networks."30-enp8s0-slave" = {
      matchConfig.Name = "enp8s0";
      networkConfig.Bridge = "br0";
    };
    networks."40-br0" = {
      matchConfig.Name = "br0";
      networkConfig.DHCP = "yes";
    };
  };
}
```

CAUTION: bam's LAN address currently lives on `enp8s0` via clan/networkd defaults. Check `modules/` and clan inventory for an existing network unit matching `enp8s0` (grep `enp8s0` and `DHCP` across repo + `networkctl status enp8s0` on bam); the slave unit above must take precedence (lower-numbered unit wins on Match). Deploying this WILL briefly drop LAN connectivity — bam stays reachable over ygg/vibepn/hyprspace overlays if the bridge misbehaves.

- [ ] **Step 2: Verify parse**

Run: `nix-instantiate --parse machines/bam/inference-net.nix` — expected: clean parse.

### Task 4: NixVirt input + domain definition

**Files:**
- Modify: `flake.nix` (add input)
- Create: `machines/bam/inference-vm.nix`

**Interfaces:**
- Consumes: `br0` (Task 3), OVMF/libvirtd (Task 2).
- Produces: libvirt domain `inference`, autostarted, with GPU + NVMe hostdevs, 28 pinned vCPUs, 108GiB hugepage RAM.

**Depends on:** none (file-level; runtime depends on 2,3)

- [ ] **Step 1: Add NixVirt input to `flake.nix`**

```nix
    nixvirt.url = "github:AshleyYakeley/NixVirt";
    nixvirt.inputs.nixpkgs.follows = "nixpkgs";
```

- [ ] **Step 2: Write `machines/bam/inference-vm.nix`**

Note on topology: libvirt `<topology>` supports `dies`/`clusters` (clusters since libvirt 10.1). Start with `dies='2'`; acceptance check is two L3 domains in guest `lstopo`. If the guest shows one L3, switch to `clusters='2'` — record whichever works.

```nix
{pkgs, inputs, ...}: let
  domainXML = pkgs.writeText "inference.xml" ''
    <domain type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
      <name>inference</name>
      <uuid>7d1f4b2a-0000-4000-8000-badc0ffee000</uuid>
      <memory unit="GiB">108</memory>
      <memoryBacking>
        <hugepages><page size="1" unit="GiB"/></hugepages>
        <locked/>
        <nosharepages/>
      </memoryBacking>
      <memtune>
        <hard_limit unit="GiB">116</hard_limit>
      </memtune>
      <vcpu placement="static">28</vcpu>
      <cputune>
        <!-- cluster 0: cores 1-7 (CCD0); vCPU 2n -> CPU, 2n+1 -> SMT sibling -->
        <vcpupin vcpu="0"  cpuset="1"/><vcpupin vcpu="1"  cpuset="17"/>
        <vcpupin vcpu="2"  cpuset="2"/><vcpupin vcpu="3"  cpuset="18"/>
        <vcpupin vcpu="4"  cpuset="3"/><vcpupin vcpu="5"  cpuset="19"/>
        <vcpupin vcpu="6"  cpuset="4"/><vcpupin vcpu="7"  cpuset="20"/>
        <vcpupin vcpu="8"  cpuset="5"/><vcpupin vcpu="9"  cpuset="21"/>
        <vcpupin vcpu="10" cpuset="6"/><vcpupin vcpu="11" cpuset="22"/>
        <vcpupin vcpu="12" cpuset="7"/><vcpupin vcpu="13" cpuset="23"/>
        <!-- cluster 1: cores 9-15 (CCD1) -->
        <vcpupin vcpu="14" cpuset="9"/><vcpupin vcpu="15" cpuset="25"/>
        <vcpupin vcpu="16" cpuset="10"/><vcpupin vcpu="17" cpuset="26"/>
        <vcpupin vcpu="18" cpuset="11"/><vcpupin vcpu="19" cpuset="27"/>
        <vcpupin vcpu="20" cpuset="12"/><vcpupin vcpu="21" cpuset="28"/>
        <vcpupin vcpu="22" cpuset="13"/><vcpupin vcpu="23" cpuset="29"/>
        <vcpupin vcpu="24" cpuset="14"/><vcpupin vcpu="25" cpuset="30"/>
        <vcpupin vcpu="26" cpuset="15"/><vcpupin vcpu="27" cpuset="31"/>
        <emulatorpin cpuset="8,24"/>
      </cputune>
      <os firmware="efi">
        <type arch="x86_64" machine="q35">hvm</type>
        <boot dev="hd"/>
      </os>
      <features>
        <acpi/><apic/>
        <kvm><hint-dedicated state="on"/></kvm>
      </features>
      <cpu mode="host-passthrough" check="none">
        <topology sockets="1" dies="2" cores="7" threads="2"/>
        <cache mode="passthrough"/>
        <feature policy="require" name="topoext"/>
        <feature policy="require" name="invtsc"/>
      </cpu>
      <clock offset="utc">
        <timer name="tsc" present="yes" mode="native"/>
      </clock>
      <devices>
        <!-- RTX PRO 6000: VGA + audio fn, same slot in guest -->
        <hostdev mode="subsystem" type="pci" managed="yes">
          <source><address domain="0x0000" bus="0x01" slot="0x00" function="0x0"/></source>
          <address type="pci" domain="0x0000" bus="0x05" slot="0x00" function="0x0" multifunction="on"/>
        </hostdev>
        <hostdev mode="subsystem" type="pci" managed="yes">
          <source><address domain="0x0000" bus="0x01" slot="0x00" function="0x1"/></source>
          <address type="pci" domain="0x0000" bus="0x05" slot="0x00" function="0x1"/>
        </hostdev>
        <!-- 1TB NVMe controller (already vfio-bound in initrd) -->
        <hostdev mode="subsystem" type="pci" managed="no">
          <source><address domain="0x0000" bus="0x0a" slot="0x00" function="0x0"/></source>
        </hostdev>
        <interface type="bridge">
          <source bridge="br0"/>
          <model type="virtio"/>
          <mac address="52:54:00:6b:a3:01"/>
          <driver name="vhost" queues="2"/>
        </interface>
        <serial type="pty"><target port="0"/></serial>
        <console type="pty"><target type="serial" port="0"/></console>
        <memballoon model="none"/>
      </devices>
      <qemu:commandline>
        <!-- 64-bit MMIO aperture for the 96GB BAR1: 256 GiB -->
        <qemu:arg value="-fw_cfg"/>
        <qemu:arg value="name=opt/ovmf/X-PciMmio64Mb,string=262144"/>
      </qemu:commandline>
    </domain>
  '';
in {
  imports = [inputs.nixvirt.nixosModules.default];
  virtualisation.libvirt = {
    enable = true;
    connections."qemu:///system".domains = [
      {
        definition = domainXML;
        active = true;
      }
    ];
  };
}
```

Implementation notes for the executor:
- `inputs` reaches modules via this repo's clan `specialArgs` (see `modules/flake-parts/nixosConfigurations.nix`) — no plumbing needed.
- NixVirt module option shape (`virtualisation.libvirt.connections`) must be checked against the pinned NixVirt revision; adjust attribute names if the API differs. Get its source per repo rule (`~/projects/`, clone if missing).
- For the bootstrap boot only, Task 6 temporarily attaches an installer ISO via `virsh` — the declarative XML stays ISO-free.

- [ ] **Step 3: Verify**

Run: `nix flake lock --update-input nixvirt && nix-instantiate --parse machines/bam/inference-vm.nix` — expected: lock updated, clean parse.

### Task 5: Deploy + host verification

**Files:** none (operational)

**Interfaces:**
- Consumes: Tasks 1–4 merged.
- Produces: running partitioned host with vfio-bound devices and defined `inference` domain.

**Depends on:** 1, 2, 3, 4

- [ ] **Step 1: Pre-checks on bam**

```
ssh root@bam.d 'lscpu -e=CPU,CORE | sort -k2 -n'
```
Expected: core N ↔ CPUs N and N+16. If layout differs, STOP and fix all cpusets/pins in Tasks 2/4 to the real sibling map.

```
ssh root@bam.d 'nix-shell -p pciutils --run "lspci -vv -s 01:00.0" | grep -E "Physical Slot|LnkSta:"'
```
Expected: `Width x16`.

- [ ] **Step 2: BIOS check (manual, one-time)** — reboot into firmware setup (or `systemctl reboot --firmware-setup`): confirm Above-4G Decoding = ON and Resizable BAR = ON. Record state in handoff notes.

- [ ] **Step 3: Build then deploy**

```
nix build .#checks.x86_64-linux.bam --no-link   # full eval must pass now
clan machines update bam
ssh root@bam.d reboot
```

- [ ] **Step 4: Verify host partitioning after reboot**

```
ssh root@bam.d '
grep HugePages_Total /proc/meminfo        # expect 108
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages  # expect 108
cat /proc/cmdline | tr " " "\n" | grep -E "nohz|rcu_nocbs|vfio|hugepage"
dmesg | grep -i avic                       # expect AVIC enabled
lspci -nnk -s 01:00.0; lspci -nnk -s 01:00.1; lspci -nnk -s 0a:00.0
                                           # all three: Kernel driver in use: vfio-pci
lspci -nnk -s 02:00.0                      # MUST be: nvme
systemctl show system.slice -p AllowedCPUs # expect 0 16
networkctl status br0                      # expect routable, LAN address
virsh list --all                           # expect: inference (shut off or running)
free -h                                    # host sees ~15G usable
'
```
Every line must match. The `02:00.0 → nvme` check is the do-not-skip one.

### Task 6: Guest bootstrap install

**Files:**
- Create: `guests/bam-inference/flake.nix`
- Create: `guests/bam-inference/configuration.nix`
- Create: `guests/bam-inference/disko.nix`

**Interfaces:**
- Produces: minimal NixOS on the passed-through NVMe, reachable at `ssh root@<vm-lan-ip>`; standalone flake `guests/bam-inference` (NOT imported by bam's flake — the `guests/` dir is outside the clan inventory; verify `nix flake show` output is unchanged).

**Depends on:** 5

- [ ] **Step 1: Write `guests/bam-inference/flake.nix`**

```nix
{
  description = "bam inference VM guest (standalone; will move to its own repo)";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = {nixpkgs, disko, ...}: {
    nixosConfigurations.inference = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./disko.nix
        ./configuration.nix
      ];
    };
  };
}
```

- [ ] **Step 2: Write `guests/bam-inference/disko.nix`**

```nix
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1"; # only NVMe visible in the guest
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
        };
        root = {
          size = "100%";
          content = { type = "filesystem"; format = "xfs"; mountpoint = "/"; };
        };
      };
    };
  };
}
```

- [ ] **Step 3: Write `guests/bam-inference/configuration.nix`** (bootstrap-minimal; Task 7 extends this same file)

```nix
{...}: {
  networking.hostName = "inference";
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = ["console=ttyS0,115200"];
  networking.useDHCP = true;
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOirp5rceowRPLnkCT2/vlTPgxtRWPeKdMIPnJ7ixJfi ds@nintendo-ds"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfFgVZxuSVWvuNua41SaxGQxpMb6oUuCEiIF7SZpAD1 root@nintendo-ds"
  ];
  nix.settings.experimental-features = ["nix-command" "flakes"];
  system.stateVersion = "26.11";
}
```

- [ ] **Step 4: Boot installer in VM**

```
ssh root@bam.d '
cd /var/lib/libvirt && curl -LO https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso
virsh attach-disk inference /var/lib/libvirt/latest-nixos-minimal-x86_64-linux.iso sda --type cdrom --config
virsh start inference
'
```
Then `virsh console inference` (serial): if the disk is empty, firmware falls through to the CD. In the installer: `sudo su; passwd` (set temp password), get IP via `ip a`.

- [ ] **Step 5: Install via nixos-anywhere from workstation**

```
nix run github:nix-community/nixos-anywhere -- \
  --flake ./guests/bam-inference#inference root@<vm-lan-ip>
```
Expected: disko partitions the guest NVMe, installs, reboots.

- [ ] **Step 6: Detach ISO + verify**

```
ssh root@bam.d 'virsh detach-disk inference sda --config; virsh reboot inference'
ssh root@<vm-lan-ip> '
nixos-version
lspci -nnk | grep -A2 -E "10de|15b7"     # GPU 10de:2bb1 present; NVMe is boot disk
lscpu | grep -E "^CPU\(s\)|Core|Socket"  # 28 CPUs, 14 cores
free -h                                   # ~108G
nix-shell -p hwloc --run lstopo-no-graphics | grep -c L3  # expect 2
lspci -vv -s <gpu-addr> | grep "Region 1" # BAR1 size 96G (needs driver? use: grep -i "prefetchable" )
'
```
If `L3` count is 1: switch `dies="2"` → `clusters="2"` in Task 4's XML, redeploy bam, reboot VM, recheck. Record which attribute worked.

### Task 7: Guest config — driver, power cap, SGLang service

**Files:**
- Modify: `guests/bam-inference/configuration.nix`
- Create: `guests/bam-inference/sglang.nix`

**Interfaces:**
- Consumes: bootstrap `configuration.nix` (Task 6 Step 3 content — if executing in wave 1 before Task 6, author against that exact content).
- Produces: `sglang.service` (podman container, port 30000), `gpu-powercap.service` (450W), nvidia driver config.

**Depends on:** none (file authoring); applied in Task 8

- [ ] **Step 1: Extend `guests/bam-inference/configuration.nix`** — add to the existing module:

```nix
  imports = [./sglang.nix];

  # NVIDIA: Blackwell requires the open kernel modules, >=570.
  services.xserver.enable = false;
  hardware.graphics.enable = true;
  hardware.nvidia = {
    open = true;
    modesetting.enable = false;
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest; # verify >=570 at apply time
  };
  services.xserver.videoDrivers = ["nvidia"]; # loads driver; no X server runs
  nixpkgs.config.allowUnfree = true;
```

(add `config` to the module args: `{config, ...}:`)

- [ ] **Step 2: Write `guests/bam-inference/sglang.nix`**

```nix
{pkgs, ...}: {
  # 450W power cap, applied after persistenced holds the GPU.
  systemd.services.gpu-powercap = {
    wantedBy = ["multi-user.target"];
    after = ["nvidia-persistenced.service"];
    requires = ["nvidia-persistenced.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "powercap" ''
        ${pkgs.linuxPackages.nvidia_x11.bin}/bin/nvidia-smi -pm 1
        ${pkgs.linuxPackages.nvidia_x11.bin}/bin/nvidia-smi -pl 450
      ''}";
    };
  };

  # SGLang in the official container: CUDA 13.x userspace comes from the
  # image (avoids packaging SGLang for NixOS). Requirement: tag >=0.5.8.post1,
  # CUDA 13.x but NOT 13.2 — verify the tag's CUDA version on Docker Hub
  # (lmsysorg/sglang) at apply time and record it in the handoff.
  hardware.nvidia-container-toolkit.enable = true;
  virtualisation.podman.enable = true;
  virtualisation.oci-containers = {
    backend = "podman";
    containers.sglang = {
      image = "lmsysorg/sglang:v0.5.8.post1-cu130"; # verify tag exists; adjust + record
      autoStart = true;
      extraOptions = [
        "--device=nvidia.com/gpu=all"
        "--network=host"
        "--ipc=host"
        "--shm-size=32g"
      ];
      volumes = ["/var/lib/models:/models"];
      cmd = [
        "python3" "-m" "sglang.launch_server"
        "--model-path" "/models/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4"
        "--host" "0.0.0.0"
        "--port" "30000"
        "--trust-remote-code"
        "--tp" "1"
        "--kv-cache-dtype" "fp8_e5m2"
        "--mem-fraction-static" "0.92"
        "--max-running-requests" "4"
        "--chunked-prefill-size" "8192"
        "--context-length" "131072"
        "--enable-hierarchical-cache"
        "--hicache-size" "64"
      ];
    };
  };
  # Supervision: oci-containers generates podman-sglang.service; harden it.
  systemd.services.podman-sglang = {
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
    };
  };
  systemd.tmpfiles.rules = ["d /var/lib/models 0755 root root -"];
  networking.firewall.allowedTCPPorts = [30000];
}
```

Executor notes:
- `--hicache-size 64` = 64GB host KV cache (GiB units — verify against SGLang v0.5.8 docs/source; clone sglang to `~/projects/` per repo rule). If hierarchical cache is unstable at runtime, remove `--enable-hierarchical-cache` + `--hicache-size` and record the deviation.
- `nvidia_x11.bin` path in gpu-powercap must match `hardware.nvidia.package`; if using `nvidiaPackages.latest`, reference `config.hardware.nvidia.package.bin` instead — preferred:
  `ExecStart` lines using `${config.hardware.nvidia.package.bin}/bin/nvidia-smi`.

- [ ] **Step 3: Verify**

Run: `nix flake check ./guests/bam-inference 2>&1 | grep -v warning` — expected: builds `nixosConfigurations.inference` cleanly (eval only; driver license needs `allowUnfree`, already set).

### Task 8: Apply guest config, download model, acceptance tests

**Files:** none (operational)

**Interfaces:**
- Consumes: Tasks 6 (running guest), 7 (config).
- Produces: serving SGLang endpoint; measured numbers for handoff.

**Depends on:** 6, 7

- [ ] **Step 1: Apply**

```
nixos-rebuild switch --flake ./guests/bam-inference#inference --target-host root@<vm-lan-ip>
```

- [ ] **Step 2: Verify driver + power cap**

```
ssh root@<vm-lan-ip> '
nvidia-smi --query-gpu=name,driver_version,power.limit,pstate --format=csv
'
```
Expected: RTX PRO 6000, driver ≥570, `power.limit 450.00 W`. Also `nvidia-smi -q | grep -A3 "BAR1"` → 96GB region. If BAR1 < 96G: fix aperture (Task 4 fw_cfg) before continuing.

- [ ] **Step 3: Download model (~80GB)**

```
ssh root@<vm-lan-ip> '
nix-shell -p python3Packages.huggingface-hub --run \
  "hf download dervig/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4 \
   --local-dir /var/lib/models/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4"
df -h /var/lib/models
'
```
Expected: ~80GB downloaded, >100GB still free.

- [ ] **Step 4: Start + watch**

```
ssh root@<vm-lan-ip> 'systemctl restart podman-sglang; journalctl -fu podman-sglang'
```
Expected: model loads, server ready on 30000. If crash mentions hierarchical cache: drop the two hicache flags (Task 7 note), record deviation.

- [ ] **Step 5: Acceptance tests (run in guest)**

```
curl -s http://localhost:30000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "default",
  "messages": [{"role": "user", "content": "Explain in ~500 words why the sky is blue."}],
  "max_tokens": 600
}'
```
Expected: coherent English text. Record `usage.completion_tokens` and wall time → tokens/sec.

32K prefill test:
```
python3 - <<'EOF'
import json, time, urllib.request
prompt = "The quick brown fox jumps over the lazy dog. " * 3500  # ~32K tokens
body = json.dumps({"model": "default", "messages": [{"role": "user", "content": prompt + "\nSummarize the above in one sentence."}], "max_tokens": 50}).encode()
t = time.time()
r = urllib.request.urlopen(urllib.request.Request("http://localhost:30000/v1/chat/completions", body, {"Content-Type": "application/json"}), timeout=600)
print(time.time() - t, json.load(r)["choices"][0]["message"]["content"])
EOF
```
Expected: completes without OOM; record prefill wall time. Check `nvidia-smi` during: no OOM, memory ~92% (mem-fraction-static).

### Task 9: Phase-2 network lockdown

**Files:**
- Modify: `machines/bam/inference-net.nix` (add NAT network + nftables)
- Modify: `machines/bam/inference-vm.nix` (switch interface)
- Modify: `guests/bam-inference/configuration.nix` (overlay join)

**Interfaces:**
- Consumes: running VM (Task 8).
- Produces: VM with WAN-only egress; user access via overlay only.

**Depends on:** 8

- [ ] **Step 1: Add isolated NAT network to `machines/bam/inference-net.nix`**

```nix
  # Phase 2: isolated NAT segment for the VM. Host-enforced: guest gets
  # WAN egress only — no LAN, no host services.
  systemd.network.netdevs."20-virbr-inf".netdevConfig = {
    Kind = "bridge";
    Name = "virbr-inf";
  };
  systemd.network.networks."40-virbr-inf" = {
    matchConfig.Name = "virbr-inf";
    networkConfig = {
      Address = "10.77.0.1/24";
      DHCPServer = true;
      IPMasquerade = "ipv4";
    };
  };
  networking.nftables.enable = true;
  networking.nftables.tables.inference-isolation = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority -10; policy accept;
        # guest -> private ranges: blocked (WAN only)
        iifname "virbr-inf" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop
      }
      chain input {
        type filter hook input priority -10; policy accept;
        # guest -> host: only DHCP + DNS on the NAT bridge
        iifname "virbr-inf" udp dport { 53, 67 } accept
        iifname "virbr-inf" tcp dport 53 accept
        iifname "virbr-inf" drop
      }
    '';
  };
```

Check first: whether this repo/clan already manages nftables tables (grep `nftables` in `modules/`); integrate rather than duplicate. DNS for the guest: DHCPServer emits the host as DNS by default — host must run a resolver reachable on virbr-inf (`services.resolved` listening) or set `EmitDNS=yes` + `DNS=9.9.9.9` in the DHCPServer config to hand the guest a public resolver directly (simplest; do that).

- [ ] **Step 2: Switch domain interface in `machines/bam/inference-vm.nix`**

Replace `<source bridge="br0"/>` with `<source bridge="virbr-inf"/>`.

- [ ] **Step 3: Guest joins overlay** — add the overlay of choice to `guests/bam-inference/configuration.nix` (yggdrasil is self-contained):

```nix
  services.yggdrasil = {
    enable = true;
    persistentKeys = true;
    settings.Peers = [
      # copy 2-3 public peers from bam's working ygg config or
      # https://publicpeers.neilalexander.dev
    ];
  };
  networking.firewall.interfaces.tun0.allowedTCPPorts = [22 30000];
```
Apply to guest FIRST (while still on br0), record the guest's ygg address, confirm `ssh root@<ygg-addr>` works from your workstation.

- [ ] **Step 4: Flip + verify isolation**

```
clan machines update bam
ssh root@bam.d 'virsh destroy inference; virsh start inference'
```
Then verify from the guest (over ygg ssh):
- `curl -4 -s https://icanhazip.com` → works (WAN OK)
- `ping -c1 192.168.8.189` → fails (LAN blocked)
- `curl -m3 http://192.168.8.1` → fails
- port 30000 reachable via ygg address from workstation, NOT via any LAN address.

### Task 10: Final verification + handoff

**Files:**
- Create: `machines/bam/inference-handoff.md`

**Depends on:** 9

- [ ] **Step 1: Full-stack reboot test**

```
ssh root@bam.d reboot
# wait, then:
ssh root@bam.d 'virsh list; systemctl --failed; free -h'
ssh root@<ygg-addr> 'systemctl is-active podman-sglang gpu-powercap; nvidia-smi --query-gpu=power.limit --format=csv'
curl -s http://[<ygg-addr>]:30000/v1/models
```
Expected: VM autostarted, SGLang serving, host has zero failed units, host services (nextcloud/vikunja/jackett) respond.

- [ ] **Step 2: Write `machines/bam/inference-handoff.md`** containing: exact final SGLang launch command (from `podman inspect sglang`), driver + CUDA + image tag versions, tokens/sec + 32K prefill numbers from Task 8, BIOS settings state, `dies` vs `clusters` outcome, hierarchical-cache kept/dropped, all deviations from spec.

- [ ] **Step 3: `jj describe`** the implementation commit(s) per repo workflow.

---

## Self-review notes

- Spec coverage: Sections 1–7 of the spec map to Tasks 2/4 (partitioning, VM), 2 (VFIO), 3/9 (networking), 6/7/8 (guest, SGLang, 450W, acceptance), 1 (cleanup), 5/10 (verification). BAR aperture: Task 4 fw_cfg + Task 5 BIOS + Task 8 Step 2 check.
- Known verify-at-apply points (explicitly delegated to executor with instructions): NixVirt option shape, SGLang image tag + its CUDA version, `--hicache-size` unit, libvirt dies/clusters rendering, existing networkd/nftables units in clan modules. These are environment facts not determinable from this repo alone; each has a recorded fallback.
- Type consistency: guest flake attr `inference` used consistently; module file names consistent across Tasks 1–4 imports.
