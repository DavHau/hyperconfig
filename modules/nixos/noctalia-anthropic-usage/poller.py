#!/usr/bin/env python3
"""Publish per-account Anthropic Fable weekly usage for the noctalia bar.

Reads every logged-in Anthropic account from omp's agent.db (READ-ONLY —
an OAuth refresh rotates the refresh token and would corrupt omp's
copy), asks the OAuth usage endpoint for each account's weekly Fable
utilization, and atomically writes a small state file the noctalia
`anthropic-usage` plugin watches:

    { "version": 1, "updatedAt": <epoch ms>,
      "accounts": [ { "email", "percent", "resetsAt", "stale" } ] }

Accounts are sorted by email so the two bars keep a stable order.

When omp's token for an account is dead (expired access + revoked
refresh token — omp marks these "oauth refresh failed" and never touches
them again), the poller falls back to Claude Code's own login at
~/.claude/.credentials.json: identity is checked via the OAuth profile
endpoint, and an expired grant is refreshed and written back IN PLACE so
the `claude` CLI keeps working (Claude Code's own protocol; in place
because the file may be bind-mounted into sandboxes). Failing all that:
omp's cached usage report, then the last published value, marked stale.

Environment:
    OMP_AGENT_DB              agent.db path   (default ~/.omp/agent/agent.db)
    ANTHROPIC_USAGE_STATE     state file path (default $XDG_STATE_HOME/anthropic-usage.json)
    ANTHROPIC_USAGE_URL       usage endpoint  (default https://api.anthropic.com/api/oauth/usage)
    ANTHROPIC_PROFILE_URL     profile endpoint(default https://api.anthropic.com/api/oauth/profile)
    ANTHROPIC_TOKEN_URL       token endpoint  (default https://api.anthropic.com/v1/oauth/token)
    CLAUDE_CODE_CREDENTIALS   Claude Code store (default ~/.claude/.credentials.json)
"""

import json
import os
import sqlite3
import sys
import time
import urllib.request

DEFAULT_URL = "https://api.anthropic.com/api/oauth/usage"
DEFAULT_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
DEFAULT_TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
# Claude Code's public OAuth client id — the grant in its store belongs
# to this client, so refreshes must present it.
CLAUDE_CODE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"


def db_path():
    return os.environ.get(
        "OMP_AGENT_DB", os.path.expanduser("~/.omp/agent/agent.db")
    )


def state_path():
    default = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "anthropic-usage.json",
    )
    return os.environ.get("ANTHROPIC_USAGE_STATE", default)


def load_accounts(db):
    """Latest credential per account email from omp's auth_credentials."""
    rows = db.execute(
        "SELECT data, updated_at FROM auth_credentials"
        " WHERE provider = 'anthropic' AND credential_type = 'oauth'"
        " ORDER BY updated_at"
    ).fetchall()
    by_email = {}
    for data, updated_at in rows:
        try:
            cred = json.loads(data)
        except ValueError:
            continue
        email = cred.get("email")
        if not email or not cred.get("access"):
            continue
        by_email[email] = cred  # rows are updated_at-ascending: last wins
    return by_email


def load_omp_usage_cache(db):
    """omp's own cached usage reports, keyed by account email.

    omp (the coding agent) polls the same endpoint while it works and
    caches the parsed report in agent.db's `cache` table under
    `usage_cache:report:anthropic:...|email:<email>`. When our direct
    fetch fails (expired access token — we never refresh, see module
    docstring) that row is the freshest data available.
    """
    rows = db.execute(
        "SELECT key, value FROM cache"
        " WHERE key LIKE 'usage_cache:report:anthropic:%'"
    ).fetchall()
    by_email = {}
    for key, value in rows:
        marker = "|email:"
        if marker not in key:
            continue
        email = key.rsplit(marker, 1)[1]
        try:
            report = json.loads(value).get("value") or {}
        except ValueError:
            continue
        by_email[email] = report
    return by_email


def fable_from_omp_report(report):
    """(percent, resetsAt ISO) from an omp usage_cache report, or (None, None)."""
    for limit in report.get("limits") or []:
        if limit.get("id") != "anthropic:7d:fable":
            continue
        amount = limit.get("amount") or {}
        window = limit.get("window") or {}
        resets_ms = window.get("resetsAt")
        resets_at = (
            time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(resets_ms / 1000))
            if isinstance(resets_ms, (int, float))
            else None
        )
        return amount.get("used"), resets_at
    return None, None


def fable_percent(usage):
    """Weekly Fable utilization from a /api/oauth/usage response."""
    for limit in usage.get("limits") or []:
        scope = limit.get("scope") or {}
        model = scope.get("model") or {}
        if model.get("display_name") == "Fable":
            return limit.get("percent"), limit.get("resets_at")
    return None, None


def api_get(url, token):
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


class ClaudeCodeSource:
    """Fallback token source: Claude Code's own login store.

    Lazily resolved — the store is only read (and at most one refresh
    performed) when some account's omp token has already failed. omp's
    agent.db is never written; the Claude Code store is only rewritten
    with the rotated grant a refresh returns, which is what Claude Code
    itself does on refresh.
    """

    def __init__(self, path, profile_url, token_url):
        self.path = path
        self.profile_url = profile_url
        self.token_url = token_url
        self._resolved = False
        self._email = None
        self._access = None

    def token_for(self, email):
        """Access token for `email`, or None if this store is not that account."""
        if not self._resolved:
            self._resolved = True
            try:
                self._email, self._access = self._resolve()
            except Exception as err:
                print(f"anthropic-usage: claude-code store unusable: {err}", file=sys.stderr)
        return self._access if email and self._email == email else None

    def _resolve(self):
        with open(self.path) as fh:
            blob = json.load(fh)
        oauth = blob.get("claudeAiOauth") or {}
        access = oauth.get("accessToken")
        # 60s of slack so a token that expires mid-poll counts as expired.
        if access and (oauth.get("expiresAt") or 0) > time.time() * 1000 + 60_000:
            profile = api_get(self.profile_url, access)
            return (profile.get("account") or {}).get("email"), access
        return self._refresh(blob, oauth)

    def _refresh(self, blob, oauth):
        req = urllib.request.Request(
            self.token_url,
            data=json.dumps(
                {
                    "grant_type": "refresh_token",
                    "refresh_token": oauth.get("refreshToken"),
                    "client_id": CLAUDE_CODE_CLIENT_ID,
                }
            ).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            tok = json.load(resp)

        oauth["accessToken"] = tok["access_token"]
        oauth["refreshToken"] = tok["refresh_token"]
        oauth["expiresAt"] = int(time.time() * 1000) + tok["expires_in"] * 1000
        blob["claudeAiOauth"] = oauth
        # In place, not rename: the file may be bind-mounted (sandboxes),
        # and Claude Code must keep seeing the rotated grant.
        with open(self.path, "w") as fh:
            json.dump(blob, fh)

        email = (tok.get("account") or {}).get("email_address")
        if not email:
            profile = api_get(self.profile_url, tok["access_token"])
            email = (profile.get("account") or {}).get("email")
        return email, tok["access_token"]


def load_previous_accounts(target):
    """Accounts from the last published state file, keyed by email."""
    try:
        with open(target) as fh:
            prev = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {a["email"]: a for a in prev.get("accounts") or [] if a.get("email")}


def main():
    url = os.environ.get("ANTHROPIC_USAGE_URL", DEFAULT_URL)
    target = state_path()
    previous = load_previous_accounts(target)
    claude_code = ClaudeCodeSource(
        path=os.environ.get(
            "CLAUDE_CODE_CREDENTIALS", os.path.expanduser("~/.claude/.credentials.json")
        ),
        profile_url=os.environ.get("ANTHROPIC_PROFILE_URL", DEFAULT_PROFILE_URL),
        token_url=os.environ.get("ANTHROPIC_TOKEN_URL", DEFAULT_TOKEN_URL),
    )

    db = sqlite3.connect(f"file:{db_path()}?mode=ro", uri=True)
    try:
        creds = load_accounts(db)
        omp_cache = load_omp_usage_cache(db)
    finally:
        db.close()

    accounts = []
    for email in sorted(creds):
        cred = creds[email]
        try:
            usage = api_get(url, cred["access"])
        except Exception as err:  # HTTP error, timeout, bad JSON, ...
            print(f"anthropic-usage: {email}: fetch failed: {err}", file=sys.stderr)
            cc_token = claude_code.token_for(email)
            if cc_token:
                try:
                    usage = api_get(url, cc_token)
                except Exception as cc_err:
                    print(
                        f"anthropic-usage: {email}: claude-code fetch failed: {cc_err}",
                        file=sys.stderr,
                    )
                else:
                    percent, resets_at = fable_percent(usage)
                    accounts.append(
                        {"email": email, "percent": percent, "resetsAt": resets_at, "stale": False}
                    )
                    continue
            percent, resets_at = fable_from_omp_report(omp_cache.get(email) or {})
            if percent is None:
                prev = previous.get(email) or {}
                percent = prev.get("percent")
                resets_at = prev.get("resetsAt")
            accounts.append(
                {"email": email, "percent": percent, "resetsAt": resets_at, "stale": True}
            )
            continue
        percent, resets_at = fable_percent(usage)
        accounts.append(
            {
                "email": email,
                "percent": percent,
                "resetsAt": resets_at,
                "stale": False,
            }
        )

    state = {
        "version": 1,
        "updatedAt": int(time.time() * 1000),
        "accounts": accounts,
    }
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, target)


if __name__ == "__main__":
    main()
