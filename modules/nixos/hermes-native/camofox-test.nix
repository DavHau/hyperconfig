# Isolation of the per-agent Camofox servers (camofox.nix): two agents,
# alice and bob. alice's first connection to her root-held port starts
# her server; her access key gates its routes. bob reaches neither her
# root-held port nor her backend, cannot read her key or profile store,
# and a listener he binds on her backend port while her server is down
# never receives her traffic.
{ pkgs }:
let
  inherit (pkgs) lib;
  hlib = import ./lib.nix { inherit lib; };
  aliceUid = 1000;
  port = toString (hlib.camofoxPortFor "alice");
  backend = toString (hlib.camofoxBackendBase + aliceUid);
  dir = hlib.camofoxDir "alice";
in
pkgs.testers.runNixOSTest {
  name = "hermes-camofox-isolation";

  nodes.machine = {
    imports = [
      ./options.nix
      ./forwards.nix
      ./firewall.nix
      ./camofox.nix
    ];
    virtualisation.memorySize = 3072;

    users.users.alice = {
      isNormalUser = true;
      uid = aliceUid;
    };
    users.users.bob = {
      isNormalUser = true;
      uid = aliceUid + 1;
    };

    services.hermes-native = {
      enable = true;
      users.alice = { };
      users.bob = { };
    };

    # What agents.nix provides around camofox.nix: the state dirs, and an
    # agent unit whose preStart hands the key to hermes.
    systemd.tmpfiles.rules = lib.concatMap (u: [
      "d ${hlib.baseDir u} 0711 root root - -"
      "d ${hlib.stateDir u} 0700 ${u} users - -"
      "d ${hlib.stateDir u}/.hermes 0700 ${u} users - -"
      "f ${hlib.stateDir u}/.hermes/.env 0600 ${u} users - -"
    ]) [ "alice" "bob" ];
    systemd.services.hermes-agent-alice.serviceConfig = {
      Type = "oneshot";
      User = "alice";
      ExecStart = "${pkgs.coreutils}/bin/true";
    };

    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
  };

  testScript = ''
    import json

    machine.wait_for_unit("hermes-firewall.service")
    machine.wait_for_unit("hermes-camofox-fwd-alice.socket")

    with subtest("alice's agent gets her key and URL in her .env"):
        machine.succeed("systemctl start hermes-agent-alice.service")
        machine.succeed("test \"$(stat -c '%a %U' ${dir}/access-key)\" = '600 alice'")
        machine.succeed("test \"$(stat -c '%a %U' ${dir})\" = '700 alice'")
        key = machine.succeed("cat ${dir}/access-key").strip()
        env = machine.succeed("cat ${hlib.stateDir "alice"}/.hermes/.env")
        assert "CAMOFOX_URL=http://127.0.0.1:${port}\n" in env, env
        assert f"CAMOFOX_API_KEY={key}\n" in env, env

    with subtest("alice's first connection starts her server"):
        machine.wait_until_succeeds("runuser -u alice -- curl -sf http://127.0.0.1:${port}/health", timeout=120)
        machine.succeed("systemctl is-active hermes-camofox-alice.service")
        machine.succeed("test \"$(stat -c %U /proc/$(systemctl show -P MainPID hermes-camofox-alice.service))\" = alice")

    tabs = "runuser -u alice -- curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"userId\":\"a\",\"sessionKey\":\"s\"}' "
    with subtest("routes need alice's key"):
        assert machine.succeed(tabs + "http://127.0.0.1:${port}/tabs").strip() == "401"
        assert machine.succeed(tabs + f"-H 'Authorization: Bearer {key}' http://127.0.0.1:${port}/tabs").strip() == "200"
        listed = json.loads(machine.succeed(f"runuser -u alice -- curl -sf -H 'Authorization: Bearer {key}' 'http://127.0.0.1:${port}/tabs?userId=a'"))
        assert len(listed["tabs"]) == 1, listed

    with subtest("bob reaches neither alice's port nor her backend"):
        machine.fail("runuser -u bob -- curl -s --max-time 10 http://127.0.0.1:${port}/health")
        machine.fail("runuser -u bob -- curl -s --max-time 10 http://127.0.0.1:${backend}/health")

    with subtest("bob reads neither alice's key nor her profile store"):
        machine.fail("runuser -u bob -- cat ${dir}/access-key")
        machine.fail("runuser -u bob -- ls ${dir}/profiles")
        machine.fail("runuser -u bob -- cat /proc/$(systemctl show -P MainPID hermes-camofox-alice.service)/environ")

    with subtest("a listener bob binds on alice's backend gets none of her traffic"):
        machine.succeed("systemctl stop hermes-camofox-alice.service")
        # Stopping saves the profile's cookies, owner-only.
        machine.succeed("test \"$(stat -c '%a %U' ${dir}/profiles/*/storage-state.json)\" = '600 alice'")
        machine.fail("journalctl -u hermes-camofox-alice --no-pager | grep -q 'failed to persist'")
        machine.succeed("systemd-run --uid=bob --unit=squat ${pkgs.python3}/bin/python3 -m http.server ${backend} --bind 127.0.0.1")
        # root may dial any gated port; bob's own dial is rejected too.
        machine.wait_until_succeeds("curl -sf -o /dev/null http://127.0.0.1:${backend}/", timeout=60)
        served = "journalctl -u squat --no-pager | grep -c 'GET /'"
        before = machine.succeed(served).strip()
        machine.fail(f"runuser -u alice -- curl -sf --max-time 30 -H 'Authorization: Bearer {key}' 'http://127.0.0.1:${port}/tabs?userId=a'")
        assert machine.succeed(served).strip() == before
        machine.wait_until_succeeds("journalctl --no-pager | grep -q 'refusing: backend 127.0.0.1:${backend} is owned by uid 1001'", timeout=60)
  '';
}
