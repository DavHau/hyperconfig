"""searxng-canary: does a SearXNG instance answer with relevant results?

Sends a fixed set of test queries (no user data) to a SearXNG instance's
JSON API, the way hermes' web_search does (q, format=json, pageno=1), and
judges each answer cheaply:
  - a query is *relevant* when one of its expected domains is in the top 5
    result URLs (hermes keeps the top 5 by score);
  - per engine that answered, its own top 5 is *on topic* when at least 2
    of them name an expected domain or one of the query's terms (URL or
    title). An engine that answers but is on topic for at most half the
    queries it answered is *junk*: an engine serving unrelated results
    (Bing from a flagged IP) fills the top 5 with them even when another
    engine's results still put one expected domain in, which the
    per-query check alone misses.

  searxng-canary --url URL [--queries N] [--rotate SECONDS]
                 [--min-relevant N] [--min-engines K] [--max-junk J]
                 [--engines a,b] [--per-engine a,b,...] [--language L]
                 [--exclude a,b] [--prom FILE] [--json] [--replay FILE]
                 [--expect-instance NAME] [--expect-version V]

Verdict (exit 0 = pass): at least --min-relevant queries relevant, at
least --min-engines engines on topic, at most --max-junk junk engines.
--queries N takes N of the fixed queries from --start (default 0);
--rotate S starts at the slot of the current time (epoch // S), so one
query per run cycles through all of them, give or take a repeat when
runs drift (a host whose engines run on paid proxy traffic sends one).
--per-engine runs every query against each named engine alone
(`engines=<name>`) and prints a table; it is a probe, no verdict.
--replay FILE answers from a recorded {query: SearXNG JSON} file instead
of a URL (the check's fixtures); --url is then ignored.
--expect-instance/--expect-version first read the instance's /config and
refuse (exit 2, no queries) unless its instance_name / version are exactly
these: a gate that started a scratch instance proves it talks to that one,
not to a stale process left on the port.
--exclude leaves the named engines out of every query (SearXNG's
`disabled_engines=<name>__general`): engines whose traffic is paid (the
residential proxy's) stay out of the canary's fixed queries. It does not
apply to an explicit --engines/--per-engine list (SearXNG ignores
disabled_engines for named engines).
--prom writes Prometheus text-format metrics (renamed into place) for a
textfile collector; the verdict still sets the exit code.

Standard library only: it runs with whatever python3 the caller has.
"""

import argparse
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# (query, expected domain substrings, on-topic terms). Real-world queries
# like the agents' (a product page, documentation, local news in another
# language), whose answer sites are stable for years. Terms are lowercase
# substrings of a URL or title that only an on-topic result carries.
QUERIES = [
    ("dialog sri lanka prepaid plans", ["dialog.lk"], ["dialog"]),
    ("nixos manual", ["nixos.org", "nixos.wiki", "nix.dev"], ["nixos"]),
    ("berita banjir jakarta", ["detik.com", "kompas.com", "jakarta.go.id", "cnnindonesia.com", "tempo.co",
                               "antaranews.com", "liputan6.com", "kumparan.com", "tribunnews.com", "bpbd"],
     ["banjir"]),
    ("python asyncio gather", ["docs.python.org", "stackoverflow.com", "realpython.com", "superfastpython.com"],
     ["asyncio"]),
    ("singapore haze psi today", ["haze.gov.sg", "nea.gov.sg", "psi.sg", "straitstimes.com"], ["haze"]),
    ("rust borrow checker", ["rust-lang.org", "stackoverflow.com", "wikipedia.org"], ["borrow"]),
]


# --source: the local address to connect from (a sandboxed instance that
# admits only one loopback peer address, ./candidate.nix).
SOURCE = None


class _SourceHTTPConnection(http.client.HTTPConnection):
    def __init__(self, *a, **kw):
        kw["source_address"] = (SOURCE, 0)
        super().__init__(*a, **kw)


class _SourceHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_SourceHTTPConnection, req)


def urlopen(req, timeout):
    if SOURCE:
        return urllib.request.build_opener(_SourceHandler).open(req, timeout=timeout)
    return urllib.request.urlopen(req, timeout=timeout)


EXCLUDE = []
REPLAY = None


def search(url, query, engines=None, language=None, timeout=20):
    if REPLAY is not None:
        if query not in REPLAY:
            return {"error": f"replay: no recorded answer for {query!r}", "seconds": 0}
        return dict(REPLAY[query], seconds=0)
    args = {"q": query, "format": "json", "pageno": "1"}
    if EXCLUDE:
        args["disabled_engines"] = ",".join(f"{e}__general" for e in EXCLUDE)
    if engines:
        args["engines"] = engines
    if language:
        args["language"] = language
    req = urllib.request.Request(
        url.rstrip("/") + "/search?" + urllib.parse.urlencode(args),
        headers={"Accept": "application/json"},
    )
    t0 = time.monotonic()
    try:
        with urlopen(req, timeout) as r:
            data = json.load(r)
    except (urllib.error.URLError, OSError, ValueError) as e:
        return {"error": f"{type(e).__name__}: {e}", "seconds": time.monotonic() - t0}
    data["seconds"] = time.monotonic() - t0
    return data


def instance_config(url, timeout=10):
    req = urllib.request.Request(url.rstrip("/") + "/config", headers={"Accept": "application/json"})
    with urlopen(req, timeout) as r:
        return json.load(r)


def on_topic(r, expected, terms):
    text = ((r.get("url") or "") + " " + (r.get("title") or "")).lower()
    return any(e in text for e in expected) or any(t in text for t in terms)


def judge(data, expected, terms, only=None):
    results = data.get("results") or []
    if only:
        # engines= with an unknown or disabled name falls back to the whole
        # category: count only what the probed engine itself returned.
        results = [r for r in results if only in (r.get("engines") or [])]
    ranked = sorted(results, key=lambda r: r.get("score") or 0, reverse=True)
    urls = [r.get("url") or "" for r in ranked[:5]]
    relevant = any(e in u.lower() for u in urls for e in expected)
    engines = sorted({e for r in results for e in (r.get("engines") or [])})
    # per engine: how many of its own top 5 are on topic
    per_engine = {}
    for eng in engines:
        own = [r for r in ranked if eng in (r.get("engines") or [])][:5]
        hits = sum(1 for r in own if on_topic(r, expected, terms))
        per_engine[eng] = {"top": len(own), "on_topic": hits, "ok": hits >= min(2, len(own))}
    unresp = [list(u) for u in data.get("unresponsive_engines") or []]
    return {
        "n": len(results),
        "relevant": relevant,
        "engines": engines,
        "per_engine": per_engine,
        "unresponsive": unresp,
        "top": urls,
        "error": data.get("error"),
        "seconds": round(data.get("seconds", 0), 2),
    }


def write_prom(path, summary):
    def esc(s):
        return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")

    def reason(err):
        # SearXNG's free text names URLs, ids and counts ("HTTP error 429",
        # "timeout (6.0s)"): only a short class of it becomes a label value,
        # so the series stay few.
        e = str(err).lower()
        for key, cls in (("captcha", "captcha"), ("too many requests", "429"), ("429", "429"),
                         ("403", "403"), ("access denied", "403"), ("timeout", "timeout"),
                         ("suspended", "suspended"), ("parsing", "parse"), ("ssl", "tls"),
                         ("http", "http"), ("connect", "connection")):
            if key in e:
                return cls
        return "other"

    lines = [
        "# HELP searxng_canary_queries Canary queries sent this run.",
        "# TYPE searxng_canary_queries gauge",
        f"searxng_canary_queries {summary['queries']}",
        "# HELP searxng_canary_relevant_queries Queries with an expected domain in the top 5.",
        "# TYPE searxng_canary_relevant_queries gauge",
        f"searxng_canary_relevant_queries {summary['relevant']}",
        "# HELP searxng_canary_results Results summed over all canary queries.",
        "# TYPE searxng_canary_results gauge",
        f"searxng_canary_results {summary['results']}",
        "# HELP searxng_canary_engines_answering Distinct engines that contributed results.",
        "# TYPE searxng_canary_engines_answering gauge",
        f"searxng_canary_engines_answering {len(summary['engines'])}",
        "# HELP searxng_canary_engines_relevant Engines whose own top 5 was on topic (more than half of the queries they answered).",
        "# TYPE searxng_canary_engines_relevant gauge",
        f"searxng_canary_engines_relevant {len(summary['relevant_engines'])}",
        "# HELP searxng_canary_engines_junk Engines that answered with off-topic results.",
        "# TYPE searxng_canary_engines_junk gauge",
        f"searxng_canary_engines_junk {len(summary['junk_engines'])}",
        "# HELP searxng_canary_engines_unresponsive Distinct engines SearXNG reported unresponsive or suspended.",
        "# TYPE searxng_canary_engines_unresponsive gauge",
        f"searxng_canary_engines_unresponsive {len(summary['unresponsive'])}",
        "# HELP searxng_canary_engine_unresponsive 1 per engine reported unresponsive, with a short class of SearXNG's error.",
        "# TYPE searxng_canary_engine_unresponsive gauge",
    ]
    for eng, err in sorted(summary["unresponsive"].items()):
        lines.append(f'searxng_canary_engine_unresponsive{{engine="{esc(str(eng)[:40])}",reason="{reason(err)}"}} 1')
    lines += [
        "# HELP searxng_canary_engine_answering 1 per engine that contributed results.",
        "# TYPE searxng_canary_engine_answering gauge",
    ]
    for eng in summary["engines"]:
        lines.append(f'searxng_canary_engine_answering{{engine="{esc(str(eng)[:40])}"}} 1')
    lines += [
        "# HELP searxng_canary_engine_junk 1 per engine that answered with off-topic results.",
        "# TYPE searxng_canary_engine_junk gauge",
    ]
    for eng in summary["junk_engines"]:
        lines.append(f'searxng_canary_engine_junk{{engine="{esc(str(eng)[:40])}"}} 1')
    lines += [
        "# HELP searxng_canary_last_run_timestamp_seconds When the canary last ran.",
        "# TYPE searxng_canary_last_run_timestamp_seconds gauge",
        f"searxng_canary_last_run_timestamp_seconds {int(time.time())}",
    ]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def pick(args):
    start = int(time.time() // args.rotate) if args.rotate else args.start
    n = min(args.queries, len(QUERIES))
    return [QUERIES[(start + i) % len(QUERIES)] for i in range(n)]


def per_engine(args, engines):
    queries = pick(args)
    rows = []
    for eng in engines:
        rel = n = 0
        errs = set()
        secs = 0.0
        for q, exp, terms in queries:
            j = judge(search(args.url, q, eng, args.language), exp, terms, only=eng)
            rel += j["per_engine"].get(eng, {}).get("ok", False)
            n += j["n"]
            secs += j["seconds"]
            errs.update(e for en, e, *_ in j["unresponsive"] if en == eng)
            if j["error"]:
                errs.add(j["error"])
            time.sleep(args.pause)
        rows.append({"engine": eng, "relevant": rel, "queries": len(queries), "results": n,
                     "seconds": round(secs / len(queries), 1), "errors": sorted(errs)})
    if args.json:
        json.dump(rows, sys.stdout, indent=1)
        print()
    else:
        print("| engine | on topic/queries | results | avg s | errors |\n|---|---|---|---|---|")
        for r in rows:
            print(f"| {r['engine']} | {r['relevant']}/{r['queries']} | {r['results']} | {r['seconds']} | {'; '.join(r['errors'])} |")
    return 0


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--url", required=True)
    ap.add_argument("--queries", type=int, default=4, help="how many of the fixed queries to send")
    ap.add_argument("--rotate", type=float, help="start at query (epoch // SECONDS): cycle through all over runs")
    ap.add_argument("--start", type=int, default=0, help="without --rotate: index of the first query")
    ap.add_argument("--min-relevant", type=int, default=3)
    ap.add_argument("--min-engines", type=int, default=2, help="engines on topic, at least")
    ap.add_argument("--max-junk", type=int, default=0, help="engines answering off topic, at most")
    ap.add_argument("--engines", help="comma list passed as engines= (default: the general category)")
    ap.add_argument("--per-engine", help="comma list: probe each engine alone, print a table")
    ap.add_argument("--language")
    ap.add_argument("--pause", type=float, default=1.0, help="seconds between queries")
    ap.add_argument("--prom")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--expect-instance", help="refuse unless /config's instance_name is exactly this")
    ap.add_argument("--expect-version", help="refuse unless /config's version is exactly this")
    ap.add_argument("--source", help="local address to connect from")
    ap.add_argument("--exclude", help="comma list of engines left out of every query")
    ap.add_argument("--replay", help="answer from a recorded {query: SearXNG JSON} file")
    args = ap.parse_args()
    global SOURCE, EXCLUDE, REPLAY
    SOURCE = args.source
    EXCLUDE = [e for e in (args.exclude or "").split(",") if e]
    if args.replay:
        with open(args.replay) as f:
            REPLAY = json.load(f)

    if args.expect_instance is not None or args.expect_version is not None:
        try:
            cfg = instance_config(args.url)
        except (urllib.error.URLError, OSError, ValueError) as e:
            print(f"searxng-canary: REFUSED: no /config from {args.url}: {type(e).__name__}: {e}")
            return 2
        for key, want in (("instance_name", args.expect_instance), ("version", args.expect_version)):
            if want is not None and cfg.get(key) != want:
                print(f"searxng-canary: REFUSED: {key} is {cfg.get(key)!r}, expected {want!r}: not the instance under test")
                return 2

    if args.per_engine:
        return per_engine(args, args.per_engine.split(","))

    queries = pick(args)
    per_query = []
    engines = set()
    unresponsive = {}
    answered = {}  # engine -> [queries answered, on topic]
    for i, (q, exp, terms) in enumerate(queries):
        if i and not REPLAY:
            time.sleep(args.pause)
        j = judge(search(args.url, q, args.engines, args.language), exp, terms)
        j["query"] = q
        per_query.append(j)
        engines.update(j["engines"])
        for eng, pe in j["per_engine"].items():
            a = answered.setdefault(eng, [0, 0])
            a[0] += 1
            a[1] += pe["ok"]
        for eng, err, *_ in j["unresponsive"]:
            unresponsive[eng] = err
    relevant_engines = sorted(e for e, (n, ok) in answered.items() if ok * 2 > n)
    junk_engines = sorted(e for e, (n, ok) in answered.items() if ok * 2 <= n)
    summary = {
        "queries": len(queries),
        "answered": sum(1 for j in per_query if not j["error"]),
        "relevant": sum(1 for j in per_query if j["relevant"]),
        "results": sum(j["n"] for j in per_query),
        "engines": sorted(engines),
        "relevant_engines": relevant_engines,
        "junk_engines": junk_engines,
        "unresponsive": unresponsive,
    }
    ok = all((summary["relevant"] >= args.min_relevant,
              len(relevant_engines) >= args.min_engines,
              len(junk_engines) <= args.max_junk))
    summary["verdict"] = "pass" if ok else "fail"
    if args.prom:
        write_prom(args.prom, summary)
    if args.json:
        json.dump({"summary": summary, "queries": per_query}, sys.stdout, indent=1)
        print()
    else:
        for j in per_query:
            err = f" error={j['error']}" if j["error"] else ""
            pe = " ".join(f"{e}={v['on_topic']}/{v['top']}" for e, v in j["per_engine"].items())
            print(f"{'ok ' if j['relevant'] else 'BAD'} n={j['n']:3} {j['seconds']:5}s {j['query']!r} on topic: {pe or '-'}{err}")
        print(f"engines answering: {summary['engines']}")
        print(f"engines on topic: {relevant_engines}; junk: {junk_engines}")
        print(f"unresponsive: {unresponsive}")
        print(f"searxng-canary: {summary['verdict'].upper()} "
              f"({summary['relevant']}/{summary['queries']} relevant, {len(relevant_engines)} engines on topic, "
              f"{len(junk_engines)} junk; need {args.min_relevant}, {args.min_engines}, at most {args.max_junk})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
