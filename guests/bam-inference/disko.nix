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
