{lib, pkgs, ...}: {
  # Auto-resize on boot: grow partition → resize LUKS → grow filesystem
  # All three steps happen during a single boot.

  # 1. Add sfdisk to the initrd so we can grow the partition
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${lib.getBin pkgs.util-linux}/bin/sfdisk
  '';

  # 2. Grow the partition BEFORE LUKS unlock, resize LUKS AFTER unlock
  boot.initrd.luks.devices.cryptusb = {
    preOpenCommands = ''
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
    postOpenCommands = ''
      cryptsetup resize cryptusb || true
    '';
  };

  # 3. Grow the ext4 filesystem after boot (adds x-systemd.growfs mount option)
  fileSystems."/".autoResize = true;
}
