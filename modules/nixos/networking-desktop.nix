# Desktop networking: NetworkManager and the wired link-local
# address (./wired-link-local.nix).
{ ... }:
{
  imports = [ ./wired-link-local.nix ];

  networking.networkmanager.enable = true;
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

  # No tailscale (Dave, 2026-11-27: unused; the mesh is yggdrasil over
  # zerotier/wireguard). Its idle traffic hurt amy on a weak 4G uplink.
}
