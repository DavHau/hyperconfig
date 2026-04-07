{ config, pkgs, lib, inputs, self, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
    # inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    # inputs.nixos-hardware.nixosModules.lenovo-yoga-7-14ARH7-amdgpu
    # inputs.nixos-hardware.nixosModules.tuxedo-pulse-14-gen3
    ../../modules/nixos/laptop-dave.nix
    ../../modules/nixos/user-grmpf.nix
    ../../modules/nixos/amdgpu.nix
    ./disko.nix
  ];

  # required by zfs
  networking.hostId = "5eb1bf28";

  system.stateVersion = "19.03"; # Did you read the comment?
}
