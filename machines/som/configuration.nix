# AM5 desktop, iGPU only. Hardware detail lives in ./facter.json.
{ inputs, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-cpu-amd-pstate
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc-ssd
    ../../modules/nixos/dave.nix
    ../../modules/nixos/user-dave.nix
    ../../modules/nixos/amdgpu.nix
    ../../modules/nixos/zfs-remote-unlock
    ./disko.nix
    ../../modules/nixos/storagebox.nix
  ];

  # r8169 is the only wired NIC; the initrd needs it to be reachable for unlock.
  boot.initrd.availableKernelModules = [ "r8169" ];

  system.stateVersion = "25.11";
}
