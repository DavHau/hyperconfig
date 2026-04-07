{ pkgs, ... }:
{
  # BOOTLOADER
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # KERNEL
  boot.initrd.availableKernelModules = [ "ahci" "sdhci_pci" ];
  boot.kernelModules = [ "br_netfilter" "xboxdrv" ];
  boot.kernel.sysctl = {
    # See https://wiki.libvirt.org/page/Net.bridge.bridge-nf-call_and_sysctl.conf
    "net.bridge.bridge-nf-call-iptables" = 0;
  };

  # FILESYSTEMS
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "80%";
  boot.supportedFilesystems = [ "ntfs-3g" "exfat" "cifs" "smb" ];
  # boot.initrd.supportedFilesystems = ["zfs"];
}
