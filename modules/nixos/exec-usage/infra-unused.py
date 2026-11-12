"""infra-unused: installed packages nobody exec'd lately, and where they come from.

Joins three things:
  - /etc/exec-usage/package-sources.json (built with the system): every
    environment.systemPackages entry, its store outputs, and the files
    (hyperconfig:<path> or <input>:<path>) whose definitions add it;
  - each package's executables (<output>/bin/*, resolved through symlinks
    the same way the tracer resolves exec'd paths);
  - /var/lib/exec-usage/usage.json from exec-usage.service.
"""
import argparse
import json
import os
import re
import socket
import sys
import time

SOURCES = os.environ.get("EXEC_USAGE_SOURCES", "/etc/exec-usage/package-sources.json")
USAGE = os.environ.get("EXEC_USAGE_STATE", "/var/lib/exec-usage/usage.json")
HUMANS = os.environ.get("EXEC_USAGE_HUMANS", "/etc/exec-usage/human-users")

# Same keying as the tracer: package name without hash and version.
STORE_RE = re.compile(r"^/nix/store/[0-9a-z]{32}-([^/]+)(/.*)?$")
NAME_RE = re.compile(r"^(.*?)-[^A-Za-z]")


def usage_key(store_path):
    m = STORE_RE.match(store_path)
    if not m:
        return None
    n = NAME_RE.match(m.group(1))
    return (n.group(1) if n else m.group(1)) + (m.group(2) or "")


def ago(ts, now):
    if not ts:
        return "never"
    d = (now - ts) / 86400
    return "%dd ago" % d if d >= 1 else "%dh ago" % ((now - ts) / 3600)


def day(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    ap.add_argument("--days", type=float, default=30,
                    help="unused = no exec in this many days (default 30; 0 = list everything with its last use)")
    ap.add_argument("--human", action="store_true",
                    help="count only execs by humans (%s), not agents/system" % HUMANS)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--prom", action="store_true", help="Prometheus textfile output (for Alloy)")
    a = ap.parse_args()

    now = int(time.time())
    with open(SOURCES) as f:
        sources = json.load(f)
    try:
        with open(USAGE) as f:
            usage = json.load(f)
    except OSError:
        usage = {"since": now, "exes": {}}
    exes = usage.get("exes", {})
    humans = set()
    if a.human:
        with open(HUMANS) as f:
            humans = set(f.read().split())

    pkgs, nobin = [], []
    for s in sources:
        bins, keys = [], set()
        for out in s["outputs"]:
            d = os.path.join(out, "bin")
            if not os.path.isdir(d):
                continue
            for x in sorted(os.listdir(d)):
                p = os.path.join(d, x)
                if not os.access(p, os.X_OK) or os.path.isdir(p):
                    continue
                if not x.startswith("."):
                    bins.append(x)
                for k in (usage_key(p), usage_key(os.path.realpath(p))):
                    if k:
                        keys.add(k)
        if not bins:
            nobin.append(s)
            continue
        by = {}
        for k in keys:
            for u, e in exes.get(k, {}).items():
                if humans and u not in humans:
                    continue
                if e["last"] > by.get(u, 0):
                    by[u] = e["last"]
        last = max(by.values(), default=0)
        pkgs.append(dict(s, bins=bins, last=last, users=sorted(by, key=lambda u: by[u], reverse=True)))

    since = usage.get("since", now)
    cutoff = now - a.days * 86400
    unused = [p for p in pkgs if p["last"] <= cutoff or a.days == 0]
    unused.sort(key=lambda p: (p["last"], p["name"]))

    if a.prom:
        host = socket.gethostname()
        n_unused30 = sum(1 for p in pkgs if p["last"] <= now - 30 * 86400)
        print("# TYPE exec_usage_tracking_since_timestamp_seconds gauge")
        print('exec_usage_tracking_since_timestamp_seconds{host="%s"} %d' % (host, since))
        print("# TYPE exec_usage_packages gauge")
        for st, n in (("total", len(pkgs) + len(nobin)), ("with_bin", len(pkgs)),
                      ("used_30d", len(pkgs) - n_unused30), ("unused_30d", n_unused30),
                      ("no_bin", len(nobin))):
            print('exec_usage_packages{host="%s",state="%s"} %d' % (host, st, n))
        print("# TYPE exec_usage_package_last_used_timestamp_seconds gauge")
        for p in pkgs:
            src = ",".join(p["files"])[:200].replace('"', "'")
            print('exec_usage_package_last_used_timestamp_seconds{host="%s",package="%s",source="%s"} %d'
                  % (host, p["pname"], src, p["last"]))
        return

    if a.json:
        json.dump({"since": since, "days": a.days, "human_only": a.human,
                   "unused": unused, "no_executables": nobin}, sys.stdout, indent=1)
        print()
        return

    span = (now - since) / 86400
    print("exec tracking since %s (%.1f days)%s" % (day(since), span,
          "" if span >= a.days else "  -- shorter than --days: 'never' means 'not since tracking began'"))
    what = "humans (%s)" % " ".join(sorted(humans)) if a.human else "anyone"
    if a.days == 0:
        print("\nAll %d packages with executables, by last exec by %s:" % (len(pkgs), what))
    else:
        print("\n%d of %d packages with executables not exec'd by %s in %g days:" % (len(unused), len(pkgs), what, a.days))
    for p in unused:
        who = ",".join(p["users"][:3])[:22] or "-"
        print("  %-34s %-10s %-22s %s" % (p["name"][:34], ago(p["last"], now), who, " ".join(p["files"])))
        print("  %34s bin: %s" % ("", " ".join(p["bins"][:8]) + (" ..." if len(p["bins"]) > 8 else "")))
    print("\nNo executables (libraries, fonts, data; judge manually): %d" % len(nobin))
    for s in sorted(nobin, key=lambda s: s["name"]):
        print("  %-45s %s" % (s["name"][:45], " ".join(s["files"])))


if __name__ == "__main__":
    main()
