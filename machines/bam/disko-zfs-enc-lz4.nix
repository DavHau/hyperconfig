# TODO: !!!!!!!!!
# PLEASE ADD SOME SWAP TO THE NEXT SERVER!

{ config, pkgs, ... }:
let
  zfs-key = pkgs.runCommand "zfs-key" { nativeBuildInputs = [pkgs.busybox];} ''
    dd if=/dev/urandom bs=32 count=1 | xxd -c32 -p > $out
  '';
in
{
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  boot.initrd.systemd.storePaths = [zfs-key];

  disko.devices = {
    disk = {
      x = rec {
        type = "disk";
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_251653801553";
        content = {
          type = "gpt";
          partitions = {
            "boot" = {
              size = "1M";
              type = "EF02"; # for grub MBR
              priority = 1;
            };
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
          compression = "lz4";
          atime = "off";
        };
        datasets = {
          "root" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              encryption = "aes-256-gcm";
              keyformat = "hex";
              keylocation = "file://${zfs-key}";
            };
          };
          "root/nixos" = {
            type = "zfs_fs";
            options.mountpoint = "/";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
