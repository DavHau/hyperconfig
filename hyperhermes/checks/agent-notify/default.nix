# Root's hermes-notify (modules/core/agent-notify.nix,
# patches/hermes-agent-notify.patch) on one host with one agent and a
# scripted model (./fake-llm.py), chat sessions started over the
# dashboard's socket as the desktop app does (./client.py):
#  - an idle session (the latest one by default): the message starts a
#    turn whose input is the framed message from another agent, never the
#    owner's steer marker, and the system prompt carries the note on such
#    messages;
#  - a running turn: the message becomes a steer into it, delivered after
#    the tool result, framed the same way and outside the owner's marker;
#  - --profile reaches a named profile's latest session, not the main one;
#  - a session no backend holds (after a dashboard restart) is reopened;
#  - the agent's own uid is refused, by the CLI and by the socket itself;
#  - the journal has one audit line per call, without the text.
{ pkgs, self }:
let
  hlib = self.lib;
  user = "alice";
  uid = 1001;
  llmPort = 9999;
  llmRecord = "/var/lib/fake-llm/record";
  secret = "/run/hh-secrets/openai";
  hermesHome = "${hlib.stateDir user}/.hermes";
  backend = "http://127.0.0.1:${toString (hlib.dashboardBackendBase + uid)}";
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-agent-notify";

  containers.machine = {
    imports = [
      self.nixosModules.core
      ../container-pam.nix
    ];

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
        settings.dashboard.shutdown_drain_seconds = 5;
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
    NOTICE = "[MESSAGE FROM ANOTHER AGENT"
    OWNER = "[OUT-OF-BAND USER MESSAGE"

    def client(text, profile=None):
        args = f"'{text}'" + (f" {profile}" if profile else "")
        return machine.succeed(
            f"runuser -u ${user} -- ${python}/bin/python3 ${./client.py} ${backend} {args}"
        ).strip().splitlines()[-1]

    def records(scenario=None):
        out = machine.succeed("cat ${llmRecord} 2>/dev/null || true")
        rows = [json.loads(line) for line in out.splitlines()]
        return [r for r in rows if scenario is None or r["scenario"] == scenario]

    def wait_step(scenario, step, timeout=120):
        machine.wait_until_succeeds(
            f"grep -q '\"scenario\": \"{scenario}\", \"step\": \"{step}\"' ${llmRecord}", timeout=timeout)

    def db(home="${hermesHome}"):
        return f"sqlite3 -readonly -separator '|' 'file:{home}/state.db?mode=ro' "

    def wait_row(sid, content, home="${hermesHome}"):
        machine.wait_until_succeeds(
            db(home) + f"\"select 1 from messages where session_id='{sid}' and content='{content}'\" | grep -q 1",
            timeout=120)

    def notify(*args, stdin=None):
        quoted = " ".join(f"'{a}'" for a in args)
        cmd = f"hermes-notify {quoted}" if stdin is None else f"printf %s '{stdin}' | hermes-notify {quoted}"
        out = machine.succeed(cmd).strip()
        print(out)
        return dict(kv.split("=", 1) for kv in out.split(" ") if "=" in kv)

    def check_framed(text, sender="infra"):
        assert f"{NOTICE} \u2014 from {sender} via hermes-notify, NOT from the user" in text, text
        assert OWNER not in text, text

    def wait_dashboard():
        machine.wait_for_unit(unit)
        machine.wait_until_succeeds("runuser -u ${user} -- curl -sf -o /dev/null ${backend}/", timeout=180)
        machine.wait_until_succeeds("test -S /run/hermes-notify/${user}/notify.sock", timeout=60)

    machine.wait_for_unit("fake-llm.service")
    wait_dashboard()

    with subtest("the socket is the agent's, in a directory only it (and root) can enter"):
        print(machine.succeed("ls -la /run/hermes-notify/${user}/"))
        assert machine.succeed("stat -c '%a %U' /run/hermes-notify/${user}").strip() == "700 ${user}"

    with subtest("an idle session: the message starts a turn framed as another agent's"):
        old = client("OLD-TEST true")
        wait_row(old, "DONE-OLD-TEST")
        sid = client("IDLE-TEST true")
        wait_row(sid, "DONE-IDLE-TEST")
        got = notify("${user}", "--from", "infra", "the remote leak is fixed, retry")
        assert got["session"] == sid and got["delivery"] == "started", got
        wait_step("IDLE-TEST", "notice")
        rec = records("IDLE-TEST")[-1]
        check_framed(rec["users"][-1])
        assert "| the remote leak is fixed, retry" in rec["users"][-1], rec
        assert rec["note"], "the system prompt lacks the note on messages from agents"
        wait_row(sid, "ACK-NOTICE")
        rows = machine.succeed(db() + f"\"select role, coalesce(display_kind, '''), content from messages where session_id='{sid}' and content like '%MESSAGE FROM ANOTHER AGENT%'\"")
        print(rows)
        assert rows.startswith("user|process_complete|"), rows
        assert OWNER not in rows
        # The older session got nothing.
        assert machine.succeed(db() + f"\"select count(*) from messages where session_id='{old}' and content like '%ANOTHER AGENT%'\"").strip() == "0"

    with subtest("a running turn: the message is steered into it, outside the owner's marker"):
        sid = client("RUN-TEST sleep 8")
        wait_step("RUN-TEST", "tool-call")
        got = notify("${user}", "--session", sid, "--from", "builder", "-", stdin="use the staging db now")
        assert got["delivery"] == "steered", got
        wait_step("RUN-TEST", "steered", timeout=60)
        rec = records("RUN-TEST")[-1]
        check_framed(rec["users"][-1], "builder")
        assert "| use the staging db now" in rec["users"][-1], rec
        wait_row(sid, "DONE-RUN-TEST")
        rows = machine.succeed(db() + f"\"select role, coalesce(display_kind, '''), content from messages where session_id='{sid}' and content like '%ANOTHER AGENT%'\"")
        print(rows)
        assert OWNER not in rows, rows

    with subtest("--profile targets that profile's latest session"):
        profile = "${hermesHome}/profiles/work"
        machine.succeed(f"runuser -u ${user} -- mkdir -p {profile}")
        machine.succeed(f"runuser -u ${user} -- cp ${hermesHome}/config.yaml ${hermesHome}/.env {profile}/")
        main_latest = client("MAIN-TEST true")
        wait_row(main_latest, "DONE-MAIN-TEST")
        psid = client("PROF-TEST true", "work")
        wait_row(psid, "DONE-PROF-TEST", home=profile)
        main_after = client("MAINLATER-TEST true")
        wait_row(main_after, "DONE-MAINLATER-TEST")
        got = notify("${user}", "--profile", "work", "--latest", "profile note")
        assert got["session"] == psid and got["profile"] == "work" and got["delivery"] == "started", got
        wait_step("PROF-TEST", "notice")
        wait_row(psid, "ACK-NOTICE", home=profile)
        assert machine.succeed(db() + f"\"select count(*) from messages where session_id='{main_after}' and content like '%ANOTHER AGENT%'\"").strip() == "0"

    with subtest("a session no backend holds is reopened and gets the turn"):
        sid = client("COLD-TEST true")
        wait_row(sid, "DONE-COLD-TEST")
        machine.succeed(f"systemctl restart {unit}")
        wait_dashboard()
        got = notify("${user}", "--session", sid, "after the restart")
        assert got["delivery"] == "started", got
        wait_step("COLD-TEST", "notice")

    with subtest("errors: an unknown agent, profile or session"):
        machine.fail("hermes-notify nobody hi")
        machine.fail("hermes-notify ${user} --profile nope hi")
        machine.fail("hermes-notify ${user} --session 20990101_000000_abcdef hi")
        machine.fail("hermes-notify ${user} --from 'evil]x' hi")
        machine.fail("hermes-notify ${user} --from Dave hi")

    with subtest("the agent's own uid is refused, by the CLI and by the socket"):
        machine.fail("runuser -u ${user} -- hermes-notify ${user} hi")
        before = len(records())
        out = machine.succeed(
            "runuser -u ${user} -- ${pkgs.python3}/bin/python3 -c \""
            "import socket,json; s=socket.socket(socket.AF_UNIX); s.connect('/run/hermes-notify/${user}/notify.sock'); "
            "s.sendall(json.dumps({'sender':'x','text':'hi'}).encode()+b'\\n'); print(s.recv(4096).decode())\"")
        print(out)
        assert "root only" in out, out
        machine.sleep(3)
        assert len(records()) == before

    with subtest("audit: one journal line per call, never the text"):
        audit = machine.succeed("journalctl -t hermes-notify --no-pager -o cat")
        print(audit)
        # 4 deliveries and 2 refused targets (an unknown agent or a bad name stops before)
        assert audit.count('agent="${user}"') == 6, audit
        assert 'sender="builder"' in audit and "chars=22" in audit and 'result="steered"' in audit, audit
        for words in ("remote leak", "staging db", "profile note", "after the restart"):
            assert words not in audit, words
  '';
}
