# AM5 desktop, iGPU only. Hardware detail lives in ./facter.json.
{ inputs, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-cpu-amd-pstate
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc-ssd
    ../../modules/nixos/laptop-dave.nix
    ../../modules/nixos/user-dave.nix
    ../../modules/nixos/amdgpu.nix
    ./disko.nix
  ];

  system.stateVersion = "25.11";
}
