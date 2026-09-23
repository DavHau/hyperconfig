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
    ../../modules/nixos/momentum-hermes.nix
    ../../modules/nixos/stefan-hermes.nix
    ../../modules/nixos/egg-hermes.nix
    ../../modules/nixos/dave-hermes.nix
    ../../modules/nixos/pinpox-hermes.nix
    ../../modules/nixos/hermes-dashboard-public.nix
    ../../modules/nixos/hermes-claude-auth.nix
    ../../modules/nixos/public-ipv6-token.nix
    ../../modules/nixos/linger-normal-users.nix
    ../../modules/nixos/rgb-off.nix
  ];

  # r8169 is the only NIC that matters; the initrd needs it to be reachable
  # for unlock (../../modules/nixos/zfs-remote-unlock, wired only).
  boot.initrd.availableKernelModules = [ "r8169" ];

  # No wifi on this desktop: it sits on the LAN cable. The AX210 stays
  # unbound (no wlan0, no supplicant, no initrd PSK); nixos-facter's
  # wlan0 network unit just never matches.
  boot.blacklistedKernelModules = [ "iwlwifi" ];

  # RAM and the cooler's fans/water block (on the board's ARGB headers) dark.
  hyper.rgbOff.colorfulArgb = true;

  # Public hermes dashboards: https://hermes.davhau.com/ (AAAA -> the token
  # address below), pocket-id login through oauth2-proxy, each account
  # routed to its own backend. Users opt in from their *-hermes.nix.
  hyper.hermesDashboard.host = "hermes.davhau.com";

  # Public address 2405:9800:b901:94e3::c0de:ba5e on the LAN NIC (prefix from
  # the RA, ../../modules/nixos/public-ipv6-token.nix); the matching AIS
  # router allow rule is `router-ais ipv6-rules list` -> "som".
  networking.publicIPv6 = {
    token = "::c0de:ba5e";
    interface = "enp6s0";
  };

  # The spaces desktop profile defaults llama-swap on, which registers a
  # local provider in every harness's models.yml (omp-common.nix) and in the
  # hermes settings, and omp picks it as the first-run default. som's iGPU
  # is not a brain; p0 is (hermes-common.nix). Off, as on vit.
  services.llama-swap.enable = false;

  system.stateVersion = "25.11";
}
