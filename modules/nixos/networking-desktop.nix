{ ... }:
{
  imports = [ ./wired-link-local.nix ];

  networking.networkmanager.enable = true;
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

  services.tailscale.enable = true;
}
