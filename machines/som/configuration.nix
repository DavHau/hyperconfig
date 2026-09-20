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
    ../../modules/nixos/users/hsjobeki-vault.nix
    ../../modules/nixos/momentum-state.nix
    ../../modules/nixos/momentum-hermes.nix
    ../../modules/nixos/stefan-hermes.nix
    ../../modules/nixos/egg-hermes.nix
    ../../modules/nixos/dave-hermes.nix
    ../../modules/nixos/hermes-dashboard-public.nix
    ../../modules/nixos/hermes-claude-auth.nix
    ../../modules/nixos/public-ipv6-token.nix
    ../../modules/nixos/linger-normal-users.nix
  ];

  # r8169 is the only wired NIC; the initrd needs it to be reachable for unlock.
  boot.initrd.availableKernelModules = [ "r8169" ];

  # Public hermes dashboards: https://hermes.davhau.com/<user>/ (AAAA ->
  # the token address below). Users opt in from their *-hermes.nix.
  hyper.hermesDashboard.host = "hermes.davhau.com";

  # Public address 2405:9800:b901:94e3::c0de:ba5e (prefix from the RA); the
  # matching AIS router allow rule is `router-ais ipv6-rules list` -> "som".
  networking.publicIPv6Token = "::c0de:ba5e";

  # The spaces desktop profile defaults llama-swap on, which registers a
  # local provider in every harness's models.yml (omp-common.nix) and in the
  # hermes settings, and omp picks it as the first-run default. som's iGPU
  # is not a brain; p0 is (hermes-common.nix). Off, as on vit.
  services.llama-swap.enable = false;

  system.stateVersion = "25.11";
}
