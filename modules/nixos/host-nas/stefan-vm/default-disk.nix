{
  pkgs ? import <nixpkgs> {
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "zerotierone"
    ];
  },
  lib ? import <nixpkgs/lib>,
}:
let
  machine = pkgs.nixos {
    imports = [
      ../../common.nix
    ];

    nixpkgs.localSystem = "x86_64-linux";

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "ext4";
    };

    boot = {
      growPartition = true;
      kernelParams = ["console=ttyS0"];
      loader.grub.device = lib.mkDefault "/dev/vda";
      loader.timeout = lib.mkDefault 0;
      initrd.availableKernelModules = [
        "uas"
        "virtio_net" "virtio_pci" "virtio_mmio" "virtio_blk" "virtio_scsi" "virtio_balloon" "virtio_console"
      ];
    };
  };

  defaultDisk = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    inherit lib;
    inherit (machine) config;
    inherit (machine.config.nixpkgs) pkgs;
    diskSize = "50000";
    format = "qcow2";
  };
in
defaultDisk
