{ ... }: {
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.forceImportRoot = true;
  boot.zfs.extraPools = ["vault"];

  # ZFS tuning for RAIDZ2 on spinning disks with 128GB RAM
  boot.kernelParams = [
    "zfs.zfs_arc_max=68719476736" # 64GB ARC
    "zfs.zfs_vdev_async_read_max_active=3"
    "zfs.zfs_vdev_async_write_max_active=10"
    "zfs.zfs_vdev_sync_read_max_active=10"
    "zfs.zfs_dirty_data_max_percent=40"
  ];

  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.interval = "monthly";

  networking.hostId = "b411ca35";
}