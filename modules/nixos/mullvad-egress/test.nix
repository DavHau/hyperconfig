# ./egress.nix and ./dns.nix against a fake Mullvad relay. The relay also
# plays "the internet": its nginx answers every request with the client
# address it saw, so 10.64.0.2 / fc00:bbbb:bbbb:bb01::2 means "came through
# the tunnel" and 192.168.1.1 / 2001:db8:1::1 means "came over the plain
# uplink". Its DNS server is both Mullvad's in-tunnel resolver and the
# uplink's: marker.example.net is 203.0.113.53 when asked through the tunnel
# and 198.51.100.53 when asked over the uplink. The client's netns `guest`
# behind veth ve-guest stands in for a container (`sources`).
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

  # Container tests (systemd-nspawn, no VM): WireGuard links, nftables
  # and policy routing live in each container's own netns.
  containers.relay = {
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
    # UDP on a port that is not DNS: answers (and logs) the sender's address
    # (bound to the public address, so its replies come from there; `$$`:
    # systemd would expand the variable itself)
    systemd.services.udp-whoami = {
      wantedBy = [ "multi-user.target" ];
      after = [ "wireguard-wg0.service" ];
      requires = [ "wireguard-wg0.service" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat UDP4-RECVFROM:9999,bind=203.0.113.10,fork SYSTEM:'echo $$SOCAT_PEERADDR | tee -a /tmp/udp.log'";
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

  containers.client =
    { lib, pkgs, ... }:
    {
      # The sandbox allows no setuid bits, so pam_unix's helper can't
      # run and tunneled's lingering manager wouldn't start: test-only
      # systemd-user PAM stack.
      imports = [
        ../../../hyperhermes/checks/container-pam.nix
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
      networking.useHostResolvConf = false;
      networking.nameservers = [ "192.168.1.2" ];
      networking.hosts."192.168.1.77" = [ "internal.example" ];

      users.users.tunneled = {
        isNormalUser = true;
        uid = 1210;
        # Its user manager runs from boot, like an agent's.
        linger = true;
      };
      # tunnelOnly: a tunneled listener (like searx) that may open no
      # loopback connection but to its own port and the tunnel's DNS.
      users.users.listener = {
        isNormalUser = true;
        uid = 1213;
      };
      systemd.services.listener = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "listener";
          ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 --directory ${pkgs.writeTextDir "index.html" "listener"} 8081";
        };
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
        users = [
          "tunneled"
          "listener"
        ];
        dns.services = [
          "dns-probe"
          "listener"
        ];
        tunnelOnly.listener = [ "127.0.0.1:8081" ];
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

      # Another loopback resolver on :53, like som's dnscrypt-proxy at
      # 127.0.5.3; it answers as the uplink would.
      systemd.services.other-resolver = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart =
          let
            conf = pkgs.writeText "other-resolver.conf" ''
              server:
                interface: 127.0.5.3
                port: 53
                access-control: 127.0.0.0/8 allow
                do-daemonize: no
                username: ""
                chroot: ""
                directory: "/"
                pidfile: ""
                use-syslog: no
                logfile: ""
                local-zone: "${marker}." static
                local-data: "${marker}. A 198.51.100.53"
            '';
          in
          "${pkgs.unbound}/bin/unbound -d -p -c ${conf}";
      };

      # sources: netns `guest` behind ve-guest stands in for a space's
      # container, NATed to the uplink as ../spaces/host.nix does.
      hyper.mullvadEgress.sources = [ "ve-guest" ];
      networking.nat = {
        enable = true;
        enableIPv6 = true;
        internalInterfaces = [ "ve-guest" ];
      };
      systemd.network.networks."05-ve-guest" = {
        matchConfig.Name = "ve-guest";
        linkConfig.Unmanaged = true;
      };
      systemd.services.guest-netns = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ip netns add guest
          ip link add ve-guest type veth peer name eth0 netns guest
          ip addr add 10.250.0.1/30 dev ve-guest
          ip -6 addr add fd99::1/64 dev ve-guest nodad
          ip link set ve-guest up
          ip -n guest link set lo up
          ip -n guest addr add 10.250.0.2/30 dev eth0
          ip -n guest -6 addr add fd99::2/64 dev eth0 nodad
          ip -n guest link set eth0 up
          ip -n guest route add default via 10.250.0.1
          ip -n guest -6 route add default via fd99::1
        '';
      };

      # The test triggers failover itself; the timer would race it.
      systemd.timers.mullvad-egress-failover.enable = false;

      environment.systemPackages = [
        pkgs.curl
        pkgs.wireguard-tools
        pkgs.dig
        pkgs.socat
        pkgs.iputils
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

    def guest(cmd):
        return client.execute(f"ip netns exec guest {cmd} 2>&1")

    def gcurl(url):
        rc, out = guest(f"curl -sS --max-time 5 '{url}'")
        if rc != 0:
            diag()
            print(client.execute("set -x; ip rule; ip -6 rule; nft list table inet mullvad-egress; ip -n guest addr; ip -n guest route")[1])
            raise AssertionError(f"guest {url}: curl exited {rc}: {out}")
        return out.strip()

    def gudp(port, bind=None):
        """One UDP datagram from the guest to the relay's port 9999: the
        address it arrived from, or "" when nothing came back."""
        src = f",bind={bind}" if bind else ""
        out = guest(f"sh -c 'echo x | socat -t 3 -T 3 - UDP4:203.0.113.10:9999,sourceport={port}{src} 2>/dev/null'")[1]
        # (socat may answer more than once per datagram)
        return " ".join(sorted(set(out.split())))

    def udp_senders():
        return relay.execute("cat /tmp/udp.log")[1].split()

    with subtest("sources: the container leaves through the tunnel, v4 and v6"):
        client.wait_for_unit("guest-netns.service")
        client.wait_until_succeeds("ip rule | grep -q 'iif ve-guest lookup 51830'", timeout=60)
        client.wait_until_succeeds("ip -6 rule | grep -q 'iif ve-guest lookup 51830'", timeout=60)
        assert gcurl(public[0]) == "10.64.0.2"
        assert gcurl(public[1]) == "fc00:bbbb:bbbb:bb01::2"
        # LAN and excluded prefixes direct, as for the users
        assert gcurl("http://192.168.1.2/") == "192.168.1.1"
        assert gcurl("http://[2001:db8:1::2]/") == "2001:db8:1::1"
        assert gcurl("http://198.51.100.10/") == "192.168.1.1"
        # the host itself (its nix-daemon fetching for it) stays direct
        assert curl("root", public[0]) == "192.168.1.1"
        # not only TCP: ICMP and UDP on a port that is not DNS take the tunnel
        relay.wait_for_unit("udp-whoami.service")
        assert guest("ping -c 1 -W 3 203.0.113.10")[0] == 0, guest("ping -c 1 -W 3 203.0.113.10")
        out = gudp(40000)
        if out != "10.64.0.2":
            print(client.execute("conntrack -L 2>&1; nft list table inet mullvad-egress")[1])
            print(relay.execute("cat /tmp/udp.log; journalctl -u udp-whoami --no-pager | tail")[1])
            raise AssertionError(f"guest UDP: {out!r}")
        # a spoofed source address (one of the LAN's) changes nothing: the
        # interface decides, so it arrives through the tunnel or not at all
        guest("ip addr add 192.168.1.50/32 dev eth0")
        gudp(40001, bind="192.168.1.50")
        guest("ip addr del 192.168.1.50/32 dev eth0")
        senders = udp_senders()
        assert set(senders) == {"10.64.0.2"}, f"guest UDP arrived from {senders}"

    with subtest("sources: the container's DNS goes to the tunnel's resolver, whichever it asks"):
        for server in ["192.168.1.2", "10.250.0.1", "2001:db8:1::2", "fd99::1", "198.51.100.10"]:
            for tcp in ["", "+tcp"]:
                rc, out = guest(f"dig +short +time=3 +tries=1 {tcp} @{server} ${marker}")
                assert rc == 0 and out.strip() == "203.0.113.53", f"guest @{server} {tcp}: {rc} {out}"
        # DoT off the tunnel: refused
        rc, out = guest("curl -sS --max-time 5 telnet://192.168.1.2:853")
        assert rc == 7, f"guest DoT to the LAN: {rc} {out}"

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

    with subtest("tunnelOnly: its own listener and DNS on loopback, nothing else"):
        client.wait_until_succeeds("ss -ltn | grep -q '127.0.0.1:8081 '", timeout=60)
        # others connect to it, its replies get out
        assert curl("direct", "http://127.0.0.1:8081/") == "listener"
        assert curl("tunneled", "http://127.0.0.1:8081/") == "listener"
        # its uid (in the unit or not) reaches its own port and the DNS
        assert curl("listener", "http://127.0.0.1:8081/") == "listener"
        out = client.succeed("runuser -u listener -- dig +short +time=3 +tries=1 @127.0.0.153 ${marker}").strip()
        assert out == "203.0.113.53", out
        # but no other loopback service: dropped, so a timeout (28), not a refusal
        for url in ["http://127.0.0.1:8080/", "http://[::1]:8080/", "http://192.168.1.1:8080/"]:
            rc = client.execute(f"runuser -u listener -- curl -sS --max-time 3 '{url}'")[0]
            assert rc == 28, f"listener {url}: curl exited {rc}, expected a drop"
        print(client.succeed("nft list table inet mullvad-egress-loopback"))

    with subtest("tunneled units resolve through the tunnel, others over the uplink"):
        for unit in ["dns-probe.service", "user@1210.service"]:
            assert resolves(unit, "${marker}") == "203.0.113.53"
            assert resolves(unit, "internal.example") == "192.168.1.77"
        assert client.succeed("getent ahostsv4 ${marker}").split()[0] == "198.51.100.53"
        assert client.succeed("runuser -u direct -- getent ahostsv4 ${marker}").split()[0] == "198.51.100.53"
        # A restarted nscd must stay hidden from the running tunneled units.
        client.succeed("systemctl restart nscd.service")
        client.wait_for_unit("nscd.service")
        for unit in ["dns-probe.service", "user@1210.service"]:
            assert resolves(unit, "${marker}") == "203.0.113.53"

    with subtest("tunneled users may not ask resolved's stub directly"):
        dig = "runuser -u tunneled -- dig +short +time=3 +tries=1"
        assert client.succeed(f"{dig} @127.0.0.153 ${marker}").strip() == "203.0.113.53"
        assert client.succeed("dig +short +time=3 +tries=1 @127.0.0.53 ${marker}").strip() == "198.51.100.53"
        for stub in ["127.0.0.53", "127.0.0.54"]:
            for tcp in ["", "+tcp"]:
                rc, out = client.execute(f"{dig} {tcp} @{stub} ${marker} 2>&1")
                assert rc != 0 and "198.51.100.53" not in out, f"tunneled reached {stub} {tcp}: {rc} {out}"

    with subtest("tunneled users may not ask another loopback resolver"):
        client.wait_until_succeeds("ss -lnu | grep -q '127.0.5.3:53 '", timeout=60)
        assert client.succeed("dig +short +time=3 +tries=1 @127.0.5.3 ${marker}").strip() == "198.51.100.53"
        for tcp in ["", "+tcp"]:
            rc, out = client.execute(f"{dig} {tcp} @127.0.5.3 ${marker} 2>&1")
            assert rc != 0 and "198.51.100.53" not in out, f"tunneled reached 127.0.5.3 {tcp}: {rc} {out}"
        # Nor the LAN's resolver.
        rc, out = client.execute(f"{dig} @192.168.1.2 ${marker} 2>&1")
        assert rc != 0 and "198.51.100.53" not in out, f"tunneled reached 192.168.1.2: {rc} {out}"

    with subtest("mullvad-egress-restart-tunneled restarts the tunneled units"):
        before = client.succeed("systemctl show -p MainPID --value dns-probe.service user@1210.service")
        client.succeed("mullvad-egress-restart-tunneled")
        client.wait_for_unit("dns-probe.service")
        client.wait_for_unit("user@1210.service")
        after = client.succeed("systemctl show -p MainPID --value dns-probe.service user@1210.service")
        assert set(before.split()).isdisjoint(after.split()), f"{before} -> {after}"
        for unit in ["dns-probe.service", "user@1210.service"]:
            assert resolves(unit, "${marker}") == "203.0.113.53"

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
        # sources: no internet and no DNS either, LAN still direct
        relay.succeed("rm -f /tmp/udp.log")
        assert guest("ping -c 1 -W 3 203.0.113.10")[0] != 0
        # neither a new UDP flow nor the one established before (port 40000)
        assert gudp(40002) == ""
        assert gudp(40000) == ""
        assert udp_senders() == [], f"guest UDP got out with the tunnel down: {udp_senders()}"
        for url in public:
            rc = guest(f"curl -sS --max-time 5 '{url}'")[0]
            assert rc == 7, f"guest {url} with the tunnel down: curl exited {rc}"
        assert gcurl("http://192.168.1.2/") == "192.168.1.1"
        rc, out = guest("dig +short +time=3 +tries=1 @192.168.1.2 ${marker}")
        assert "198.51.100.53" not in out and "203.0.113.53" not in out, f"guest DNS with the tunnel down: {rc} {out}"
  '';
}
