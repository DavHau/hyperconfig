#!/usr/bin/env python3
"""Publish per-account Anthropic weekly usage for the noctalia bar.

Credentials come from every omp agent.db under $OMP_HOME (the shared
~/.omp/agent/agent.db plus ~/.omp/profiles/*/agent/agent.db), opened
READ-ONLY — an OAuth refresh rotates the refresh token and would corrupt
omp's copy. omp moves where it keeps logins between releases and
profiles, so no single database is trusted: per account email the token
with the latest expiry wins. The numbers themselves always come live
from the OAuth usage endpoint, so the choice of token cannot make the
bars jump.

For each account the poller asks the usage endpoint for two weekly
utilizations and atomically writes a small state file the noctalia
`anthropic-usage` plugin watches:

    { "version": 2, "updatedAt": <epoch ms>,
      "accounts": [ { "email",
                      "weekly", "weeklyResetsAt",   # all models
                      "fable",  "fableResetsAt",    # Fable-scoped
                      "fetchedAt",                  # epoch ms of last success
                      "stale" } ] }

Percents are 0..100 or null. Accounts are sorted by email so the bars
keep a stable order.

An account without an unexpired token anywhere (omp idle for hours,
subscription paused) is not queried at all — an expired token only earns
401/429s — and, like a failed fetch (rate limit, outage), keeps its last
published values, marked stale.

Environment:
    OMP_HOME                  omp state root (default ~/.omp)
    ANTHROPIC_USAGE_STATE     state file path (default $XDG_STATE_HOME/anthropic-usage.json)
    ANTHROPIC_USAGE_URL       usage endpoint  (default https://api.anthropic.com/api/oauth/usage)
"""

import glob
import json
import os
import sqlite3
import sys
import time
import urllib.request

DEFAULT_URL = "https://api.anthropic.com/api/oauth/usage"
EMPTY = {"weekly": None, "weeklyResetsAt": None, "fable": None, "fableResetsAt": None,
         "fetchedAt": None}
# A token this close to expiry may die mid-request; treat it as expired.
EXPIRY_MARGIN_MS = 60_000


def agent_dbs():
    root = os.environ.get("OMP_HOME", os.path.expanduser("~/.omp"))
    return [os.path.join(root, "agent", "agent.db"),
            *sorted(glob.glob(os.path.join(root, "profiles", "*", "agent", "agent.db")))]


def state_path():
    default = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "anthropic-usage.json",
    )
    return os.environ.get("ANTHROPIC_USAGE_STATE", default)


def read_creds(path):
    """Anthropic OAuth credential dicts stored in one agent.db."""
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except sqlite3.Error:
        return []
    try:
        rows = db.execute(
            "SELECT data FROM auth_credentials"
            " WHERE provider = 'anthropic' AND credential_type = 'oauth'"
        ).fetchall()
    except sqlite3.Error as err:  # missing file/table, locked, ...
        print(f"anthropic-usage: {path}: {err}", file=sys.stderr)
        return []
    finally:
        db.close()
    creds = []
    for (data,) in rows:
        try:
            cred = json.loads(data)
        except ValueError:
            continue
        if isinstance(cred, dict) and cred.get("email") and cred.get("access"):
            creds.append(cred)
    return creds


def load_accounts(paths):
    """Best credential per account email across all agent.dbs: the one
    expiring last. Every email ever logged in is listed, even when all
    its tokens are expired."""
    best = {}
    for path in paths:
        if not os.path.exists(path):
            continue
        for cred in read_creds(path):
            email = cred["email"]
            if email not in best or cred.get("expires", 0) > best[email].get("expires", 0):
                best[email] = cred
    return best


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
    creds = load_accounts(agent_dbs())
    now_ms = int(time.time() * 1000)

    accounts = []
    for email in sorted(creds):
        cred = creds[email]
        entry = None
        if cred.get("expires", 0) <= now_ms + EXPIRY_MARGIN_MS:
            print(f"anthropic-usage: {email}: no unexpired token, skipping", file=sys.stderr)
        else:
            try:
                entry = {**weekly_usage(api_get(url, cred["access"])), "fetchedAt": now_ms}
            except Exception as err:  # HTTP error, timeout, bad JSON, ...
                print(f"anthropic-usage: {email}: fetch failed: {err}", file=sys.stderr)
        stale = entry is None
        if stale:
            prev = previous.get(email) or {}
            entry = {k: prev.get(k) for k in EMPTY}
        accounts.append({"email": email, **entry, "stale": stale})

    state = {
        "version": 2,
        "updatedAt": now_ms,
        "accounts": accounts,
    }
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, target)


if __name__ == "__main__":
    main()
