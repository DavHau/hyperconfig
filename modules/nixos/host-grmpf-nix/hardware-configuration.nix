# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = "x86_64-linux";

  fileSystems."/" =
    { device = "master/root-nixos";
      fsType = "zfs";
    };

  fileSystems."/nix" =
    { device = "master/nix";
      fsType = "zfs";
    };

  fileSystems."/home" =
    { device = "master/home";
      fsType = "zfs";
    };

  fileSystems."/tmp" =
    { device = "master/tmp";
      fsType = "zfs";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/0657-6726";
      fsType = "vfat";
    };

  swapDevices = [ ];

}