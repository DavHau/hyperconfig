# ./egress.nix and ./dns.nix against a fake Mullvad relay. The relay also
# plays "the internet": its nginx answers every request with the client
# address it saw, so 10.64.0.2 / fc00:bbbb:bbbb:bb01::2 means "came through
# the tunnel" and 192.168.1.1 / 2001:db8:1::1 means "came over the plain
# uplink". Its DNS server is both Mullvad's in-tunnel resolver and the
# uplink's: marker.example.net is 203.0.113.53 when asked through the tunnel
# and 198.51.100.53 when asked over the uplink.
{ pkgs }:
let
  # Not under .test: unbound answers that itself (RFC 6761).
  marker = "marker.example.net";
  # Test-only keys.
  clientKey = pkgs.writeText "client.key" "oDo351gr0UPzU4ex3TzYbnJCvCDP5TGQMxnLUsPr0mo=";
  clientPub = "cPO7htK35VbRGFJsVIomGX9hau09HpGGgNdv7SBbKTw=";
  relayKey = pkgs.writeText "relay.key" "EJI6HBbdnope4OYeIWH24MLGfOYkxPe9cRzaZHmG40E=";
  relayPub = "brG6NaMb5h/iC8RwTcGQ7sXKr6kL9N0gaPUOnrZisgI=";
  # Nothing listens for this one: the failover has to move off it.
  deadPub = "LgBD+YGGtYEOgvHvaTh1JWq5pgEGKrWQnKz0vEKJAy0=";
in
pkgs.testers.runNixOSTest {
  name = "mullvad-egress";
  globalTimeout = 900;

  nodes.relay = {
    networking.firewall.enable = false;
    networking.wireguard.interfaces.wg0 = {
      # Plus the "public" addresses: local, so reached both through the
      # tunnel and over the client's default route.
      ips = [
        "10.64.0.1/32"
        "fc00:bbbb:bbbb:bb01::1/128"
        "203.0.113.10/32"
        # Relay endpoint outside every direct prefix, like a real relay.
        "192.0.2.2/32"
        "198.51.100.10/32"
        "2001:db8:ff::10/128"
      ];
      listenPort = 51820;
      privateKeyFile = "${relayKey}";
      peers = [
        {
          publicKey = clientPub;
          allowedIPs = [
            "10.64.0.2/32"
            "fc00:bbbb:bbbb:bb01::2/128"
          ];
        }
      ];
    };
    services.nginx = {
      enable = true;
      virtualHosts.whoami = {
        default = true;
        locations."/".return = ''200 "$remote_addr\n"'';
      };
    };
    services.unbound = {
      enable = true;
      resolveLocalQueries = false;
      enableRootTrustAnchor = false;
      settings = {
        server = {
          interface = [
            "10.64.0.1"
            "fc00:bbbb:bbbb:bb01::1"
            "192.168.1.2"
            "2001:db8:1::2"
          ];
          # wg0's addresses may come up after unbound.
          ip-freebind = true;
          access-control = [
            "0.0.0.0/0 allow"
            "::/0 allow"
          ];
          access-control-view = [
            "10.64.0.0/16 tunnel"
            "fc00:bbbb:bbbb:bb01::/64 tunnel"
            "192.168.1.0/24 uplink"
            "2001:db8:1::/64 uplink"
          ];
        };
        view =
          map
            (v: {
              inherit (v) name;
              local-zone = ''"${marker}." static'';
              local-data = ''"${marker}. A ${v.addr}"'';
            })
            [
              {
                name = "tunnel";
                addr = "203.0.113.53";
              }
              {
                name = "uplink";
                addr = "198.51.100.53";
              }
            ];
      };
    };
  };

  nodes.client =
    { pkgs, ... }:
    {
      imports = [
        ./egress.nix
        ./dns.nix
      ];

      networking.useNetworkd = true;
      networking.nftables.enable = true;
      networking.defaultGateway = {
        address = "192.168.1.2";
        interface = "eth1";
      };
      networking.defaultGateway6 = {
        address = "2001:db8:1::2";
        interface = "eth1";
      };
      # Strict, as on som: the tunnel must still get its replies in.
      boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = 1;
      # The host's own resolver, as on som; the relay is its upstream.
      services.resolved.enable = true;
      networking.nameservers = [ "192.168.1.2" ];
      networking.hosts."192.168.1.77" = [ "internal.example" ];

      users.users.tunneled = {
        isNormalUser = true;
        uid = 1210;
        # Its user manager runs from boot, like an agent's.
        linger = true;
      };
      users.users.direct = {
        isNormalUser = true;
        uid = 1212;
      };

      # A tunneled system unit, like an agent's gateway.
      systemd.services.dns-probe = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "tunneled";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };

      hyper.mullvadEgress = {
        users = [ "tunneled" ];
        dns.services = [ "dns-probe" ];
        addresses = [
          "10.64.0.2/32"
          "fc00:bbbb:bbbb:bb01::2/128"
        ];
        privateKeyFile = "${clientKey}";
        relays = [
          {
            endpoint = "192.0.2.2:51821";
            publicKey = deadPub;
          }
          {
            endpoint = "192.0.2.2:51820";
            publicKey = relayPub;
          }
        ];
        # 198.51.100.0/24 is only reachable via the default route; the LAN's
        # global /64 stands in for som's.
        directPrefixes = [
          "198.51.100.0/24"
          "2001:db8:1::/64"
        ];
      };

      # A host service on loopback, like SearXNG or the dashboards.
      services.nginx = {
        enable = true;
        virtualHosts.local = {
          listen = [
            {
              addr = "127.0.0.1";
              port = 8080;
            }
            {
              addr = "[::1]";
              port = 8080;
            }
          ];
          locations."/".return = ''200 "local\n"'';
        };
      };

      # The test triggers failover itself; the timer would race it.
      systemd.timers.mullvad-egress-failover.enable = false;

      environment.systemPackages = [
        pkgs.curl
        pkgs.wireguard-tools
        pkgs.dig
      ];
    };

  testScript = ''
    def diag():
        print(client.execute("set -x; ip route get 203.0.113.10 uid 1210; ip -6 route get 2001:db8:ff::10 uid 1210; wg show; ip -s link show wg-mullvad; nft list ruleset | grep -A8 'chain tunneled'; ip route; ip addr")[1])
        print(relay.execute("set -x; wg show; ip route; ip -6 route; ip addr; sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.wg0.rp_filter")[1])

    def curl(user, url):
        rc, out = client.execute(f"runuser -u {user} -- curl -sS --max-time 5 '{url}' 2>&1")
        if rc != 0:
            diag()
            raise AssertionError(f"{user} {url}: curl exited {rc}: {out}")
        return out.strip()

    def refused(user, url):
        # 7 = could not connect; 28 would be a timeout, i.e. packets sent somewhere.
        rc = client.execute(f"runuser -u {user} -- curl -sS --max-time 5 '{url}'")[0]
        assert rc == 7, f"{user} {url}: curl exited {rc}, expected an immediate refusal"

    public = ["http://203.0.113.10/", "http://[2001:db8:ff::10]/"]

    def lookup(unit, name):
        """getent as the tunneled user inside the unit's mount namespace."""
        pid = client.succeed(f"systemctl show -p MainPID --value {unit}").strip()
        return client.execute(f"nsenter -t {pid} -m -S 1210 -G 100 -- timeout 30 getent ahostsv4 {name}")

    def resolves(unit, name):
        rc, out = lookup(unit, name)
        if rc != 0:
            pid = client.succeed(f"systemctl show -p MainPID --value {unit}").strip()
            print(client.execute(f"set -x; nsenter -t {pid} -m -- sh -c 'cat /etc/resolv.conf; grep hosts /etc/nsswitch.conf; ls -la /run/nscd /run/systemd/resolve'; dig +time=3 +tries=1 @127.0.0.153 {name}; journalctl -u mullvad-egress-dns --no-pager | tail -n 20; nft list table inet mullvad-egress-dns")[1])
            print(relay.execute("set -x; journalctl -u unbound --no-pager | tail -n 20; ss -lnup")[1])
            raise AssertionError(f"{unit}: getent {name} exited {rc}: {out}")
        return out.split()[0]

    start_all()
    relay.wait_for_unit("wireguard-wg0.service", timeout=120)
    relay.wait_for_unit("nginx.service", timeout=120)
    client.wait_for_unit("nginx.service", timeout=120)
    relay.wait_for_unit("unbound.service", timeout=120)
    client.wait_until_succeeds("ss -lnu | grep -q '127.0.0.153:53 '", timeout=60)
    client.wait_for_unit("dns-probe.service", timeout=120)
    client.wait_for_unit("user@1210.service", timeout=120)
    try:
        client.wait_until_succeeds("ip rule | grep -q 'uidrange 1210-1210 lookup 51830'", timeout=60)
        client.wait_until_succeeds("ip -6 rule | grep -q 'uidrange 1210-1210 lookup 51830'", timeout=60)
        client.wait_until_succeeds("ip route show table 51830 | grep -q 'default dev wg-mullvad'", timeout=60)
    except Exception:
        print(client.execute("ip rule; ip -6 rule; ip route show table 51830; ip -6 route show table 51830; networkctl status wg-mullvad --no-pager; journalctl -u systemd-networkd --no-pager | tail -n 40")[1])
        raise
    client.succeed("test $(sysctl -n net.ipv4.conf.wg-mullvad.rp_filter) = 2")

    with subtest("dead relay: nothing gets out, and not over the uplink either"):
        assert client.execute("runuser -u tunneled -- curl -sS --max-time 3 http://203.0.113.10/")[0] != 0

    with subtest("failover moves to the next relay, then leaves a live one alone"):
        client.succeed("wg show wg-mullvad peers | grep -qF '${deadPub}'")
        client.succeed("systemctl start mullvad-egress-failover.service")
        client.succeed("wg show wg-mullvad peers | grep -qF '${relayPub}'")
        client.wait_until_succeeds("wg show wg-mullvad latest-handshakes | awk '$2 > 0 { ok = 1 } END { exit !ok }'", timeout=30)
        client.succeed("systemctl start mullvad-egress-failover.service")
        client.succeed("wg show wg-mullvad peers | grep -qF '${relayPub}'")

    with subtest("the tunneled user leaves through the tunnel, v4 and v6"):
        assert curl("tunneled", public[0]) == "10.64.0.2"
        assert curl("tunneled", public[1]) == "fc00:bbbb:bbbb:bb01::2"

    with subtest("other users keep the uplink"):
        for user in ["direct", "root"]:
            assert curl(user, public[0]) == "192.168.1.1"
            assert curl(user, public[1]) == "2001:db8:1::1"

    with subtest("LAN and excluded prefixes stay direct for the tunneled user"):
        assert curl("tunneled", "http://192.168.1.2/") == "192.168.1.1"
        assert curl("tunneled", "http://[2001:db8:1::2]/") == "2001:db8:1::1"
        assert curl("tunneled", "http://198.51.100.10/") == "192.168.1.1"

    with subtest("loopback services stay reachable for the tunneled user"):
        assert curl("tunneled", "http://127.0.0.1:8080/") == "local"
        assert curl("tunneled", "http://[::1]:8080/") == "local"

    with subtest("tunneled units resolve through the tunnel, others over the uplink"):
        for unit in ["dns-probe.service", "user@1210.service"]:
            assert resolves(unit, "${marker}") == "203.0.113.53"
            assert resolves(unit, "internal.example") == "192.168.1.77"
        assert client.succeed("getent ahostsv4 ${marker}").split()[0] == "198.51.100.53"
        assert client.succeed("runuser -u direct -- getent ahostsv4 ${marker}").split()[0] == "198.51.100.53"

    with subtest("tunneled users may not ask resolved over D-Bus"):
        call = "busctl call org.freedesktop.resolve1 /org/freedesktop/resolve1 org.freedesktop.resolve1.Manager ResolveHostname isit 0 ${marker} 0 0"
        client.succeed(call)
        out = client.fail(f"runuser -u tunneled -- {call} 2>&1")
        assert "denied" in out.lower(), out

    with subtest("tunnel down: refused v4 and v6, no fallback to the uplink"):
        client.succeed("ip link set wg-mullvad down")
        # networkd drops the link's rules: only nftables stands in the way.
        client.fail("ip rule | grep -q uidrange")
        client.fail("ip -6 rule | grep -q uidrange")
        for url in public:
            refused("tunneled", url)
        assert curl("direct", public[0]) == "192.168.1.1"
        assert curl("direct", public[1]) == "2001:db8:1::1"
        # Excluded and LAN prefixes need no tunnel.
        assert curl("tunneled", "http://198.51.100.10/") == "192.168.1.1"
        assert curl("tunneled", "http://[2001:db8:1::2]/") == "2001:db8:1::1"
        # No DNS either, not even the uplink's answer; /etc/hosts still is.
        rc, out = lookup("dns-probe.service", "${marker}")
        assert rc != 0 and out.strip() == "", f"tunnel down, yet ${marker}: {rc} {out}"
        assert resolves("dns-probe.service", "internal.example") == "192.168.1.77"
        assert client.succeed("getent ahostsv4 ${marker}").split()[0] == "198.51.100.53"
  '';
}
