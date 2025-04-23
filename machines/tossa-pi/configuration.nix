{config, lib, inputs, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/dyndns-porkbun.nix
    ../../modules/nixos/monitoring.nix
    ./hardware-configuration.nix
    ./reverse-proxy.nix
  ];
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.wireless.enable = true;
  networking.useDHCP = true;
  image.modules.sd-card = {
    disabledModules = [
      ./hardware-configuration.nix
    ];
  };
  clan.core.networking.targetHost = "root@192.168.10.21";
  clan.core.networking.buildHost = "grmpf@localhost";
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
}
