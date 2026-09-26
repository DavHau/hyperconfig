# Proxmox KVM guest in Singapore (provider search domain sgp3): 1 vCPU, 1G RAM,
# 30G virtio-scsi disk, SeaBIOS. Hardware detail lives in ./facter.json.
{ ... }:
{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
  ];

  clan.core.networking.targetHost = "root@38.89.142.76";

  # 1G of RAM: zram (common.nix) plus a disk swapfile so a nix evaluation or
  # a service spike does not hit the OOM killer.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 2048;
    }
  ];

  # Static addressing from the provider (no DHCPv4, no DHCPv6 server on the
  # segment). The VM has exactly one NIC; match it by type, not MAC (a panel
  # reinstall may hand out a new MAC) nor name (facter recorded Ubuntu's eth0,
  # NixOS calls it ens18). The unit sorts before facter's 40-eth0 and the
  # 99-ethernet-default-dhcp fallback.
  #
  # IPv6: the provider assigns 2402:4480:2:2::140:3c/127 and one of the two
  # routers advertises exactly that prefix; the default route comes from the
  # RA (two link-local routers).
  systemd.network.networks."10-uplink" = {
    matchConfig = {
      Type = "ether";
      Kind = "!*";
    };
    address = [
      "38.89.142.76/24"
      "2402:4480:2:2::140:3c/127"
    ];
    gateway = [ "38.89.142.1" ];
    dns = [
      "1.1.1.1"
      "1.0.0.1"
      "2606:4700:4700::1111"
    ];
    networkConfig.IPv6AcceptRA = true;
    linkConfig.RequiredForOnline = "routable";
  };
}
