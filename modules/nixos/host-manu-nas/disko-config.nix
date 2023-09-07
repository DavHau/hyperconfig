{...}: {
  disko.devices.disk = {
    # TODO: the disko script was not applied yet for the root disk.
    #    Do this once swithcing the ssd
    # root-disk = {
    #   type = "disk";
    #   device = "/dev/disk/by-id/usb-SanDisk_Ultra_4C530001161024123022-0:0";
    #   content = {
    #     type = "gpt";
    #     partitions = {
    #       ESP = {
    #         size = "512M";
    #         type = "EF00";
    #         content = {
    #           type = "filesystem";
    #           format = "vfat";
    #           mountpoint = "/boot";
    #         };
    #       };
    #       root = {
    #         size = "100%";
    #         content = {
    #           type = "filesystem";
    #           format = "ext4";
    #           mountpoint = "/";
    #         };
    #       };
    #     };
    #   };
    # };
    raid-disk-1 = {
      type = "disk";
      device = "/dev/disk/by-id/wwn-0x50014ee2663b9923";
      content = {
        type = "gpt";
        partitions = {
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "raidpool";
            };
          };
        };
      };
    };
    raid-disk-2 = {
      type = "disk";
      device = "/dev/disk/by-id/wwn-0x50014ee2baa55439";
      content = {
        type = "gpt";
        partitions = {
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "raidpool";
            };
          };
        };
      };
    };
    raid-disk-3 = {
      type ="disk";
      device = "/dev/disk/by-id/wwn-0x50014ee20ffa618b";
      content = {
        type = "gpt";
        partitions = {
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "raidpool";
            };
          };
        };
      };
    };
    raid-disk-4 = {
      type = "disk";
      device = "/dev/disk/by-id/wwn-0x50014ee2663b98ff";
      content = {
        type = "gpt";
        partitions = {
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "raidpool";
            };
          };
        };
      };
    };
  };

  disko.devices.zpool = {
    raidpool = {
      type = "zpool";
      mode = "raidz";
      rootFsOptions = {
        compression = "zstd";
        "com.sun:auto-snapshot" = "false";
      };
      mountpoint = null;
      postCreateHook = "zfs snapshot raidpool@blank";

      datasets = {
        raidset = {
          type = "zfs_fs";
          options.mountpoint = "legacy";
          mountpoint = "/raid";
        };
      };
    };
  };
}
