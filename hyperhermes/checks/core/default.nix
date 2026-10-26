# Core end to end on one host with two agents, alice and bob, on the
# patched hermes package: both agents' gateway and dashboard units start;
# alice's secretEnv entry reaches her .env (owner-only, hers) and nobody
# else's, and a rotated value replaces the old one on restart; the
# root-held dashboard forward of each agent answers its owner and root,
# while the other agent gets a reset, at the forward and at the backend
# behind it; the hermes-native chain is in place and hooked into OUTPUT.
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
  '';
}
