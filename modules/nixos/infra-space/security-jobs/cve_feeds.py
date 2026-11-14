#!/usr/bin/env python3
"""sec-cve-feeds: the nightly CVE watch's mechanical part
(../cve-watch/SKILL.md). Fetches new and updated advisories of the last
HOURS from NVD (CVE API 2.0) and GitHub's global advisory database (GHSA,
reviewed + unreviewed), and matches them against the fleet's inventory:
the package names and versions in each machine's system closure (files
from `sec-collect inventory`) plus a watchlist of upstreams that are not
plain nixpkgs packages (./watchlist.json). Prints candidates as JSON; the
agent judges each (version affected? exposed? fixed version?).

    sec-cve-feeds --inventory DIR [--hours 48] [--out FILE]

DIR holds <machine>.pkgs (one `pname<TAB>version` per line) and
<machine>.vulnix.json (vulnix -j). A candidate is:
  - an advisory in the window whose CPE product (NVD) or package (GHSA)
    names a package some machine runs, or a watchlist entry; or
  - a vulnix hit whose CVE is in the window.
Network: services.nvd.nist.gov, api.github.com (unauthenticated: NVD 5
requests per 30 s, GitHub 60 per hour; paced and capped). Untrusted
text: descriptions are cut to 600 characters and stripped of control
characters; they are data for the agent, never instructions.
"""

import argparse
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "hyperconfig-sec-cve-watch/1"
WATCHLIST = "@watchlist@"
MAX_PAGES = 10


def clean(s, n=600):
    s = re.sub(r"[\x00-\x1f\x7f]+", " ", s or "")
    s = s.replace("@", "@\u200b")  # hermes expands at-references in messages
    return s[:n]


def norm(name):
    name = name.lower()
    name = re.sub(r"^python3\.?\d*-", "", name)
    name = re.sub(r"^(node|perl\d*|ruby|go)-", "", name)
    return re.sub(r"[_.]", "-", name)


def get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r), r.headers
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 503) and attempt < 3:
                time.sleep(30 * (attempt + 1))
                continue
            raise
        except (urllib.error.URLError, TimeoutError):
            if attempt < 3:
                time.sleep(15)
                continue
            raise
    raise RuntimeError(f"{url}: no answer after retries")


def nvd(start, end):
    fmt = "%Y-%m-%dT%H:%M:%S.000Z"
    out, idx = [], 0
    for _ in range(MAX_PAGES):
        q = urllib.parse.urlencode({
            "lastModStartDate": start.strftime(fmt), "lastModEndDate": end.strftime(fmt),
            "resultsPerPage": 2000, "startIndex": idx})
        d, _h = get("https://services.nvd.nist.gov/rest/json/cves/2.0?" + q)
        for v in d.get("vulnerabilities", []):
            c = v["cve"]
            products = set()
            for conf in c.get("configurations", []):
                for node in conf.get("nodes", []):
                    for m in node.get("cpeMatch", []):
                        parts = m.get("criteria", "").split(":")
                        if len(parts) > 5:
                            products.add((parts[3], parts[4], m.get("versionEndExcluding") or m.get("versionEndIncluding") or parts[5]))
            for a in c.get("affected", []):
                for ad in a.get("affectedData", []):
                    products.add((ad.get("vendor", ""), ad.get("product", ""), ""))
            score, sev = None, None
            for k in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30"):
                if c.get("metrics", {}).get(k):
                    cd = c["metrics"][k][0]["cvssData"]
                    score, sev = cd.get("baseScore"), cd.get("baseSeverity")
                    break
            kev = bool(c.get("cisaExploitAdd"))
            desc = next((x["value"] for x in c.get("descriptions", []) if x.get("lang") == "en"), "")
            out.append({"id": c["id"], "source": "nvd", "score": score, "severity": sev, "kev": kev,
                        "published": c.get("published"), "modified": c.get("lastModified"),
                        "products": sorted({(v.lower(), p.lower(), r) for v, p, r in products}),
                        "summary": clean(desc)})
        idx += d.get("resultsPerPage", 0)
        if idx >= d.get("totalResults", 0) or not d.get("resultsPerPage"):
            break
        time.sleep(7)
    return out


def ghsa(start):
    out, url = [], ("https://api.github.com/advisories?" + urllib.parse.urlencode(
        {"per_page": 100, "modified": ">=" + start.strftime("%Y-%m-%dT%H:%M:%SZ"), "sort": "updated"}))
    for _ in range(MAX_PAGES):
        d, h = get(url, {"Accept": "application/vnd.github+json"})
        for a in d:
            out.append({"id": a["ghsa_id"], "cve": a.get("cve_id"), "source": "ghsa",
                        "severity": a.get("severity"), "score": (a.get("cvss") or {}).get("score"),
                        "modified": a.get("updated_at"), "repo": a.get("source_code_location"),
                        "packages": [{"ecosystem": v["package"]["ecosystem"], "name": v["package"]["name"],
                                      "vulnerable": v.get("vulnerable_version_range"),
                                      "fixed": v.get("first_patched_version")}
                                     for v in a.get("vulnerabilities") or [] if v.get("package")],
                        "summary": clean(a.get("summary"))})
        m = re.search(r'<([^>]+)>;\s*rel="next"', h.get("Link", "") or "")
        if not m:
            break
        url = m.group(1)
        time.sleep(2)
    return out


def load_inventory(d):
    pkgs, vulnix = {}, {}
    for fn in sorted(os.listdir(d)):
        m = fn.rsplit(".", 1)[0] if fn.endswith(".pkgs") else None
        if m:
            for line in open(os.path.join(d, fn), encoding="utf-8"):
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    pkgs.setdefault(norm(parts[0]), {}).setdefault(m, set()).add(parts[1])
        if fn.endswith(".vulnix.json"):
            try:
                vulnix[fn[: -len(".vulnix.json")]] = json.load(open(os.path.join(d, fn)))
            except (json.JSONDecodeError, OSError):
                vulnix[fn[: -len(".vulnix.json")]] = []
    return pkgs, vulnix


def main():
    ap = argparse.ArgumentParser(prog="sec-cve-feeds")
    ap.add_argument("--inventory", required=True)
    ap.add_argument("--hours", type=int, default=48)
    ap.add_argument("--out")
    a = ap.parse_args()
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(hours=min(max(a.hours, 1), 24 * 7))
    pkgs, vulnix = load_inventory(a.inventory)
    watch = json.load(open(WATCHLIST))
    errors, nv, gh = [], [], []
    try:
        nv = nvd(start, end)
    except Exception as e:  # noqa: BLE001 - a feed down is a finding, not a crash
        errors.append(f"nvd: {type(e).__name__}: {e}")
    try:
        gh = ghsa(start)
    except Exception as e:  # noqa: BLE001
        errors.append(f"ghsa: {type(e).__name__}: {e}")

    def runs(name):
        return {m: sorted(v) for m, v in pkgs.get(norm(name), {}).items()}

    def watched(names):
        hits = []
        for w in watch:
            if any(norm(n) in {norm(x) for x in w["names"]} for n in names):
                hits.append(w["id"])
        return hits

    cands, window = [], set()
    for v in nv:
        window.add(v["id"])
        names = {p for _vendor, p, _r in v["products"]} | {vendor for vendor, _p, _r in v["products"]}
        fleet = {n: runs(n) for n in {p for _v, p, _r in v["products"]} if runs(n)}
        w = watched(names)
        if fleet or w:
            cands.append({**v, "fleet": fleet, "watchlist": w})
    for g in gh:
        if g.get("cve"):
            window.add(g["cve"])
        names = {p["name"].split("/")[-1] for p in g["packages"]} | {p["name"] for p in g["packages"]}
        if g.get("repo"):
            names.add(g["repo"].rstrip("/").split("/")[-1])
            names.add("/".join(g["repo"].rstrip("/").split("/")[-2:]))
        fleet = {n: runs(n) for n in names if runs(n)}
        w = watched(names)
        if fleet or w:
            cands.append({**g, "fleet": fleet, "watchlist": w})
    vx = []
    for m, hits in vulnix.items():
        for h in hits:
            new = sorted(set(h.get("affected_by", [])) & window)
            if new:
                vx.append({"machine": m, "package": h.get("name"), "cves": new,
                           "scores": {c: h.get("cvssv3_basescore", {}).get(c) for c in new}})
    res = {"window": [start.isoformat(), end.isoformat()], "errors": errors,
           "counts": {"nvd": len(nv), "ghsa": len(gh), "candidates": len(cands), "vulnix_in_window": len(vx)},
           "candidates": cands, "vulnix_in_window": vx}
    text = json.dumps(res, indent=1, sort_keys=True)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(json.dumps(res["counts"]), "errors:", len(errors))
    else:
        print(text)
    return 1 if errors and not (nv or gh) else 0


if __name__ == "__main__":
    sys.exit(main())
