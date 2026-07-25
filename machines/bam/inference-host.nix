# Dedicates bam's hardware to the inference VM.
# CPU plan (9950X, SMT sibling of CPU n is n+16 — verified via lscpu -e):
#   core 0  (CPUs 0,16)  -> host OS
#   core 8  (CPUs 8,24)  -> QEMU emulator + vhost threads
#   cores 1-7,9-15       -> guest vCPUs (7 per CCD, symmetric)
{pkgs, lib, ...}: {
  boot.kernelParams = [
    "iommu=pt"
    "hugepagesz=1G"
    # Make /dev/hugepages a 1G-page mount so libvirt/QEMU find a usable
    # hugetlbfs (without this: "Unable to find any usable hugetlbfs mount").
    "default_hugepagesz=1G"
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
  # any driver loads (systemd stage 1: runs before modules-load/udev, so
  # neither nvme nor vfio-pci is registered yet — the override then decides
  # binding whenever each driver appears). 0000:02:00.0 is the host root
  # disk and is never touched.
  boot.initrd.systemd.services.vfio-nvme-override = {
    description = "driver_override=vfio-pci for 0000:0a:00.0";
    wantedBy = ["initrd.target"];
    before = ["systemd-modules-load.service" "systemd-udev-trigger.service"];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ -e /sys/bus/pci/devices/0000:0a:00.0 ]; then
        echo vfio-pci > /sys/bus/pci/devices/0000:0a:00.0/driver_override
      fi
    '';
  };

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
      # OVMF: since nixpkgs 25.11 all QEMU-distributed OVMF images are
      # available by default (virtualisation.libvirtd.qemu.ovmf removed).
    };
    # "ignore": NixVirt (active = true) starts the domain at activation;
    # libvirt-guests starting it too raced and failed every boot.
    onBoot = "ignore";
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
