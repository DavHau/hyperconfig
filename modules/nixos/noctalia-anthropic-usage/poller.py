#!/usr/bin/env python3
"""Publish per-account Anthropic weekly usage for the noctalia bar.

The numbers come from our TeamClaude gateway's `GET /teamclaude/status`,
which lists every pooled Claude account with the quota the gateway last
saw for it (from the rate-limit headers of the traffic it forwards and of
its own probes). The request carries a TeamClaude client key as
`x-api-key`; any client key may read the status.

The poller atomically writes a small state file the noctalia
`anthropic-usage` plugin watches:

    { "version": 3, "updatedAt": <epoch ms>,
      "accounts": [ { "email",
                      "weekly", "weeklyResetsAt",   # all models
                      "fable",  "fableResetsAt",    # Fable-scoped
                      "fetchedAt",                  # epoch ms of last success
                      "stale" } ] }

Percents are 0..100 or null; *ResetsAt are epoch ms or null. Accounts are
sorted by email so the bars keep a stable order.

When the fetch fails (no key file, HTTP error, outage, bad response) every
previously published account keeps its last values, marked stale.

Environment:
    TEAMCLAUDE_KEY_FILE       file holding the TeamClaude client key (required)
    TEAMCLAUDE_STATUS_URL     status endpoint (default https://teamclaude.davhau.com/teamclaude/status)
    ANTHROPIC_USAGE_STATE     state file path (default $XDG_STATE_HOME/anthropic-usage.json)
"""

import json
import os
import sys
import time
import urllib.request

DEFAULT_URL = "https://teamclaude.davhau.com/teamclaude/status"
VERSION = 3
FIELDS = ("weekly", "weeklyResetsAt", "fable", "fableResetsAt", "fetchedAt")


def state_path():
    default = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "anthropic-usage.json",
    )
    return os.environ.get("ANTHROPIC_USAGE_STATE", default)


def percent(ratio):
    return None if ratio is None else ratio * 100


def fetch_status(url):
    key_file = os.environ.get("TEAMCLAUDE_KEY_FILE")
    if not key_file:
        raise RuntimeError("TEAMCLAUDE_KEY_FILE is not set")
    with open(key_file) as fh:
        key = fh.read().strip()
    req = urllib.request.Request(url, headers={"x-api-key": key})
    with urllib.request.urlopen(req, timeout=20) as resp:
        status = json.load(resp)
    if not isinstance(status, dict) or not isinstance(status.get("accounts"), list):
        raise ValueError("response has no accounts list")
    return status


def current_accounts(status, now_ms):
    accounts = []
    for acc in status["accounts"]:
        if not isinstance(acc, dict) or not acc.get("name"):
            continue
        quota = acc.get("quota") or {}
        accounts.append({
            "email": acc["name"],
            "weekly": percent(quota.get("unified7d")),
            "weeklyResetsAt": quota.get("unified7dReset"),
            "fable": percent(quota.get("unified7dFable")),
            "fableResetsAt": quota.get("unified7dFableReset"),
            "fetchedAt": now_ms,
            "stale": False,
        })
    return accounts


def previous_accounts(target):
    """Accounts from the last published state file, marked stale."""
    try:
        with open(target) as fh:
            prev = json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(prev, dict) or prev.get("version") != VERSION:
        return []
    return [
        {"email": a["email"], **{k: a.get(k) for k in FIELDS}, "stale": True}
        for a in prev.get("accounts") or []
        if isinstance(a, dict) and a.get("email")
    ]


def main():
    url = os.environ.get("TEAMCLAUDE_STATUS_URL", DEFAULT_URL)
    target = state_path()
    now_ms = int(time.time() * 1000)

    try:
        accounts = current_accounts(fetch_status(url), now_ms)
    except Exception as err:  # key file, HTTP error, timeout, bad JSON, ...
        print(f"anthropic-usage: fetch failed: {err}", file=sys.stderr)
        accounts = previous_accounts(target)
    accounts.sort(key=lambda a: a["email"])

    state = {"version": VERSION, "updatedAt": now_ms, "accounts": accounts}
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, target)


if __name__ == "__main__":
    main()
