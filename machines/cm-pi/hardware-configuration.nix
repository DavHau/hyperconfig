{
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/44444444-4444-4444-8888-888888888888";
      fsType = "ext4";
    };
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
}
