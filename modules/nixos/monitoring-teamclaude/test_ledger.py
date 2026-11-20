"""Tests for ledger.py: python3 test_ledger.py (the flake check runs it)."""

import json
import os
import tempfile
import unittest

import ledger as L

S = L.STEP


def steps(n):
    return list(range(0, n * S, S))


def series(vals):
    """{t: v} from a list with None gaps, one value per step."""
    return {i * S: v for i, v in enumerate(vals) if v is not None}


def total(led, client):
    return sum(v for (c, _), v in led.used.items() if c == client)


class Rises(unittest.TestCase):
    def test_reset_rounding_and_cap(self):
        util = series([0.50, 0.52, 0.51, 0.53, 0.98, 0.98, 0.99, 0.0, 0.02])
        reset = series([100] * 7 + [100 + 7 * 86400] * 2)
        got = list(L.account_rises(util, reset, steps(9), cap=0.98))
        # 0.52->0.51 is rounding (no rise, no new window); 0.51->0.53 rises
        # only over the high-water mark 0.52; a rise from the cap is outside.
        self.assertEqual([round(d, 4) for _, d, _ in got], [0.02, 0.01, 0.45, 0.01, 0.02])
        self.assertEqual([c for _, _, c in got], [False, False, False, True, False])

    def test_missed_reset_by_fall(self):
        # The fall starts a new window: its first 10% and the next 10% count.
        got = list(L.account_rises(series([0.9, 0.1, 0.2]), {}, steps(3)))
        self.assertEqual([round(d, 4) for _, d, _ in got], [0.1, 0.1])


class Compute(unittest.TestCase):
    def test_precise_split_outside_and_fallback(self):
        n = 6
        util = {"a@x": series([0.10, 0.10, 0.13, 0.13, 0.15, 0.15]),
                "fallback": series([0.0] * n)}
        reset = {"a@x": series([1000] * n)}
        cost = {
            # alice spends 2 USD, bob 1 USD before the 3% rise: 2% / 1%.
            ("alice", "a@x"): series([0, 1, 2, 2, 2, 2]),
            ("bob", "a@x"): series([0, 1, 1, 1, 1, 1]),
            # carol on the fallback gateway: 6 USD, at 3%/3 USD = 6%.
            ("carol", "fallback"): series([0, 0, 0, 6, 6, 6]),
        }
        led, rate = L.compute(util, reset, cost, {}, {"a@x": 0.98}, {"a@x"}, steps(n))
        self.assertAlmostEqual(total(led, "alice"), 0.02)
        self.assertAlmostEqual(total(led, "bob"), 0.01)
        # 0.13 -> 0.15 with nothing spent through the gateway: outside.
        self.assertAlmostEqual(total(led, L.OUTSIDE), 0.02)
        assert rate is not None
        self.assertAlmostEqual(rate, 0.01)
        self.assertAlmostEqual(sum(led.fallback.values()), 0.06)
        self.assertNotIn("carol", {c for c, _ in led.used})

    def test_estimated_before_cost_history(self):
        n = 8
        util = {"a@x": series([0.10, 0.11, 0.12, 0.98, 0.99, 0.99, 0.99, 0.99]),
                "b@x": series([0.20, 0.20, 0.22, 0.22, 0.22, 0.22, 0.22, 0.22])}
        tokens = {"alice": series([None, 0, 300, 300, 300, 300, 300, 300]),
                  "bob": series([None, 0, 100, 100, 100, 100, 100, 100])}
        led, _ = L.compute(util, {}, {}, tokens, {}, {"a@x", "b@x"}, steps(n))
        # The first rise predates the client counters: unsplit.
        self.assertAlmostEqual(total(led, L.UNSPLIT), 0.01)
        # 0.01 + 0.02 at step 2 shared 3:1 by output tokens.
        self.assertAlmostEqual(total(led, "alice"), 0.0225)
        self.assertAlmostEqual(total(led, "bob"), 0.0075)
        # 0.12 -> 0.98 at step 3: no tokens since step 2, so outside; then
        # 0.98 -> 0.99 from the cap: outside too.
        self.assertAlmostEqual(total(led, L.OUTSIDE), 0.86 + 0.01)
        self.assertEqual(led.expired, {})
        sumall = sum(led.used.values())
        self.assertAlmostEqual(sumall, 0.01 + 0.03 + 0.87)

    def test_gap_in_cost_history_is_estimated(self):
        n = 5
        util = {"a@x": series([0.10, 0.11, 0.12, 0.13, 0.14])}
        cost = {("alice", "a@x"): series([0, 1, None, None, 2])}
        tokens = {"bob": series([0, 0, 0, 5, 5])}
        led, _ = L.compute(util, {}, cost, tokens, {}, {"a@x"}, steps(n))
        # step 1 precise (alice); step 3 in the gap, estimated (bob's
        # tokens); step 2 in the gap with no tokens yet, outside; step 4
        # precise again (alice).
        self.assertAlmostEqual(total(led, "alice"), 0.02)
        self.assertAlmostEqual(total(led, "bob"), 0.01)
        self.assertAlmostEqual(total(led, L.OUTSIDE), 0.01)

    def test_expired_at_reset(self):
        util = {"a@x": series([0.5, 0.7, 0.0, 0.1])}
        reset = {"a@x": series([1000, 1000, 1000 + 7 * 86400, 1000 + 7 * 86400])}
        led, _ = L.compute(util, reset, {}, {}, {}, {"a@x"}, steps(4))
        self.assertAlmostEqual(sum(led.expired.values()), 0.3)

    def test_to_json_keeps_older_history(self):
        led = L.Ledger()
        led.book(led.used, "alice", 10 * L.HOUR, 0.5)
        led.precise_hours.add(10 * L.HOUR)
        led.book(led.used, "alice", 40 * L.HOUR, 0.5)
        led.precise_hours.add(40 * L.HOUR)
        led.expired[39 * L.HOUR] = 0.25
        prev = {"version": 1, "start": 0, "hours": 36, "used": {"old": [0.1] * 36}, "fallback": {},
                "method": [0] * 36, "expired": [0.5] + [0.0] * 35}
        acc = [{"name": "a@x", "own": True, "pool": True}, {"name": "b@x", "own": True, "pool": False}]
        d = L.to_json(led, 8 * L.HOUR, 41 * L.HOUR, acc, None, prev, margin=86400)
        self.assertEqual(d["start"], 0)
        self.assertEqual(d["hours"], 42)
        # Hours up to `margin` (a day here) past the new window's start come
        # from the old file (computed with context), the rest is new.
        keep = 8 + 86400 // L.HOUR
        self.assertEqual(d["used"]["old"][:keep], [0.1] * keep)
        self.assertEqual(d["used"]["old"][keep:], [0.0] * (42 - keep))
        self.assertLess(10, keep)  # hour 10 is kept, not recomputed
        self.assertNotIn(10, [i for i, v in enumerate(d["used"].get("alice", [])) if v])
        self.assertEqual(d["used"]["alice"][40], 0.5)
        self.assertEqual(d["method"][40], 1)
        self.assertEqual(d["capacity"], 1)
        self.assertEqual(d["expired"][0], 0.5)
        self.assertEqual(d["expired"][39], 0.25)

    def test_sliding_window_keeps_true_history(self):
        """A steady 1%/5 min client, run every hour over a sliding window:
        the hours kept from earlier files equal the live ones."""
        days, hours = 2, 24 * 4
        led_all = {}
        prev = None
        for run in range(days * 24 + 1, hours + 1):
            end = run * L.HOUR
            start = end - days * 86400
            st = list(range(start, end + 1, S))
            util = {"a@x": {t: (t // S % 2000) * 0.0001 for t in st}}
            reset = {"a@x": {t: 10 ** 9 for t in st}}
            cost = {("alice", "a@x"): {t: float(t // S) for t in st}}
            led, rate = L.compute(util, reset, cost, {}, {}, {"a@x"}, st)
            prev = L.to_json(led, start, end, [{"name": "a@x", "own": True, "pool": True}], rate, prev, margin=86400)
        arr = prev["used"]["alice"]
        # 12 steps of 0.0001 per full hour, everywhere but the very first hours
        # of the first window (no context there yet).
        full = [round(x, 6) for x in arr[2:-1]]
        self.assertEqual(set(full), {0.0012})


class Main(unittest.TestCase):
    def test_main_end_to_end(self):
        """main() against a stubbed Mimir, the fields the pages read."""
        now = 10 * 86400
        st = list(range(now - 2 * 86400, now + 1, S))

        def fake(base, query, start, end, step=S, timeout=60):
            def mk(labels, f):
                return {tuple(sorted(labels.items())): {t: f(t) for t in st}}
            if "weekly_utilization" in query:
                return {**mk({"account": "a@x"}, lambda t: (t - st[0]) // S * 0.001),
                        **mk({"account": "own@x"}, lambda t: 0.3),
                        **mk({"account": "fallback"}, lambda t: 0.1)}
            if "reset_timestamp" in query:
                return {**mk({"account": "a@x"}, lambda t: now + 86400),
                        **mk({"account": "own@x"}, lambda t: now + 86400)}
            if "cost_usd" in query:
                return mk({"client": "alice", "account": "a@x"}, lambda t: float(t))
            if "output_tokens" in query:
                return mk({"client": "alice"}, lambda t: float(t))
            if "max_usage" in query:
                return {**mk({"account": "a@x"}, lambda t: 0.98), **mk({"account": "own@x"}, lambda t: 0.01)}
            if "account_info" in query:
                return {**mk({"account": "a@x", "type": "oauth", "tier": "default_claude_max_20x"}, lambda t: 1),
                        **mk({"account": "own@x", "type": "oauth", "tier": "default_claude_max_20x"}, lambda t: 1),
                        **mk({"account": "fallback", "type": "apikey", "tier": ""}, lambda t: 1)}
            raise AssertionError(query)

        orig = L.query_range
        L.query_range = fake
        try:
            with tempfile.TemporaryDirectory() as tmp:
                out = os.path.join(tmp, "data.json")
                L.main(["--mimir", "http://x", "--days", "2", "--out", out, "--now", str(now)])
                with open(out) as f:
                    d = json.load(f)
        finally:
            L.query_range = orig
        # own@x is capped at 1%: its owner's, not the pool's.
        self.assertEqual(d["capacity"], 1)
        acc = {a["name"]: a for a in d["accounts"]}
        self.assertEqual(acc["own@x"]["pool"], False)
        self.assertEqual(acc["own@x"]["own"], True)
        self.assertEqual(acc["a@x"]["tier"], "default_claude_max_20x")
        self.assertEqual(acc["fallback"]["own"], False)
        self.assertEqual(acc["a@x"]["resetAt"], now + 86400)
        self.assertAlmostEqual(sum(d["used"]["alice"]), (len(st) - 1) * 0.001, places=4)
        self.assertEqual(set(d["method"]), {1})


if __name__ == "__main__":
    unittest.main()
