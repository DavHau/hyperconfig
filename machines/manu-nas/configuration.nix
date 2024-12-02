# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ lib, inputs, config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./users.nix
      ./samba.nix
     ../../modules/nixos/deployment.nix
      ./disko-config.nix
      inputs.nixos-generators.nixosModules.all-formats
    ];

  deployAddress = "10.241.225.42";

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "zerotierone"
  ];

  # fileSystems."/raid".device = "/dev/md127";
  fileSystems."/var/log".fsType = "tmpfs";

  # raid
  # boot.initrd.services.swraid.enable = true;
  # boot.initrd.services.swraid.mdadmConf =
  #   config.environment.etc."mdadm.conf".text;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "manu-nas";
  networking.hostId = "19795521";
  networking.useDHCP = true;

  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "af415e486f4514ce"
  ];

  # nixos-generators specific config
  formatConfigs.sd-x86_64 = {
    disabledModules = [./hardware-configuration.nix];
    boot.initrd.availableKernelModules = ["usb_storage"];
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  system.stateVersion = lib.mkForce "22.05"; # Did you read the comment?
}
