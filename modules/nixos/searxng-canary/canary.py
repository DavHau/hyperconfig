"""searxng-canary: does a SearXNG instance answer with relevant results?

Sends a fixed set of test queries (no user data) to a SearXNG instance's
JSON API, the way hermes' web_search does (q, format=json, pageno=1), and
judges each answer cheaply: a query is *relevant* when one of its expected
domains is in the top 5 result URLs (hermes keeps the top 5 by score).

  searxng-canary --url URL [--queries N] [--min-relevant N] [--min-engines K]
                 [--engines a,b] [--per-engine a,b,...] [--language L]
                 [--prom FILE] [--json]
                 [--expect-instance NAME] [--expect-version V]

Verdict (exit 0 = pass): at least --min-relevant queries relevant, and
the results of all queries together came from at least --min-engines
distinct engines. --per-engine runs every query against each named engine
alone (`engines=<name>`) and prints a table; it is a probe, no verdict.
--expect-instance/--expect-version first read the instance's /config and
refuse (exit 2, no queries) unless its instance_name / version are exactly
these: a gate that started a scratch instance proves it talks to that one,
not to a stale process left on the port.
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

# (query, expected domain substrings). General-knowledge technical queries
# whose answer sites are stable for years; an engine returning junk (Bing
# without a market) misses them.
QUERIES = [
    ("nixos ipp-usb printer", ["nixos.org", "nixos.wiki", "mynixos.com", "github.com/nixos", "search.nixos"]),
    ("python asyncio gather", ["docs.python.org", "stackoverflow.com", "realpython.com", "superfastpython.com"]),
    ("rust borrow checker", ["rust-lang.org", "doc.rust-lang.org", "stackoverflow.com", "wikipedia.org"]),
    ("home assistant voice preview edition wake word", ["home-assistant.io", "nabucasa.com", "github.com"]),
    ("singapore mrt map", ["lta.gov.sg", "wikipedia.org", "smrt.com.sg", "mrt.sg", "transitlink"]),
    ("curl_cffi impersonate", ["github.com/lexiforest", "curl-cffi.readthedocs.io", "pypi.org"]),
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


def search(url, query, engines=None, language=None, timeout=20):
    args = {"q": query, "format": "json", "pageno": "1"}
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


def judge(data, expected, only=None):
    results = data.get("results") or []
    if only:
        # engines= with an unknown or disabled name falls back to the whole
        # category: count only what the probed engine itself returned.
        results = [r for r in results if only in (r.get("engines") or [])]
    top = sorted(results, key=lambda r: r.get("score") or 0, reverse=True)[:5]
    urls = [r.get("url") or "" for r in top]
    relevant = any(e in u.lower() for u in urls for e in expected)
    engines = sorted({e for r in results for e in (r.get("engines") or [])})
    unresp = [list(u) for u in data.get("unresponsive_engines") or []]
    return {
        "n": len(results),
        "relevant": relevant,
        "engines": engines,
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
        "# HELP searxng_canary_last_run_timestamp_seconds When the canary last ran.",
        "# TYPE searxng_canary_last_run_timestamp_seconds gauge",
        f"searxng_canary_last_run_timestamp_seconds {int(time.time())}",
    ]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def per_engine(args, engines):
    queries = QUERIES[: args.queries]
    rows = []
    for eng in engines:
        rel = n = 0
        errs = set()
        secs = 0.0
        for q, exp in queries:
            j = judge(search(args.url, q, eng, args.language), exp, only=eng)
            rel += j["relevant"]
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
        print("| engine | relevant/queries | results | avg s | errors |\n|---|---|---|---|---|")
        for r in rows:
            print(f"| {r['engine']} | {r['relevant']}/{r['queries']} | {r['results']} | {r['seconds']} | {'; '.join(r['errors'])} |")
    return 0


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--url", required=True)
    ap.add_argument("--queries", type=int, default=4, help="how many of the fixed queries to send")
    ap.add_argument("--min-relevant", type=int, default=3)
    ap.add_argument("--min-engines", type=int, default=2)
    ap.add_argument("--engines", help="comma list passed as engines= (default: the general category)")
    ap.add_argument("--per-engine", help="comma list: probe each engine alone, print a table")
    ap.add_argument("--language")
    ap.add_argument("--pause", type=float, default=1.0, help="seconds between queries")
    ap.add_argument("--prom")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--expect-instance", help="refuse unless /config's instance_name is exactly this")
    ap.add_argument("--expect-version", help="refuse unless /config's version is exactly this")
    ap.add_argument("--source", help="local address to connect from")
    args = ap.parse_args()
    global SOURCE
    SOURCE = args.source

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

    queries = QUERIES[: args.queries]
    per_query = []
    engines = set()
    unresponsive = {}
    for i, (q, exp) in enumerate(queries):
        if i:
            time.sleep(args.pause)
        j = judge(search(args.url, q, args.engines, args.language), exp)
        j["query"] = q
        per_query.append(j)
        engines.update(j["engines"])
        for eng, err, *_ in j["unresponsive"]:
            unresponsive[eng] = err
    summary = {
        "queries": len(queries),
        "answered": sum(1 for j in per_query if not j["error"]),
        "relevant": sum(1 for j in per_query if j["relevant"]),
        "results": sum(j["n"] for j in per_query),
        "engines": sorted(engines),
        "unresponsive": unresponsive,
    }
    ok = summary["relevant"] >= args.min_relevant and len(engines) >= args.min_engines
    summary["verdict"] = "pass" if ok else "fail"
    if args.prom:
        write_prom(args.prom, summary)
    if args.json:
        json.dump({"summary": summary, "queries": per_query}, sys.stdout, indent=1)
        print()
    else:
        for j in per_query:
            err = f" error={j['error']}" if j["error"] else ""
            print(f"{'ok ' if j['relevant'] else 'BAD'} n={j['n']:3} {j['seconds']:5}s {j['query']!r} engines={j['engines']}{err}")
        print(f"engines answering: {summary['engines']}")
        print(f"unresponsive: {unresponsive}")
        print(f"searxng-canary: {summary['verdict'].upper()} "
              f"({summary['relevant']}/{summary['queries']} relevant, {len(engines)} engines; "
              f"need {args.min_relevant} and {args.min_engines})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
