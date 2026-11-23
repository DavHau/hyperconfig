# ./default.nix (patched yggdrasil, `hyper.yggdrasil.noTransit`) in VMs:
#
#   a --vlan1-- b --vlan2-- c        b: noTransit
#   a ---------vlan3-------- c       (a<->c peering added mid-test)
#
#   - b talks to a and c, a and c each talk to b;
#   - a cannot reach c through b, though the path lookup through b still
#     works (a learns c's path: protocol messages pass);
#   - with a direct a<->c peering a reaches c over it, and b's counters
#     show none of that traffic; removing it cuts the pair again;
#   - the v6-fallback ip6ip6 tunnel (../v6-fallback) from no-transit b to
#     its direct peer c (the gateway) works;
#   - control: b restarted without NoTransit carries a<->c again (the
#     cut above comes from the option, nothing else).
{ pkgs }:
let
  inherit (pkgs) lib;
  # Throwaway yggdrasil keys for the test only.
  keys = {
    a = {
      key = "7e02b4bd114cc99182410f7e44079feb9e5320f94bd6bbfaa19c6d55614988d688a3fc4d84d0efb7354e33d126ab8dccb5b19605c273f7e2748b706e51f13722";
      addr = "200:eeb8:764:f65e:2091:9563:985d:b2a8";
    };
    b = {
      key = "dcf30ecf5e2f1f1e2e39f206eb0e12585012ffacbfaf25d54e9ee49360f8ab904fa36751729d6cbda2bc2b86a3d4498e69d472cfa78681c18e431005a00a9e55";
      addr = "201:c172:62ba:358a:4d09:750f:51e5:70ae";
    };
    c = {
      key = "dbec9160fd42c10ffac235f0f0a1f148058758ebb0975fa68b52d7a656da9abac8a2dfaf911980ff5b82a1bd68af71cfeb02381c2a5349c842ddb3adb7fca7da";
      addr = "200:6eba:40a0:ddcc:fe01:48fa:bc85:2ea1";
    };
  };
  pem =
    name:
    pkgs.runCommand "ygg-test-key-${name}" { } ''
      echo '{"PrivateKey":"${keys.${name}.key}"}' > conf.json
      ${pkgs.yggdrasil}/bin/yggdrasil -useconffile conf.json -exportkey > $out
    '';

  node =
    name: peers:
    { config, ... }:
    {
      imports = [
        ./default.nix
        ../v6-fallback
      ];
      networking.useNetworkd = true;
      networking.useDHCP = false;
      networking.nftables.enable = true;
      networking.firewall.checkReversePath = "loose";
      networking.firewall.allowedTCPPorts = [
        7000
        8000
      ];
      environment.systemPackages = [
        config.services.yggdrasil.package
        pkgs.curl
        pkgs.jq
      ];
      services.yggdrasil = {
        enable = true;
        settings = {
          PrivateKeyPath = pem name;
          Listen = [ "tcp://[::]:7000" ];
          Peers = peers;
          MulticastInterfaces = [ ];
          IfName = "ygg";
        };
      };
      # 4 MiB to fetch over yggdrasil (python's http.server on the ygg address).
      systemd.services.blob = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          mkdir -p /run/blob
          head -c 4194304 /dev/urandom > /run/blob/blob
          exec ${pkgs.python3}/bin/python3 -m http.server --bind :: --directory /run/blob 8000
        '';
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "yggdrasil-no-transit";
  globalTimeout = 900;

  nodes.a = {
    imports = [ (node "a" [ "tcp://192.168.1.2:7000" ]) ];
    virtualisation.vlans = [
      1
      3
    ];
  };

  nodes.b = {
    imports = [ (node "b" [ ]) ];
    virtualisation.vlans = [
      1
      2
    ];
    hyper.yggdrasil.noTransit = true;
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    hyper.v6Fallback = {
      enable = true;
      role = "client";
      localYggAddress = keys.b.addr;
      gateway.yggAddress = keys.c.addr;
      probeTimeout = 2;
    };
  };

  nodes.c = {
    imports = [ (node "c" [ "tcp://192.168.2.2:7000" ]) ];
    virtualisation.vlans = [
      2
      3
    ];
    hyper.v6Fallback = {
      enable = true;
      role = "gateway";
      localYggAddress = keys.c.addr;
      uplinkInterface = "eth2";
      blockedDestinations = [ ];
      clients.b = {
        index = 1;
        yggAddress = keys.b.addr;
      };
    };
  };

  testScript = ''
    import json

    A, B, C = "${keys.a.addr}", "${keys.b.addr}", "${keys.c.addr}"
    start_all()
    for m in (a, b, c):
        m.wait_for_unit("yggdrasil.service")
        m.wait_for_unit("blob.service")
        m.wait_for_open_port(8000)

    def key(m):
        return json.loads(m.succeed("yggdrasilctl -json getSelf"))["key"]
    ka, kb, kc = key(a), key(b), key(c)

    def b_bytes():
        """b's bytes sent+received per peer key."""
        out = {}
        for p in json.loads(b.succeed("yggdrasilctl -json getPeers")).get("peers", []):
            if p.get("up"):
                k = p["key"]
                out[k] = out.get(k, 0) + p.get("bytes_sent", 0) + p.get("bytes_recvd", 0)
        return out

    def fetch(src, dst):
        return src.succeed(f"curl -sf -m 60 -o /dev/null -w '%{{size_download}}' http://[{dst}]:8000/blob").strip()

    def dump():
        for m in (a, b, c):
            print(m.execute("yggdrasilctl getPeers; yggdrasilctl getPaths; yggdrasilctl getTree; journalctl -u yggdrasil --no-pager | tail -15")[1])

    with subtest("b runs in no-transit mode"):
        b.succeed("journalctl -u yggdrasil | grep -q 'No-transit mode'")
        a.fail("journalctl -u yggdrasil | grep -q 'No-transit mode'")

    with subtest("b talks to its direct peers, they talk to b"):
        try:
            for src, dst in ((a, B), (c, B), (b, A), (b, C)):
                src.wait_until_succeeds(f"ping -6 -c1 -W2 {dst}", timeout=90)
        except Exception:
            dump()
            raise
        assert fetch(a, B) == "4194304"
        assert fetch(b, C) == "4194304"

    with subtest("a cannot reach c through b, though lookups pass b"):
        a.fail(f"ping -6 -c3 -W2 {C}")
        c.fail(f"ping -6 -c3 -W2 {A}")
        a.fail(f"curl -sf -m 10 -o /dev/null http://[{C}]:8000/blob")
        # the path lookup/notify crossed b: a knows c's path
        a.wait_until_succeeds(f"yggdrasilctl -json getPaths | jq -e '.paths[] | select(.key == \"{kc}\")'", timeout=30)

    with subtest("a direct a<->c link carries a<->c, not b"):
        a.succeed("yggdrasilctl addPeer uri=tcp://192.168.3.3:7000")
        try:
            a.wait_until_succeeds(f"ping -6 -c1 -W2 {C}", timeout=90)
        except Exception:
            dump()
            raise
        c.succeed(f"ping -6 -c3 -W2 {A}")
        before = b_bytes()
        for _ in range(3):
            assert fetch(a, C) == "4194304"
        after = b_bytes()
        moved = sum(after.get(k, 0) - before.get(k, 0) for k in (ka, kc))
        print(f"b's counters to a and c moved {moved} bytes during 12 MiB a<->c")
        assert moved < 1048576, moved
        # and b's own traffic still flows
        b.succeed(f"ping -6 -c1 -W2 {A}", f"ping -6 -c1 -W2 {C}")

    with subtest("without the direct link the pair is cut again"):
        a.succeed("yggdrasilctl removePeer uri=tcp://192.168.3.3:7000")
        a.wait_until_fails(f"ping -6 -c1 -W2 {C}", timeout=60)

    with subtest("the v6-fallback tunnel from no-transit b to its peer c works"):
        try:
            b.wait_until_succeeds("ping -6 -c1 -W2 -I v6fb fd99:6fb:0:1::1", timeout=90)
        except Exception:
            print(b.execute("ip -br a; journalctl -u v6-fallback --no-pager | tail -20")[1])
            raise
        b.wait_until_succeeds("ip -6 rule show priority 32800 | grep -q 'uidrange 1000-29999 lookup 6464'", timeout=60)
        # a user's v6 on b leaves through c's uplink (vlan 3, masqueraded):
        # the 4 MiB blob from a's vlan-3 address.
        out = b.succeed("runuser -u alice -- curl -sf -m 60 -o /dev/null -w '%{size_download} %{remote_ip}' http://[2001:db8:3::1]:8000/blob").strip()
        assert out == "4194304 2001:db8:3::1", out
        # root on b has no route there (the fallback is for users only)
        b.fail("curl -sf -m 5 -o /dev/null http://[2001:db8:3::1]:8000/blob")

    with subtest("control: b without NoTransit carries a<->c"):
        conf = b.succeed("grep -o '/nix/store/[^ ]*-yggdrasil.conf' $(systemctl show -p ExecStart --value yggdrasil | grep -o '/nix/store/[^ ;]*' | head -1)").strip()
        b.succeed(
            f"jq 'del(.NoTransit)' {conf} > /run/ygg-transit.conf",
            "chmod 644 /run/ygg-transit.conf",
            "mkdir -p /run/systemd/system/yggdrasil.service.d",
            "printf '[Service]\\nExecStart=\\nExecStart=%s -useconffile /run/ygg-transit.conf\\n' "
            "$(readlink -f $(command -v yggdrasil)) > /run/systemd/system/yggdrasil.service.d/transit.conf",
            "systemctl daemon-reload",
            "systemctl restart yggdrasil",
        )
        b.wait_for_unit("yggdrasil.service")
        b.fail("journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value yggdrasil) | grep -q 'No-transit mode'")
        try:
            a.wait_until_succeeds(f"ping -6 -c1 -W2 {C}", timeout=120)
        except Exception:
            dump()
            raise
        before = b_bytes()
        assert fetch(a, C) == "4194304"
        after = b_bytes()
        moved = sum(after.get(k, 0) - before.get(k, 0) for k in (ka, kc))
        print(f"transit b carried {moved} bytes of a<->c")
        assert moved > 4194304, moved
  '';
}
