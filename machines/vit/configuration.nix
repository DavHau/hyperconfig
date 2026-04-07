{ config, pkgs, lib, inputs, self, ... }:
{
  imports = [
    ../../modules/nixos/laptop-dave.nix
    ./disko.nix
  ];

  # Enable all hardware support
  hardware.enableAllHardware = true;

  system.stateVersion = "25.11";
}
