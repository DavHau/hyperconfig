# Context compaction writes a real summary for every agent, in its home and
# in a profile created later with `hermes profile create`
# (modules/core/options.nix, compactionModel). One host, the core module,
# a fake model (./fake-llm.py) serving both an Anthropic Messages endpoint
# behind a gateway path (like TeamClaude: not api.anthropic.com) and an
# OpenAI-compatible one, and real compactions (./compact.py) run with each
# agent's own environment:
#  - alice holds an Anthropic credential (ANTHROPIC_TOKEN +
#    ANTHROPIC_BASE_URL, as the teamclaude module sets them), her main model
#    Claude Sonnet: her effective config routes compaction to anthropic /
#    claude-opus-5-5, the summary comes from Opus through the gateway, with
#    her credential; the same in a profile created after the start;
#  - with Opus failing (429 rate limit, 529 overloaded, 401), her summary
#    still comes from her session's main model through the gateway (hermes'
#    main-model fallback; for 529 and 401 only with
#    modules/core/patches/hermes-aux-anthropic-env-gateway.patch);
#  - bob has no Anthropic credential (main model on a custom endpoint): no
#    anthropic route in his config (nor in a new profile's), and the summary
#    comes from his own main model;
#  - without the route (hermes' own `auto`), alice's gateway setup gets a
#    summary from her main model (the same patch; before it, the bug: "no
#    auxiliary LLM provider configured").
{ pkgs, self }:
let
  hlib = self.lib;
  llmPort = 9999;
  llmRecord = "/var/lib/fake-llm/record";
  failModels = "/var/lib/fake-llm/fail";
  gateway = "http://127.0.0.1:${toString llmPort}/gateway";
  openaiBase = "http://127.0.0.1:${toString llmPort}/v1";
  tokenFile = "/run/hh-secrets/alice-anthropic";
  openaiFile = "/run/hh-secrets/openai";
  homeOf = user: "${hlib.stateDir user}/.hermes";
  # The control's config: alice's main model and nothing else.
  bareConfig = pkgs.writeText "bare-config.yaml" (
    builtins.toJSON {
      model = {
        provider = "anthropic";
        default = "claude-sonnet-5-5";
      };
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-compaction";

  # A container test (systemd-nspawn, no VM).
  containers.machine =
    { config, ... }:
    {
      imports = [
        self.nixosModules.core
        ../container-pam.nix
      ];

      services.hyperhermes = {
        pythonPackages = _: [ ];
        agents.alice = {
          uid = 1001;
          initialModel = {
            provider = "anthropic";
            default = "claude-sonnet-5-5";
          };
          environment.ANTHROPIC_BASE_URL = gateway;
          secretEnv.ANTHROPIC_TOKEN = tokenFile;
        };
        agents.bob = {
          uid = 1002;
          initialModel = {
            provider = "custom";
            base_url = openaiBase;
            default = "fake-model";
          };
          secretEnv.OPENAI_API_KEY = openaiFile;
        };
      };

      systemd.tmpfiles.rules = [
        "d /run/hh-secrets 0700 root root - -"
        "f ${tokenFile} 0400 root root - fake-alice-token"
        "f ${openaiFile} 0400 root root - fake-openai"
      ];

      systemd.services.fake-llm = {
        wantedBy = [ "multi-user.target" ];
        environment.FAKE_FAIL_MODELS_FILE = failModels;
        serviceConfig = {
          StateDirectory = "fake-llm";
          ExecStart = "${pkgs.python3}/bin/python3 ${./fake-llm.py} ${toString llmPort} ${llmRecord}";
        };
      };

      # compact <user> <HERMES_HOME> <main provider> <main model>: one
      # compaction as that agent, with its unit's HERMES_MANAGED_DIR
      # (NO_MANAGED=1: an empty one, hermes' own defaults).
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "compact" ''
          user=$1 home=$2; shift 2
          managed=$(systemctl show -p Environment "hermes-agent-$user.service" \
            | sed 's/^Environment=//' | tr ' ' '\n' | sed -n 's/^HERMES_MANAGED_DIR=//p')
          cd /
          [ -z "''${NO_MANAGED:-}" ] || managed=/nonexistent
          exec runuser -u "$user" -- env HOME=/home/$user HERMES_HOME="$home" \
            HERMES_MANAGED_DIR="$managed" \
            ${config.services.hyperhermes.package.hermesVenv}/bin/python3 ${./compact.py} "$@"
        '')
      ];
    };

  testScript = ''
    import json

    def compact(user, home, provider, model):
        out = machine.succeed(f"compact {user} {home} {provider} {model} 2>&1")
        print(out)
        return json.loads(out.strip().splitlines()[-1])

    def records():
        out = machine.succeed("cat ${llmRecord} 2>/dev/null || true")
        return [json.loads(line) for line in out.splitlines()]

    def summary_calls(since):
        return [r for r in records()[since:] if r["prompt"].startswith("You are a summarization agent")]

    homes = {"alice": "${homeOf "alice"}", "bob": "${homeOf "bob"}"}

    def profile(user, name):
        # As the person does, through the agent's `hermes` shim.
        machine.succeed(f"cd / && runuser -u {user} -- hermes profile create {name} --no-alias")
        home = f"{homes[user]}/profiles/{name}"
        machine.wait_until_succeeds(f"test -f {home}/config.yaml")
        return home

    machine.wait_for_unit("fake-llm.service")
    machine.wait_for_open_port(${toString llmPort})
    for user in ("alice", "bob"):
        machine.wait_for_unit(f"hermes-agent-{user}.service")

    with subtest("alice (Anthropic credential): Opus 5.5 writes the summary, with her credential"):
        n = len(records())
        r = compact("alice", "${homeOf "alice"}", "anthropic", "claude-sonnet-5-5")
        assert r["route"] == {"provider": "anthropic", "model": "claude-opus-5-5"}, r
        assert r["llm_summary"] and r["error"] is None and r["after"] < r["before"], r
        calls = summary_calls(n)
        assert [c["model"] for c in calls] == ["claude-opus-5-5"], calls
        assert all(c["path"] == "/gateway/v1/messages" and c["auth"] for c in calls), calls

    with subtest("a profile alice creates later gets the same route and summary"):
        home = profile("alice", "work")
        # The profile's .env gets the credential blocks from the path unit.
        machine.wait_until_succeeds(f"grep -q '^ANTHROPIC_TOKEN=' {home}/.env", timeout=30)
        n = len(records())
        r = compact("alice", home, "anthropic", "claude-sonnet-5-5")
        assert r["route"] == {"provider": "anthropic", "model": "claude-opus-5-5"}, r
        assert r["llm_summary"] and r["error"] is None, r
        assert [c["model"] for c in summary_calls(n)] == ["claude-opus-5-5"], records()[n:]

    # 401 last: it may mark alice's credential exhausted in her pool.
    for status in (429, 529, 401):
        with subtest(f"Opus fails with {status}: the summary comes from the session's main model"):
            machine.succeed(f"echo 'claude-opus-5-5 {status}' > ${failModels}")
            n = len(records())
            r = compact("alice", "${homeOf "alice"}", "anthropic", "claude-sonnet-5-5")
            machine.succeed("rm ${failModels}")
            assert r["llm_summary"] and r["error"] is None, r
            calls = summary_calls(n)
            assert calls[0]["model"] == "claude-opus-5-5" and calls[-1]["model"] == "claude-sonnet-5-5", calls
            assert all(c["path"] == "/gateway/v1/messages" for c in calls), calls

    with subtest("bob (no Anthropic credential): no anthropic route, his own main model summarizes"):
        for home in ("${homeOf "bob"}", profile("bob", "side")):
            n = len(records())
            r = compact("bob", home, "custom", "fake-model")
            assert r["route"]["provider"] in (None, "auto"), r
            assert r["llm_summary"] and r["error"] is None, r
            calls = summary_calls(n)
            assert [(c["path"], c["model"]) for c in calls] == [("/v1/chat/completions", "fake-model")], calls

    with subtest("without the route, hermes' auto route reaches the gateway with the main model"):
        # Before patches/hermes-aux-anthropic-env-gateway.patch this was the
        # bug: "no auxiliary LLM provider configured", no summary.
        machine.succeed("install -d -o alice -m 700 /tmp/bare-home")
        machine.succeed("install -o alice -m 600 ${homeOf "alice"}/.env /tmp/bare-home/.env")
        machine.succeed("install -o alice -m 600 ${bareConfig} /tmp/bare-home/config.yaml")
        n = len(records())
        out = machine.succeed("NO_MANAGED=1 compact alice /tmp/bare-home anthropic claude-sonnet-5-5 2>&1")
        print(out)
        r = json.loads(out.strip().splitlines()[-1])
        assert r["route"]["provider"] in (None, "auto"), r
        assert r["llm_summary"] and r["error"] is None, r
        calls = summary_calls(n)
        assert [(c["path"], c["model"]) for c in calls] == [("/gateway/v1/messages", "claude-sonnet-5-5")], calls
  '';
}
