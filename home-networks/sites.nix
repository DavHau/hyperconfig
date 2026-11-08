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
    # 10.147/10.233/10.241 and infra-space's 10.235.0.0/30 are taken).
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
            e1-camera = {
              mac = "2c:1b:3a:75:04:a6";
              ip = "192.168.10.30";
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
