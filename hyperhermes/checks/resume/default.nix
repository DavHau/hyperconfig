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
#  - subagents (modules/core/patches/hermes-subagents-resume-after-restart.patch):
#    background subagents a restart kills are re-dispatched and the parent
#    gets the original call's result, for one consolidated unit (alice) and
#    for per-task units (bob, delegation.independent_completions as on som).
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
  # A second agent with som's delegation settings
  # (machines/som/hermes-agents.nix): every background task its own unit.
  user2 = "bob";
  uid2 = 1002;
  hermesHome2 = "${hlib.stateDir user2}/.hermes";
  workspace2 = hlib.workspace user2;
  backend2 = "http://127.0.0.1:${toString (hlib.dashboardBackendBase + uid2)}";
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-resume";

  nodes.machine = {
    imports = [ self.nixosModules.core ];
    virtualisation.memorySize = 4096;
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
      agents.${user2} = {
        uid = uid2;
        environment.OPENAI_BASE_URL = "http://127.0.0.1:${toString llmPort}/v1";
        secretEnv.OPENAI_API_KEY = secret;
        settings.dashboard.shutdown_drain_seconds = 20;
        settings.delegation = {
          max_concurrent_children = 20;
          independent_completions = true;
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d /run/hh-secrets 0700 root root - -"
      "f ${secret} 0400 root root - fake-key"
    ];

    systemd.services.fake-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [
        "hermes-dashboard-${user}.service"
        "hermes-dashboard-${user2}.service"
      ];
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

    def client(*args, user="${user}", backend="${backend}"):
        quoted = " ".join(f"'{a}'" for a in args)
        return machine.succeed(
            f"runuser -u {user} -- ${python}/bin/python3 ${./client.py} {backend} {quoted}"
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

    def wait_dashboard(unit=unit, user="${user}", backend="${backend}"):
        machine.wait_for_unit(unit)
        machine.wait_until_succeeds(f"runuser -u {user} -- curl -sf -o /dev/null {backend}/", timeout=180)

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

    with subtest("a restart re-dispatches the unfinished subagent and the parent gets the original call's result"):
        wait_dashboard()
        ws = "${workspace}"
        child_a = f"CHILDA-TEST echo a >> {ws}/childa.count"
        # The first run leaves a mark and hangs until the restart kills it; the re-dispatched run finds the mark.
        child_b = (f"CHILDB-TEST test -e {ws}/childb.mark || {{ touch {ws}/childb.mark; sleep 300; }}; "
                   f"echo b >> {ws}/childb.count")
        sid = client("start", "DELEG-TEST", f"{child_a} ||| {child_b}")
        wait_step("CHILDA-TEST", "after-tool")
        wait_step("CHILDB-TEST", "tool-call")
        wait_step("DELEG-TEST", "after-tool")
        machine.wait_until_succeeds("pgrep -u ${user} -f 'sleep 300'")
        # The parent's turn has ended (its dispatch returned): only the subagent unit is running.
        machine.wait_until_succeeds(
            "sqlite3 -readonly 'file:${hermesHome}/state.db?mode=ro' "
            f"\"select 1 from messages where session_id='{sid}' and content='DONE-DELEG-TEST'\" | grep -q 1",
            timeout=60)
        machine.succeed(f"systemctl restart {unit}")
        machine.fail("pgrep -u ${user} -f 'sleep 300'")
        wait_dashboard()
        wait_step("CHILDB-TEST", "after-tool", timeout=240)
        wait_step("DELEGATION-RESULT", "result", timeout=180)
        assert record("CHILDA-TEST") == ["tool-call", "after-tool"], record("CHILDA-TEST")
        assert record("CHILDB-TEST") == ["tool-call", "resume-tool-call", "after-tool"], record("CHILDB-TEST")
        assert machine.succeed(f"cat {ws}/childa.count").split() == ["a"]
        assert machine.succeed(f"cat {ws}/childb.count").split() == ["b"]
        assert record("DELEGATION-RESULT") == ["result"], record("DELEGATION-RESULT")
        db = "sqlite3 -readonly 'file:${hermesHome}/state.db?mode=ro' "
        print(machine.succeed(db + "\"select delegation_id, state, delivery_state from async_delegations\""))
        ledger = machine.succeed(db + "\"select state from async_delegations\"").split()
        assert "unknown" not in ledger and "resumed" in ledger, ledger
        machine.wait_until_succeeds(
            db + f"\"select 1 from messages where session_id='{sid}' and content='GOT-RESULT'\" | grep -q 1",
            timeout=60)
        delivered = machine.succeed(
            db + f"\"select content from messages where session_id='{sid}' and content like '%ASYNC DELEGATION%'\"")
        print(delivered)
        assert delivered.count("[ASYNC DELEGATION BATCH COMPLETE") == 1, delivered
        assert "Resumed after a restart (attempt 1)" in delivered, delivered
        for part in ("TASK 1/2: CHILDA-TEST", "TASK 2/2: CHILDB-TEST", "DONE-CHILDA-TEST", "DONE-CHILDB-TEST"):
            assert part in delivered, part
        assert "outcome unknown" not in delivered, delivered
        machine.succeed("grep -q 'subagent re-dispatch: .* resumed as' ${hermesHome}/logs/agent.log")

    with subtest("per-task units (independent_completions, as on som): each one resumes, one result per task"):
        unit2 = "hermes-dashboard-${user2}.service"
        wait_dashboard(unit2, "${user2}", "${backend2}")
        print(machine.succeed("cat ${hermesHome2}/config.yaml"))
        ws = "${workspace2}"
        db2 = "sqlite3 -readonly 'file:${hermesHome2}/state.db?mode=ro' "
        # One task finishes before the restart; two hang until it kills them and finish when re-dispatched.
        hang = lambda name: (f"{name}-TEST test -e {ws}/{name}.mark || {{ touch {ws}/{name}.mark; sleep 300; }}; "
                             f"echo {name} >> {ws}/{name}.count")
        sid = client("start", "DELEGI-TEST",
                     f"CHILDC-TEST echo c >> {ws}/childc.count ||| {hang('CHILDD')} ||| {hang('CHILDE')}",
                     user="${user2}", backend="${backend2}")
        wait_step("CHILDC-TEST", "after-tool")
        wait_step("CHILDD-TEST", "tool-call")
        wait_step("CHILDE-TEST", "tool-call")
        machine.wait_until_succeeds(f"test -e {ws}/CHILDD.mark && test -e {ws}/CHILDE.mark")
        machine.wait_until_succeeds("pgrep -u ${user2} -x sleep")
        # The parent's turn has ended, and task 1's own unit has delivered its result to it (that turn is over too,
        # so the restart leaves no turn to continue).
        wait_step("DELEGI-TEST", "after-tool")
        machine.wait_until_succeeds(
            db2 + f"\"select count(*) from messages where session_id='{sid}' and content='GOT-RESULT'\" | grep -qx 1",
            timeout=120)
        machine.succeed(f"systemctl restart {unit2}")
        machine.fail("pgrep -u ${user2} -x sleep")
        wait_dashboard(unit2, "${user2}", "${backend2}")
        wait_step("CHILDD-TEST", "after-tool", timeout=240)
        wait_step("CHILDE-TEST", "after-tool", timeout=240)
        # The parent has all three results (one model turn each, or fewer when they arrive together).
        machine.wait_until_succeeds(
            db2 + f"\"select content from messages where session_id='{sid}'\" "
            "| grep -c 'ASYNC DELEGATION BATCH COMPLETE' | grep -qx 3", timeout=180)
        machine.wait_until_succeeds(
            db2 + f"\"select count(*) from messages where session_id='{sid}' and content='GOT-RESULT'\" | grep -qvx 1",
            timeout=60)
        assert record("CHILDC-TEST") == ["tool-call", "after-tool"], record("CHILDC-TEST")
        # "resume-tool-call": the re-dispatch note frames the old transcript tail as untrusted data (fake-llm.py).
        for name in ("CHILDD-TEST", "CHILDE-TEST"):
            assert record(name) == ["tool-call", "resume-tool-call", "after-tool"], (name, record(name))
        for name in ("childc", "CHILDD", "CHILDE"):
            assert len(machine.succeed(f"cat {ws}/{name}.count").split()) == 1, name
        print(machine.succeed(db2 + "\"select delegation_id, state, delivery_state from async_delegations\""))
        ledger = machine.succeed(db2 + "\"select state from async_delegations\"").split()
        assert "unknown" not in ledger and ledger.count("resumed") == 2, ledger
        delivered = machine.succeed(
            db2 + f"\"select content from messages where session_id='{sid}' and content like '%ASYNC DELEGATION%'\"")
        print(delivered)
        # One result per original task, under its original number; the two re-dispatched ones say so.
        assert delivered.count("[ASYNC DELEGATION BATCH COMPLETE") == 3, delivered
        assert delivered.count("Resumed after a restart (attempt 1)") == 2, delivered
        for part in ("TASK 1/3: CHILDC-TEST", "TASK 2/3: CHILDD-TEST", "TASK 3/3: CHILDE-TEST",
                     "DONE-CHILDC-TEST", "DONE-CHILDD-TEST", "DONE-CHILDE-TEST"):
            assert delivered.count(part) == 1, (part, delivered)
        assert "outcome unknown" not in delivered and "TASK FAILED" not in delivered, delivered
        machine.succeed("test $(grep -c 'subagent re-dispatch: .* resumed as' ${hermesHome2}/logs/agent.log) -eq 2")

    print(machine.succeed(
        "grep -i 'drain\\|startup resume\\|auto-continue\\|turn finished\\|Interrupt requested\\|re-dispatch\\|async delegation' ${hermesHome}/logs/agent.log || true"
    ))
  '';
}
