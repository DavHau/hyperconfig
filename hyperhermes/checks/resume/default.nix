# A dashboard restart does not lose the chat turn it interrupts
# (modules/core/patches/hermes-dashboard-resume-after-restart.patch), on
# one host with one agent and a scripted model (./fake-llm.py): a turn is
# started over the dashboard's chat socket (./client.py) and the client
# leaves, as a closed browser tab does.
#  - drain: a restart while the turn runs a short command lets the command
#    finish and the turn complete in the old process;
#  - resume: a stop while the turn runs a long command keeps the turn's
#    restart marker; the next start continues the turn by itself, with no
#    client, through hermes' auto-continue note, and the answer is
#    recorded;
#  - a user Stop retires the marker, and a restart then continues nothing.
{ pkgs, self }:
let
  hlib = self.lib;
  user = "alice";
  uid = 1001;
  llmPort = 9999;
  llmRecord = "/var/lib/fake-llm/record";
  secret = "/run/hh-secrets/openai";
  hermesHome = "${hlib.stateDir user}/.hermes";
  workspace = hlib.workspace user;
  backend = "http://127.0.0.1:${toString (hlib.dashboardBackendBase + uid)}";
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-resume";

  nodes.machine = {
    imports = [ self.nixosModules.core ];
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    services.hyperhermes = {
      pythonPackages = _: [ ];
      initialModel = {
        provider = "custom";
        base_url = "http://127.0.0.1:${toString llmPort}/v1";
        default = "fake-model";
      };
      agents.${user} = {
        inherit uid;
        environment.OPENAI_BASE_URL = "http://127.0.0.1:${toString llmPort}/v1";
        secretEnv.OPENAI_API_KEY = secret;
        # Shorter than the deployed 60s, so the resume case does not wait
        # out a full drain.
        settings.dashboard.shutdown_drain_seconds = 20;
      };
    };

    systemd.tmpfiles.rules = [
      "d /run/hh-secrets 0700 root root - -"
      "f ${secret} 0400 root root - fake-key"
    ];

    systemd.services.fake-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "hermes-dashboard-${user}.service" ];
      serviceConfig = {
        StateDirectory = "fake-llm";
        ExecStart = "${pkgs.python3}/bin/python3 ${./fake-llm.py} ${toString llmPort} ${llmRecord}";
      };
    };

    environment.systemPackages = [
      pkgs.curl
      pkgs.sqlite
    ];
  };

  testScript = ''
    import json

    unit = "hermes-dashboard-${user}.service"
    markers = "${hermesHome}/desktop/interrupted_turns.json"

    def client(*args):
        quoted = " ".join(f"'{a}'" for a in args)
        return machine.succeed(
            f"runuser -u ${user} -- ${python}/bin/python3 ${./client.py} ${backend} {quoted}"
        ).strip().splitlines()[-1]

    def record(scenario):
        out = machine.succeed("cat ${llmRecord} 2>/dev/null || true")
        return [r["step"] for r in map(json.loads, out.splitlines()) if r["scenario"] == scenario]

    def wait_step(scenario, step, timeout=120):
        machine.wait_until_succeeds(
            f"grep -q '\"scenario\": \"{scenario}\", \"step\": \"{step}\"' ${llmRecord}", timeout=timeout
        )

    def marker_keys():
        out = machine.succeed(f"cat {markers} 2>/dev/null || echo '{{}}'")
        return set(json.loads(out))

    def rows(sid):
        return machine.succeed(
            "sqlite3 -readonly -separator '|' 'file:${hermesHome}/state.db?mode=ro' "
            f"\"select role, coalesce(display_kind, '''), substr(coalesce(content, '''), 1, 80) "
            f"from messages where session_id='{sid}' order by id\""
        )

    def wait_dashboard():
        machine.wait_for_unit(unit)
        machine.wait_until_succeeds("runuser -u ${user} -- curl -sf -o /dev/null ${backend}/", timeout=180)

    machine.wait_for_unit("fake-llm.service")
    wait_dashboard()
    config = machine.succeed("cat ${hermesHome}/config.yaml")
    print(config)

    with subtest("the dashboard unit drains: SIGTERM to the main process only, stop timeout above the drain"):
        props = machine.succeed(f"systemctl show -p KillMode -p TimeoutStopUSec {unit}")
        assert "KillMode=mixed" in props, props
        assert "TimeoutStopUSec=2min" in props, props

    with subtest("a restart lets a running tool call finish and the turn complete"):
        sid = client("start", "DRAIN-TEST", "sleep 10; echo ran >> ${workspace}/drain.count")
        wait_step("DRAIN-TEST", "tool-call")
        machine.wait_until_succeeds("pgrep -u ${user} -f 'sleep 10'")
        machine.succeed(f"systemctl restart {unit}")
        assert machine.succeed("cat ${workspace}/drain.count").strip() == "ran"
        assert record("DRAIN-TEST") == ["tool-call", "after-tool"], record("DRAIN-TEST")
        assert sid not in marker_keys()
        print(rows(sid))
        assert "DONE-DRAIN-TEST" in rows(sid)
        wait_dashboard()

    with subtest("a stop mid-turn keeps the turn's restart marker"):
        sid = client("start", "RESUME-TEST", "sleep 300; echo ran >> ${workspace}/resume.count")
        wait_step("RESUME-TEST", "tool-call")
        machine.wait_until_succeeds("pgrep -u ${user} -f 'sleep 300'")
        machine.succeed(f"systemctl stop {unit}")
        assert sid in marker_keys(), machine.succeed(f"cat {markers}")
        machine.fail("test -e ${workspace}/resume.count")
        # Nothing the turn started outlives the dashboard (KillMode=mixed).
        machine.fail("pgrep -u ${user} -f 'sleep 300'")

    with subtest("the next start continues the turn without a client and records the answer"):
        machine.succeed(f"systemctl start {unit}")
        wait_step("RESUME-TEST", "resume")
        # hermes logs to $HERMES_HOME/logs, not to the journal.
        machine.succeed(f"grep -q 'startup resume: reopened session {sid}' ${hermesHome}/logs/agent.log")
        machine.wait_until_succeeds(f"! grep -q {sid} {markers} 2>/dev/null", timeout=60)
        machine.wait_until_succeeds(
            "sqlite3 -readonly 'file:${hermesHome}/state.db?mode=ro' "
            f"\"select 1 from messages where session_id='{sid}' and content='RESUMED-RESUME-TEST'\" | grep -q 1",
            timeout=60,
        )
        log = rows(sid)
        print(log)
        assert "user|auto_continue|[System note: Your previous turn was interrupted" in log, log
        # One continuation, no loop; the scripted model answers it without
        # re-running the command (what a real model does is its call: the
        # note tells it to check the state first).
        assert record("RESUME-TEST") == ["tool-call", "resume"], record("RESUME-TEST")
        machine.fail("test -e ${workspace}/resume.count")

    with subtest("a user Stop retires the marker and a restart continues nothing"):
        wait_dashboard()
        sid = client("start", "STOP-TEST", "sleep 600")
        wait_step("STOP-TEST", "tool-call")
        assert sid in marker_keys()
        client("stop", sid)
        assert sid not in marker_keys(), machine.succeed(f"cat {markers}")
        machine.succeed(f"systemctl restart {unit}")
        wait_dashboard()
        machine.sleep(20)
        assert record("STOP-TEST") == ["tool-call"], record("STOP-TEST")
        assert "auto_continue" not in rows(sid)

    print(machine.succeed(
        "grep -i 'drain\\|startup resume\\|auto-continue\\|turn finished\\|Interrupt requested' ${hermesHome}/logs/agent.log || true"
    ))
  '';
}
