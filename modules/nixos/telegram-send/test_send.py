"""Unit tests of ./send.py against a stub Telegram, and of the ssh
dispatcher (./default.nix runs both at build)."""

import http.client
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import send  # noqa: E402


class StubResponse:
    def __init__(self, status, body=b"{}"):
        self.status = status
        self.body = body

    def read(self, n=-1):
        return self.body


class StubTelegram:
    """http.client.HTTPSConnection's surface as send.py uses it."""

    def __init__(self, status=200, fail_connect=False, fail_answer=False):
        self.status, self.fail_connect, self.fail_answer = status, fail_connect, fail_answer
        self.requests = []

    def __call__(self):
        return self

    def connect(self):
        if self.fail_connect:
            raise ConnectionRefusedError(111, "refused")

    def request(self, method, url, body=None, headers=None):
        self.requests.append((method, url, body))

    def getresponse(self):
        if self.fail_answer:
            raise TimeoutError("timed out")
        return StubResponse(self.status, b'{"ok": false, "description": "Bad Request"}')

    def close(self):
        pass


class Send(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.creds = os.path.join(self.tmp.name, "creds")
        self.state = os.path.join(self.tmp.name, "state")
        os.makedirs(self.creds)
        os.makedirs(self.state)
        for name, value in (("telegram-bot-token", "123:SECRET"), ("telegram-chat-id", "42")):
            with open(os.path.join(self.creds, name), "w") as f:
                f.write(value + "\n")
        env = {"CREDENTIALS_DIRECTORY": self.creds, "STATE_DIRECTORY": self.state}
        self.env = mock.patch.dict(os.environ, env)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def run_send(self, text, stub, *argv):
        out, err = io.StringIO(), io.StringIO()
        stdin = mock.Mock()
        stdin.buffer = io.BytesIO(text.encode())
        with mock.patch.object(send, "connect", stub), mock.patch("sys.stdin", stdin), \
                mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            try:
                rc = send.main(list(argv))
            except SystemExit as e:
                rc = e.code
        self.assertNotIn("SECRET", out.getvalue() + err.getvalue())
        return rc, err.getvalue()

    def stamp(self):
        try:
            with open(os.path.join(self.state, "brief-sent")) as f:
                return f.read().strip()
        except FileNotFoundError:
            return None

    def test_sent_and_stamped(self):
        stub = StubTelegram()
        rc, _ = self.run_send("hello\n", stub, "--mark-brief")
        self.assertEqual(rc, 0)
        method, url, body = stub.requests[0]
        self.assertEqual((method, url), ("POST", "/bot123:SECRET/sendMessage"))
        self.assertIn(b"chat_id=42", body)
        self.assertIn(b"text=hello", body)
        self.assertEqual(self.stamp(), send.today())

    def test_plain_send_does_not_stamp(self):
        self.assertEqual(self.run_send("x", StubTelegram())[0], 0)
        self.assertIsNone(self.stamp())

    def test_state_write_failure_after_200_is_maybe_sent(self):
        real = send.write_atomic

        def failing(path, data):
            if path.endswith("brief-sent"):
                raise PermissionError(13, "denied")
            return real(path, data)
        with mock.patch.object(send, "write_atomic", failing):
            rc, err = self.run_send("x", StubTelegram(), "--mark-brief")
        self.assertEqual(rc, send.EXIT_MAYBE_SENT)
        self.assertIn("not retrying", err)
        # the counter failing after the request is out: still no exit 1
        with mock.patch.object(send, "write_atomic", mock.Mock(side_effect=OSError(28, "full"))):
            self.assertEqual(self.run_send("x", StubTelegram())[0], 0)
            self.assertEqual(self.run_send("x", StubTelegram(fail_answer=True))[0], send.EXIT_MAYBE_SENT)

    def test_failures_exit_codes_no_stamp(self):
        rc, err = self.run_send("x", StubTelegram(fail_connect=True), "--mark-brief")
        self.assertEqual(rc, send.EXIT_NOT_SENT)
        self.assertIn("not sent", err)
        rc, _ = self.run_send("x", StubTelegram(status=400), "--mark-brief")
        self.assertEqual(rc, send.EXIT_NOT_SENT)
        rc, _ = self.run_send("x", StubTelegram(status=502), "--mark-brief")
        self.assertEqual(rc, send.EXIT_MAYBE_SENT)
        rc, _ = self.run_send("x", StubTelegram(fail_answer=True), "--mark-brief")
        self.assertEqual(rc, send.EXIT_MAYBE_SENT)
        self.assertIsNone(self.stamp())
        rc, _ = self.run_send("   \n", StubTelegram())
        self.assertEqual(rc, send.EXIT_NOT_SENT)

    def test_daily_cap(self):
        stub = StubTelegram()
        for _ in range(send.DAILY_MAX):
            self.assertEqual(self.run_send("x", stub)[0], 0)
        rc, err = self.run_send("x", stub)
        self.assertEqual(rc, send.EXIT_RATE_LIMITED)
        self.assertEqual(len(stub.requests), send.DAILY_MAX)
        # a refused-before-sending attempt does not count
        with open(os.path.join(self.state, "count.json"), "w") as f:
            json.dump({"date": send.today(), "n": send.DAILY_MAX - 1}, f)
        self.run_send("x", StubTelegram(fail_connect=True))
        self.assertEqual(self.run_send("x", stub)[0], 0)
        # yesterday's count is not today's
        with open(os.path.join(self.state, "count.json"), "w") as f:
            json.dump({"date": "2000-01-01", "n": 99}, f)
        self.assertEqual(self.run_send("x", stub)[0], 0)

    def test_utf16_cap(self):
        # 3000 emoji = 6000 UTF-16 units: over Telegram's 4096
        text = "\U0001F600" * 3000
        stub = StubTelegram()
        self.assertEqual(self.run_send(text, stub)[0], 0)
        import urllib.parse
        sent = urllib.parse.parse_qs(stub.requests[0][2].decode())["text"][0]
        self.assertLessEqual(send.utf16_units(sent), send.MAX_UNITS)
        self.assertTrue(sent.endswith("…"))
        self.assertEqual(send.cap("a" * 4096), "a" * 4096)
        self.assertEqual(send.utf16_units(send.cap("a" * 5000)), 4096)

    def test_connect_is_https_to_telegram(self):
        c = send.connect()
        self.assertIsInstance(c, http.client.HTTPSConnection)
        self.assertEqual(c.host, "api.telegram.org")


class Dispatch(unittest.TestCase):
    """./dispatch.sh with a stub root helper in place of sudo."""

    def run_dispatch(self, command, stdin=b""):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "log")
            stub = os.path.join(d, "sudo")
            with open(stub, "w") as f:
                f.write(f'#!/bin/sh\necho "$*" >> {log}\ncat >> {log}\n')
            os.chmod(stub, 0o755)
            env = {"PATH": os.environ.get("PATH", ""), "DISPATCH_SUDO": stub, "DISPATCH_ROOT": "ROOT"}
            if command is not None:
                env["SSH_ORIGINAL_COMMAND"] = command
            p = subprocess.run(["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "dispatch.sh")],
                               input=stdin, env=env, capture_output=True)
            calls = ""
            if os.path.exists(log):
                with open(log) as f:
                    calls = f.read()
        return p.returncode, calls, p.stderr.decode()

    def test_allowed(self):
        rc, calls, _ = self.run_dispatch("send", b"the brief")
        self.assertEqual(rc, 0)
        self.assertEqual(calls, "-n ROOT send\nthe brief")
        rc, calls, _ = self.run_dispatch("send-nostamp", b"no digest")
        self.assertEqual(rc, 0)
        self.assertEqual(calls, "-n ROOT send-nostamp\nno digest")
        rc, calls, _ = self.run_dispatch("digest-json")
        self.assertEqual((rc, calls), (0, "-n ROOT digest-json\n"))
        rc, calls, _ = self.run_dispatch("recurring-json")
        self.assertEqual((rc, calls), (0, "-n ROOT recurring-json\n"))

    def test_refused(self):
        for bad in (None, "", "bash", "send; id", "send x", " send", "send\n", "digest-json --dry-run",
                    "send-nostamp x", "send-nostamp --mark-brief", "recurring-json x", "recurring", "send nostamp", "send-",
                    "fleet-telegram-send", "scp -t /tmp", "internal-sftp", "$(id)"):
            rc, calls, err = self.run_dispatch(bad)
            self.assertEqual(rc, 2, bad)
            self.assertEqual(calls, "", bad)
            self.assertIn("refused", err)


if __name__ == "__main__":
    unittest.main()
