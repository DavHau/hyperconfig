"""Summary tables from results.jsonl."""
from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

from .classify import VERDICTS

_SHORT = {"ok": "ok", "gated": "GATE", "blocked": "BLOCK", "error": "err"}


def read_records(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def summary(records: list[dict], planned: int | None = None) -> str:
    setups = list(dict.fromkeys(r["setup"] for r in records))
    out = ["# web-bench summary", ""]
    if planned is not None:
        out += [f"Loads done: {len(records)} of {planned} planned.", ""]

    out += ["| setup | engine | " + " | ".join(VERDICTS) + " | ok % | ok paterson | ok audit | median load s |",
            "|---|---|" + "---:|" * (len(VERDICTS) + 4)]
    for s in setups:
        rs = [r for r in records if r["setup"] == s]
        c = Counter(r["verdict"] for r in rs)
        by_src = {src: [r for r in rs if r["source"] == src] for src in ("paterson", "audit")}
        ok_src = [f"{sum(r['verdict'] == 'ok' for r in v)}/{len(v)}" for v in by_src.values()]
        times = sorted(r["load_ms"] for r in rs)
        med = times[len(times) // 2] / 1000 if times else 0
        out.append(f"| {s} | {rs[0].get('engine', '')} | " + " | ".join(str(c[v]) for v in VERDICTS)
                   + f" | {100 * c['ok'] / len(rs):.0f} | {ok_src[0]} | {ok_src[1]} | {med:.1f} |")

    cells: dict[str, dict[str, dict]] = defaultdict(dict)
    meta: dict[str, dict] = {}
    for r in records:
        cells[r["target"]][r["setup"]] = r
        meta.setdefault(r["target"], r)
    out += ["", "| target | source | vendors | " + " | ".join(setups) + " |",
            "|---|---|---|" + "---|" * len(setups)]
    for t in sorted(cells, key=lambda t: (meta[t]["source"], t)):
        vend = sorted({v for r in cells[t].values() for v in r.get("vendors", [])})
        row = []
        for s in setups:
            r = cells[t].get(s)
            if r is None:
                row.append("-")
                continue
            mark = r.get("marker") or ""
            row.append(_SHORT[r["verdict"]] + (f" `{mark}`" if mark else ""))
        out.append(f"| {t} | {meta[t]['source']} | {', '.join(vend)} | " + " | ".join(row) + " |")
    return "\n".join(out) + "\n"
