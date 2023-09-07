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
      ../deployment.nix
      inputs.disko.nixosModules.disko
      ./disko-config.nix
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

  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "12ac4a1e71b04480"
  ];

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  system.stateVersion = lib.mkForce "22.05"; # Did you read the comment?

}
