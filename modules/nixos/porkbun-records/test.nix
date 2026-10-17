# ./default.nix against ./stub.py (porkbun's API on 127.0.0.1:8053): two
# names with an A and an AAAA each, the AAAA from eth1's /64 at sync time
# (ipv6OnLink). Covered: the first run creates all four, a second run makes
# no write, re-addressing eth1 edits only the AAAAs (with a warning), an
# ambiguous prefix or a failing API answer fails the unit without a write,
# and dropping a name (the `nobob` specialisation) deletes exactly its
# records while an unmanaged record in the zone stays.
{ pkgs }:
let
  inherit (pkgs) lib;
  port = 8053;
  api = "http://127.0.0.1:${toString port}";

  stub = pkgs.writers.writePython3 "porkbun-stub" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./stub.py
  );
  seed = pkgs.writeText "seed.json" (
    builtins.toJSON [
      {
        name = "other.slots.test";
        type = "A";
        content = "192.0.2.99";
      }
      {
        name = "other.slots.test";
        type = "AAAA";
        content = "2001:db8::99";
      }
    ]
  );

  slot = id: {
    A = "38.89.142.76";
    AAAA.ipv6OnLink = {
      interface = "eth1";
      suffix = "::5107:${toString id}";
      expectedPrefix = "2001:db8:1:2";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "porkbun-records";
  globalTimeout = 600;

  nodes.som = {
    imports = [ ./. ];
    # What clan would provide: the generator declaration is ignored here.
    options.clan.core.vars.generators = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
    };
    config = {
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
        {
          address = "2001:db8:1:2::2";
          prefixLength = 64;
        }
        # a ULA next to it does not count as a second prefix
        {
          address = "fd00:1:2::2";
          prefixLength = 64;
        }
      ];
      hyper.porkbunRecords = {
        apiBase = "${api}/api/json/v3";
        apiKeyFile = "${pkgs.writeText "apikey" "test-key"}";
        secretKeyFile = "${pkgs.writeText "secretkey" "test-secret"}";
        records = {
          "alice.slots.test" = slot 4;
          "bob.slots.test" = slot 5;
        };
      };
      specialisation.nobob.configuration = {
        hyper.porkbunRecords.records = lib.mkForce { "alice.slots.test" = slot 4; };
      };
      # the test runs the unit itself
      systemd.timers.porkbun-records.timerConfig.OnBootSec = lib.mkForce "1d";
      systemd.services.porkbun-stub = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${stub} ${toString port} ${seed}";
      };
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript = ''
    import json

    def writes():
        return som.succeed("curl -sf ${api}/_writes").splitlines()

    def zone():
        return {(r["name"], r["type"]): r["content"] for r in json.loads(som.succeed("curl -sf ${api}/_records"))}

    def managed():
        return sorted((r["name"], r["type"]) for r in json.loads(som.succeed("cat /var/lib/porkbun-records/managed.json")))

    def settle(addr):
        som.wait_until_succeeds(f"ip -6 addr show dev eth1 | grep '{addr}/64' | grep -qv tentative", timeout=30)

    som.wait_for_unit("porkbun-stub.service")
    som.wait_until_succeeds("curl -sf ${api}/_records", timeout=30)
    som.succeed("systemctl is-active porkbun-records.timer")
    settle("2001:db8:1:2::2")

    with subtest("the first run creates A and AAAA for each name"):
        som.succeed("systemctl start porkbun-records")
        assert sorted(writes()) == [
            "create alice.slots.test A 38.89.142.76",
            "create alice.slots.test AAAA 2001:db8:1:2::5107:4",
            "create bob.slots.test A 38.89.142.76",
            "create bob.slots.test AAAA 2001:db8:1:2::5107:5",
        ], writes()
        assert managed() == [("alice.slots.test", "A"), ("alice.slots.test", "AAAA"),
                             ("bob.slots.test", "A"), ("bob.slots.test", "AAAA")], managed()
        som.fail("journalctl -u porkbun-records --no-pager | grep -q WARNING")
        # a dynamic user, its state behind /var/lib/private
        som.succeed("test -L /var/lib/porkbun-records")

    with subtest("a second run makes no write"):
        som.succeed("systemctl start porkbun-records")
        assert len(writes()) == 4, writes()

    with subtest("a new prefix on the link updates only the AAAA records"):
        som.succeed("ip -6 addr del 2001:db8:1:2::2/64 dev eth1")
        som.succeed("ip -6 addr add 2001:db8:9:9::2/64 dev eth1")
        settle("2001:db8:9:9::2")
        som.succeed("systemctl start porkbun-records")
        assert sorted(writes()[4:]) == [
            "edit alice.slots.test AAAA 2001:db8:9:9::5107:4",
            "edit bob.slots.test AAAA 2001:db8:9:9::5107:5",
        ], writes()
        assert zone()[("alice.slots.test", "A")] == "38.89.142.76"
        # loud: at warning priority, naming both prefixes
        out = som.succeed("journalctl -u porkbun-records -p warning --no-pager")
        assert "WARNING: eth1 is in 2001:db8:9:9::/64 now" in out and "2001:db8:1:2::/64" in out, out

    with subtest("two prefixes on the link: no guess, no write"):
        som.succeed("ip -6 addr add 2001:db8:7:7::2/64 dev eth1")
        settle("2001:db8:7:7::2")
        som.fail("systemctl start porkbun-records")
        assert len(writes()) == 6, writes()
        som.succeed("journalctl -u porkbun-records --no-pager | grep -q 'need exactly one global /64'")
        som.succeed("ip -6 addr del 2001:db8:7:7::2/64 dev eth1")

    with subtest("a bad API answer fails the unit and deletes nothing"):
        som.succeed("/run/booted-system/specialisation/nobob/bin/switch-to-configuration test")
        for mode, logged in [("error", "stub says no"), ("garbage", "maintenance")]:
            som.succeed(f"curl -sf ${api}/_fail/{mode}")
            som.fail("systemctl start porkbun-records")
            som.succeed(f"journalctl -u porkbun-records --no-pager | grep -q '{logged}'")
        som.succeed("curl -sf ${api}/_fail/off")
        assert len(writes()) == 6, writes()
        assert ("bob.slots.test", "AAAA") in zone()
        assert ("bob.slots.test", "A") in managed()

    with subtest("a name dropped from the config loses exactly its records"):
        before = zone()
        som.succeed("systemctl start porkbun-records")
        assert sorted(writes()[6:]) == [
            "delete bob.slots.test A",
            "delete bob.slots.test AAAA",
        ], writes()
        after = zone()
        del before[("bob.slots.test", "A")], before[("bob.slots.test", "AAAA")]
        assert after == before, (before, after)
        assert after[("other.slots.test", "A")] == "192.0.2.99"
        assert managed() == [("alice.slots.test", "A"), ("alice.slots.test", "AAAA")], managed()
        som.succeed("systemctl start porkbun-records")
        assert len(writes()) == 8, writes()
  '';
}
