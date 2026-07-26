# Guest networking: static, on bam's internal routed bridge br-inf
# (see machines/bam/inference-net.nix for the topology + policy).
# The VM is L2-isolated from the LAN; its only public identity is
# 2405:9800:b901:94e3::feed:da7a (bam proxies NDP on the LAN and
# routes the /128 here). IPv4 is NAT via bam — outbound only.
#
# Only enp1s0 is matched; anything else stays unmanaged.
{
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network.networks."10-lan" = {
    matchConfig.Name = "enp1s0";
    networkConfig = {
      Address = [
        "10.42.0.2/24"
        "2405:9800:b901:94e3::feed:da7a/128"
      ];
      # public DNS: the router's resolver is a LAN service we no
      # longer talk to (and bam's firewall would drop it anyway)
      DNS = ["9.9.9.9" "149.112.112.112" "2620:fe::fe"];
    };
    routes = [
      {Gateway = "10.42.0.1";}
      # bam's static link-local on br-inf; on-link because our v6
      # address is a /128 with no on-link prefix
      {
        Gateway = "fe80::1";
        GatewayOnLink = true;
      }
    ];
  };
}
