{config, lib, inputs, ...}: {
  imports = [
    inputs.nixos-generators.nixosModules.all-formats
    ../../modules/nixos/common.nix
    ../../modules/nixos/monitoring.nix
    ../../modules/nixos/role-flixbus.nix
    ./hardware-configuration.nix
  ];
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.useDHCP = true;
  formatConfigs.sd-aarch64 = {
    disabledModules = [
      ./hardware-configuration.nix
    ];
  };
  # clan.core.networking.targetHost = "root@192.168.10.21";
  clan.core.networking.buildHost = "grmpf@localhost";
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
}
