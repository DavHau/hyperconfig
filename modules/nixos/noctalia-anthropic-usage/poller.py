#!/usr/bin/env python3
"""Publish per-account Anthropic weekly usage for the noctalia bar.

Single source of truth: the logins of omp's `afk` profile
(~/.omp/profiles/afk/agent/agent.db), opened READ-ONLY — an OAuth
refresh rotates the refresh token and would corrupt omp's copy. For each
account the poller asks the OAuth usage endpoint for two weekly
utilizations and atomically writes a small state file the noctalia
`anthropic-usage` plugin watches:

    { "version": 2, "updatedAt": <epoch ms>,
      "accounts": [ { "email",
                      "weekly", "weeklyResetsAt",   # all models
                      "fable",  "fableResetsAt",    # Fable-scoped
                      "stale" } ] }

Percents are 0..100 or null. Accounts are sorted by email so the bars
keep a stable order.

When a fetch fails (expired token while omp is idle, rate limit,
outage) the account keeps its last published values, marked stale.
Nothing else is consulted: other omp profiles, omp's usage cache and
Claude Code's login all carry older data for the same accounts, and
mixing them in made the bars jump between values.

Environment:
    OMP_AGENT_DB              agent.db path (default ~/.omp/profiles/afk/agent/agent.db)
    ANTHROPIC_USAGE_STATE     state file path (default $XDG_STATE_HOME/anthropic-usage.json)
    ANTHROPIC_USAGE_URL       usage endpoint  (default https://api.anthropic.com/api/oauth/usage)
"""

import json
import os
import sqlite3
import sys
import time
import urllib.request

DEFAULT_URL = "https://api.anthropic.com/api/oauth/usage"
EMPTY = {"weekly": None, "weeklyResetsAt": None, "fable": None, "fableResetsAt": None}


def db_path():
    return os.environ.get(
        "OMP_AGENT_DB",
        os.path.expanduser("~/.omp/profiles/afk/agent/agent.db"),
    )


def state_path():
    default = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "anthropic-usage.json",
    )
    return os.environ.get("ANTHROPIC_USAGE_STATE", default)


def load_accounts(path):
    """Live credential per account email.

    auth_credentials keeps every historical login row; the newest
    (updated_at-ascending, last wins) is the live one.
    """
    if not os.path.exists(path):
        return {}
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        rows = db.execute(
            "SELECT data FROM auth_credentials"
            " WHERE provider = 'anthropic' AND credential_type = 'oauth'"
            " ORDER BY updated_at"
        ).fetchall()
    finally:
        db.close()
    creds = {}
    for (data,) in rows:
        try:
            cred = json.loads(data)
        except ValueError:
            continue
        email = cred.get("email")
        if email and cred.get("access"):
            creds[email] = cred
    return creds


def weekly_usage(usage):
    """Weekly all-model and Fable utilization from a /api/oauth/usage response."""
    out = dict(EMPTY)
    for limit in usage.get("limits") or []:
        model = (limit.get("scope") or {}).get("model") or {}
        if limit.get("kind") == "weekly_all":
            out["weekly"] = limit.get("percent")
            out["weeklyResetsAt"] = limit.get("resets_at")
        elif model.get("display_name") == "Fable":
            out["fable"] = limit.get("percent")
            out["fableResetsAt"] = limit.get("resets_at")
    return out


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


def load_previous_accounts(target):
    """Accounts from the last published state file, keyed by email."""
    try:
        with open(target) as fh:
            prev = json.load(fh)
    except (OSError, ValueError):
        return {}
    if prev.get("version") != 2:
        return {}
    return {a["email"]: a for a in prev.get("accounts") or [] if a.get("email")}


def main():
    url = os.environ.get("ANTHROPIC_USAGE_URL", DEFAULT_URL)
    target = state_path()
    previous = load_previous_accounts(target)
    creds = load_accounts(db_path())

    accounts = []
    for email in sorted(creds):
        try:
            entry = weekly_usage(api_get(url, creds[email]["access"]))
            stale = False
        except Exception as err:  # HTTP error, timeout, bad JSON, ...
            print(f"anthropic-usage: {email}: fetch failed: {err}", file=sys.stderr)
            prev = previous.get(email) or {}
            entry = {k: prev.get(k) for k in EMPTY}
            stale = True
        accounts.append({"email": email, **entry, "stale": stale})

    state = {
        "version": 2,
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
