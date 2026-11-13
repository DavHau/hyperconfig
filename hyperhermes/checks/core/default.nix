# Core end to end on one host with two agents, alice and bob, on the
# patched hermes package: both agents' gateway and dashboard units start;
# alice's secretEnv entry reaches her .env (owner-only, hers) and nobody
# else's, and a rotated value replaces the old one on restart; a key in
# alice's dashboardDropEnv is gone from her .env once the dashboard
# restarts, while the others stay; the
# root-held dashboard forward of each agent answers its owner and root,
# while the other agent gets a reset, at the forward and at the backend
# behind it; the hermes-native chain is in place and hooked into OUTPUT;
# a `gateway run` beside alice's unit is refused, and the unit takes
# over from a stray gateway of her home instead of exiting 75 forever.
{ pkgs, self }:
let
  hlib = self.lib;
  secret = "/run/hh-secrets/alice-token";
  envOf = user: "${hlib.stateDir user}/.hermes/.env";
  portOf = user: toString (hlib.dashboardPortFor user);
  backendOf = uid: toString (hlib.dashboardBackendBase + uid);
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-core";

  nodes.machine = {
    imports = [ self.nixosModules.core ];
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    services.hyperhermes = {
      # The agents' pip venv without the default data-science set: the
      # test needs the unit, not torch.
      pythonPackages = _: [ ];
      agents.alice = {
        uid = 1001;
        secretEnv.HH_TEST_TOKEN = secret;
        dashboardDropEnv = [ "HH_DROP_ME" ];
      };
      agents.bob.uid = 1002;
    };

    # A runtime secret file outside the store, as a deployment's secret
    # store provides one.
    systemd.tmpfiles.rules = [
      "d /run/hh-secrets 0700 root root - -"
      "f ${secret} 0400 root root - first-secret"
    ];

    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    def dial(user, port):
        # Any HTTP answer is a connection the forward admitted.
        return f"runuser -u {user} -- curl -sS -o /dev/null -w '%{{http_code}}' --max-time 10 http://127.0.0.1:{port}/"

    machine.wait_for_unit("hermes-firewall.service")
    for user in ("alice", "bob"):
        machine.wait_for_unit(f"hermes-agent-{user}.service")
        machine.wait_for_unit(f"hermes-dashboard-{user}.service")
        machine.wait_for_unit(f"hermes-dashboard-fwd-{user}.socket")

    with subtest("the firewall chain is in place"):
        machine.succeed("iptables -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j ${hlib.chain}")
        rules = machine.succeed("iptables -w -S ${hlib.chain}")
        for port in ("${portOf "alice"}", "${portOf "bob"}", "${backendOf 1001}", "${backendOf 1002}"):
            assert f"--dport {port} -m owner --uid-owner" in rules, (port, rules)

    with subtest("secretEnv lands in the owner's .env only"):
        machine.wait_until_succeeds("grep -qx 'HH_TEST_TOKEN=first-secret' ${envOf "alice"}")
        mode = machine.succeed("stat -c '%a %U' ${envOf "alice"}").strip()
        assert mode == "600 alice", mode
        machine.fail("grep -q HH_TEST_TOKEN ${envOf "bob"}")
        machine.fail("runuser -u bob -- cat ${envOf "alice"}")

    with subtest("a rotated secret replaces the old one on restart"):
        machine.succeed("printf second-secret > ${secret}")
        machine.succeed("systemctl restart hermes-agent-alice.service")
        machine.wait_until_succeeds("grep -qx 'HH_TEST_TOKEN=second-secret' ${envOf "alice"}")
        machine.fail("grep -q first-secret ${envOf "alice"}")
        assert machine.succeed("grep -c '^HH_TEST_TOKEN=' ${envOf "alice"}").strip() == "1"

    with subtest("dashboardDropEnv keys are dropped before the dashboard starts"):
        machine.succeed("runuser -u alice -- sh -c 'echo HH_DROP_ME=x >> ${envOf "alice"}'")
        machine.succeed("systemctl restart hermes-dashboard-alice.service")
        machine.wait_for_unit("hermes-dashboard-alice.service")
        machine.fail("grep -q '^HH_DROP_ME=' ${envOf "alice"}")
        machine.succeed("grep -qx 'HH_TEST_TOKEN=second-secret' ${envOf "alice"}")

    with subtest("the dashboard forward admits its owner and root"):
        for user in ("alice", "bob"):
            port = "${portOf "alice"}" if user == "alice" else "${portOf "bob"}"
            machine.wait_until_succeeds(f"{dial(user, port)} | grep -qv '^000$'", timeout=180)
        machine.succeed(f"{dial('root', '${portOf "alice"}')} | grep -qv '^000$'")

    with subtest("the other agent is refused at the forward and the backend"):
        machine.fail(dial("bob", "${portOf "alice"}"))
        machine.fail(dial("bob", "${backendOf 1001}"))
        machine.fail(dial("alice", "${portOf "bob"}"))
        machine.fail(dial("alice", "${backendOf 1002}"))

    # Only the unit runs alice's gateway (modules/core/reap-stray-gateway.py,
    # patches/hermes-gateway-managed-unit-only.patch).
    def gateway_pids():
        return machine.succeed("pgrep -u alice -f 'bin/hermes gateway' || true").split()

    with subtest("a gateway started beside the unit is refused"):
        out = machine.fail("runuser -u alice -- hermes gateway run --force 2>&1")
        assert "managed by the systemd unit hermes-agent-alice.service" in out, out

    with subtest("the unit takes over from a stray gateway of its home"):
        import re
        exec_start = machine.succeed("systemctl show -p ExecStart --value hermes-agent-alice.service")
        m = re.search(r"(/nix/store/\S+/bin/hermes) gateway", exec_start)
        assert m is not None, exec_start
        hermes = m.group(1)
        lock = "${hlib.stateDir "alice"}/.hermes/gateway.lock"
        machine.succeed("systemctl stop hermes-agent-alice.service")
        # A stopped unit is named as such, with the command that starts it
        # (the package's hermes: the shim refuses a stopped unit itself).
        out = machine.fail(
            "runuser -u alice -- env HOME=/home/alice HERMES_HOME=${hlib.stateDir "alice"}/.hermes "
            "HERMES_GATEWAY_MANAGED_UNIT=hermes-agent-alice.service "
            "HERMES_GATEWAY_MANAGED_HOME=${hlib.stateDir "alice"}/.hermes "
            f"{hermes} gateway run 2>&1")
        # The gateway's SIGTERM exit can leave the unit "failed" rather
        # than "inactive"; either way the hint names the start command.
        assert "As root: systemctl " in out and "systemctl start hermes-agent-alice.service" in out, out
        # What a cron worker spawned while the unit restarted, before the
        # patch: a gateway of alice's home outside the unit, here without
        # HERMES_GATEWAY_MANAGED_UNIT (an older hermes, or the var unset).
        machine.succeed(
            "systemd-run --unit=stray-gateway --uid=alice --gid=users "
            "-p WorkingDirectory=${hlib.workspace "alice"} "
            "-E HOME=/home/alice -E HERMES_HOME=${hlib.stateDir "alice"}/.hermes "
            f"{hermes} gateway run --idle-exit"
        )
        # It holds the home's gateway lock: what made the unit exit 75.
        machine.wait_until_succeeds(
            f"p=$(grep -o '\"pid\": [0-9]*' {lock} | grep -o '[0-9]*$') && grep -q stray-gateway.service /proc/$p/cgroup",
            timeout=180)
        restarts = machine.succeed("systemctl show -p NRestarts --value hermes-agent-alice.service").strip()
        machine.succeed("systemctl start hermes-agent-alice.service")
        machine.wait_until_fails("systemctl is-active stray-gateway.service", timeout=60)
        machine.wait_for_unit("hermes-agent-alice.service")
        machine.sleep(20)
        after = machine.succeed("systemctl show -p NRestarts --value hermes-agent-alice.service").strip()
        assert int(after) <= int(restarts), (restarts, after)
        main = machine.succeed("systemctl show -p MainPID --value hermes-agent-alice.service").strip()
        assert gateway_pids() == [main], (gateway_pids(), main)
        machine.succeed("journalctl -u hermes-agent-alice.service | grep -q 'taking over from a stray gateway'")
  '';
}
