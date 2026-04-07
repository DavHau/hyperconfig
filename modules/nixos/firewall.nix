{ ... }:
{
  networking.firewall.allowedTCPPorts = [
    # 631 655
    27015 27036  # don't starve together
  ];
  networking.firewall.allowedUDPPorts = [
    # 26000
    # 631
    # 655
    6881  # deluge
    10999 27015 27031 27032 27033 27034 27035 27036  # don't starve together
  ];
  networking.firewall.allowPing = true;
  networking.firewall.enable = true;
}
