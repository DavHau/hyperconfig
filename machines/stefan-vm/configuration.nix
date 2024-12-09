{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
   ../../modules/nixos/common.nix
    ./voicinator.nix
   ../../modules/nixos/users/stefan.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  clan.core.networking.targetHost = "root@192.168.194.5";
  clan.core.networking.buildHost = "grmpf@localhost";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  boot = {
    initrd.systemd.enable = false;
    growPartition = true;
    kernelParams = ["console=ttyS0"];
    loader.grub.device = lib.mkDefault "/dev/vda";
    loader.timeout = lib.mkDefault 0;
    initrd.availableKernelModules = [
      "uas"
      "virtio_net" "virtio_pci" "virtio_mmio" "virtio_blk" "virtio_scsi" "virtio_balloon" "virtio_console"
    ];
  };
  users.mutableUsers = false;
  # allow root login for stefan
  users.users.root.openssh.authorizedKeys.keys = config.users.users.stefan.openssh.authorizedKeys.keys;
  nix.gc.automatic = true;
  nix.gc.dates = "daily";
}
