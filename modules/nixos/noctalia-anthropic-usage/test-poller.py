#!/usr/bin/env python3
"""Behavior tests for the anthropic-usage poller.

The poller's contract: collect the Anthropic logins from every omp
agent.db under $OMP_HOME (read-only), pick the latest-expiring token per
account, ask the Anthropic OAuth usage endpoint for each account's weekly
all-model and weekly Fable utilization, and publish one small JSON state
file the noctalia bar widget renders.

Everything is stubbed locally: fake agent.dbs with omp's real schema and
an in-process HTTP server mapping bearer tokens to usage responses. No
network, no omp.
"""

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

POLLER = os.environ.get("POLLER", os.path.join(os.path.dirname(__file__), "poller.py"))

NOW_MS = int(time.time() * 1000)


def usage_response(weekly, fable, resets_at="2026-07-15T15:59:59+00:00",
                   fable_resets_at="2026-07-15T15:59:58+00:00"):
    """Shape of https://api.anthropic.com/api/oauth/usage (fields we touch)."""
    return {
        "five_hour": {"utilization": 30.0, "resets_at": "2026-07-10T05:59:59+00:00"},
        "seven_day": {"utilization": float(weekly), "resets_at": resets_at},
        "limits": [
            {"kind": "session", "group": "session", "percent": 30,
             "severity": "normal", "resets_at": "2026-07-10T05:59:59+00:00",
             "scope": None, "is_active": True},
            {"kind": "weekly_all", "group": "weekly", "percent": weekly,
             "severity": "normal", "resets_at": resets_at, "scope": None, "is_active": False},
            {"kind": "weekly_scoped", "group": "weekly", "percent": fable,
             "severity": "normal", "resets_at": fable_resets_at,
             "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None},
             "is_active": False},
        ],
    }


class StubApi(BaseHTTPRequestHandler):
    # access token -> usage dict | int status
    responses = {}
    # tokens seen, in request order
    requests = []

    def do_GET(self):
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        self.requests.append(token)
        resp = self.responses.get(token, 401)
        status, payload = (resp, {"error": "unauthorized"}) if isinstance(resp, int) else (200, resp)
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def make_db(omp_home, rel, creds):
    """Fake omp agent.db at $OMP_HOME/<rel>: auth_credentials, real schema."""
    path = os.path.join(omp_home, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.execute(
        """CREATE TABLE auth_credentials (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             provider TEXT NOT NULL,
             credential_type TEXT NOT NULL,
             data TEXT NOT NULL,
             disabled_cause TEXT DEFAULT NULL,
             identity_key TEXT DEFAULT NULL,
             created_at INTEGER NOT NULL DEFAULT 0,
             updated_at INTEGER NOT NULL DEFAULT 0)"""
    )
    for c in creds:
        db.execute(
            "INSERT INTO auth_credentials (provider, credential_type, data, identity_key, updated_at)"
            " VALUES ('anthropic', 'oauth', ?, ?, ?)",
            (json.dumps(c["data"]), c.get("identity_key"), c.get("updated_at", 0)),
        )
    db.commit()
    db.close()


def cred(email, token, updated_at=100, expires_in_ms=3_600_000):
    return {
        "data": {
            "access": token,
            "refresh": "rt-" + token,
            "expires": NOW_MS + expires_in_ms,
            "accountId": "acct-" + email,
            "email": email,
        },
        "identity_key": "email:" + email,
        "updated_at": updated_at,
    }


SHARED = "agent/agent.db"
AFK = "profiles/afk/agent/agent.db"


def run_poller(omp_home, state_path, url):
    env = dict(os.environ)
    env.update(OMP_HOME=omp_home, ANTHROPIC_USAGE_STATE=state_path, ANTHROPIC_USAGE_URL=url)
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


def test_happy_path_two_accounts(tmp, url):
    """Both tokens valid: both accounts, sorted by email, with weekly and
    Fable percents + reset times taken from their own limit entries."""
    db = os.path.join(tmp, "omp")
    state = os.path.join(tmp, "state.json")
    make_db(db, SHARED, [cred("bob@example.com", "tok-bob"), cred("alice@example.com", "tok-alice")])
    StubApi.responses = {
        "tok-alice": usage_response(42, 11, resets_at="2026-07-15T16:00:00+00:00",
                                    fable_resets_at="2026-07-15T15:59:59+00:00"),
        "tok-bob": usage_response(72, 63),
    }

    got = run_poller(db, state, url)

    accounts = got.get("accounts")
    check("version 2", got.get("version") == 2, f"got {got!r}")
    emails = [a["email"] for a in accounts]
    check("sorted by email", emails == ["alice@example.com", "bob@example.com"], f"got {emails}")
    a, b = accounts
    check("alice weekly", a["weekly"] == 42, f"got {a!r}")
    check("alice fable", a["fable"] == 11, f"got {a!r}")
    check("bob weekly/fable", (b["weekly"], b["fable"]) == (72, 63), f"got {b!r}")
    check("weekly reset", a["weeklyResetsAt"] == "2026-07-15T16:00:00+00:00", f"got {a!r}")
    check("fable reset", a["fableResetsAt"] == "2026-07-15T15:59:59+00:00", f"got {a!r}")
    check("not stale", a["stale"] is False and b["stale"] is False, f"got {accounts!r}")


def test_failure_keeps_previous_values(tmp, url):
    """A failed fetch keeps that account's last published values, marked
    stale — it never blanks the bar or substitutes another source."""
    db = os.path.join(tmp, "omp")
    state = os.path.join(tmp, "state.json")
    make_db(db, SHARED, [cred("alice@example.com", "tok-alice"), cred("bob@example.com", "tok-bob")])
    StubApi.responses = {"tok-alice": usage_response(42, 11), "tok-bob": usage_response(72, 63)}
    run_poller(db, state, url)

    StubApi.responses = {"tok-alice": usage_response(43, 12), "tok-bob": 429}
    got = run_poller(db, state, url)

    accounts = {a["email"]: a for a in got["accounts"]}
    bob = accounts["bob@example.com"]
    check("bob keeps previous", (bob["weekly"], bob["fable"]) == (72, 63), f"got {bob!r}")
    check("bob stale", bob["stale"] is True, f"got {bob!r}")
    check("bob keeps fetch time", bob["fetchedAt"] is not None, f"got {bob!r}")
    alice = accounts["alice@example.com"]
    check("alice updated", (alice["weekly"], alice["fable"], alice["stale"]) == (43, 12, False),
          f"got {alice!r}")


def test_failure_without_history_is_null(tmp, url):
    """First run fails: the account is listed with null percents, stale."""
    db = os.path.join(tmp, "omp")
    state = os.path.join(tmp, "state.json")
    make_db(db, SHARED, [cred("bob@example.com", "tok-bob")])
    StubApi.responses = {}

    bob = run_poller(db, state, url)["accounts"][0]
    check("null percents", bob["weekly"] is None and bob["fable"] is None, f"got {bob!r}")
    check("stale", bob["stale"] is True, f"got {bob!r}")


def test_latest_expiring_token_across_dbs_wins(tmp, url):
    """omp keeps logins in several agent.dbs (shared store, per-profile
    stores, historical rows). A profile's expired copy must not shadow the
    live token in another database — the regression that froze the bar."""
    db = os.path.join(tmp, "omp")
    state = os.path.join(tmp, "state.json")
    make_db(db, AFK, [cred("alice@example.com", "tok-alice-afk", updated_at=300,
                           expires_in_ms=-3_600_000)])
    make_db(db, SHARED, [
        cred("alice@example.com", "tok-alice-live", updated_at=200),
        cred("alice@example.com", "tok-alice-older", updated_at=100, expires_in_ms=600_000),
    ])
    StubApi.responses = {
        "tok-alice-afk": 429,
        "tok-alice-older": usage_response(99, 99),
        "tok-alice-live": usage_response(42, 11),
    }

    got = run_poller(db, state, url)

    check("one account after dedupe", len(got["accounts"]) == 1, f"got {got['accounts']!r}")
    alice = got["accounts"][0]
    check("live token used", (alice["weekly"], alice["stale"]) == (42, False), f"got {alice!r}")


def test_expired_account_not_queried(tmp, url):
    """An account whose every token is expired is still listed with its
    last values, stale, but the endpoint is never called for it."""
    db = os.path.join(tmp, "omp")
    state = os.path.join(tmp, "state.json")
    make_db(db, SHARED, [cred("bob@example.com", "tok-bob")])
    StubApi.responses = {"tok-bob": usage_response(72, 63)}
    run_poller(db, state, url)

    os.remove(os.path.join(db, SHARED))
    make_db(db, SHARED, [cred("bob@example.com", "tok-bob-dead", expires_in_ms=-1)])
    StubApi.requests.clear()
    bob = run_poller(db, state, url)["accounts"][0]

    check("no request for expired token", StubApi.requests == [], f"got {StubApi.requests!r}")
    check("keeps values, stale", (bob["weekly"], bob["stale"]) == (72, True), f"got {bob!r}")


def main():
    server = HTTPServer(("127.0.0.1", 0), StubApi)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/api/oauth/usage"

    tests = [
        test_happy_path_two_accounts,
        test_failure_keeps_previous_values,
        test_failure_without_history_is_null,
        test_latest_expiring_token_across_dbs_wins,
        test_expired_account_not_queried,
    ]
    for t in tests:
        StubApi.responses = {}
        StubApi.requests = []
        with tempfile.TemporaryDirectory() as tmp:
            t(tmp, url)
    print(f"PASS: {len(tests)} poller behavior test(s)")


if __name__ == "__main__":
    main()
