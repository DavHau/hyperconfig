{ lib, ... }:
{
  services.easytier = {
    enable = true;
    instances.default = {
      settings = {
        network_name = "pick_a_name";
        network_secret = "pick_a_secret";
        listeners = [
          "tcp://0.0.0.0:11010"
        ];
        peers = [
          "tcp://public.easytier.cn:11010"
        ];
        dhcp = true;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    11010
    11011
  ];
  networking.firewall.allowedUDPPorts = [
    11010
    11011
  ];
}
