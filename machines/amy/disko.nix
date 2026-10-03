{
  disko.devices = {
    disk = {
      root = {
        type = "disk";
        device = "/dev/nvme0n1";
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
                mountOptions = [ "nofail" ];
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
          mountpoint = "none";
          compression = "zstd-1";
          acltype = "posixacl";
          xattr = "sa";
          "com.sun:auto-snapshot" = "true";
        };
        options.ashift = "12";
        datasets = {
          "root" = {
            type = "zfs_fs";
            options = {
              encryption = "aes-256-gcm";
              keyformat = "passphrase";
              #keylocation = "file:///tmp/secret.key";
              keylocation = "prompt";
            };
            mountpoint = "/";

          };
          "root/nix" = {
            type = "zfs_fs";
            options.mountpoint = "/nix";
            options."com.sun:auto-snapshot" = "false";
            mountpoint = "/nix";
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
            options = {
              mountpoint = "/home/grmpf/bigfiles";
              recordsize = "1M";
            };
            mountpoint = "/home/grmpf/bigfiles";
          };
          "root/nobackup/temp" = {
            type = "zfs_fs";
            options.mountpoint = "/home/grmpf/temp";
            mountpoint = "/home/grmpf/temp";
          };
          # Rebuildable, high-churn state: kept out of the root dataset's
          # auto-snapshots (inherits auto-snapshot=false from nobackup).
          # Created by hand on the live pool (2026-10-03); disko only
          # applies these on a fresh install.
          "root/nobackup/sbox-state" = {
            type = "zfs_fs";
            options = {
              mountpoint = "/home/grmpf/.local/state/sbox";
              compression = "zstd-1";
            };
            mountpoint = "/home/grmpf/.local/state/sbox";
          };
          "root/nobackup/cache" = {
            type = "zfs_fs";
            options = {
              mountpoint = "/home/grmpf/.cache";
              compression = "zstd-1";
            };
            mountpoint = "/home/grmpf/.cache";
          };
          "root/nobackup/docker" = {
            type = "zfs_fs";
            options.mountpoint = "/home/grmpf/.local/share/docker";
            mountpoint = "/home/grmpf/.local/share/docker";
          };
          "root/nobackup/steam" = {
            type = "zfs_fs";
            options.mountpoint = "/home/grmpf/.local/share/Steam";
            mountpoint = "/home/grmpf/.local/share/Steam";
          };
          # Emergency headroom: never mounted, holds 30G back from the pool.
          # When the pool is full: `zfs set refreservation=none zroot/reserved`.
          "reserved" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              canmount = "off";
              refreservation = "30G";
            };
          };
        };
      };
    };
  };
}
