# Isolation of the per-agent Camofox servers (camofox.nix): two agents,
# alice and bob. alice's first connection to her root-held port starts
# her server; her access key gates its routes. bob reaches neither her
# root-held port nor her backend, cannot read her key or profile store,
# and a listener he binds on her backend port while her server is down
# never receives her traffic.
#
# Downloads: hermes' browser_downloads tool (the patched hermes package,
# patches/hermes-camofox-browser-downloads.patch), called through hermes'
# tool registry against alice's real server and a local site, saves the
# files that a link, a form POST, a form POST redirected to another origin
# and a script start, and reports their sha256. It refuses paths outside
# the working directory, an existing file and a file over 50 MiB. Neither
# another camofox userId on her server nor bob sees her downloads, and
# closing the session deletes the server's copies.
{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  hlib = import ./lib.nix { inherit lib; };
  aliceUid = 1000;
  port = toString (hlib.camofoxPortFor "alice");
  backend = toString (hlib.camofoxBackendBase + aliceUid);
  dir = hlib.camofoxDir "alice";

  # Only the hermes package is used; it reads neither cfg nor hlib.
  hermes =
    (import ./agent-config.nix {
      inherit lib pkgs inputs;
      hlib = null;
      cfg = { };
    }).hermesPackage;
  site = ./camofox-test-site.py;

  # Runs the driver as an agent with hermes' own interpreter, the agent's
  # camofox URL and key from its .env (as hermes reads them) and its
  # working directory.
  driver =
    user: args:
    "runuser -u ${user} -- sh -c 'set -a; . ${hlib.stateDir user}/.hermes/.env; set +a; "
    + "HERMES_HOME=/home/${user}/hermes-test TERMINAL_CWD=${hlib.workspace user} "
    + "exec ${hermes.hermesVenv}/bin/python3 ${./camofox-test-downloads.py} ${args}' 2>&1";
  privateTmp = "/tmp/systemd-private-*-hermes-camofox-alice.service-*/tmp";
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
    systemd.services = lib.genAttrs [ "hermes-agent-alice" "hermes-agent-bob" ] (unit: {
      serviceConfig = {
        Type = "oneshot";
        User = lib.removePrefix "hermes-agent-" unit;
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
    }) // {
      # The downloads test opens two camofox userIds next to the "a" one
      # the routes subtest left open.
      hermes-camofox-alice.environment.MAX_SESSIONS = lib.mkForce "3";
      download-site = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.python3}/bin/python3 ${site} 8765";
        };
      };
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

    with subtest("browser_downloads saves alice's downloads, and only into her workspace"):
        machine.wait_for_unit("download-site.service")
        out = machine.succeed("${driver "alice" "owner http://127.0.0.1:8765 ${site}"}")
        print(out)
        assert "ALL PASSED" in out
        ids = json.loads(out.split("IDS: ", 1)[1].splitlines()[0])
        users = json.loads(out.split("USERS: ", 1)[1].splitlines()[0])
        # The workspace files belong to alice.
        machine.succeed("test \"$(stat -c %U ${hlib.workspace "alice"}/redirect.bin)\" = alice")

    with subtest("bob sees none of alice's downloads"):
        machine.succeed("systemctl start hermes-agent-bob.service")
        machine.succeed(f"echo '{json.dumps(ids)}' > /tmp/alice-ids.json && chmod 644 /tmp/alice-ids.json")
        out = machine.succeed("${driver "bob" "other http://127.0.0.1:8765 /tmp/alice-ids.json"}")
        print(out)
        assert "ALL PASSED" in out
        out = machine.succeed("runuser -u bob -- env CAMOFOX_URL=http://127.0.0.1:${port} CAMOFOX_API_KEY=x HERMES_HOME=/home/bob/hermes-test2 TERMINAL_CWD=/home/bob/ws ${hermes.hermesVenv}/bin/python3 ${./camofox-test-downloads.py} unreachable 2>&1")
        print(out)
        assert "ALL PASSED" in out

    with subtest("closing a session deletes the server's copies of its downloads"):
        copies = "ls ${privateTmp} | grep -c '^camofox-download-' || true"
        assert machine.succeed(copies).strip() == str(len(ids)), machine.succeed("ls ${privateTmp}")
        for u in users:
            machine.succeed(f"runuser -u alice -- curl -sf -X DELETE -H 'Authorization: Bearer {key}' http://127.0.0.1:${port}/sessions/{u}")
        assert machine.succeed(copies).strip() == "0", machine.succeed("ls ${privateTmp}")
        # Playwright's own copies (its artifacts dir) go with the browser context.
        assert machine.succeed("find ${privateTmp}/playwright-artifacts-* -type f").strip() == "", machine.succeed("ls -laR ${privateTmp}")

    with subtest("bob reaches neither alice's port nor her backend"):
        machine.fail("runuser -u bob -- curl -s --max-time 10 http://127.0.0.1:${port}/health")
        machine.fail("runuser -u bob -- curl -s --max-time 10 http://127.0.0.1:${backend}/health")

    with subtest("bob reads neither alice's key nor her profile store"):
        machine.fail("runuser -u bob -- cat ${dir}/access-key")
        machine.fail("runuser -u bob -- ls ${dir}/profiles")
        machine.fail("runuser -u bob -- cat /proc/$(systemctl show -P MainPID hermes-camofox-alice.service)/environ")

    with subtest("a listener bob binds on alice's backend gets none of her traffic"):
        machine.succeed("systemctl stop hermes-camofox-alice.service")
        # Stopping saves the profiles' cookies, owner-only.
        machine.succeed("test \"$(stat -c '%a %U' ${dir}/profiles/*/storage-state.json | sort -u)\" = '600 alice'")
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
