#!/usr/bin/env python3
"""Behavior tests for the anthropic-usage poller.

The poller's contract: read every logged-in Anthropic account from omp's
agent.db (read-only), ask the Anthropic OAuth usage endpoint how much of
the weekly Fable allowance each account has used, and publish one small
JSON state file the noctalia bar widget renders as two mini-bars.

Covered behavior (one test per vertical slice):
  1. happy path — two accounts, both tokens valid: state file lists both
     accounts (sorted by email, so the bars have a stable order) with the
     Fable percent and reset time from the endpoint.

Everything is stubbed locally: a fake agent.db with omp's real schema, a
fake Claude Code credential store, and an in-process HTTP server that
maps bearer tokens to usage/profile responses and refresh tokens to
rotated grants. No network, no omp.
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


def usage_response(fable_percent, session_percent=30, resets_at="2026-07-15T15:59:59+00:00"):
    """Shape of https://api.anthropic.com/api/oauth/usage (fields we touch)."""
    return {
        "five_hour": {"utilization": session_percent, "resets_at": "2026-07-10T05:59:59+00:00"},
        "seven_day": {"utilization": 7.0, "resets_at": resets_at},
        "limits": [
            {"kind": "session", "group": "session", "percent": session_percent,
             "severity": "normal", "resets_at": "2026-07-10T05:59:59+00:00",
             "scope": None, "is_active": True},
            {"kind": "weekly_all", "group": "weekly", "percent": 7,
             "severity": "normal", "resets_at": resets_at, "scope": None, "is_active": False},
            {"kind": "weekly_scoped", "group": "weekly", "percent": fable_percent,
             "severity": "normal", "resets_at": resets_at,
             "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None},
             "is_active": False},
        ],
    }


class StubApi(BaseHTTPRequestHandler):
    # access token -> usage dict | int status  (GET .../usage)
    responses = {}
    # access token -> email                    (GET .../profile)
    profiles = {}
    # refresh token -> token-response dict | int status (POST .../token)
    refreshes = {}

    def _reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def _bearer(self):
        return self.headers.get("Authorization", "").removeprefix("Bearer ")

    def do_GET(self):
        token = self._bearer()
        if self.path.endswith("/profile"):
            email = self.profiles.get(token)
            if email is None:
                self._reply(401, {"error": "unauthorized"})
            else:
                self._reply(200, {"account": {"uuid": "u-" + email, "email": email}})
            return
        resp = self.responses.get(token)
        if resp is None:
            resp = 401
        if isinstance(resp, int):
            self._reply(resp, {"error": "unauthorized"})
        else:
            self._reply(200, resp)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        resp = self.refreshes.get(body.get("refresh_token"))
        if resp is None:
            self._reply(400, {"error": "invalid_grant",
                              "error_description": "Refresh token not found or invalid"})
        elif isinstance(resp, int):
            self._reply(resp, {"error": "invalid_grant"})
        else:
            self._reply(200, resp)

    def log_message(self, *a):
        pass


def clear_stub():
    StubApi.responses = {}
    StubApi.profiles = {}
    StubApi.refreshes = {}


def make_db(path, creds, cache_rows=()):
    """Fake omp agent.db: the two tables the poller reads, real schema."""
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
    db.execute(
        """CREATE TABLE cache (
             key TEXT PRIMARY KEY,
             value TEXT NOT NULL,
             expires_at INTEGER NOT NULL)"""
    )
    for c in creds:
        db.execute(
            "INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause, identity_key, updated_at)"
            " VALUES ('anthropic', 'oauth', ?, ?, ?, ?)",
            (json.dumps(c["data"]), c.get("disabled_cause"), c.get("identity_key"), c.get("updated_at", 0)),
        )
    for k, v in cache_rows:
        db.execute(
            "INSERT INTO cache (key, value, expires_at) VALUES (?, ?, ?)",
            (k, json.dumps(v), int(time.time()) + 86400),
        )
    db.commit()
    db.close()


def cred(email, token, expires_in_ms=3_600_000, updated_at=100):
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


def claude_code_store(tmp, access, refresh, expires_in_ms=3_600_000, extra=None):
    """~/.claude/.credentials.json as Claude Code writes it."""
    path = os.path.join(tmp, "claude-credentials.json")
    blob = {
        "accessToken": access,
        "refreshToken": refresh,
        "expiresAt": NOW_MS + expires_in_ms,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max",
    }
    blob.update(extra or {})
    with open(path, "w") as fh:
        json.dump({"claudeAiOauth": blob}, fh)
    return path


def run_poller(tmp, db_path, state_path, url, claude_code=None):
    base = url.removesuffix("/api/oauth/usage")
    env = dict(os.environ)
    env.update(
        OMP_AGENT_DB=db_path,
        ANTHROPIC_USAGE_STATE=state_path,
        ANTHROPIC_USAGE_URL=url,
        ANTHROPIC_PROFILE_URL=base + "/api/oauth/profile",
        ANTHROPIC_TOKEN_URL=base + "/v1/oauth/token",
        CLAUDE_CODE_CREDENTIALS=claude_code or os.path.join(tmp, "no-such-credentials.json"),
    )
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
    db = os.path.join(tmp, "agent.db")
    state = os.path.join(tmp, "state.json")
    make_db(db, [
        cred("alice@example.com", "tok-alice"),
        cred("bob@example.com", "tok-bob"),
    ])
    StubApi.responses = {
        "tok-alice": usage_response(11, resets_at="2026-07-15T15:59:59+00:00"),
        "tok-bob": usage_response(63, resets_at="2026-07-14T09:00:00+00:00"),
    }

    got = run_poller(tmp, db, state, url)

    accounts = got.get("accounts")
    check("two accounts", isinstance(accounts, list) and len(accounts) == 2, f"got {accounts!r}")
    emails = [a["email"] for a in accounts]
    check("sorted by email", emails == ["alice@example.com", "bob@example.com"], f"got {emails}")
    a, b = accounts
    check("alice fable percent", a["percent"] == 11, f"got {a!r}")
    check("bob fable percent", b["percent"] == 63, f"got {b!r}")
    check("alice not stale", a["stale"] is False, f"got {a!r}")
    check("resets_at carried", a["resetsAt"] == "2026-07-15T15:59:59+00:00", f"got {a!r}")
    check("updatedAt present", isinstance(got.get("updatedAt"), int) and got["updatedAt"] > 0)


def omp_cache_row(email, account_id, fable_used, resets_at_ms=1784131200000):
    """omp's own usage_cache report row (shape observed in agent.db)."""
    key = (
        "usage_cache:report:anthropic:https://api.anthropic.com:oauth"
        f"|account:{account_id}|email:{email}"
    )
    value = {
        "value": {
            "provider": "anthropic",
            "fetchedAt": NOW_MS - 60_000,
            "limits": [
                {"id": "anthropic:5h", "amount": {"used": 30, "unit": "percent"},
                 "window": {"id": "5h", "resetsAt": NOW_MS + 3_600_000}},
                {"id": "anthropic:7d:fable", "amount": {"used": fable_used, "unit": "percent"},
                 "window": {"id": "7d", "resetsAt": resets_at_ms}},
            ],
        }
    }
    return key, value


def test_unauthorized_falls_back_to_omp_cache(tmp, url):
    """Expired/revoked token: reuse omp's own cached usage report, marked stale.

    The poller never refreshes tokens (rotation would corrupt omp's copy),
    so a 401 is expected steady-state for an account omp isn't actively
    using; omp's usage_cache row is the freshest data available.
    """
    db = os.path.join(tmp, "agent.db")
    state = os.path.join(tmp, "state.json")
    make_db(
        db,
        [cred("alice@example.com", "tok-alice"), cred("bob@example.com", "tok-bob-dead")],
        cache_rows=[omp_cache_row("bob@example.com", "acct-bob@example.com", 42)],
    )
    StubApi.responses = {"tok-alice": usage_response(11)}  # bob -> 401

    got = run_poller(tmp, db, state, url)

    accounts = {a["email"]: a for a in got["accounts"]}
    check("both accounts present", len(accounts) == 2, f"got {got['accounts']!r}")
    bob = accounts["bob@example.com"]
    check("bob percent from omp cache", bob["percent"] == 42, f"got {bob!r}")
    check("bob marked stale", bob["stale"] is True, f"got {bob!r}")
    check("alice unaffected", accounts["alice@example.com"]["percent"] == 11)


def test_unauthorized_keeps_previous_state(tmp, url):
    """401 with no omp cache row: last published value survives, marked stale.

    A transient outage (or an account omp hasn't touched since login) must
    not blank that account's bar.
    """
    db = os.path.join(tmp, "agent.db")
    state = os.path.join(tmp, "state.json")
    make_db(db, [cred("alice@example.com", "tok-alice"), cred("bob@example.com", "tok-bob")])

    # First run: both fetches succeed and publish a state file.
    StubApi.responses = {
        "tok-alice": usage_response(11),
        "tok-bob": usage_response(63),
    }
    run_poller(tmp, db, state, url)

    # Second run: bob's token now rejected, no omp cache to lean on.
    del StubApi.responses["tok-bob"]
    got = run_poller(tmp, db, state, url)

    accounts = {a["email"]: a for a in got["accounts"]}
    bob = accounts["bob@example.com"]
    check("bob keeps previous percent", bob["percent"] == 63, f"got {bob!r}")
    check("bob stale after outage", bob["stale"] is True, f"got {bob!r}")
    check("alice still fresh", accounts["alice@example.com"]["stale"] is False)


def test_newest_credential_per_email_wins(tmp, url):
    """agent.db keeps every historical login row; only the newest token counts.

    The real table has dozens of superseded rows per account — polling
    with an old token would 401 (or worse, report some stale org).
    """
    db = os.path.join(tmp, "agent.db")
    state = os.path.join(tmp, "state.json")
    make_db(db, [
        cred("alice@example.com", "tok-alice-old", updated_at=100),
        cred("alice@example.com", "tok-alice-new", updated_at=200),
    ])
    StubApi.responses = {
        "tok-alice-old": usage_response(99),
        "tok-alice-new": usage_response(11),
    }

    got = run_poller(tmp, db, state, url)

    check("one account after dedupe", len(got["accounts"]) == 1, f"got {got['accounts']!r}")
    alice = got["accounts"][0]
    check("newest token used", alice["percent"] == 11 and alice["stale"] is False, f"got {alice!r}")


def test_claude_code_covers_dead_omp_token(tmp, url):
    """omp's token dead but Claude Code is logged into the same account:
    the poller borrows that access token (identity checked via the
    profile endpoint) and reports fresh, non-stale usage."""
    db = os.path.join(tmp, "agent.db")
    state = os.path.join(tmp, "state.json")
    make_db(db, [cred("alice@example.com", "tok-alice"), cred("bob@example.com", "tok-bob-dead")])
    cc = claude_code_store(tmp, "tok-cc-bob", "rt-cc-bob")
    StubApi.responses = {
        "tok-alice": usage_response(11),
        "tok-cc-bob": usage_response(1),
    }
    StubApi.profiles = {"tok-cc-bob": "bob@example.com"}

    got = run_poller(tmp, db, state, url, claude_code=cc)

    accounts = {a["email"]: a for a in got["accounts"]}
    bob = accounts["bob@example.com"]
    check("bob fresh via claude-code token", bob["percent"] == 1, f"got {bob!r}")
    check("bob not stale", bob["stale"] is False, f"got {bob!r}")


def test_claude_code_refresh_and_write_back(tmp, url):
    """Expired Claude Code access token: the poller refreshes it and
    rewrites the store IN PLACE (rotated grant), so the claude CLI's
    login keeps working. omp's agent.db is never written."""
    db = os.path.join(tmp, "agent.db")
    state = os.path.join(tmp, "state.json")
    make_db(db, [cred("bob@example.com", "tok-bob-dead")])
    cc = claude_code_store(tmp, "tok-cc-expired", "rt-cc-bob", expires_in_ms=-1000,
                           extra={"subscriptionType": "max"})
    StubApi.responses = {"tok-cc-new": usage_response(1)}
    StubApi.refreshes = {
        "rt-cc-bob": {
            "access_token": "tok-cc-new",
            "refresh_token": "rt-cc-rotated",
            "expires_in": 28800,
            "account": {"uuid": "u-bob", "email_address": "bob@example.com"},
        }
    }

    got = run_poller(tmp, db, state, url, claude_code=cc)

    bob = got["accounts"][0]
    check("bob fresh after refresh", bob["percent"] == 1 and bob["stale"] is False, f"got {bob!r}")
    store = json.load(open(cc))["claudeAiOauth"]
    check("rotated access written back", store["accessToken"] == "tok-cc-new", f"got {store!r}")
    check("rotated refresh written back", store["refreshToken"] == "rt-cc-rotated", f"got {store!r}")
    check("expiry advanced", store["expiresAt"] > NOW_MS, f"got {store['expiresAt']}")
    check("unrelated keys preserved", store.get("subscriptionType") == "max", f"got {store!r}")


def test_claude_code_dead_refresh_falls_back(tmp, url):
    """Claude Code refresh token also dead: existing fallbacks still apply."""
    db = os.path.join(tmp, "agent.db")
    state = os.path.join(tmp, "state.json")
    make_db(
        db,
        [cred("bob@example.com", "tok-bob-dead")],
        cache_rows=[omp_cache_row("bob@example.com", "acct-bob@example.com", 42)],
    )
    cc = claude_code_store(tmp, "tok-cc-expired", "rt-cc-dead", expires_in_ms=-1000)
    # StubApi.refreshes empty -> 400 invalid_grant

    got = run_poller(tmp, db, state, url, claude_code=cc)

    bob = got["accounts"][0]
    check("falls back to omp cache", bob["percent"] == 42 and bob["stale"] is True, f"got {bob!r}")


def main():
    server = HTTPServer(("127.0.0.1", 0), StubApi)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/api/oauth/usage"

    tests = [
        test_happy_path_two_accounts,
        test_unauthorized_falls_back_to_omp_cache,
        test_unauthorized_keeps_previous_state,
        test_newest_credential_per_email_wins,
        test_claude_code_covers_dead_omp_token,
        test_claude_code_refresh_and_write_back,
        test_claude_code_dead_refresh_falls_back,
    ]
    for t in tests:
        clear_stub()
        with tempfile.TemporaryDirectory() as tmp:
            t(tmp, url)
    print(f"PASS: {len(tests)} poller behavior test(s)")


if __name__ == "__main__":
    main()
