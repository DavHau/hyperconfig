{ config, pkgs, ... }:
{

  # tailscal
  # services.tailscale.enable = true;

  # mullvad
  services.mullvad-vpn.enable = true;
  networking.firewall.checkReversePath = "loose";

  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    # wg0 = {
    #   ips = [ "192.168.223.108/32" ];
    #   privateKeyFile = "/home/grmpf/wireguard-keys/private";
    #   peers = [# For a client configuration, one peer entry for the server will suffice.
    #     {
    #       publicKey = "MComxeC7EeB+GcydNsPqvBE/G7/cXZAIu+EGzHiRixg=";
    #       allowedIPs = [ "192.168.223.0/24" "192.168.88.0/24" ];
    #       endpoint = "212.114.224.138:51820";
    #       persistentKeepalive = 25;
    #     }
    #   ];
    # };

    wg1 = {
      ips = [ "10.254.1.3/32" ];
      privateKeyFile = "/home/grmpf/wireguard-keys/genesis";
      peers = [# For a client configuration, one peer entry for the server will suffice.
        {
          publicKey = "nk7vdKuuGaMLorJCP5yh13WnaNl9urdzKaus+1GMTnE=";
          presharedKeyFile = config.sops.secrets.vpn-genesis-preshared-key.path;
          allowedIPs = [ "10.254.1.1/32" "10.254.0.0/24" "10.254.2.0/24" ];
          endpoint = "34.174.161.245:59990";
          persistentKeepalive = 25;
        }
      ];
    };
  };
  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "af415e486f4514ce" # home
    "12ac4a1e71b04480" # manu
  ];
}
