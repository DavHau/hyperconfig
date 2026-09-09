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
    ../../modules/nixos/vault-nfs-client.nix
    ../../modules/nixos/users/stefan-vault.nix
    ../../modules/nixos/users/momentum-vault.nix
    ../../modules/nixos/momentum-state.nix
    ../../modules/nixos/momentum-hermes.nix
    ../../modules/nixos/egg-hermes.nix
    ../../modules/nixos/egg-dashboard.nix
    ../../modules/nixos/hermes-claude-auth.nix
    ../../modules/nixos/public-ipv6-token.nix
  ];

  # r8169 is the only wired NIC; the initrd needs it to be reachable for unlock.
  boot.initrd.availableKernelModules = [ "r8169" ];

  # Public address 2405:9800:b901:94e3::c0de:ba5e (prefix from the RA); the
  # matching AIS router allow rule is `router-ais ipv6-rules list` -> "som".
  networking.publicIPv6Token = "::c0de:ba5e";

  system.stateVersion = "25.11";
}
