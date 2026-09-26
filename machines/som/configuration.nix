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
    ../../modules/nixos/users/hsjobeki-vault.nix
    ./hermes-agents.nix
    ../../modules/nixos/hermes-claude-auth.nix
    ../../modules/nixos/public-ipv6-token.nix
    ../../modules/nixos/linger-normal-users.nix
    ../../modules/nixos/rgb-off.nix
    ../../modules/nixos/ipv4-forward.nix
    ../../modules/nixos/container-slots.nix
  ];

  # Public IPv4 38.89.142.76, borrowed from sgp through a WireGuard tunnel
  # (../../modules/nixos/ipv4-forward.nix); this firewall still decides which
  # ports answer.
  hyper.ipv4Forward.role = "backend";

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
  # routed to its own backend. Every agent in ./hermes-agents.nix is published.
  hyper.hermesDashboard.host = "hermes.davhau.com";

  # Public address 2405:9800:b901:94e3::c0de:ba5e on the LAN bridge (prefix
  # from the RA, ../../modules/nixos/public-ipv6-token.nix); the matching AIS
  # router allow rule is `router-ais ipv6-rules list` -> "som".
  networking.publicIPv6 = {
    token = "::c0de:ba5e";
    interface = "br0";
  };

  # Container slots for other repos to deploy into
  # (../../modules/nixos/container-slots.nix). enp6s0 is a port of br0,
  # which keeps its MAC and carries som's own DHCP/SLAAC addresses. Add a
  # slot as `slots.<name> = { id; mode; deployKeys; }`.
  hyper.containerSlots = {
    enable = true;
    uplink = "enp6s0";
    uplinkMac = "a4:0c:66:1b:29:f1";
  };

  # The spaces desktop profile defaults llama-swap on, which registers a
  # local provider in every harness's models.yml (omp-common.nix) and in the
  # hermes settings, and omp picks it as the first-run default. som's iGPU
  # is not a brain; p0 is (hermes-common.nix). Off, as on vit.
  services.llama-swap.enable = false;

  system.stateVersion = "25.11";
}
