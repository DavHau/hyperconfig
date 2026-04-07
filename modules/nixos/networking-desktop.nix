{ ... }:
{
  networking.networkmanager.enable = true;
  networking.dhcpcd.extraConfig = "nohook resolv.conf";
  # networking.networkmanager.insertNameservers = [
  #   "8.8.8.8"
  # ];

  services.tailscale.enable = true;
}
