{ config, pkgs, lib, inputs, self, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.asus-zephyrus-gu605cw
    ../../modules/nixos/laptop-dave.nix
    ./disko.nix
  ];

  # Enable all hardware support
  hardware.enableAllHardware = true;

  system.stateVersion = "25.11";
}
