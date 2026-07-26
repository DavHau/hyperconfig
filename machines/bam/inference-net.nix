# Inference VM networking: ROUTED (2026-07-26), replacing the LAN
# bridge. The VM hangs off a port-less internal bridge `br-inf`; bam
# routes. Goals: (a) VM is L2-isolated from the LAN, (b) it stays
# reachable at its public IPv6 2405:9800:b901:94e3::feed:da7a — no
# prefix delegation here, so bam answers neighbor solicitations for
# that ONE address on br0 (networkd IPv6ProxyNDP, no ndppd daemon)
# and forwards; (c) IPv4 is NAT-only (outbound internet, no LAN
# presence, no inbound).
#
# Policy (FORWARD, custom chain inf-fwd):
#   VM -> LAN (192.168.8.0/24 or on-link /64): DROP — incl. the
#     router-hairpin trick (packets die on bam before any router).
#   VM -> internet: allowed (v4 masqueraded, v6 native).
#   inbound -> VM: tcp 22 + 30000 and ICMPv6 to feed:da7a only; v4
#     established-only. LAN clients therefore CAN reach the VM, but
#     only via the public address routed through bam.
#   VM -> bam itself (10.42.0.1 / .150): INPUT path, not FORWARD —
#     ssh-jump for management if the public path is ever down.
{
  systemd.network = {
    # bam's own LAN uplink stays a bridge (historical; carries DHCP).
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
      networkConfig = {
        DHCP = "yes";
        # Answer NDP on the LAN for the VM's public address; the
        # router then delivers feed:da7a traffic to bam's MAC.
        IPv6ProxyNDP = true;
        IPv6ProxyNDPAddress = "2405:9800:b901:94e3::feed:da7a";
      };
    };

    # Internal VM segment: no physical port, bam is 10.42.0.1/fe80::1.
    netdevs."21-br-inf".netdevConfig = {
      Kind = "bridge";
      Name = "br-inf";
    };
    networks."41-br-inf" = {
      matchConfig.Name = "br-inf";
      networkConfig = {
        Address = ["10.42.0.1/24" "fe80::1/64"];
        ConfigureWithoutCarrier = true;
      };
      routes = [
        {Destination = "2405:9800:b901:94e3::feed:da7a/128";}
      ];
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # v4: masquerade the internal segment out the LAN uplink.
  networking.nat = {
    enable = true;
    internalInterfaces = ["br-inf"];
    externalInterface = "br0";
  };

  # (No guest services accepted from the VM segment.)

  networking.firewall.extraCommands = ''
    for ipt in iptables ip6tables; do
      $ipt -w -N inf-fwd 2>/dev/null || true
      $ipt -w -F inf-fwd
      $ipt -w -C FORWARD -j inf-fwd 2>/dev/null || $ipt -w -I FORWARD -j inf-fwd
    done

    # replies flow both ways
    iptables  -w -A inf-fwd -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    ip6tables -w -A inf-fwd -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    # VM must not reach the LAN (router excepted implicitly: its own
    # address is dst only for DHCP/DNS which the guest does not use;
    # public dsts pass, LAN dsts die here — hairpin-proof).
    iptables  -w -A inf-fwd -i br-inf -d 192.168.8.0/24 -j DROP
    ip6tables -w -A inf-fwd -i br-inf -d 2405:9800:b901:94e3::/64 -j DROP

    # inbound to the VM: ssh + inference API + ICMPv6 only
    ip6tables -w -A inf-fwd -o br-inf -d 2405:9800:b901:94e3::feed:da7a \
      -p tcp -m multiport --dports 22,30000 -j RETURN
    ip6tables -w -A inf-fwd -o br-inf -p ipv6-icmp -j RETURN
    ip6tables -w -A inf-fwd -o br-inf -j DROP
    # v4 inbound: nothing (NAT has no DNAT rules; established handled above)
  '';
  networking.firewall.extraStopCommands = ''
    for ipt in iptables ip6tables; do
      $ipt -w -D FORWARD -j inf-fwd 2>/dev/null || true
      $ipt -w -F inf-fwd 2>/dev/null || true
      $ipt -w -X inf-fwd 2>/dev/null || true
    done
  '';
}
