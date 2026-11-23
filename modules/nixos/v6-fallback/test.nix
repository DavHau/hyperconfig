# ./default.nix in a VM: `client` (v4-only, like amy on a hotel Wi-Fi)
# gets global IPv6 through `gw` (som's role) over yggdrasil, with the
# mesh unaffected:
#   - a local user's v6 reaches `inet` from gw's uplink address; root's
#     and the yggdrasil daemon's v6 never enter the tunnel (no route), and
#     a yggdrasil peer at a public v6 address stays unreachable instead
#     of looping into the tunnel it carries (the hotfix's failure);
#   - container traffic (a veth in a netns, NATed) goes through it too;
#   - gw forwards only to global unicast outside its LAN prefixes, only
#     the client's tunnel address, inbound replies only;
#   - gw's own services: reachable at its public address as from the
#     internet, closed at its other addresses;
#   - native v6 wins once present, WARP's rule (5209) wins while there;
#   - gateway gone: the route is withdrawn (fail fast), held down, and
#     comes back.
{ pkgs }:
let
  inherit (pkgs) lib;
  # Throwaway yggdrasil keys for the test only.
  gwKey = "9d26394930b8b401c455d60c8bb518d3f09d2bbb68e888b5b125d32923c4b3c456e5f468c989d0359e30635eb64da7e362a69e4deae0359e734bd9bbe131e390";
  gwYgg = "201:a468:2e5c:d9d8:bf29:873e:7285:26c9";
  clientKey = "c2640922b3312c28a5a21de94975d8ba60db42faf1dbaf085b572d90c207dead4d592887d3456698b9a0a59ae5e1e87916b6e5de92ebc933d528f62607ade710";
  clientYgg = "201:ca9b:5de0:b2ea:659d:197d:6994:6878";

  # PEM key files, as services.yggdrasil wants them (PrivateKeyPath).
  pem =
    name: hex:
    pkgs.runCommand "ygg-test-key-${name}" { } ''
      echo '{"PrivateKey":"${hex}"}' > conf.json
      ${pkgs.yggdrasil}/bin/yggdrasil -useconffile conf.json -exportkey > $out
    '';

  common = {
    imports = [ ./default.nix ];
    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.nftables.enable = true;
    networking.firewall.checkReversePath = "loose";
    environment.systemPackages = [
      pkgs.curl
      pkgs.yggdrasil
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "v6-fallback";
  globalTimeout = 900;

  nodes.inet = {
    imports = [ common ];
    virtualisation.vlans = [ 1 ];
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
      {
        address = "2001:db8:5::5";
        prefixLength = 64;
      }
      # gw's "home LAN" stand-in: global, but blocked for the clients.
      {
        address = "2001:db8:9::9";
        prefixLength = 64;
      }
    ];
    networking.interfaces.eth1.ipv6.routes = [
      {
        address = "2001:db8:2::";
        prefixLength = 64;
        via = "2001:db8:5::1";
      }
    ];
    networking.firewall.allowedTCPPorts = [ 80 ];
    services.nginx = {
      enable = true;
      virtualHosts.default = {
        default = true;
        listen = [
          {
            addr = "[::]";
            port = 80;
          }
        ];
        locations."/".return = ''200 "$remote_addr\n"'';
      };
    };
  };

  nodes.gw = {
    imports = [ common ];
    virtualisation.vlans = [
      1
      2
    ];
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
      {
        address = "2001:db8:5::1";
        prefixLength = 64;
      }
    ];
    networking.interfaces.eth1.ipv6.routes = [
      {
        address = "2001:db8:9::";
        prefixLength = 64;
        via = "2001:db8:5::5";
      }
    ];
    networking.interfaces.eth2.ipv6.addresses = lib.mkForce [ ];
    networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
      {
        address = "192.168.2.1";
        prefixLength = 24;
      }
    ];
    networking.firewall.allowedTCPPorts = [ 7000 ];
    services.yggdrasil = {
      enable = true;
      settings = {
        PrivateKeyPath = pem "gw" gwKey;
        Listen = [ "tcp://[::]:7000" ];
        MulticastInterfaces = [ ];
        IfName = "ygg";
      };
    };
    hyper.v6Fallback = {
      enable = true;
      role = "gateway";
      localYggAddress = gwYgg;
      uplinkInterface = "eth1";
      blockedDestinations = [ "2001:db8:9::/64" ];
      publicSuffixes = [ "::c0de:ba5e" ];
      clients.client = {
        index = 1;
        yggAddress = clientYgg;
      };
    };
  };

  nodes.client = {
    imports = [ common ];
    virtualisation.vlans = [ 2 ];
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "192.168.2.2";
        prefixLength = 24;
      }
    ];
    # A listener the firewall admits, so only the tunnel's own rules
    # decide whether it is reachable through the tunnel.
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.listener = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind :: 8080";
    };
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    services.yggdrasil = {
      enable = true;
      settings = {
        PrivateKeyPath = pem "client" clientKey;
        Peers = [
          "tcp://192.168.2.1:7000"
          # A peer at a public v6 address, as amy's peers over public
          # endpoints: must stay unreachable, never ride the tunnel.
          "tcp://[2001:db8:5::1]:7000"
        ];
        MulticastInterfaces = [ ];
        IfName = "ygg";
      };
    };
    # A container stand-in: netns `ct` behind veth ve-test, NATed like
    # the spaces (nixos-nat masquerade of the internal interfaces).
    networking.nat = {
      enable = true;
      enableIPv6 = true;
      internalInterfaces = [ "ve-test" ];
    };
    hyper.v6Fallback = {
      enable = true;
      role = "client";
      localYggAddress = clientYgg;
      gateway.yggAddress = gwYgg;
      holdDown = 30;
      probeTimeout = 2;
    };
  };

  testScript = ''
    import time

    start_all()
    inet.wait_for_unit("nginx.service")
    gw.wait_for_unit("v6-fallback-client.service")
    client.wait_for_unit("yggdrasil.service")

    def user(cmd):
        return f"runuser -u alice -- {cmd}"

    with subtest("mesh comes up and the fallback switches on"):
        try:
            client.wait_until_succeeds("ping -6 -c1 -W2 ${gwYgg}", timeout=60)
        except Exception:
            for m in (client, gw):
                print(m.execute("yggdrasilctl getPeers; ip -br a; ip r; ss -tnp; journalctl -u yggdrasil --no-pager | tail -20; nft list ruleset | head -80")[1])
            raise
        client.wait_until_succeeds("ip -6 rule show priority 32800 | grep -q 'uidrange 1000-29999 lookup 6464'", timeout=60)
        client.succeed("ip -6 rule show priority 32800 | grep -q 'fwmark 0x80000000/0x80000000 lookup 6464'")
        # nothing global in main
        client.fail("ip -6 route show table main | grep -E '^(default|2000::/3)'")

    with subtest("a user's v6 leaves from the gateway's uplink address"):
        out = client.succeed(user("curl -sf -m 10 http://[2001:db8:5::5]/")).strip()
        assert out == "2001:db8:5::1", out

    with subtest("root and the yggdrasil daemon never enter the tunnel"):
        client.fail("curl -sf -m 5 http://[2001:db8:5::5]/")
        out = client.succeed("ip -6 route get 2001:db8:5::1 2>&1 || true")
        assert "v6fb" not in out, out
        yuid = client.succeed("stat -c %u /proc/$(systemctl show -p MainPID --value yggdrasil)").strip()
        out = client.succeed(f"ip -6 route get 2001:db8:5::1 uid {yuid} 2>&1 || true")
        assert "v6fb" not in out, out
        # the public-v6 peer stays down, the v4 peer up
        peers = client.succeed("yggdrasilctl -json getPeers")
        assert "2001:db8:5::1" not in [p.get("remote", "") for p in __import__("json").loads(peers).get("peers", []) if p.get("up")], peers

    with subtest("the mesh survives with the fallback on"):
        for _ in range(10):
            client.succeed("ping -6 -c1 -W3 ${gwYgg}")
            time.sleep(1)
        client.succeed(user("curl -sf -m 10 http://[2001:db8:5::5]/"))

    with subtest("container traffic goes through it, masqueraded"):
        client.succeed(
            "ip netns add ct",
            "ip link add ve-test type veth peer name eth0 netns ct",
            "ip addr add fd23:5ace:9::1/64 dev ve-test",
            "ip link set ve-test up",
            "ip -n ct addr add fd23:5ace:9::2/64 dev eth0",
            "ip -n ct link set eth0 up",
            "ip -n ct link set lo up",
            "ip -n ct -6 route add default via fd23:5ace:9::1",
        )
        client.wait_until_succeeds("ip netns exec ct ping -6 -c1 -W2 fd23:5ace:9::1", timeout=30)
        # networkd configured ve-test (80-container-ve.network): the
        # fallback's rules are still there, not removed as foreign.
        client.succeed("ip -6 rule show priority 32800 | grep -q 'fwmark 0x80000000'")
        out = client.succeed("ip netns exec ct curl -sf -m 10 http://[2001:db8:5::5]/").strip()
        assert out == "2001:db8:5::1", out

    with subtest("the gateway forwards to global unicast outside its LAN only"):
        # refused at once (admin-prohibited), not left to time out
        t0 = time.monotonic()
        client.fail(user("curl -sf -m 5 http://[2001:db8:9::9]/"))
        assert time.monotonic() - t0 < 3, "the LAN should be refused, not dropped"

    with subtest("nothing new reaches the client through the tunnel"):
        client.wait_for_open_port(8080)
        client.succeed("curl -sf -m 5 http://[::1]:8080/ >/dev/null")
        def gw_drops(chain):
            out = gw.succeed(f"nft list chain ip6 v6-fallback {chain} | grep 'oifname \"v6fb-\\*\" counter'")
            return int(out.split("packets ")[1].split()[0])
        # from the gateway itself (a tenant there): its output drops it
        n = gw_drops("output")
        gw.fail("curl -sf -m 5 http://[fd99:6fb:0:1::2]:8080/")
        assert gw_drops("output") > n
        # from the internet behind the gateway: its forward drops it
        inet.succeed("ip -6 route add fd99:6fb::/32 via 2001:db8:5::1")
        n = gw_drops("forward")
        inet.fail("curl -sf -m 5 http://[fd99:6fb:0:1::2]:8080/")
        assert gw_drops("forward") > n
        # the gateway's own services aren't open to the client's tunnel
        gw.succeed("systemd-run --unit=gwlisten ${pkgs.python3}/bin/python3 -m http.server --bind :: 8081")
        gw.wait_for_open_port(8081)
        gw.succeed("nft insert rule inet nixos-fw input-allow tcp dport 8081 accept")
        out = gw.succeed("nft list chain ip6 v6-fallback input | grep 'iifname \"v6fb-\\*\" counter'")
        n = int(out.split("packets ")[1].split()[0])
        client.fail("curl -sf -m 5 http://[fd99:6fb:0:1::1]:8081/")
        out = gw.succeed("nft list chain ip6 v6-fallback input | grep 'iifname \"v6fb-\\*\" counter'")
        assert int(out.split("packets ")[1].split()[0]) > n, out

    with subtest("the gateway's public address: what the internet reaches"):
        # som's ::c0de:ba5e stand-in (deprecated: masquerade keeps ::1)
        gw.succeed("ip -6 addr add 2001:db8:5::c0de:ba5e/64 dev eth1 nodad preferred_lft 0")
        # its firewall's global ports: open to the client, as to inet
        out = client.succeed(user("curl -sf -m 10 http://[2001:db8:5::c0de:ba5e]:8081/ -o /dev/null -w '%{http_code}'"))
        assert out == "200", out
        inet.succeed("curl -sf -m 10 http://[2001:db8:5::c0de:ba5e]:8081/ >/dev/null")
        # a port the firewall opens only on another interface: closed
        gw.succeed("systemd-run --unit=gwlisten2 ${pkgs.python3}/bin/python3 -m http.server --bind :: 8082")
        gw.wait_for_open_port(8082)
        gw.succeed("nft insert rule inet nixos-fw input-allow iifname eth2 tcp dport 8082 accept")
        client.fail(user("curl -sf -m 5 http://[2001:db8:5::c0de:ba5e]:8082/"))
        # its other uplink address: still closed, refused at once
        t0 = time.monotonic()
        client.fail(user("curl -sf -m 5 http://[2001:db8:5::1]:8081/"))
        assert time.monotonic() - t0 < 3, "should be refused, not dropped"
        # a spoofed inner source to it: dropped
        client.succeed(
            "ip -6 addr add fd99:6fb:0:1::3/64 dev v6fb nodad",
            "ip -6 route add 2001:db8:5::c0de:ba5e/128 dev v6fb",
        )
        client.fail("curl -sf -m 5 --interface fd99:6fb:0:1::3 http://[2001:db8:5::c0de:ba5e]:8081/")
        out = gw.succeed("nft list chain ip6 v6-fallback input | grep 'saddr != { fd99:6fb:0:1::2'")
        assert "packets 0 " not in out, out
        client.succeed(
            "ip -6 route del 2001:db8:5::c0de:ba5e/128 dev v6fb",
            "ip -6 addr del fd99:6fb:0:1::3/64 dev v6fb",
        )
        gw.succeed("ip -6 addr del 2001:db8:5::c0de:ba5e/64 dev eth1")
        # the same suffix on a non-global (ULA) address: closed
        gw.succeed("ip -6 addr add fd00:5::c0de:ba5e/64 dev eth2 nodad")
        client.succeed("ip -6 route add fd00:5::c0de:ba5e/128 dev v6fb src fd99:6fb:0:1::2")
        client.fail("curl -sf -m 5 http://[fd00:5::c0de:ba5e]:8081/")
        client.succeed("ip -6 route del fd00:5::c0de:ba5e/128 dev v6fb")
        gw.succeed("ip -6 addr del fd00:5::c0de:ba5e/64 dev eth2")

    with subtest("a spoofed inner source is dropped at the gateway"):
        client.succeed(
            "ip -6 addr add fd99:6fb:0:1::3/64 dev v6fb nodad",
            "ip -6 route add 2001:db8:5::5/128 dev v6fb",
        )
        client.fail("curl -sf -m 5 --interface fd99:6fb:0:1::3 http://[2001:db8:5::5]/")
        out = gw.succeed("nft list chain ip6 v6-fallback forward | grep 'saddr != fd99:6fb:0:1::2'")
        assert "packets 0 " not in out, out
        client.succeed(
            "ip -6 route del 2001:db8:5::5/128 dev v6fb",
            "ip -6 addr del fd99:6fb:0:1::3/64 dev v6fb",
        )

    with subtest("outer packets with the gateway's address from the LAN are dropped"):
        # gw sends its tunnel packets to the client over the plain LAN
        # (as an attacker on the same Wi-Fi could, with som's address):
        # the client must take them only from the ygg interface.
        ll = client.succeed("ip -6 -o addr show dev eth1 scope link | awk '{print $4}' | cut -d/ -f1").strip()
        gw.succeed(f"ip -6 route add ${clientYgg}/128 via {ll} dev eth2")
        client.fail("ping -6 -c2 -W3 -I v6fb fd99:6fb:0:1::1")
        out = client.succeed("nft list chain ip6 v6-fallback tunnel-pin | grep 'iifname != \"ygg\"'")
        assert "packets 0 " not in out, out
        gw.succeed(f"ip -6 route del ${clientYgg}/128 via {ll} dev eth2")
        client.wait_until_succeeds("ping -6 -c1 -W3 -I v6fb fd99:6fb:0:1::1", timeout=30)

    with subtest("WARP's rule (5209) wins while present"):
        client.succeed(
            "ip link add warp0 type dummy", "ip link set warp0 up",
            "ip -6 route add 2000::/3 dev warp0 table 65743",
            "ip -6 rule add priority 5209 lookup 65743",
        )
        out = client.succeed(user("ip -6 route get 2001:db8:5::5"))
        assert "warp0" in out, out
        client.succeed("ip -6 rule del priority 5209", "ip link del warp0")
        out = client.succeed(user("ip -6 route get 2001:db8:5::5"))
        assert "v6fb" in out, out

    with subtest("native v6 wins once present"):
        client.succeed(
            "ip addr add 2001:db8:2::2/64 dev eth1",
            "ip -6 route add default via 2001:db8:2::1 dev eth1 metric 1024",
        )
        gw.succeed("ip addr add 2001:db8:2::1/64 dev eth2")
        client.wait_until_succeeds("ping -6 -c1 -W2 2001:db8:2::1", timeout=30)
        out = client.succeed(user("curl -sf -m 10 http://[2001:db8:5::5]/")).strip()
        assert out == "2001:db8:2::2", out
        client.succeed("ip -6 route del default via 2001:db8:2::1", "ip addr del 2001:db8:2::2/64 dev eth1")
        out = client.succeed(user("curl -sf -m 10 http://[2001:db8:5::5]/")).strip()
        assert out == "2001:db8:5::1", out

    with subtest("gateway gone: withdrawn (fail fast), held down, back"):
        gw.succeed("systemctl stop v6-fallback-client.service")
        client.wait_until_fails("ip -6 rule show priority 32800 | grep -q lookup", timeout=90)
        client.succeed("journalctl -u v6-fallback | grep -q 'withdrawing the route'")
        t0 = time.monotonic()
        client.fail(user("curl -sf -m 10 http://[2001:db8:5::5]/"))
        assert time.monotonic() - t0 < 5, "should fail fast (no route), not time out"
        gw.succeed("systemctl start v6-fallback-client.service")
        client.wait_until_succeeds("ping -6 -c1 -W2 -I v6fb fd99:6fb:0:1::1", timeout=60)
        # still held down for a while
        client.fail("ip -6 rule show priority 32800 | grep -q lookup")
        client.wait_until_succeeds("ip -6 rule show priority 32800 | grep -q 'uidrange'", timeout=90)
        out = client.succeed(user("curl -sf -m 10 http://[2001:db8:5::5]/")).strip()
        assert out == "2001:db8:5::1", out

    with subtest("stopping the timer removes everything"):
        client.succeed("systemctl stop v6-fallback.timer")
        client.wait_until_fails("ip link show v6fb", timeout=30)
        client.fail("ip -6 rule show priority 32800 | grep -q lookup")
        client.succeed("ping -6 -c1 -W3 ${gwYgg}")
  '';
}
