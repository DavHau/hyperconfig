{ ... }:
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
            # Install-time only: `clan machines install` writes the clan var here.
            keylocation = "file:///tmp/zfs.key";
          };
          # No key file on the installed system — it is fed over ssh at boot,
          # or typed at the console.
          postCreateHook = "zfs change-key -o keylocation=prompt zroot/root";
        };
        "root/nix" = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.mountpoint = "/nix";
          options."com.sun:auto-snapshot" = "false";
        };
      };
    };
  };
}
