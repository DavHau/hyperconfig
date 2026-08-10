{ config, ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_2512ET401381";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
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

    zpool.zroot = {
      type = "zpool";
      options.ashift = "12";
      rootFsOptions = {
        mountpoint = "none";
        compression = "zstd-1";
        acltype = "posixacl";
        xattr = "sa";
        "com.sun:auto-snapshot" = "true";
      };
      datasets = {
        "root" = {
          type = "zfs_fs";
          mountpoint = "/";
          options = {
            encryption = "aes-256-gcm";
            keyformat = "passphrase";
            # Install-time only, and only on the installer: clan uploads this
            # var to /run/partitioning-secrets before disko runs, because
            # files.passphrase.neededFor = "partitioning".
            keylocation = "file://${config.clan.core.vars.generators.zfs-key.files.passphrase.path}";
          };
          # The key material stays exactly as created - only the pointer moves,
          # since the installer's /run path is gone on the booted system. Must
          # be `zfs set`, not `zfs change-key`: change-key rekeys the dataset
          # and blocks asking for a new passphrase. At boot the key arrives via
          # `zfs load-key -L file:///dev/stdin` (ssh) or the console prompt.
          postCreateHook = "zfs set keylocation=prompt zroot/root";
        };
        "root/nix" = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.mountpoint = "/nix";
          options."com.sun:auto-snapshot" = "false";
        };
        "root/nobackup" = {
          type = "zfs_fs";
          options = {
            mountpoint = "none";
            compression = "zstd-6";
            "com.sun:auto-snapshot" = "false";
          };
        };
        "root/nobackup/bigfiles" = {
          type = "zfs_fs";
          mountpoint = "/home/grmpf/bigfiles";
          options = {
            mountpoint = "/home/grmpf/bigfiles";
            recordsize = "1M";
          };
        };
        "root/nobackup/temp" = {
          type = "zfs_fs";
          mountpoint = "/home/grmpf/temp";
          options.mountpoint = "/home/grmpf/temp";
        };
      };
    };
  };
}
