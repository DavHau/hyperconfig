# ./egress.nix against a fake Mullvad relay. The relay also plays "the
# internet": its nginx answers every request with the client address it saw,
# so 10.64.0.2 / fc00:bbbb:bbbb:bb01::2 means "came through the tunnel" and
# 192.168.1.1 / 2001:db8:1::1 means "came over the plain uplink".
{ pkgs }:
let
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
  };

  nodes.client =
    { pkgs, ... }:
    {
      imports = [ ./egress.nix ];

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

      users.users.tunneled = {
        isNormalUser = true;
        uid = 1210;
      };
      users.users.direct = {
        isNormalUser = true;
        uid = 1211;
      };

      hyper.mullvadEgress = {
        users = [ "tunneled" ];
        addresses = [
          "10.64.0.2/32"
          "fc00:bbbb:bbbb:bb01::2/128"
        ];
        privateKeyFile = "${clientKey}";
        relays = [
          {
            endpoint = "192.168.1.2:51821";
            publicKey = deadPub;
          }
          {
            endpoint = "192.168.1.2:51820";
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

    start_all()
    relay.wait_for_unit("wireguard-wg0.service", timeout=120)
    relay.wait_for_unit("nginx.service", timeout=120)
    client.wait_for_unit("nginx.service", timeout=120)
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
  '';
}
