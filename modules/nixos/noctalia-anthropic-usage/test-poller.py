#!/usr/bin/env python3
"""Behavior tests for the anthropic-usage poller.

The poller's contract: read a TeamClaude client key from
$TEAMCLAUDE_KEY_FILE, fetch the gateway's GET /teamclaude/status with it
as x-api-key, and publish one small JSON state file the noctalia bar
widget renders: per account the weekly all-model and weekly Fable usage
as percents with their reset times (epoch ms). A failed fetch keeps the
previously published accounts, marked stale.

The gateway is a local in-process HTTP stub. No network, no TeamClaude.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

POLLER = os.environ.get("POLLER", os.path.join(os.path.dirname(__file__), "poller.py"))

KEY = "tc-client-key"
STATUS_PATH = "/teamclaude/status"


def account(name, weekly, fable, weekly_reset, fable_reset):
    """One entry of TeamClaude's /teamclaude/status `accounts` (fields we touch
    plus some we ignore)."""
    return {
        "name": name,
        "type": "oauth",
        "orgName": None,
        "enabled": True,
        "rateLimitedUntil": None,
        "quota": {
            "unified5h": 0.3,
            "unified5hReset": weekly_reset - 86_400_000,
            "unified7d": weekly,
            "unified7dReset": weekly_reset,
            "unified7dFable": fable,
            "unified7dFableReset": fable_reset,
            "unified7dSonnet": None,
            "unified7dSeenAt": 1_793_000_000_000,
        },
    }


class StubGateway(BaseHTTPRequestHandler):
    # dict served as JSON, or an int status
    response = 500
    # x-api-key values seen, in request order
    keys = []

    def do_GET(self):
        key = self.headers.get("x-api-key")
        self.keys.append(key)
        if self.path != STATUS_PATH:
            status, payload = 404, {"error": "not found"}
        elif key != KEY:
            status, payload = 401, {"error": "unauthorized"}
        elif isinstance(self.response, int):
            status, payload = self.response, {"error": "boom"}
        else:
            status, payload = 200, self.response
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def write_key(tmp, key=KEY):
    path = os.path.join(tmp, "key")
    with open(path, "w") as fh:
        fh.write(key + "\n")  # clan vars may end in a newline
    return path


def run_poller(tmp, url, key_file):
    state_path = os.path.join(tmp, "state.json")
    env = dict(os.environ)
    env.update(ANTHROPIC_USAGE_STATE=state_path, TEAMCLAUDE_STATUS_URL=url,
               TEAMCLAUDE_KEY_FILE=key_file)
    proc = subprocess.run(
        [sys.executable, POLLER], env=env, capture_output=True, text=True, timeout=60
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"poller exited {proc.returncode}\nstdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    with open(state_path) as fh:
        return json.load(fh)


def check(name, cond, detail=""):
    if not cond:
        raise AssertionError(f"{name}: {detail}")
    print(f"ok: {name}")


def two_accounts():
    return {
        "currentAccount": "bob@example.com",
        "accounts": [
            account("bob@example.com", 0.75, None, 1_793_552_400_000, None),
            account("alice@example.com", 0.5, 0.25, 1_793_552_400_000, 1_793_552_399_000),
        ],
    }


def test_happy_path_two_accounts(tmp, url):
    """Both accounts, sorted by email; ratios become percents, reset epoch
    ms pass through, a null Fable quota stays null; the key goes out as
    x-api-key without its trailing newline."""
    StubGateway.response = two_accounts()

    before = int(time.time() * 1000)
    got = run_poller(tmp, url, write_key(tmp))

    check("version 3", got.get("version") == 3, f"got {got!r}")
    check("key sent stripped", StubGateway.keys == [KEY], f"got {StubGateway.keys!r}")
    accounts = got["accounts"]
    emails = [a["email"] for a in accounts]
    check("sorted by email", emails == ["alice@example.com", "bob@example.com"], f"got {emails}")
    a, b = accounts
    check("alice percents", (a["weekly"], a["fable"]) == (50, 25), f"got {a!r}")
    check("alice resets", (a["weeklyResetsAt"], a["fableResetsAt"])
          == (1_793_552_400_000, 1_793_552_399_000), f"got {a!r}")
    check("bob weekly", (b["weekly"], b["weeklyResetsAt"]) == (75, 1_793_552_400_000), f"got {b!r}")
    check("bob null fable", b["fable"] is None and b["fableResetsAt"] is None, f"got {b!r}")
    check("not stale", a["stale"] is False and b["stale"] is False, f"got {accounts!r}")
    check("fetchedAt now", all(before <= x["fetchedAt"] <= got["updatedAt"] for x in accounts),
          f"got {accounts!r}")


def assert_kept_stale(name, first, got):
    want = {a["email"]: a for a in first["accounts"]}
    accounts = got["accounts"]
    check(f"{name}: same accounts", [a["email"] for a in accounts] == sorted(want),
          f"got {accounts!r}")
    for a in accounts:
        prev = want[a["email"]]
        check(f"{name}: {a['email']} keeps values",
              all(a[k] == prev[k] for k in
                  ("weekly", "weeklyResetsAt", "fable", "fableResetsAt", "fetchedAt")),
              f"got {a!r}, before {prev!r}")
        check(f"{name}: {a['email']} stale", a["stale"] is True, f"got {a!r}")


def test_server_error_keeps_previous_values(tmp, url):
    """A 500 keeps every account's last published values (fetchedAt too),
    marked stale — it never blanks the bar."""
    key = write_key(tmp)
    StubGateway.response = two_accounts()
    first = run_poller(tmp, url, key)

    StubGateway.response = 500
    assert_kept_stale("500", first, run_poller(tmp, url, key))


def test_wrong_key_keeps_previous_values(tmp, url):
    """A rejected key (401) is a failure like any other."""
    StubGateway.response = two_accounts()
    first = run_poller(tmp, url, write_key(tmp))

    assert_kept_stale("401", first, run_poller(tmp, url, write_key(tmp, "wrong")))
    check("401: wrong key was sent", StubGateway.keys[-1] == "wrong", f"got {StubGateway.keys!r}")


def test_missing_key_file_keeps_previous_values(tmp, url):
    """No key file: nothing is fetched, previous values stay, stale."""
    StubGateway.response = two_accounts()
    first = run_poller(tmp, url, write_key(tmp))

    StubGateway.keys.clear()
    got = run_poller(tmp, url, os.path.join(tmp, "absent"))
    check("missing key: no request", StubGateway.keys == [], f"got {StubGateway.keys!r}")
    assert_kept_stale("missing key", first, got)


def test_bad_response_keeps_previous_values(tmp, url):
    """A 200 without an accounts list is a failure, not "no accounts"."""
    StubGateway.response = two_accounts()
    first = run_poller(tmp, url, write_key(tmp))

    StubGateway.response = {"currentAccount": None}
    assert_kept_stale("no accounts list", first, run_poller(tmp, url, write_key(tmp)))


def test_first_run_failure_has_no_accounts(tmp, url):
    """Failing with nothing published yet: an empty account list."""
    StubGateway.response = 500
    got = run_poller(tmp, url, write_key(tmp))
    check("first failure: version 3", got.get("version") == 3, f"got {got!r}")
    check("first failure: no accounts", got["accounts"] == [], f"got {got!r}")


def main():
    server = HTTPServer(("127.0.0.1", 0), StubGateway)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}{STATUS_PATH}"

    tests = [
        test_happy_path_two_accounts,
        test_server_error_keeps_previous_values,
        test_wrong_key_keeps_previous_values,
        test_missing_key_file_keeps_previous_values,
        test_bad_response_keeps_previous_values,
        test_first_run_failure_has_no_accounts,
    ]
    for t in tests:
        StubGateway.response = 500
        StubGateway.keys = []
        with tempfile.TemporaryDirectory() as tmp:
            t(tmp, url)
    print(f"PASS: {len(tests)} poller behavior test(s)")


if __name__ == "__main__":
    main()
