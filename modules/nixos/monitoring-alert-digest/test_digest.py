"""Unit tests for digest.py: fixtures shaped like edi's live Grafana 13
answers (prometheus-style alerts API, /api/annotations?type=alert)."""

import json
import os
import sys
import tempfile
import unittest
import urllib.parse
from datetime import datetime, timezone
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import digest  # noqa: E402

NOW = datetime(2026, 11, 14, 2, 0, tzinfo=timezone.utc)  # 09:00 +07


def ms(s):
    return int(datetime.fromisoformat(s).timestamp() * 1000)


ALERTS = [
    # Firing warning (nas automount since 11-05).
    {"labels": {"alertname": "Systemd unit failed", "grafana_folder": "Fleet",
                "instance": "nas", "job": "integrations/unix",
                "name": "automount.service", "severity": "warning",
                "state": "failed", "type": "oneshot"},
     "annotations": {"summary": "automount.service on nas has failed"},
     "state": "Alerting", "activeAt": "2026-11-05T04:42:20Z", "value": "1e+00"},
    # Held by keepFiringFor: still counts as firing.
    {"labels": {"alertname": "Filesystem almost full", "instance": "som",
                "pool": "zroot", "severity": "warning"},
     "annotations": {"summary": "pool zroot on som is 84.10% full"},
     "state": "Recovering", "activeAt": "2026-11-13T20:00:00.123456789+00:00"},
    # Normal warning and a firing critical: both left out.
    {"labels": {"alertname": "Filesystem filling up", "instance": "som",
                "severity": "warning"}, "state": "Normal (NoData)",
     "activeAt": "2026-11-12T13:37:20Z"},
    {"labels": {"alertname": "Host stopped reporting", "instance": "bam",
                "severity": "critical"}, "state": "Alerting",
     "activeAt": "2026-11-14T01:00:00Z"},
]


def ann(t, prev, new, tags, name):
    return {"time": ms(t), "prevState": prev, "newState": new,
            "alertName": name, "tags": tags}


VIT_TAGS = ["alertname:Systemd unit failed", "grafana_folder:Fleet",
            "instance:vit", "job:integrations/unix",
            "name:run-p4049073-i16626757.service", "severity:warning",
            "state:failed", "type:simple"]
ANNOTATIONS = [
    # vit unit fired twice and resolved within the window.
    ann("2026-11-13T05:00:00+00:00", "Pending", "Alerting", VIT_TAGS,
        "Systemd unit failed"),
    ann("2026-11-13T05:30:00+00:00", "Alerting", "Normal", VIT_TAGS,
        "Systemd unit failed"),
    ann("2026-11-13T07:00:00+00:00", "Pending", "Alerting", VIT_TAGS,
        "Systemd unit failed"),
    ann("2026-11-13T07:20:00+00:00", "Alerting", "Normal (MissingSeries)",
        VIT_TAGS, "Systemd unit failed"),
    # Pending that never fired: not in the digest.
    ann("2026-11-13T09:00:00+00:00", "Normal", "Pending",
        ["alertname:Systemd unit failed", "instance:amy", "name:x.service",
         "severity:warning"], "Systemd unit failed"),
    # Alerting -> Recovering is not a new firing.
    ann("2026-11-13T21:00:00+00:00", "Alerting", "Recovering",
        ["alertname:Filesystem almost full", "instance:som", "pool:zroot",
         "severity:warning", "grafana_folder:Fleet"],
        "Filesystem almost full"),
    # Critical history: left out.
    ann("2026-11-13T10:00:00+00:00", "Pending", "Alerting",
        ["alertname:Host stopped reporting", "instance:bam",
         "severity:critical"], "Host stopped reporting"),
    # Before the window: left out.
    ann("2026-11-12T10:00:00+00:00", "Pending", "Alerting",
        ["alertname:Systemd unit failed", "instance:amy", "name:y.service",
         "severity:warning"], "Systemd unit failed"),
]


class Collect(unittest.TestCase):
    def test_entries(self):
        got = digest.collect(ALERTS, ANNOTATIONS, NOW)
        self.assertEqual([(e["host"], e["alert"], e["state"]) for e in got], [
            ("nas", "Systemd unit failed", "firing"),
            ("som", "Filesystem almost full", "firing"),
            ("vit", "Systemd unit failed", "resolved"),
        ])
        nas, som, vit = got
        self.assertEqual(nas["since"], "2026-11-05T04:42:20Z")
        self.assertEqual(nas["detail"], "name=automount.service")
        self.assertEqual(som["since"], "2026-11-13T20:00:00Z")
        self.assertEqual(som["fired"], 0)
        self.assertEqual(vit["since"], "2026-11-13T05:00:00Z")
        self.assertEqual(vit["fired"], 2)
        json.dumps(got)  # --json must serialise

    def test_empty(self):
        self.assertIsNone(digest.render(digest.collect([], [], NOW)))
        quiet = [a for a in ALERTS if a["labels"]["severity"] == "critical"]
        self.assertIsNone(digest.render(digest.collect(quiet, [], NOW)))

    def test_render(self):
        msg = digest.render(digest.collect(ALERTS, ANNOTATIONS, NOW))
        self.assertIn("2 firing, 1 resolved", msg)
        self.assertIn("• nas: Systemd unit failed (name=automount.service), "
                      "since 11-05 11:42", msg)
        self.assertIn("fired 2×", msg)
        self.assertLess(msg.index("Firing"), msg.index("Fired and resolved"))

    def test_escape_and_cap(self):
        many = [{"labels": {"alertname": "A<b>&", "instance": f"h{i}",
                            "severity": "warning"},
                 "annotations": {"summary": "x" * 200},
                 "state": "Alerting", "activeAt": "2026-11-13T00:00:00Z"}
                for i in range(100)]
        msg = digest.render(digest.collect(many, [], NOW))
        self.assertLessEqual(len(msg), 4096)
        self.assertIn("A&lt;b&gt;&amp;", msg)
        self.assertIn("more (Grafana", msg)


class ErrorStates(unittest.TestCase):
    """A warning rule whose query fails is in Error (Grafana sends it as
    DatasourceError with the rule's labels, muted with the warnings), so
    the digest is where it shows."""

    ERR = {"labels": {"alertname": "Filesystem filling up", "instance": "som",
                      "severity": "warning"},
           "annotations": {"summary": "pool  on som () is projected"},
           "state": "Error", "activeAt": "2026-11-14T00:00:00Z"}

    def test_error_now_is_firing(self):
        got = digest.collect([self.ERR], [], NOW)
        self.assertEqual([(e["alert"], e["state"]) for e in got],
                         [("Filesystem filling up", "firing")])
        self.assertIn("query failed", got[0]["summary"])
        for st in ("NoData", "Alerting (Error)"):
            a = dict(self.ERR, state=st)
            self.assertEqual(len(digest.collect([a], [], NOW)), 1, st)
        self.assertEqual(digest.collect(
            [dict(self.ERR, state="Normal (NoData)")], [], NOW), [])

    def test_error_in_history(self):
        tags = ["alertname:Filesystem filling up", "instance:som",
                "severity:warning"]
        got = digest.collect([], [
            ann("2026-11-13T10:00:00+00:00", "Normal", "Error", tags,
                "Filesystem filling up"),
            ann("2026-11-13T10:30:00+00:00", "Error", "Normal", tags,
                "Filesystem filling up")], NOW)
        self.assertEqual([(e["alert"], e["state"], e["fired"]) for e in got],
                         [("Filesystem filling up", "resolved", 1)])


class Cut(unittest.TestCase):
    def test_no_empty_header_after_cut(self):
        # Sweep the line length so that, for some of them, the firing
        # lines fill the message right up to the cut and the next lines
        # would be the blank + "Fired and resolved" header.
        tags = ["alertname:B", "instance:zz", "severity:warning"]
        hist = [ann("2026-11-13T10:00:00+00:00", "Pending", "Alerting",
                    tags[:1] + [f"instance:zz{i}"] + tags[2:], "B")
                for i in range(30)]
        cuts = 0
        for width in range(100, 300):
            firing = [{"labels": {"alertname": "A", "instance": f"h{i:02}",
                                  "severity": "warning"},
                       "annotations": {"summary": "x" * width},
                       "state": "Alerting",
                       "activeAt": "2026-11-13T00:00:00Z"}
                      for i in range(20)]
            msg = digest.render(digest.collect(firing, hist, NOW))
            lines = msg.split("\n")
            self.assertLessEqual(len(msg), 4096)
            if "more (Grafana" in lines[-1]:
                cuts += 1
                self.assertFalse(lines[-2].startswith("<b>"), width)
                self.assertNotEqual(lines[-2], "", width)
        self.assertGreater(cuts, 0)


class Send(unittest.TestCase):
    """No double send: once the POST is out, never fail (systemd would
    retry and send it again)."""

    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        for n, v in (("telegram-bot-token", "SECRET-TOKEN"),
                     ("telegram-chat-id", "42")):
            with open(os.path.join(self.d.name, n), "w") as f:
                f.write(v)
        self.env = mock.patch.dict(os.environ,
                                   {"CREDENTIALS_DIRECTORY": self.d.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.d.cleanup()

    def conn(self, connect=None, request=None, response=None):
        c = mock.MagicMock()
        if connect:
            c.connect.side_effect = connect
        if request:
            c.request.side_effect = request
        if isinstance(response, BaseException):
            c.getresponse.side_effect = response
        elif response is not None:
            c.getresponse.return_value = response
        return mock.patch.object(digest.http.client, "HTTPSConnection",
                                 return_value=c), c

    def resp(self, status, body=b'{"ok":true}'):
        r = mock.MagicMock()
        r.status = status
        r.read.return_value = body
        return r

    def test_ok(self):
        p, c = self.conn(response=self.resp(200))
        with p:
            self.assertTrue(digest.send("hi"))
        self.assertEqual(c.request.call_count, 1)

    def test_timeout_after_request_exits_maybe_sent(self):
        p, c = self.conn(response=TimeoutError("timed out"))
        with p, mock.patch("sys.stderr") as err, \
                self.assertRaises(SystemExit) as cm:
            digest.send("hi")
        self.assertEqual(cm.exception.code, digest.EXIT_MAYBE_SENT)
        self.assertEqual(c.request.call_count, 1)
        logged = "".join(x.args[0] for x in err.write.call_args_list)
        self.assertIn("not retrying", logged)
        self.assertNotIn("SECRET-TOKEN", logged)

    def test_5xx_after_request_exits_maybe_sent(self):
        p, _ = self.conn(response=self.resp(502, b"bad gateway"))
        with p, mock.patch("sys.stderr"), self.assertRaises(SystemExit) as cm:
            digest.send("hi")
        self.assertEqual(cm.exception.code, digest.EXIT_MAYBE_SENT)

    def test_main_exits_maybe_sent_after_lost_answer(self):
        p, _ = self.conn(response=ConnectionResetError(104, "reset"))
        with p, mock.patch("sys.stderr"), mock.patch("sys.stdout"), \
                mock.patch.object(digest, "grafana_get", lambda path, params=None:
                                  {"data": {"alerts": ALERTS}}
                                  if path.startswith("/api/prometheus") else []), \
                self.assertRaises(SystemExit) as cm:
            digest.main([])
        self.assertEqual(cm.exception.code, digest.EXIT_MAYBE_SENT)

    def test_maybe_sent_code_is_restart_prevented(self):
        # The unit must list the code, or systemd retries and sends twice.
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "default.nix")) as f:
            nix = f.read()
        self.assertIn(f"RestartPreventExitStatus = [ {digest.EXIT_MAYBE_SENT} ]",
                      nix)

    def test_errors_before_send_are_not_maybe_sent(self):
        # 1 (retry) and EXIT_MAYBE_SENT (no retry) must differ.
        p, _ = self.conn(connect=OSError(101, "Network is unreachable"))
        with p, self.assertRaises(SystemExit) as cm:
            digest.send("hi")
        self.assertNotEqual(cm.exception.code, digest.EXIT_MAYBE_SENT)

    def test_connect_error_fails_without_token(self):
        p, c = self.conn(connect=OSError(101, "Network is unreachable"))
        with p, self.assertRaises(SystemExit) as cm:
            digest.send("hi")
        self.assertIn("not sent", str(cm.exception))
        self.assertNotIn("SECRET-TOKEN", str(cm.exception))
        c.request.assert_not_called()

    def test_refused_fails_without_token(self):
        p, _ = self.conn(response=self.resp(
            400, b'{"ok":false,"description":"chat not found"}'))
        with p, self.assertRaises(SystemExit) as cm:
            digest.send("hi")
        self.assertIn("chat not found", str(cm.exception))
        self.assertNotIn("SECRET-TOKEN", str(cm.exception))

    def test_notify_failure(self):
        p, c = self.conn(response=self.resp(200))
        with p, mock.patch("sys.stdout"), \
                mock.patch.object(digest, "grafana_get",
                                  side_effect=AssertionError("no Grafana")):
            digest.main(["--notify-failure"])
        body = c.request.call_args.kwargs["body"].decode()
        self.assertIn("digest+failed", body)

    def test_notify_failure_names_unit(self):
        p, c = self.conn(response=self.resp(200))
        with p, mock.patch("sys.stdout"), mock.patch.dict(os.environ, {
                "MONITOR_UNIT": "fleet-alert-digest-token.service",
                "MONITOR_EXIT_CODE": "exited", "MONITOR_EXIT_STATUS": "1"}):
            digest.main(["--notify-failure"])
        body = urllib.parse.parse_qs(c.request.call_args.kwargs["body"].decode())
        text = body["text"][0]
        self.assertIn("fleet-alert-digest-token.service failed", text)
        self.assertIn("journalctl -u fleet-alert-digest-token.service", text)

    def test_failure_message(self):
        unit = "fleet-alert-digest.service"
        maybe = digest.failure_message({
            "MONITOR_UNIT": unit, "MONITOR_EXIT_CODE": "exited",
            "MONITOR_EXIT_STATUS": str(digest.EXIT_MAYBE_SENT)})
        self.assertIn("may not have arrived", maybe)
        self.assertIn("(Telegram error after sending)", maybe)
        self.assertIn(f"journalctl -u {unit}", maybe)
        failed = digest.failure_message({
            "MONITOR_UNIT": unit, "MONITOR_EXIT_CODE": "exited",
            "MONITOR_EXIT_STATUS": "1"})
        self.assertIn(f"{unit} failed", failed)
        self.assertNotIn("may not have arrived", failed)
        # Started by hand, no $MONITOR_UNIT: the digest's unit.
        self.assertIn(f"journalctl -u {unit}", digest.failure_message({}))


class Main(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        for n, v in (("grafana-token", "SECRET-GRAFANA"),
                     ("telegram-bot-token", "SECRET-TOKEN"),
                     ("telegram-chat-id", "42")):
            with open(os.path.join(self.d.name, n), "w") as f:
                f.write(v + "\n")
        self.env = mock.patch.dict(os.environ,
                                   {"CREDENTIALS_DIRECTORY": self.d.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.d.cleanup()

    def fake_get(self, alerts, annotations):
        def get(path, params=None):
            if path.startswith("/api/prometheus"):
                return {"data": {"alerts": alerts}}
            return annotations
        return get

    def run_main(self, argv, alerts, annotations):
        sent = []
        with mock.patch.object(digest, "grafana_get",
                               self.fake_get(alerts, annotations)), \
             mock.patch.object(digest, "send", sent.append), \
             mock.patch("sys.stdout") as out:
            digest.main(argv)
        printed = "".join(c.args[0] for c in out.write.call_args_list)
        return sent, printed

    def test_dry_run_sends_nothing(self):
        sent, printed = self.run_main(["--dry-run"], ALERTS, [])
        self.assertEqual(sent, [])
        self.assertIn("Fleet warnings", printed)
        self.assertNotIn("SECRET-TOKEN", printed)

    def test_json_sends_nothing(self):
        sent, printed = self.run_main(["--json"], ALERTS, ANNOTATIONS)
        self.assertEqual(sent, [])
        data = json.loads(printed)
        self.assertEqual({tuple(sorted(e)) for e in data}, {(
            "alert", "detail", "fired", "host", "since", "state", "summary")})

    def test_no_warnings_no_message(self):
        sent, printed = self.run_main([], [], [])
        self.assertEqual(sent, [])
        self.assertIn("nothing to send", printed)

    def test_send(self):
        sent, _ = self.run_main([], ALERTS, [])
        self.assertEqual(len(sent), 1)


if __name__ == "__main__":
    unittest.main()
