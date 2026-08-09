# Layout of the running system — som is switched, never installed from here.
# Boot is systemd-boot in the 1G ESP; the 1M EF02 partition is unused.
{ ... }:
{
  disko.devices = {
    disk = {
      x = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_2512ET401381";
        content = {
          type = "gpt";
          partitions = {
            "boot" = {
              size = "1M";
              type = "EF02";
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
        };
        datasets = {
          "root" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
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
