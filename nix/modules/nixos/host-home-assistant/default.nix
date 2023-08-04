{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: {
  imports = [
    ../common.nix
    # ../role-parasit.nix
    ../role-flixbus.nix
  ];
  deployAddress = "192.168.178.4";
  # nixpkgs.hostPlatform = "aarch64-linux";
  nixpkgs.pkgs = pkgs-unstable;
  boot.loader.raspberryPi = {
    enable = true;
    version = 4;
  };
  boot.loader.grub.enable = false;
  fileSystems."/" = lib.mkDefault
    { device = "/dev/disk/by-uuid/44444444-4444-4444-8888-888888888888";
      fsType = "ext4";
    };
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";
  system.stateVersion = "22.11";

  services.home-assistant = {
    enable = true;
    config = null;
    extraComponents = [
      # List of components required to complete the onboarding
      "default_config"
      "met"
      "esphome"
      "rpi_power"
      "radio_browser"
      "backup"
    ];
  };
  networking.firewall.allowedTCPPorts = [8123];

  # boot.extraModulePackages = [
  #   # pkgs.linuxPackages.rtl8821au
  # ];

  # hardware.enableRedistributableFirmware = lib.mkDefault true;
}
