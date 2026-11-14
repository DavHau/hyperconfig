# The three home LANs, bridged over the clan zerotier network zt-eu
# (controller edi). Plain data; ./default.nix derives the rest from it:
#   - edi's controller config: the routes below, the IPv4 pool, each
#     router's pinned IPv4 (../modules/nixos/zt-eu-sites.nix);
#   - the routers' authorization (`allowedIds` of the zt-eu instance in
#     ../modules/flake-parts/nixosConfigurations.nix);
#   - the routers' own config: `nix run .#site-routers-apply` (./apply.py);
#   - playa's ISP router's DHCP: `nix run .#playa-isp-apply`
#     (../modules/flake-parts/apps.playa-isp-apply.nix).
#
# Routing: every zt-eu member installs a site's LAN prefixes via that site's
# router (ZeroTier's allowManaged, on by default); a router skips its own
# (the `via` is its own address). A route is installed regardless of what
# else the host has: ZeroTier does not look at the host's own routes, only
# at its zt addresses (OneService.cpp syncManagedStuff). It goes in with
# metric 5000 (LinuxNetLink.cpp), so a host's connected LAN route still
# wins, but the route is there.
{
  zerotier = {
    instance = "zt-eu";
    # zt-eu's IPv4: needed only to reach the IPv4-only LAN devices (ESPHome).
    # Collides with nothing in the fleet (10.42/10.43/10.64/10.77/10.99/
    # 10.147/10.233/10.241, the spaces' 10.235.0.0/28 and the hermes
    # desktop spaces' 10.235.1.0/28 are taken).
    # Routers are pinned below .100, every other member draws from the pool.
    ipv4 = {
      subnet = "10.194.0.0/24";
      poolStart = "10.194.0.100";
      poolEnd = "10.194.0.250";
    };
  };

  sites = {
    # Dave's home, where som, bam and amy (when home) sit on the LAN
    # directly. Its LAN is NOT routed over zt-eu: they would all get it as
    # a second route. LAN devices still reach the other sites through the
    # Beryl, masqueraded to its zt-eu IPv4.
    home = {
      router = {
        name = "cm-beryl";
        # Management address: the old zerotier net af415e486f4514ce.
        address = "192.168.194.4";
        ztNodeId = "224b430dcf";
        ztIpv4 = "10.194.0.4";
        # GL.iNet 4.11 (OpenWrt 21.02, fw3)
        zerotierSection = "gl";
        # Dave's admin keys are installed; the password from this var is
        # only the fallback should key login ever be refused.
        passwordVar = "router-cm-beryl/password";
      };
      lan.ipv4 = "192.168.8.0/24";
      lan.ipv6 = null; # relayed provider prefix, no ULA
      routeLan = false;
      masqueradeFromLan = true;
      masqueradeToLan = false;

      # Offline devices (the Canon MF272dw printer): the GL firmware's IoT
      # network, converged by ./apply.py. No internet of any kind and no
      # IPv6: the zone `iot` has no forwarding out, and its input allows
      # only DHCP to the router (no DNS, no web UI, no ssh). LAN hosts
      # reach it (forwarding lan -> iot: print, eSCL scans are pulled from
      # the LAN side); it reaches nothing (no iot -> lan, zteu, zerotier,
      # guest, wan, VPN). No DNS: the lease names no DNS server (option 6
      # empty) and the router drops port 53 from it, which closes DNS as a
      # phone-home or tunnel channel. LAN clients still resolve printer.lan.
      # GL drift: the GL web UI (and its vlan_subnet.lua) re-adds what this
      # removes (Allow-DNS, iot -> wan, iot in
      # route_policy.global.append_source_if, which makes the VPN client
      # forward iot -> <vpn> and GL's /etc/firewall.dns_order redirect
      # br-iot's DNS to dnsmasq past the zone's REJECT, so its removal is
      # what keeps "no DNS" true): re-run `nix run .#site-routers-apply -- home`
      # after touching the GL web UI.
      # GL's default 192.168.10.0/24 is renumbered: it is playa's LAN,
      # routed over zt-eu to every LAN host here (bam, som).
      iot = {
        prefix = "192.168.18.0/24";
        # Also not to overlap (besides zt-eu and the sites' LANs, added by
        # ./default.nix): what the router has on its other interfaces, as
        # read with `ip -4 route` on 2026-11-14: GL's guest network, the
        # two WAN uplinks, and the old zerotier management net.
        reservedPrefixes = [
          "192.168.9.0/24" # guest (br-guest, disabled)
          "192.168.1.0/24" # WAN eth0
          "192.168.0.0/24" # WAN eth2
          "192.168.194.0/24" # zerotier af415e486f4514ce (management)
        ];
        address = "192.168.18.1";
        netmask = "255.255.255.0";
        # GL's prepared wifi-iface sections: 2.4 GHz on, 5 GHz stays off.
        wifiIface = "iot2g";
        offIfaces = [ "iot5g" ];
        ssid = "Macro";
        # WPA2-PSK AES only, no PMF: the MF272dw has no WPA3.
        encryption = "psk2+ccmp";
        pskVar = "router-cm-beryl-iot/psk";
        # Fixed addresses below the DHCP pool (.100-.249), each also a DNS
        # name for everyone on the router (printer -> printer.lan). The
        # DHCP reservation needs the MAC: null = DNS name only, until the
        # device has joined once (its lease shows the MAC:
        # `ssh root@192.168.194.4 cat /tmp/dhcp.leases`).
        hosts = {
          printer = {
            ip = "192.168.18.20";
            mac = null;
          };
        };
      };
    };

    # Roman's playa: router-tossa is not the LAN's gateway (the ISP router
    # 192.168.10.1 is, and nothing announces an IPv6 default route), so LAN
    # hosts would answer zt-eu sources the wrong way: masquerade into the LAN.
    playa = {
      router = {
        name = "router-tossa";
        address = "192.168.194.10";
        ztNodeId = "571742a187";
        ztIpv4 = "10.194.0.10";
        # OpenWrt 23.05 (fw4); keys only (no passwordVar)
        zerotierSection = "sample_config";
      };
      lan.ipv4 = "192.168.10.0/24";
      lan.ipv6 = "fd2a:8abf:35da::/48";
      routeLan = true;
      masqueradeFromLan = false;
      masqueradeToLan = true;
      # The LAN's gateway and DHCP server: Orange's Livebox Fibra (Arcadyan
      # PRV3399B), web UI only. `nix run .#playa-isp-apply` converges its
      # DHCP to this (../tools/router-playa-isp); undeclared reservations
      # are deleted. The pool is declared as found (the UI restarts the
      # router and drops reservations when it changes). Reservation names
      # are the labels the router stores, [A-Za-z0-9._-].
      ispRouter = {
        address = "192.168.10.1";
        user = "admin";
        passwordVar = "router-playa-isp/password";
        dhcp = {
          poolStart = "192.168.10.100";
          poolEnd = "192.168.10.250";
          leaseTime = 86400;
          reservations = {
            GL-MT6000 = {
              mac = "94:83:c4:a4:38:09";
              ip = "192.168.10.2";
            };
            homeassistant = {
              mac = "d8:3a:dd:ed:e0:a9";
              ip = "192.168.10.3";
            };
            tossa-pi = {
              mac = "b8:27:eb:8c:e2:b5";
              ip = "192.168.10.21";
            };
          };
        };
      };
    };

    # Roman's casa: router-waldkirch is the LAN's IPv4 gateway and its IPv6
    # default router (ra_default), so the LAN answers zt-eu sources itself.
    # nas sits on this LAN and gets its routes twice (see the header).
    casa = {
      router = {
        name = "router-waldkirch";
        address = "192.168.194.20";
        ztNodeId = "34d0757647";
        ztIpv4 = "10.194.0.20";
        # GL.iNet 4.9 (OpenWrt 21.02, fw3); keys only (no passwordVar)
        zerotierSection = "gl";
      };
      lan.ipv4 = "192.168.20.0/24";
      lan.ipv6 = "fd99:a769:4eae::/48";
      routeLan = true;
      masqueradeFromLan = false;
      masqueradeToLan = false;
    };
  };
}
