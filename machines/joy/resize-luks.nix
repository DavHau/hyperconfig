{lib, pkgs, ...}: {
  # Auto-resize on boot: grow partition → resize LUKS → grow filesystem
  # All three steps happen during a single boot, in the systemd initrd (the
  # scripted initrd with its preOpenCommands/postOpenCommands is gone from
  # nixpkgs).
  boot.initrd.systemd.initrdBin = [ pkgs.util-linux pkgs.cryptsetup ];

  # 1. Grow the partition BEFORE LUKS unlock
  boot.initrd.systemd.services.grow-luks-partition = {
    description = "Grow the LUKS partition to fill the disk";
    unitConfig.DefaultDependencies = false;
    requires = [ "dev-disk-by\\x2dpartlabel-disk\\x2dmain\\x2dluks.device" ];
    after = [ "dev-disk-by\\x2dpartlabel-disk\\x2dmain\\x2dluks.device" ];
    before = [ "systemd-cryptsetup@cryptusb.service" ];
    wantedBy = [ "systemd-cryptsetup@cryptusb.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      # Resolve the LUKS partition symlink to the real block device
      luks_part="$(readlink -f /dev/disk/by-partlabel/disk-main-luks)"
      # Strip trailing digits to get the parent disk device
      parent="$luks_part"
      while [ "''${parent%[0-9]}" != "''${parent}" ]; do
        parent="''${parent%[0-9]}"
      done
      partnum="''${luks_part#"$parent"}"
      # Handle NVMe-style devices (e.g. /dev/nvme0n1p2 → /dev/nvme0n1)
      if [ "''${parent%[0-9]p}" != "''${parent}" ] && [ -b "''${parent%p}" ]; then
        parent="''${parent%p}"
      fi
      # Grow the partition to fill all available space
      echo ", +" | sfdisk --no-reread -N "$partnum" "$parent" && udevadm settle || true
    '';
  };

  # 2. Resize LUKS AFTER unlock, before the root is mounted
  boot.initrd.systemd.services.resize-luks = {
    description = "Grow the opened LUKS volume to its partition";
    unitConfig.DefaultDependencies = false;
    requires = [ "systemd-cryptsetup@cryptusb.service" ];
    after = [ "systemd-cryptsetup@cryptusb.service" ];
    before = [ "sysroot.mount" ];
    wantedBy = [ "sysroot.mount" ];
    serviceConfig.Type = "oneshot";
    script = ''
      cryptsetup resize cryptusb || true
    '';
  };

  # 3. Grow the ext4 filesystem after boot (adds x-systemd.growfs mount option)
  fileSystems."/".autoResize = true;
}
