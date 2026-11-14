"""Unit tests for provision_token.py: Grafana's API is faked by `call`."""

import os
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import provision_token as pt  # noqa: E402


class FakeGrafana:
    def __init__(self, role="Viewer", disabled=False, token_ok=True):
        self.sa = {"id": 7, "name": pt.NAME, "role": role,
                   "isDisabled": disabled}
        self.token_ok = token_ok
        self.calls = []

    def __call__(self, method, path, auth, body=None, timeout=30):
        self.calls.append((method, path))
        if path == "/api/health":
            return {}
        if auth.startswith("Bearer "):
            if not self.token_ok:
                raise urllib.error.HTTPError(path, 403, "no", {}, None)
            return {}
        if path.startswith("/api/serviceaccounts/search"):
            return {"serviceAccounts": [self.sa]}
        if method == "PATCH":
            self.sa.update(body)
            return {}
        if method == "GET" and path.endswith("/tokens"):
            return [{"id": 1}]
        if method == "POST" and path.endswith("/tokens"):
            self.token_ok = True
            return {"key": "NEW-TOKEN"}
        return {}


class Provision(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        for n, v in (("grafana-admin-username", "admin"),
                     ("grafana-admin-password", "pw")):
            with open(os.path.join(self.d.name, n), "w") as f:
                f.write(v)
        self.path = os.path.join(self.d.name, "grafana-token")
        with open(self.path, "w") as f:
            f.write("OLD-TOKEN")
        self.env = mock.patch.dict(os.environ,
                                   {"CREDENTIALS_DIRECTORY": self.d.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.d.cleanup()

    def run_main(self, g):
        with mock.patch.object(pt, "call", g), \
                mock.patch.object(sys, "argv", ["x", self.path]), \
                mock.patch("sys.stdout"):
            pt.main()
        with open(self.path) as f:
            return f.read()

    def test_viewer_with_working_token_is_kept(self):
        g = FakeGrafana()
        self.assertEqual(self.run_main(g), "OLD-TOKEN")
        self.assertNotIn("PATCH", [m for m, _ in g.calls])
        # Both endpoints the digest reads are probed.
        probed = [p for m, p in g.calls if p in pt.PROBES]
        self.assertEqual(sorted(set(probed)), sorted(pt.PROBES))
        self.assertIn("/api/annotations?type=alert&limit=1", pt.PROBES)

    def test_role_checked_even_when_token_works(self):
        g = FakeGrafana(role="Admin", token_ok=True)
        self.assertEqual(self.run_main(g), "NEW-TOKEN")
        self.assertEqual(g.sa["role"], "Viewer")
        self.assertIn(("DELETE", "/api/serviceaccounts/7/tokens/1"), g.calls)

    def test_disabled_account_reenabled_and_rotated(self):
        g = FakeGrafana(disabled=True)
        self.assertEqual(self.run_main(g), "NEW-TOKEN")
        self.assertFalse(g.sa["isDisabled"])

    def test_broken_token_rotated(self):
        g = FakeGrafana(token_ok=False)
        self.assertEqual(self.run_main(g), "NEW-TOKEN")


class Wait(unittest.TestCase):
    def test_bounded_wait(self):
        clock = [0.0]
        timeouts = []

        def call(method, path, auth, body=None, timeout=30):
            timeouts.append(timeout)
            clock[0] += timeout  # every try hangs until its timeout
            raise OSError("timed out")

        def sleep(s):
            clock[0] += s

        with mock.patch.object(pt, "call", call), \
                mock.patch.object(pt.time, "monotonic", lambda: clock[0]), \
                mock.patch.object(pt.time, "sleep", sleep), \
                self.assertRaises(SystemExit):
            pt.wait_for_grafana()
        self.assertEqual(set(timeouts), {pt.WAIT_TRY_TIMEOUT})
        self.assertLessEqual(clock[0], pt.WAIT_TOTAL + pt.WAIT_TRY_TIMEOUT)

    def test_up_at_once(self):
        with mock.patch.object(pt, "call", lambda *a, **k: {}):
            pt.wait_for_grafana()


if __name__ == "__main__":
    unittest.main()
