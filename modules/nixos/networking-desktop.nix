# Desktop networking: NetworkManager, tailscale, and the wired link-local
# address (./wired-link-local.nix).
{ ... }:
{
  imports = [ ./wired-link-local.nix ];

  networking.networkmanager.enable = true;
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

  services.tailscale.enable = true;
}
