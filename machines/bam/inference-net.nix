# LAN bridge: the guest lives on the LAN via br0 (bridged virtio NIC).
# Decision 2026-07-25: the planned phase-2 NAT/nftables lockdown was
# dropped — the VM stays bridged until its config moves out of this clan.
{
  systemd.network = {
    netdevs."20-br0".netdevConfig = {
      Kind = "bridge";
      Name = "br0";
    };
    networks."30-enp8s0-slave" = {
      matchConfig.Name = "enp8s0";
      networkConfig.Bridge = "br0";
    };
    networks."40-br0" = {
      matchConfig.Name = "br0";
      networkConfig.DHCP = "yes";
    };
  };
}
