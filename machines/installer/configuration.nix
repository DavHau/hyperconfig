{
  config,
  clan-core,
  inputs,
  lib,
  ...
}:
{
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

  # The kexec image carries bcachefs. Linux 6.18.64 backported
  # inode_state_read{,_once} and inode_state_set_raw to include/linux/fs.h,
  # while bcachefs-tools 1.39.7's out-of-tree module still defines its own
  # copies for every kernel before 6.19 (redefinition errors). Move its cut-off
  # to 6.18.64. --replace-fail breaks the build once upstream changes the
  # line: drop this override then.
  boot.bcachefs.modulePackage =
    (config.boot.kernelPackages.callPackage config.boot.bcachefs.package.kernelModule { }).overrideAttrs
      (old: lib.optionalAttrs (config.boot.kernelPackages.kernel.kernelAtLeast "6.18.64") {
        postPatch = old.postPatch + ''
          substituteInPlace src/fs/bcachefs/vfs/fs.h \
            --replace-fail 'LINUX_VERSION_CODE < KERNEL_VERSION(6,19,0)' 'LINUX_VERSION_CODE < KERNEL_VERSION(6,18,64)'
        '';
      });

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

  # Only ever runs from RAM (the kexec image below sets its own root and
  # bootloader); these just let the plain toplevel evaluate.
  fileSystems."/" = lib.mkDefault { device = "none"; fsType = "tmpfs"; };
  boot.loader.grub.enable = lib.mkDefault false;

  # nixpkgs removed the scripted initrd and with it the option
  # boot.initrd.systemd.enable: reading it throws, setting it fails an
  # assertion. clan-core's iso image module still reads it to pick its
  # extra-files extraction (clan-core main as of 2026-11 too). Swap it for
  # the same module that is told the systemd initrd is on, the only initrd
  # left; drop this once clan-core stops reading the option.
  disabledModules = [ "${clan-core.sourceInfo}/nixosModules/clanCore/image/iso" ];
  imports = [
    ({config, lib, pkgs, ...}@args: let
      clanIso = import "${clan-core.sourceInfo}/nixosModules/clanCore/image/iso" args;
    in clanIso // {
      config = clanIso.config // {
        image.modules.iso = {config, lib, pkgs, ...}@isoArgs: let
          c = isoArgs.config;
        in clanIso.config.image.modules.iso (isoArgs // {
          config = c // { boot = c.boot // { initrd = c.boot.initrd // {
            systemd = c.boot.initrd.systemd // { enable = true; };
          }; }; };
        });
      };
    })
  ];

  image.modules.kexecTarball = {config, ...}: {
    # nixos-images' restore-remote-access.nix sets the removed
    # boot.initrd.systemd.enable = true (nix-community/nixos-images#453, open
    # as of 2026-11): keep its initrd service, drop the option.
    disabledModules = [ "${inputs.nixos-images}/nix/restore-remote-access.nix" ];
    imports = [
      inputs.nixos-images.nixosModules.kexec-installer
      { boot.initrd.systemd.services = (import "${inputs.nixos-images}/nix/restore-remote-access.nix").boot.initrd.systemd.services; }
    ];
    system.build.image = lib.mkForce config.system.build.kexecInstallerTarball;

    # needed to prevent conflict in module eval
    systemd.network.networks."99-ethernet-default-dhcp".networkConfig.MulticastDNS = true;
    systemd.network.networks."99-wireless-client-dhcp".networkConfig.MulticastDNS = true;
  };
}
