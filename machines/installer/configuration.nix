{
  config,
  clan-core,
  inputs,
  lib,
  ...
}:
{
  imports = [
    # nixos-install runs on this machine, so its nix.conf governs how the
    # target's closure is fetched. Without the clan caches every clan-built
    # path is a miss here and has to arrive over the ssh push instead.
    ../../modules/nixos/nix-caches.nix
  ];

  # Stock Nix throttles that install badly: 16 parallel substitutions over 25
  # HTTP connections, sharing a 1 MiB download buffer that stalls workers as
  # soon as a few NARs decompress slower than they arrive.
  nix.settings = {
    max-substitution-jobs = 64;
    http-connections = 200;
    download-buffer-size = 128 * 1024 * 1024;
  };

  networking.hostName = "nixos-installer";

  clan.core.deployment.requireExplicitUpdate = true;

  nixpkgs.pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  system.stateVersion = config.system.nixos.release;

  # Nothing in this image pulls in nixpkgs' installation-cd profile, so it had
  # neither firmware (wifi card absent) nor the boot-device modules - the iso
  # variant only adds virtio. This is the install-media knob: every bootable
  # controller in the initrd plus hardware.enableRedistributableFirmware.
  hardware.enableAllHardware = true;

  # disko ships the zfs userland to the target itself, but zpool needs zfs.ko
  # in the *running* installer - without it every pool command dies with "The
  # ZFS modules cannot be auto-loaded". Any machine with a zfs root (som) is
  # unformattable from media that lacks this.
  #
  # Do not set networking.hostId here: clanCore/zfs.nix pins 8425e349 fleet-wide
  # (the install-ISO/nixos-anywhere id) so a pool created from this media
  # imports on the target without forceImportRoot, which clan turns off.
  boot.supportedFilesystems.zfs = true;

  image.modules.kexecTarball = {config, ...}: {
    imports = [
      inputs.nixos-images.nixosModules.kexec-installer
    ];
    system.build.image = lib.mkForce config.system.build.kexecInstallerTarball;

    # needed to prevent conflict in module eval
    systemd.network.networks."99-ethernet-default-dhcp".networkConfig.MulticastDNS = true;
    systemd.network.networks."99-wireless-client-dhcp".networkConfig.MulticastDNS = true;
  };
}
