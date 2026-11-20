"""TeamClaude usage ledger: who used how much of the pooled Claude accounts.

Reads som's TeamClaude metrics from Mimir and writes one JSON file for the
usage pages (./site): per client and hour, the share of ONE account's weekly
quota it used, in "account-weeks" (1.0 = a whole account's week).

Where the numbers come from (./default.nix says the same for Dave):

- The measured truth is each account's weekly utilization as Anthropic
  reports it (`anthropic-ratelimit-unified-7d-*`, which TeamClaude reads on
  every reply and probes every 5 min): teamclaude_account_weekly_utilization,
  0..1 in whole percent. Its rises within one weekly window ARE the quota
  used; a reset (the reset timestamp moves on, or the value falls) starts a
  new window. Small falls inside a window (0.85 -> 0.84) are rounding and
  are ignored by a high-water mark. Caps (accounts[].maxUsage) are taken as
  they are now for the whole range: an account whose cap changed shows its
  earlier rises on the wrong side of "outside" until the range moves on.
- At the switch from the estimate to the per-account split, the first rise
  of each account goes to OUTSIDE (no spend is pending yet): one rise each.
- Each rise is split among the clients that spent on that account since the
  previous rise, weighted by their API-list-price cost
  (teamclaude_client_cost_usd_total{client,account}, from TeamClaude's usage
  history; cache reads, cache writes, input and output priced per model).
  That weighting assumes the subscription quota is metered roughly like the
  API price, which is the best public proxy; the totals per account are
  exact to the 1% steps Anthropic reports, the split among clients is an
  estimate.
- A rise with no gateway spend on that account since the previous one is
  usage outside the gateway (the account owner's own claude.ai/Claude Code),
  booked to OUTSIDE.
- The pool is the subscription (OAuth) accounts the gateway may use: one
  capped below POOL_MIN_CAP (teamclaude-accounts cap) stays its owner's and
  is left out of capacity and use. Capacity = one account-week per pool
  account and week.
- Spend on an upstream gateway account (`fallback`) uses another pool's
  quota; it is converted with the %-per-USD rate measured on our own
  accounts and booked to each client as `fallback`, not against capacity.
  So is gateway spend on an owner's account left out of the pool.
- Unused capacity is measured too: when an own account's window resets,
  whatever it had left (1 - its last utilization) expired unused.
- Before TeamClaude's usage history existed (no cost series yet) there is no
  per-account split: each rise of the pool is shared by the clients' output
  tokens over the same interval ("estimated"), and a rise on an account at or
  above its cap (which the gateway does not use) is OUTSIDE. Before even the
  client counters existed, the pool's rises are UNSPLIT.

Stdlib only; runs as a DynamicUser oneshot on the monitoring server.
"""

import argparse
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request

STEP = 300
HOUR = 3600
OUTSIDE = "(outside gateway)"
# Quota used before the per-client counters existed: measured, not split.
UNSPLIT = "(before per-client data)"
# A reset moves the reset timestamp a whole week on; jitter of a few seconds
# (…:59:59 vs …:00:00) is not one.
RESET_MOVE_S = 86400
# A fall this large inside a window is a reset whose timestamp we missed.
RESET_FALL = 0.05
# Each run recomputes the whole Mimir window, but an hour near its start is
# computed without what came before (the first sample only seeds the
# high-water mark, pending spend starts empty). So hours closer than this to
# the window's start are taken over from the previous file, which computed
# them while they were well inside its window. A week: longer than the gap
# between two 1% rises of a quiet account (whose split needs the spend since
# the previous rise), and the high-water mark is then seeded from a reset.
# main() keeps it to at most half the window.
KEEP_MARGIN = 7 * 86400
# An own account counts in the pool only when the gateway may use most of
# it: one capped lower (teamclaude-accounts cap) is its owner's.
POOL_MIN_CAP = 0.5


def query_range(base, query, start, end, step=STEP, timeout=60):
    """{labels-tuple: {t: value}} for one PromQL range query."""
    params = urllib.parse.urlencode(
        {"query": query, "start": start, "end": end, "step": step}
    )
    with urllib.request.urlopen(f"{base}/query_range?{params}", timeout=timeout) as r:
        body = json.load(r)
    if body.get("status") != "success":
        raise RuntimeError(f"query failed: {query}: {body.get('error')}")
    out = {}
    for s in body["data"]["result"]:
        out[tuple(sorted(s["metric"].items()))] = {
            int(float(t)): float(v) for t, v in s["values"]
        }
    return out


def by_label(series, *names):
    """Re-key {labels-tuple: points} by the given label values."""
    out = {}
    for labels, points in series.items():
        d = dict(labels)
        key = tuple(d.get(n, "") for n in names)
        out[key[0] if len(key) == 1 else key] = points
    return out


def deltas(points, steps):
    """Per-step increase of a counter, a fall read as a reset (like increase())."""
    out = {}
    prev = None
    for t in steps:
        v = points.get(t)
        if v is None:
            continue
        if prev is not None:
            # A counter only resets to ~0; a fall by rounding is no reset.
            d = v - prev if v >= prev - 1e-6 * max(1.0, abs(prev)) else v
            if d > 0:
                out[t] = d
        prev = v
    return out


def account_rises(util, reset, steps, cap=None, on_reset=None):
    """Yield (t, rise, at_cap_before) for one account's weekly utilization.

    `rise` is the quota used since the last rise (high-water mark per
    window); `at_cap_before` is whether the account sat at or above `cap`
    just before it (the gateway sends nothing there, so the rise came from
    outside). `on_reset(t, hw)` is told each new window and the high-water
    mark the old one ended at."""
    hw = None
    last_u = None
    last_r = None
    for t in steps:
        u = util.get(t)
        if u is None:
            continue
        r = reset.get(t)
        if hw is None:
            hw, last_u, last_r = u, u, r
            continue
        moved = r is not None and last_r is not None and r > last_r + RESET_MOVE_S
        if moved or u < hw - RESET_FALL:
            if on_reset:
                on_reset(t, hw)
            hw = 0.0
            last_u = 0.0
        if u > hw + 1e-9:
            yield t, u - hw, (cap is not None and last_u is not None and last_u >= cap - 1e-9)
            hw = u
        last_u = u
        if r is not None:
            last_r = r


class Ledger:
    def __init__(self):
        # (client, hour) -> account-weeks
        self.used = {}
        self.fallback = {}
        self.precise_hours = set()
        # account-weeks that expired unused at a weekly reset, per hour
        self.expired = {}

    def book(self, table, client, t, amount):
        if amount <= 0:
            return
        h = t - t % HOUR
        table[(client, h)] = table.get((client, h), 0.0) + amount


def split(pending, amount):
    tot = sum(pending.values())
    return {c: amount * v / tot for c, v in pending.items() if v > 0} if tot > 0 else {}


def compute(util, reset, cost, tokens, caps, own, steps):
    """The ledger from Mimir series (all keyed by label, points {t: v}).

    util/reset: account -> points; cost: (client, account) -> counter points;
    tokens: client -> output-token counter points (the pre-history fallback);
    caps: account -> maxUsage (missing = 0.98); own: set of our own accounts.
    """
    led = Ledger()
    # Precise wherever the per-account cost series has samples; a gap (the
    # exporter failing on som) falls back to the estimate, rather than
    # booking every rise in it as outside use.
    cost_alive = set()
    for p in cost.values():
        cost_alive.update(p)

    def precise(t):
        return t in cost_alive

    cost_d = {k: deltas(p, steps) for k, p in cost.items()}
    tok_d = {c: deltas(p, steps) for c, p in tokens.items()}

    # Precise: per own account, rises split by that account's client cost.
    own_cost = 0.0
    own_pct = 0.0
    for acct in sorted(own):
        pending = {}
        clients = [c for (c, a) in cost_d if a == acct]
        rises = {
            t: (d, at_cap)
            for t, d, at_cap in account_rises(
                util.get(acct, {}), reset.get(acct, {}), steps, caps.get(acct, 0.98)
            )
        }
        for t in steps:
            if not precise(t):
                continue
            led.precise_hours.add(t - t % HOUR)
            for c in clients:
                v = cost_d[(c, acct)].get(t)
                if v:
                    pending[c] = pending.get(c, 0.0) + v
            if t in rises:
                d, _ = rises[t]
                shares = split(pending, d)
                if shares:
                    own_cost += sum(pending.values())
                    own_pct += d
                    for c, v in shares.items():
                        led.book(led.used, c, t, v)
                else:
                    led.book(led.used, OUTSIDE, t, d)
                pending = {}

    # Upstream gateway accounts: their spend at our own measured rate.
    rate = own_pct / own_cost if own_cost > 0 else None
    if rate is not None:
        for (c, acct), dl in cost_d.items():
            if acct in own or acct not in util:
                continue
            for t, v in dl.items():
                led.book(led.fallback, c, t, v * rate)

    # Unused capacity, measured: what an own account still had at a reset.
    def expire(t, hw):
        h = t - t % HOUR
        led.expired[h] = led.expired.get(h, 0.0) + max(0.0, 1.0 - hw)

    # Estimated: before the cost history, the pool's rises by output tokens.
    pool_rises = {}
    for acct in own:
        for t, d, at_cap in account_rises(
            util.get(acct, {}), reset.get(acct, {}), steps, caps.get(acct, 0.98), expire
        ):
            if precise(t):
                continue
            served, outside = pool_rises.get(t, (0.0, 0.0))
            pool_rises[t] = (served, outside + d) if at_cap else (served + d, outside)
    tok_start = min((min(p) for p in tokens.values() if p), default=None)
    pending = {}
    for t in steps:
        if precise(t):
            pending = {}
            continue
        if tok_start is None or t <= tok_start:
            if t in pool_rises:
                served, outside = pool_rises[t]
                led.book(led.used, OUTSIDE, t, outside)
                led.book(led.used, UNSPLIT, t, served)
            continue
        for c, dl in tok_d.items():
            v = dl.get(t)
            if v:
                pending[c] = pending.get(c, 0.0) + v
        if t in pool_rises:
            served, outside = pool_rises[t]
            led.book(led.used, OUTSIDE, t, outside)
            if served:
                shares = split(pending, served)
                if shares:
                    for c, v in shares.items():
                        led.book(led.used, c, t, v)
                    pending = {}
                else:
                    led.book(led.used, OUTSIDE, t, served)
    return led, rate


def to_json(led, start, end, accounts, rate, previous=None, margin=KEEP_MARGIN):
    """The page's data: hourly arrays from `start` (merged onto older hours
    kept from `previous`, the last file, since Mimir keeps only 30 days)."""
    first = start - start % HOUR
    last = end - end % HOUR
    old_start = None
    old = {}
    n_old = 0
    if previous and previous.get("version") == 1 and previous.get("start", first) <= first:
        old_start = previous["start"]
        n_old = min((first + margin - old_start) // HOUR, previous.get("hours", 0))
        for kind in ("used", "fallback"):
            for c, arr in previous.get(kind, {}).items():
                old.setdefault(kind, {})[c] = arr[:n_old]
        old["method"] = previous.get("method", [])[:n_old]
        old["expired"] = previous.get("expired", [])[:n_old]
    base = old_start if old_start is not None else first
    n = (last - base) // HOUR + 1
    # New values only from here on; before it, the previous file's.
    off = n_old

    def arrays(table, kind):
        out = {}
        for c, arr in old.get(kind, {}).items():
            out[c] = arr + [0.0] * (n - len(arr))
        for (c, h), v in table.items():
            i = (h - base) // HOUR
            if off <= i < n:
                out.setdefault(c, [0.0] * n)[i] += v
        return {c: [round(x, 6) for x in arr] for c, arr in out.items() if any(arr)}

    expired = old.get("expired") or []
    expired = expired + [0.0] * (n - len(expired))
    for h, v in led.expired.items():
        i = (h - base) // HOUR
        if off <= i < n:
            expired[i] += v
    method = (old.get("method") or []) + [0] * (n - len(old.get("method") or []))
    for i in range(off, n):
        method[i] = 0
    for h in led.precise_hours:
        i = (h - base) // HOUR
        if off <= i < n:
            method[i] = 1
    return {
        "version": 1,
        "generated": int(time.time()),
        "unit": "account-week",
        "start": base,
        "step": HOUR,
        "hours": n,
        "outside": OUTSIDE,
        "unsplit": UNSPLIT,
        "accounts": accounts,
        "capacity": sum(1 for a in accounts if a["pool"]),
        "usdPerAccountWeek": (1 / rate) if rate else None,
        "used": arrays(led.used, "used"),
        "fallback": arrays(led.fallback, "fallback"),
        "method": method,
        "expired": [round(x, 6) for x in expired],
    }


def latest(points_by_key):
    """The last value of each series, keyed as given."""
    return {k: p[max(p)] for k, p in points_by_key.items() if p}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--mimir", required=True, help=".../prometheus/api/v1")
    ap.add_argument("--days", type=int, default=29)
    ap.add_argument("--out", required=True)
    ap.add_argument("--now", type=int, default=None, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)

    end = a.now if a.now is not None else int(time.time())
    end -= end % STEP
    start = end - a.days * 86400
    q = lambda e: query_range(a.mimir, e, start, end)  # noqa: E731
    util = by_label(q("max by (account) (teamclaude_account_weekly_utilization)"), "account")
    reset = by_label(q("max by (account) (teamclaude_account_weekly_reset_timestamp_seconds)"), "account")
    cost = by_label(q("sum by (client, account) (teamclaude_client_cost_usd_total)"), "client", "account")
    tokens = by_label(q("sum by (client) (teamclaude_client_output_tokens_total)"), "client")
    caps = latest(by_label(q("max by (account) (teamclaude_account_max_usage)"), "account"))
    info = {}
    for labels, p in q("max by (account, type, tier) (teamclaude_account_info)").items():
        d = dict(labels)
        info[d["account"]] = d
    # Own = a subscription (OAuth) account; before the info metric existed,
    # those are the ones named by their login email.
    subscriptions = {
        acct for acct in util
        if (info[acct].get("type") == "oauth" if acct in info else "@" in acct)
    }
    own = {a for a in subscriptions if caps.get(a, 0.98) >= POOL_MIN_CAP}
    steps = list(range(start, end + 1, STEP))
    led, rate = compute(util, reset, cost, tokens, caps, own, steps)

    last_util = latest(util)
    last_reset = latest(reset)
    accounts = [
        {
            "name": acct,
            "own": acct in subscriptions,
            "pool": acct in own,
            "tier": info.get(acct, {}).get("tier") or None,
            "cap": caps.get(acct),
            "util": last_util.get(acct),
            "resetAt": int(last_reset[acct]) if acct in last_reset else None,
        }
        for acct in sorted(util)
    ]
    previous = None
    try:
        with open(a.out) as f:
            previous = json.load(f)
    except (OSError, ValueError):
        pass
    data = to_json(led, start, end, accounts, rate, previous, min(KEEP_MARGIN, a.days * 86400 // 2))
    tmp = a.out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, a.out)
    total = sum(sum(v) for v in data["used"].values())
    print(f"ledger: {len(data['used'])} clients, {data['hours']} hours, "
          f"{total:.2f} account-weeks used, rate {rate}", file=sys.stderr)


if __name__ == "__main__":
    main()
