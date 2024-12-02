{config, lib, inputs, ...}: {
  imports = [
    inputs.nixos-generators.nixosModules.all-formats

   ../../modules/nixos/common.nix
   ../../modules/nixos/dyndns-porkbun.nix
   ../../modules/nixos/monitoring.nix
    ./hardware-configuration.nix
    ./reverse-proxy.nix
  ];
  services.nginx.enable = true;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.wireless.enable = true;
  users.users.root.password = "hello";
  networking.useDHCP = true;
  formatConfigs.sd-aarch64 = {
    disabledModules = [
      ./hardware-configuration.nix
    ];
  };
  clan.core.networking.targetHost = "root@192.168.10.21";
  clan.core.networking.buildHost = "grmpf@localhost";
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
}
