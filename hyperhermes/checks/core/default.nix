# Core end to end on one host with two agents, alice and bob, on the
# patched hermes package: both agents' gateway and dashboard units start;
# alice's secretEnv entry reaches her .env (owner-only, hers) and nobody
# else's, and a rotated value replaces the old one on restart; the .env
# of each of her named profiles gets the same hermes-native blocks
# (credentials and environment, ANTHROPIC_BASE_URL among them): a
# profile created while the gateway runs within seconds, all of them
# again with the rotated value on restart, a stale hand-copied block
# replaced rather than duplicated, a symlinked .env never followed; a key in
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
  profilesOf = user: "${hlib.stateDir user}/.hermes/profiles";
  baseUrl = "http://127.0.0.1:9/teamclaude";
  portOf = user: toString (hlib.dashboardPortFor user);
  backendOf = uid: toString (hlib.dashboardBackendBase + uid);
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-core";

  # A container test (systemd-nspawn, no VM): nothing here needs a kernel
  # of its own; the owner-match rules are iptables-nft on the host kernel.
  containers.machine = {
    imports = [
      self.nixosModules.core
      ../container-pam.nix
    ];

    services.hyperhermes = {
      # The agents' pip venv without the default data-science set: the
      # test needs the unit, not torch.
      pythonPackages = _: [ ];
      agents.alice = {
        uid = 1001;
        secretEnv.HH_TEST_TOKEN = secret;
        environment.ANTHROPIC_BASE_URL = baseUrl;
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

    profiles = "${profilesOf "alice"}"

    import shlex

    def as_alice(cmd):
        return machine.succeed(f"runuser -u alice -- sh -c {shlex.quote(cmd)}")

    def write_as_alice(path, text):
        as_alice(f"printf %s {shlex.quote(text)} > {path}")

    def publish_profile(name, env_text=None, link=None):
        # As hermes does: build in a staging directory, rename it in.
        staging = f"{profiles}/.{name}.staging-1"
        as_alice(f"mkdir -p {staging} && touch {staging}/config.yaml")
        if env_text is not None:
            write_as_alice(f"{staging}/.env", env_text)
        if link is not None:
            as_alice(f"ln -s {link} {staging}/.env")
        as_alice(f"mv {staging} {profiles}/{name}")

    def blocks_once(env, token):
        for block in ("environment", "credentials"):
            n = machine.succeed(f"grep -c '^# BEGIN hermes-native {block}$' {env}").strip()
            assert n == "1", (env, block, n)
        machine.succeed(f"grep -qx 'HH_TEST_TOKEN={token}' {env}")
        machine.succeed(f"grep -qx 'ANTHROPIC_BASE_URL=${baseUrl}' {env}")
        assert machine.succeed(f"grep -c '^HH_TEST_TOKEN=' {env}").strip() == "1"

    with subtest("a profile created while the gateway runs gets the blocks"):
        machine.succeed("systemctl is-active hermes-profile-env-alice.path")
        as_alice(f"mkdir -p {profiles}")
        publish_profile("fresh", env_text="# Per-profile secrets\n")
        machine.wait_until_succeeds(f"grep -qx 'HH_TEST_TOKEN=first-secret' {profiles}/fresh/.env", timeout=10)
        blocks_once(f"{profiles}/fresh/.env", "first-secret")
        machine.succeed(f"grep -qx '# Per-profile secrets' {profiles}/fresh/.env")
        mode = machine.succeed(f"stat -c '%a %U' {profiles}/fresh/.env").strip()
        assert mode == "600 alice", mode
        # A profile without a .env yet gets one.
        publish_profile("bare")
        machine.wait_until_succeeds(f"grep -qx 'HH_TEST_TOKEN=first-secret' {profiles}/bare/.env", timeout=10)
        # A marker-less directory (a log write after a delete) is no
        # profile and is left alone.
        as_alice(f"mkdir {profiles}/ghost")
        publish_profile("later")
        machine.wait_until_succeeds(f"test -f {profiles}/later/.env", timeout=10)
        machine.fail(f"test -e {profiles}/ghost/.env")
        # One made by hand, its marker a moment after the directory.
        as_alice(f"mkdir {profiles}/byhand && sleep 1 && touch {profiles}/byhand/config.yaml")
        machine.wait_until_succeeds(f"grep -qx 'HH_TEST_TOKEN=first-secret' {profiles}/byhand/.env", timeout=10)
        machine.fail("grep -rq HH_TEST_TOKEN ${profilesOf "bob"}")

    with subtest("a symlinked profile .env is not followed"):
        write_as_alice("/home/alice/target", "untouched")
        publish_profile("linked", link="/home/alice/target")
        publish_profile("trigger")
        machine.wait_until_succeeds(f"test -f {profiles}/trigger/.env", timeout=10)
        machine.succeed(f"test -L {profiles}/linked/.env")
        assert machine.succeed("cat /home/alice/target") == "untouched"

    # What a hand copy of the blocks left in a profile, plus a key core
    # drops and one of the user's.
    write_as_alice(
        f"{profiles}/fresh/.env",
        "KEEP_ME=1\n"
        "# BEGIN hermes-native credentials\nHH_TEST_TOKEN=stale\n# END hermes-native credentials\n"
        "# BEGIN hermes-native environment\nANTHROPIC_BASE_URL=https://api.anthropic.com\n# END hermes-native environment\n"
        "PYTHONPATH=/x\n",
    )

    with subtest("a rotated secret replaces the old one on restart"):
        machine.succeed("printf second-secret > ${secret}")
        machine.succeed("systemctl restart hermes-agent-alice.service")
        machine.wait_until_succeeds("grep -qx 'HH_TEST_TOKEN=second-secret' ${envOf "alice"}")
        machine.fail("grep -q first-secret ${envOf "alice"}")
        assert machine.succeed("grep -c '^HH_TEST_TOKEN=' ${envOf "alice"}").strip() == "1"
        for name in ("fresh", "bare", "later", "trigger", "byhand"):
            env = f"{profiles}/{name}/.env"
            blocks_once(env, "second-secret")
            machine.fail(f"grep -q -e first-secret -e stale -e api.anthropic.com -e PYTHONPATH {env}")
        # A stale hand-copied block is replaced, not duplicated.
        machine.succeed(f"grep -qx KEEP_ME=1 {profiles}/fresh/.env")
        assert machine.succeed("cat /home/alice/target") == "untouched"

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
