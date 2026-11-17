# ./default.nix on one machine with an nspawn guest: a fake task on the
# host and one in the guest succeed, show as fresh, then go stale and the
# alert rule's own PromQL (./promql.nix) reports the breach, evaluated by
# a local Prometheus scraping the exporter's textfile (node exporter
# standing in for Alloy -> Mimir). Also: a failed run is no success, the
# result probe (unprivileged) and its staleness, hermes cron counts (read
# as the agent, a hostile jobs.json costs only its own counts), the dead
# man's switch's expression, the Alloy file's syntax.
{ pkgs }:
let
  inherit (pkgs) lib;
  promql = import ./promql.nix { inherit lib; };
  # runSlo short enough to go stale within the test
  slo = 40;
in
pkgs.testers.runNixOSTest {
  name = "recurring-tasks";

  nodes.machine =
    { config, ... }:
    {
      imports = [ ./default.nix ];
      networking.hostName = "machine";
      virtualisation.memorySize = 1536;

      hyper.recurringTasks = {
        tasks = {
          fake = {
            host = "machine";
            unit = "fake-task.service";
            runSlo = slo;
            result = {
              command = "cat /etc/fake-result-time";
              slo = 7 * 86400;
              what = "the fake result";
            };
          };
          guest-fake = {
            host = "machine";
            container = "guest";
            unit = "guest-task.service";
            runSlo = slo;
          };
          elsewhere = {
            host = "other";
            unit = "x.service";
            runSlo = 1;
          };
        };
        hermesHomes.alice = "/var/lib/hermes/alice/state/.hermes";
      };

      systemd.services.fake-task = {
        serviceConfig.Type = "oneshot";
        script = "test ! -e /etc/fake-task-fail";
      };

      containers.guest = {
        autoStart = true;
        config = {
          system.stateVersion = "25.11";
          systemd.services.guest-task = {
            serviceConfig.Type = "oneshot";
            script = "true";
          };
        };
      };

      services.prometheus = {
        enable = true;
        globalConfig.scrape_interval = "2s";
        scrapeConfigs = [
          # a host whose exporter stopped two hours ago: Alloy keeps
          # sending its last file (written by the test script)
          {
            job_name = "silent";
            fallback_scrape_protocol = "PrometheusText0.0.4";
            static_configs = [
              {
                targets = [ "127.0.0.1:9101" ];
                labels.instance = "silent-host";
              }
            ];
          }
          {
            job_name = "textfile";
            static_configs = [
              {
                targets = [ "127.0.0.1:9100" ];
                labels.instance = "machine";
              }
            ];
          }
        ];
        exporters.node = {
          enable = true;
          enabledCollectors = [ "textfile" ];
          extraFlags = [ "--collector.textfile.directory=/run/recurring-tasks" ];
        };
      };
      users.users.alice.isNormalUser = true;

      systemd.services.silent-host = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "''${pkgs.python3}/bin/python3 -m http.server 9101 --bind 127.0.0.1 --directory /run/silent-host";
        serviceConfig.RuntimeDirectory = "silent-host";
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.grafana-alloy
      ];
    };

  testScript = ''
    import json, time, urllib.parse

    def q(expr):
        out = machine.succeed("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=" + urllib.parse.quote(expr) + "'")
        return json.loads(out)["data"]["result"]

    def stale():
        return {(r["metric"]["task"], r["metric"]["why"]) for r in q(${builtins.toJSON promql.stale})}

    def export():
        # many starts in a row: clear the start rate limit
        machine.succeed("systemctl reset-failed recurring-tasks-metrics.service")
        machine.succeed("systemctl start recurring-tasks-metrics.service")
        return machine.succeed("cat /run/recurring-tasks/tasks.prom")

    def scraped(expr):
        # the next scrape of the new file
        machine.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=" + urllib.parse.quote(expr) + "' | jq -e '.data.result | length > 0'", timeout=60)

    machine.wait_for_unit("prometheus.service")
    machine.wait_for_unit("prometheus-node-exporter.service")
    machine.wait_for_unit("container@guest.service")
    machine.wait_until_succeeds("systemctl -M guest is-system-running --wait | grep -E 'running|degraded'", timeout=120)

    with subtest("the Alloy file parses"):
        machine.succeed("alloy fmt /etc/alloy/recurring-tasks.alloy")

    with subtest("nothing on record: both run SLOs breached, the other host's task not exported"):
        out = export()
        assert 'recurring_task_slo_seconds{task="fake",kind="run"} ${toString slo}' in out, out
        assert "elsewhere" not in out, out
        assert "recurring_task_last_success_seconds{" not in out, out
        scraped("recurring_tasks_exporter_last_run_seconds")
        s = stale()
        assert ("fake", "no successful run on record") in s, s
        assert ("guest-fake", "no successful run on record") in s, s
        assert ("fake", "result not measured (probe failing)") in s, s

    with subtest("a failed run is no success"):
        machine.succeed("touch /etc/fake-task-fail")
        machine.fail("systemctl start fake-task.service")
        assert 'task="fake"' not in export().split("recurring_task_last_success_seconds")[-1].split("# HELP")[0]
        machine.succeed("rm /etc/fake-task-fail")

    with subtest("host and guest tasks succeed: fresh"):
        machine.succeed("systemctl start fake-task.service")
        machine.succeed("systemctl -M guest start guest-task.service")
        now = int(time.time())
        # the probe: a result made an hour ago
        machine.succeed(f"echo {now - 3600} > /etc/fake-result-time")
        machine.succeed("systemctl start recurring-tasks-probe.service")
        probe = json.loads(machine.succeed("cat /run/recurring-tasks-probe/results.json"))
        assert set(probe["results"]) == {"fake"}, probe
        out = export()
        for task in ("fake", "guest-fake"):
            assert f'recurring_task_last_success_seconds{{task="{task}"}}' in out, out
        # an hour, give or take the driver's and the VM's clocks
        age = float(out.split('recurring_task_result_age_seconds{task="fake"} ')[1].split()[0])
        assert 3540 < age < 3700, out
        machine.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=count(recurring_task_last_success_seconds)' | jq -e '.data.result[0].value[1] == \"2\"'", timeout=60)
        s = stale()
        assert s == set(), s

    with subtest("the probe ran without privileges"):
        machine.succeed("journalctl -u recurring-tasks-probe.service | grep -q 'Deactivated successfully'")
        assert machine.succeed("stat -c %U /run/recurring-tasks-probe/results.json").strip() != "root"

    with subtest("both go stale, the result gets old: the rule's PromQL reports the breach"):
        machine.succeed(f"echo {now - 8 * 86400} > /etc/fake-result-time")
        machine.succeed("systemctl start recurring-tasks-probe.service")
        time.sleep(${toString slo} + 5)
        export()
        machine.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=max(recurring_task_result_age_seconds)' | jq -e '.data.result[0].value[1] | tonumber > 600000'", timeout=60)
        s = stale()
        assert s == {("fake", "late: no successful run within its SLO"),
                     ("guest-fake", "late: no successful run within its SLO"),
                     ("fake", "result older than its SLO")}, s

    with subtest("a probe that stops working: result not measured"):
        machine.succeed("rm /etc/fake-result-time")
        machine.succeed("systemctl start recurring-tasks-probe.service")
        out = export()
        assert "recurring_task_result_age_seconds{" not in out, out
        machine.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=recurring_task_result_age_seconds' | jq -e '.data.result | length == 0'", timeout=60)
        assert ("fake", "result not measured (probe failing)") in stale()

    with subtest("hermes cron counts"):
        machine.succeed("mkdir -p /var/lib/hermes/alice/state/.hermes/cron")
        machine.succeed("""echo '{"jobs": [{"enabled": true, "last_status": "ok"}, {"enabled": true, "last_status": "error"}]}' > /var/lib/hermes/alice/state/.hermes/cron/jobs.json""")
        out = export()
        assert 'hermes_cron_jobs_enabled{agent="alice"} 2' in out, out
        assert 'hermes_cron_jobs_failing{agent="alice"} 1' in out, out

    with subtest("hermes cron: read as the agent, a hostile file costs only that agent's counts"):
        # a file alice cannot read is not counted (root would read it)
        machine.succeed("mkdir -p /var/lib/hermes/alice/state/.hermes/profiles/p/cron")
        machine.succeed("""echo '[{"enabled": true, "last_status": "error"}]' > /var/lib/hermes/alice/state/.hermes/profiles/p/cron/jobs.json""")
        machine.succeed("chmod 600 /var/lib/hermes/alice/state/.hermes/profiles/p/cron/jobs.json")
        out = export()
        assert 'hermes_cron_jobs_enabled{agent="alice"} 2' in out, out
        machine.succeed("chown -R alice /var/lib/hermes/alice")
        assert 'hermes_cron_jobs_enabled{agent="alice"} 3' in export()
        # deeply nested JSON: alice's counts go, the file is still written
        machine.succeed("${pkgs.python3}/bin/python3 -c 'print(\"[\" * 200000)' > /var/lib/hermes/alice/state/.hermes/cron/jobs.json")
        before = machine.succeed("stat -c %Y /run/recurring-tasks/tasks.prom")
        time.sleep(1.1)
        out = export()
        assert machine.succeed("stat -c %Y /run/recurring-tasks/tasks.prom") != before
        assert "recurring_tasks_exporter_last_run_seconds " in out, out
        assert 'hermes_cron_jobs_enabled{agent="alice"} 1' in out, out

    with subtest("dead man's switch: a reporting host and one never deployed are quiet, a silent one fires"):
        machine.succeed(f"echo 'recurring_tasks_exporter_last_run_seconds {int(time.time()) - 7200}' > /run/silent-host/metrics")
        scraped('recurring_tasks_exporter_last_run_seconds{instance="silent-host"}')
        assert q(${builtins.toJSON (promql.exporterSilent [ "machine" ])}) == []
        assert q(${builtins.toJSON (promql.exporterSilent [ "never-deployed" ])}) == []
        r = q(${builtins.toJSON (promql.exporterSilent [ "machine" "silent-host" "never-deployed" ])})
        assert [x["metric"].get("instance") for x in r] == ["silent-host"], r
  '';
}
