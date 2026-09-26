# Single virtio-scsi disk on a SeaBIOS (no EFI) Proxmox guest: GRUB in the
# BIOS boot partition, ext4 root (no ZFS on 1G of RAM).
#
# Installed by flashing a disko image over the running cloud image instead of
# nixos-anywhere (kexec does not fit in 1G). The image is `imageSize` small;
# growPartition + autoResize stretch root to the real 30G disk on first boot.
{ config, pkgs, ... }:
{
  # disko passes vmTools an aggregateModules tree as `kernel`; current nixpkgs
  # vmTools can neither boot that (no bzImage) nor close its modules. No ZFS
  # here, so hand it the plain kernel whatever disko asks for.
  disko.imageBuilder.pkgs = pkgs.extend (_: prev: {
    vmTools = prev.vmTools // {
      override = args: prev.vmTools.override (args // {
        kernel = config.boot.kernelPackages.kernel;
      });
    };
  });

  boot.loader.grub.enable = true;

  boot.growPartition = true;
  fileSystems."/".autoResize = true;

  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    imageSize = "6G";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
