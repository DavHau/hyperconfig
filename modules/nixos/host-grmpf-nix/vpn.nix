{ config, pkgs, lib, ... }:
{
  # mullvad
  services.mullvad-vpn.enable = true;
  networking.firewall.checkReversePath = "loose";

  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "af415e486f4514ce" # home
    "12ac4a1e71b04480" # manu
    "7c31a21e86f9a75c" # lassulus
    "363c67c55a553deb" # papa
    "a0cbf4b62a5113d8" # thaiger sprint
  ];
}
