# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ lib, config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./users.nix
      ./samba.nix
    ];

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "zerotierone"
  ];

  fileSystems."/raid".device = "/dev/md127";
  fileSystems."/var/log".fsType = "tmpfs";

  # raid
  # boot.initrd.services.swraid.enable = true;
  # boot.initrd.services.swraid.mdadmConf =
  #   config.environment.etc."mdadm.conf".text;
  environment.etc."mdadm.conf".text = ''
    ARRAY /dev/md/omv-manu:raid01 metadata=1.2 name=omv-manu:raid01 UUID=a862555a:12582ddd:09fadcb9:36c42614
  '';

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "manu-nas"; # Define your hostname.

  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "12ac4a1e71b04480"
  ];

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  system.stateVersion = "22.05"; # Did you read the comment?

}
