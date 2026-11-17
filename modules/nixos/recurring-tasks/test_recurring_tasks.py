"""Unit tests of ./recurring_tasks.py, run by ./default.nix at build time."""

import io
import json
import os
import stat
import tempfile
import urllib.parse
import unittest
from contextlib import redirect_stdout
from unittest import mock

import recurring_tasks as rt

NOW = 1_800_000_000.0


class Export(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def cfg(self, **kw):
        c = {
            "tasks": [
                {"name": "bump", "unit": "nixpkgs-bump.service", "machine": "infra-space",
                 "run_slo": 93600, "result_slo": 604800},
                {"name": "backup", "unit": "borgbackup-job-nas.service", "run_slo": 93600},
            ],
            "probe": os.path.join(self.d, "probe.json"),
            "out": os.path.join(self.d, "out.prom"),
            "hermes_homes": {},
        }
        c.update(kw)
        return c

    def fake_run(self, journal=None, show=None):
        def run(cmd, timeout=60):
            unit = next((a[5:] for a in cmd if a.startswith("UNIT=")), cmd[-1])
            if cmd[0] == "journalctl":
                ts = (journal or {}).get(unit)
                return json.dumps({"__REALTIME_TIMESTAMP": str(int(ts * 1e6))}) + "\n" if ts else ""
            return (show or {}).get(unit, "")
        return run

    def export(self, cfg, **kw):
        with mock.patch.object(rt, "run", self.fake_run(**kw)):
            rt.cmd_export(cfg, now=NOW)
        with open(cfg["out"]) as f:
            return f.read()

    def test_success_from_journal_and_show(self):
        show = {"borgbackup-job-nas.service":
                "ActiveState=inactive\nResult=success\nExecMainStatus=0\nExecMainExitTimestamp=@1799990000\n"}
        out = self.export(self.cfg(), journal={"nixpkgs-bump.service": NOW - 7200,
                                               "borgbackup-job-nas.service": 1799980000}, show=show)
        self.assertIn('recurring_task_last_success_seconds{task="bump"} 1799992800', out)
        # the newer of the two
        self.assertIn('recurring_task_last_success_seconds{task="backup"} 1799990000', out)
        self.assertIn('recurring_task_slo_seconds{task="bump",kind="result"} 604800', out)
        self.assertNotIn('task="backup",kind="result"', out)
        self.assertIn("recurring_tasks_exporter_last_run_seconds 1800000000", out)
        self.assertFalse(os.path.exists(self.cfg()["out"] + ".tmp"))
        self.assertEqual(stat.S_IMODE(os.stat(self.cfg()["out"]).st_mode), 0o644)

    def test_failed_or_running_is_no_success(self):
        for s in ("ActiveState=failed\nResult=exit-code\nExecMainStatus=1\nExecMainExitTimestamp=@1799990000\n",
                  "ActiveState=activating\nResult=success\nExecMainStatus=0\nExecMainExitTimestamp=@1799990000\n",
                  "ActiveState=inactive\nResult=success\nExecMainStatus=0\nExecMainExitTimestamp=\n",
                  "ActiveState=inactive\nResult=success\nExecMainStatus=0\nExecMainExitTimestamp=@0\n"):
            out = self.export(self.cfg(), show={"borgbackup-job-nas.service": s})
            self.assertNotIn("recurring_task_last_success_seconds{", out, s)

    def test_machine_flag(self):
        calls = []

        def run(cmd, timeout=60):
            calls.append(cmd)
            return ""
        with mock.patch.object(rt, "run", run):
            rt.cmd_export(self.cfg(), now=NOW)
        bump = [c for c in calls if "nixpkgs-bump.service" in " ".join(c)]
        self.assertTrue(bump and all(c[1:3] == ["-M", "infra-space"] for c in bump), bump)
        backup = [c for c in calls if "borgbackup-job-nas.service" in " ".join(c)]
        self.assertTrue(backup and all("-M" not in c for c in backup), backup)
        j = next(c for c in bump if c[0] == "journalctl")
        self.assertIn("_PID=1", j)
        self.assertIn(f"MESSAGE_ID={rt.MSG_UNIT_SUCCESS}", j)

    def test_result_age_from_probe(self):
        cfg = self.cfg()
        with open(cfg["probe"], "w") as f:
            json.dump({"at": NOW - 60, "results": {"bump": NOW - 10 * 86400, "backup": NOW}}, f)
        out = self.export(cfg)
        self.assertIn('recurring_task_result_age_seconds{task="bump"} 864000', out)
        # no result SLO: no age
        self.assertNotIn('recurring_task_result_age_seconds{task="backup"}', out)

    def test_stale_or_broken_probe_is_ignored(self):
        cfg = self.cfg()
        for content in (json.dumps({"at": NOW - 4 * 3600, "results": {"bump": NOW}}), "{broken",
                        json.dumps({"at": NOW, "results": ["x"]}), json.dumps([1])):
            with open(cfg["probe"], "w") as f:
                f.write(content)
            self.assertNotIn("recurring_task_result_age_seconds{", self.export(cfg), content)

    def test_label_escaping(self):
        cfg = self.cfg(tasks=[{"name": 'a"b\\c', "unit": "x.service", "run_slo": 1}])
        out = self.export(cfg)
        self.assertIn('recurring_task_slo_seconds{task="a\\"b\\\\c",kind="run"} 1', out)

    def test_cron_counts(self):
        a = os.path.join(self.d, "a")
        os.makedirs(os.path.join(a, "cron"))
        os.makedirs(os.path.join(a, "profiles", "p1", "cron"))
        with open(os.path.join(a, "cron", "jobs.json"), "w") as f:
            json.dump({"jobs": [{"enabled": True, "last_status": "ok"},
                                {"enabled": True, "last_status": "blocked_config"},
                                {"enabled": True, "last_status": None},
                                {"enabled": False, "last_status": "error"}, "junk"]}, f)
        with open(os.path.join(a, "profiles", "p1", "cron", "jobs.json"), "w") as f:
            json.dump([{"enabled": True, "last_status": "error"}], f)
        b = os.path.join(self.d, "b")
        os.makedirs(os.path.join(b, "cron"))
        with open(os.path.join(b, "cron", "jobs.json"), "w") as f:
            f.write("{broken")
        # a jobs.json symlinked out of the home is not followed
        c = os.path.join(self.d, "c")
        os.makedirs(os.path.join(c, "cron"))
        os.symlink(os.path.join(a, "cron", "jobs.json"), os.path.join(c, "cron", "jobs.json"))
        out = self.export(self.cfg(hermes_homes={"a": a, "b": b, "c": c, "missing": os.path.join(self.d, "m")}))
        self.assertIn('hermes_cron_jobs_enabled{agent="a"} 4', out)
        self.assertIn('hermes_cron_jobs_failing{agent="a"} 2', out)
        for agent in ("b", "c", "missing"):
            self.assertNotIn(f'agent="{agent}"', out)

    def test_nested_jobs_json_costs_only_that_agent(self):
        a = os.path.join(self.d, "a")
        os.makedirs(os.path.join(a, "cron"))
        with open(os.path.join(a, "cron", "jobs.json"), "w") as f:
            f.write("[" * 200_000)
        self.assertIsNone(rt.read_jobs(a, "cron/jobs.json"))
        b = os.path.join(self.d, "b")
        os.makedirs(os.path.join(b, "cron"))
        with open(os.path.join(b, "cron", "jobs.json"), "w") as f:
            json.dump([{"enabled": True, "last_status": "ok"}], f)
        out = self.export(self.cfg(hermes_homes={"a": a, "b": b}))
        self.assertIn("recurring_tasks_exporter_last_run_seconds ", out)
        self.assertIn('hermes_cron_jobs_enabled{agent="b"} 1', out)
        self.assertNotIn('agent="a"', out)

    def test_oversized_jobs_json_is_skipped(self):
        a = os.path.join(self.d, "a")
        os.makedirs(os.path.join(a, "cron"))
        with open(os.path.join(a, "cron", "jobs.json"), "w") as f:
            f.write("[" + " " * rt.JOBS_MAX_BYTES + "]")
        self.assertIsNone(rt.read_jobs(a, "cron/jobs.json"))

    def test_crashing_reader_costs_only_that_agent(self):
        b = os.path.join(self.d, "b")
        os.makedirs(os.path.join(b, "cron"))
        with open(os.path.join(b, "cron", "jobs.json"), "w") as f:
            json.dump([{"enabled": True}], f)
        real = rt.read_cron_as

        def flaky(user, home):
            if user == "a":
                raise RuntimeError("boom")
            return real(user, home)
        with mock.patch.object(rt, "read_cron_as", flaky):
            out = self.export(self.cfg(hermes_homes={"a": b, "b": b}))
        self.assertIn('hermes_cron_jobs_enabled{agent="b"} 1', out)
        self.assertNotIn('agent="a"', out)

    def test_bool_is_no_time(self):
        with open(os.path.join(self.d, "probe.json"), "w") as f:
            json.dump({"at": NOW, "results": {"bump": True}}, f)
        self.assertEqual(rt.read_probe(os.path.join(self.d, "probe.json"), NOW), {})


class Probe(unittest.TestCase):
    def test_probe(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "probe.json")
            cfg = {"out": out, "tasks": [
                {"name": "ok", "command": "echo 1792773339"},
                {"name": "float", "command": "echo 1792773339.5"},
                {"name": "fails", "command": "echo 1; false"},
                {"name": "garbage", "command": "echo null"},
                {"name": "pipefail", "command": "false | echo 5"},
            ]}
            rt.cmd_probe(cfg, now=NOW)
            with open(out) as f:
                data = json.load(f)
            self.assertEqual(data, {"at": NOW, "results": {"ok": 1792773339.0, "float": 1792773339.5}})


class Status(unittest.TestCase):
    REG = {
        "bump": {"host": "som", "run_slo": 100, "result_slo": 1000, "result_what": "main's nixpkgs", "repair": "nixpkgs-bump"},
        "brief": {"host": "som", "run_slo": 100},
        "pin": {"host": "som", "result_slo": 1000, "result_what": "pin"},
        "sync": {"host": "bam", "run_slo": 100},
    }

    def opener(self, series):
        def op(url, timeout=30):
            expr = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["query"][0]
            res = [{"metric": {"instance": i, **({"task": t} if t else {})}, "value": [NOW, str(v)]}
                   for (name, i, t), v in series.items() if name == expr]
            return io.BytesIO(json.dumps({"status": "success", "data": {"result": res}}).encode())
        return op

    def status(self, series):
        out = io.StringIO()
        with redirect_stdout(out):
            rt.cmd_status(self.REG, "http://m", now=NOW, opener=self.opener(series))
        return json.loads(out.getvalue())

    def test_judgement(self):
        beat = "recurring_tasks_exporter_last_run_seconds"
        last = "recurring_task_last_success_seconds"
        age = "recurring_task_result_age_seconds"
        r = self.status({
            (beat, "som", ""): NOW - 60,
            (beat, "bam", ""): NOW - 7200,
            (last, "som", "bump"): NOW - 50,
            (age, "som", "bump"): 2000,
            (last, "som", "brief"): NOW - 10,
            (last, "bam", "sync"): NOW,
        })
        by = {t["task"]: t for t in r["tasks"]}
        self.assertEqual((r["fresh"], r["total"]), (1, 4))
        self.assertTrue(by["brief"]["fresh"])
        self.assertEqual(by["bump"]["problems"], [{"kind": "result", "why": "old", "age": 2000, "slo": 1000}])
        self.assertEqual(by["bump"]["what"], "main's nixpkgs")
        self.assertEqual(by["pin"]["problems"][0]["why"], "not measured")
        # bam's exporter silent: its last success is not trusted
        self.assertEqual([p["kind"] for p in by["sync"]["problems"]], ["exporter"])

    def test_query_error(self):
        def op(url, timeout=30):
            return io.BytesIO(b'{"status": "error", "error": "bad"}')
        with self.assertRaises(ValueError):
            rt.cmd_status(self.REG, "http://m", now=NOW, opener=op)


if __name__ == "__main__":
    unittest.main()
