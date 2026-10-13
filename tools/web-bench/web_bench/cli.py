"""web-bench: rate-limited, single-sweep anti-bot benchmark of fetch setups.

Safeguards enforced here (not configurable below these limits):
- one sweep per setup, one attempt per (setup, target), never a retry;
- strictly sequential loads with a random 5-30 s pause between them,
  optionally stretched over --spread-hours;
- public GET pages only, with a hard exclusion list checked at plan time and
  on every main-frame navigation;
- a global budget of main-frame requests per run;
- `run` only executes as a systemd DynamicUser (throwaway uid), never root
  and never an agent uid; `launch` starts it that way.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from html import unescape
from pathlib import Path

from . import classify
from .report import read_records, summary
from .setups import MAX_HOPS, SETUPS, BrowserSetup, NavDenied
from .targets import SMOKE_URL, Target, excluded, split_targets

MIN_DELAY_S = 5.0
MAX_DELAY_S = 30.0
HARD_MAX_BUDGET = 1000  # main-frame requests per run, whatever --budget says
DYNAMIC_UID_RANGE = range(61184, 65520)  # systemd DynamicUser= allocation range
STATE_ROOT = Path("/var/lib/web-bench")  # StateDirectory=web-bench
UNIT = "web-bench"  # fixed unit name: systemd refuses a second concurrent run

# Rough per-load wall time for ETAs (launch + load + network idle + settle).
_EST_HTTP_S = 3.0
_EST_BROWSER_S = 12.0


@dataclass
class Load:
    seq: int
    setup: str
    target: str
    url: str
    source: str
    settle_s: float
    delay_before_s: float


def _est_load_s(setup: str, settle_s: float) -> float:
    return _EST_BROWSER_S + settle_s if isinstance(SETUPS[setup], BrowserSetup) else _EST_HTTP_S


def make_plan(setup_names: list[str], seed: int, spread_hours: float | None,
              targets: list[Target]) -> list[Load]:
    rng = random.Random(seed)
    loads: list[Load] = []
    for s in setup_names:
        order = list(targets)
        rng.shuffle(order)
        for t in order:
            loads.append(Load(len(loads), s, t.name, t.url, t.source, t.settle_s, 0.0))
    gaps = [rng.uniform(MIN_DELAY_S, MAX_DELAY_S) for _ in loads[1:]]
    if spread_hours and gaps:
        work = sum(_est_load_s(l.setup, l.settle_s) for l in loads)
        scale = max(1.0, (spread_hours * 3600 - work) / sum(gaps))  # stretch only, never shrink
        gaps = [g * scale for g in gaps]
    for load, gap in zip(loads[1:], gaps):
        load.delay_before_s = round(gap, 1)
    return loads


def eta_s(loads: list[Load]) -> float:
    return sum(l.delay_before_s + _est_load_s(l.setup, l.settle_s) for l in loads)


def _fmt_dur(s: float) -> str:
    return f"{int(s // 3600)}h{int(s % 3600 // 60):02d}m"


def _budget(args, loads: list[Load]) -> int:
    budget = args.budget or 2 * len(loads)
    if budget > HARD_MAX_BUDGET:
        sys.exit(f"budget {budget} exceeds the hard maximum {HARD_MAX_BUDGET}")
    if len(loads) > budget:
        sys.exit(f"plan has {len(loads)} loads but the budget is {budget}")
    return budget


def _resolve_setups(names: list[str] | None) -> list[str]:
    known = list(SETUPS)
    names = names or known
    bad = [n for n in names if n not in known]
    if bad or len(set(names)) != len(names):
        sys.exit(f"setups must be distinct names from {known}, got {names}")
    return names


def cmd_plan(args) -> int:
    targets, dropped = split_targets()
    names = _resolve_setups(args.setups)
    loads = make_plan(names, args.seed, args.spread_hours, targets)
    budget = _budget(args, loads)
    print(f"seed {args.seed}; setups (in order): {', '.join(names)}")
    print(f"targets: {len(targets)} planned "
          f"({sum(t.source == 'paterson' for t in targets)} paterson, "
          f"{sum(t.source == 'audit' for t in targets)} audit), {len(dropped)} excluded")
    print(f"loads: {len(loads)} (one per setup x target); request budget {budget}"
          f" (hard max {HARD_MAX_BUDGET})")
    delays = [l.delay_before_s for l in loads[1:]]
    if delays:
        print(f"delays: min {min(delays):.1f}s, max {max(delays):.1f}s, total {_fmt_dur(sum(delays))}")
    print(f"estimated duration: {_fmt_dur(eta_s(loads))}")
    print("\nexcluded:")
    for t, why in dropped:
        print(f"  {t.name:24s} {t.url:60s} {why}")
    print("\nplanned loads:")
    t = 0.0
    for l in loads:
        t += l.delay_before_s
        print(f"  {l.seq:4d} +{_fmt_dur(t)} wait {l.delay_before_s:6.1f}s  {l.setup:18s} {l.url}")
        t += _est_load_s(l.setup, l.settle_s)
    return 0


def _refuse_root() -> None:
    if os.geteuid() == 0:
        sys.exit("refusing to run as root")


def _child_cmd(setup_name: str, plan_file: Path, out_file: Path, budget_left: int) -> list[str]:
    cmd = [sys.executable, "-c", "from web_bench.cli import main; main()", "_child",
           "--plan", str(plan_file), "--setup", setup_name, "--out", str(out_file),
           "--budget-left", str(budget_left)]
    if SETUPS[setup_name].needs_display:
        cmd = [shutil.which("xvfb-run") or "xvfb-run", "-a", "-s", "-screen 0 1920x1080x24 -nolisten tcp"] + cmd
    return cmd


def _child_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(p for p in sys.path if p)
    return env


def _execute(loads: list[Load], out_dir: Path, budget: int) -> list[dict]:
    """Run the plan setup by setup, one child process at a time."""
    plan_file = out_dir / "plan.json"
    results = out_dir / "results.jsonl"
    results.touch()
    for name in dict.fromkeys(l.setup for l in loads):
        used = sum(r["nav_requests"] for r in _records(results))
        rc = subprocess.run(_child_cmd(name, plan_file, results, budget - used), env=_child_env()).returncode
        if rc == 3:
            print("request budget exhausted; stopping the run", file=sys.stderr)
            break
        if rc != 0:
            print(f"setup {name} exited with {rc}; continuing with the next setup", file=sys.stderr)
    return _records(results)


def _records(path: Path) -> list[dict]:
    return read_records(path) if path.exists() else []


def _write_plan(out_dir: Path, args, loads: list[Load], budget: int) -> None:
    (out_dir / "plan.json").write_text(json.dumps({
        "seed": args.seed, "spread_hours": args.spread_hours, "budget": budget,
        "loads": [asdict(l) for l in loads],
    }, indent=1))


def cmd_run(args) -> int:
    _refuse_root()
    if os.geteuid() not in DYNAMIC_UID_RANGE:
        sys.exit(f"`run` executes only as a systemd DynamicUser (uid {DYNAMIC_UID_RANGE.start}-"
                 f"{DYNAMIC_UID_RANGE.stop - 1}); start it with `web-bench launch run`")
    targets, _ = split_targets()
    loads = make_plan(_resolve_setups(args.setups), args.seed, args.spread_hours, targets)
    budget = _budget(args, loads)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=False)  # never resume or repeat a sweep
    _write_plan(out_dir, args, loads, budget)
    records = _execute(loads, out_dir, budget)
    text = summary(records, planned=len(loads))
    (out_dir / "summary.md").write_text(text)
    print(text)
    return 0


def _fingerprint(body: str) -> dict:
    m = re.search(r"\{.*\}", unescape(body or ""), re.S)
    try:
        j = json.loads(m.group(0)) if m else {}
    except json.JSONDecodeError:
        return {}
    tls, h2 = j.get("tls") or {}, j.get("http2") or {}
    return {"http_version": j.get("http_version"), "user_agent": j.get("user_agent"),
            "ja4": tls.get("ja4"), "ja3_hash": tls.get("ja3_hash"),
            "peetprint_hash": tls.get("peetprint_hash"),
            "akamai_fingerprint_hash": h2.get("akamai_fingerprint_hash")}


def cmd_smoke(args) -> int:
    _refuse_root()
    names = _resolve_setups(args.setups)
    target = Target("smoke", SMOKE_URL, "smoke", settle_s=2)
    loads = [Load(i, n, target.name, target.url, target.source, target.settle_s,
                  MIN_DELAY_S if i else 0.0) for i, n in enumerate(names)]
    out_dir = Path(args.out) if args.out else Path(os.environ.get("TMPDIR", "/tmp")) / f"web-bench-smoke-{os.getpid()}"
    out_dir.mkdir(parents=True, exist_ok=False)
    args.seed, args.spread_hours = None, None
    _write_plan(out_dir, args, loads, len(loads) * 2)
    records = _execute(loads, out_dir, len(loads) * 2)
    for r in records:
        print(json.dumps({k: r[k] for k in ("setup", "engine", "status", "verdict", "load_ms", "error")}))
        print("   ", json.dumps(r.get("fingerprint", {})))
    print(f"results: {out_dir}/results.jsonl")
    return 0 if len(records) == len(loads) and all(r["verdict"] == "ok" for r in records) else 1


def cmd_child(args) -> int:
    plan = json.loads(Path(args.plan).read_text())
    loads = [Load(**l) for l in plan["loads"] if l["setup"] == args.setup]
    setup = SETUPS[args.setup]
    left = args.budget_left
    with setup.open() as s, open(args.out, "a") as out:
        engine = s.engine_version()
        for load in loads:
            if left <= 0:
                return 3
            time.sleep(load.delay_before_s)
            hops = 0

            def guard(url: str) -> None:
                nonlocal hops, left
                why = excluded(url)
                if why:
                    raise NavDenied(f"{url}: {why}")
                if hops >= MAX_HOPS:
                    raise NavDenied("too many main-frame navigations")
                if left <= 0:
                    raise NavDenied("request budget exhausted")
                hops += 1
                left -= 1

            started = datetime.now(timezone.utc)
            t0 = time.monotonic()
            obs = s.load(load.url, guard, load.settle_s)
            load_ms = int((time.monotonic() - t0) * 1000)
            v, marker = classify.verdict(obs.status, obs.title, obs.body, obs.error)
            rec = {
                "seq": load.seq, "setup": load.setup, "engine": engine, "target": load.target,
                "url": load.url, "source": load.source, "ts": started.isoformat(timespec="seconds"),
                "delay_before_s": load.delay_before_s, "load_ms": load_ms,
                "status": obs.status, "statuses": obs.statuses, "final_url": obs.final_url,
                "verdict": v, "marker": marker, "vendors": classify.vendors(obs.headers, obs.body),
                "title": obs.title[:200], "body_len": len(obs.body), "nav_requests": hops,
                "error": obs.error,
            }
            if load.source == "smoke":
                rec["fingerprint"] = _fingerprint(obs.body)
            out.write(json.dumps(rec) + "\n")
            out.flush()
            print(f"{load.seq:4d} {load.setup:18s} {v:7s} {obs.status!s:4s} {load_ms:6d}ms {load.url}",
                  flush=True)
    return 0


def cmd_summarize(args) -> int:
    d = Path(args.dir)
    plan = json.loads((d / "plan.json").read_text()) if (d / "plan.json").exists() else None
    print(summary(read_records(d / "results.jsonl"), planned=len(plan["loads"]) if plan else None))
    return 0


def cmd_launch(args, rest: list[str]) -> int:
    """Start `run`/`smoke` as a transient systemd service with a throwaway DynamicUser."""
    if os.geteuid() != 0:
        sys.exit("launch needs root to start a system unit (the bench itself runs as a DynamicUser)")
    self_bin = os.environ.get("WEB_BENCH_BIN")
    if not self_bin or not self_bin.startswith("/nix/store/"):
        sys.exit("WEB_BENCH_BIN is not set to the packaged web-bench binary")
    run_id = datetime.now(timezone.utc).strftime(f"{args.what}-%Y%m%dT%H%M%SZ")
    max_s = 3600
    if args.what == "run":
        sub = build_parser().parse_args(["run", "--out", "-", *rest])
        if sub.seed is None:
            sub.seed = random.SystemRandom().randrange(2**31)
            rest = [*rest, "--seed", str(sub.seed)]
        targets, _ = split_targets()
        loads = make_plan(_resolve_setups(sub.setups), sub.seed, sub.spread_hours, targets)
        _budget(sub, loads)
        max_s = int(eta_s(loads) * 1.5) + 3600
        print(f"{len(loads)} loads, estimated {_fmt_dur(eta_s(loads))}, hard stop after {_fmt_dur(max_s)}")
    props = [
        "DynamicUser=yes", f"StateDirectory={UNIT}", "PrivateTmp=yes", "ProtectSystem=strict",
        "ProtectHome=yes", "NoNewPrivileges=yes", "RestrictSUIDSGID=yes", "ProtectKernelTunables=yes",
        "ProtectKernelModules=yes", "ProtectControlGroups=yes", "LockPersonality=yes",
        "MemoryMax=4G", "Nice=10", f"RuntimeMaxSec={max_s}",
        "Environment=HOME=/tmp", "Environment=TMPDIR=/tmp", "WorkingDirectory=/tmp",
    ]
    cmd = ["systemd-run", f"--unit={UNIT}", "--collect", "--no-ask-password"]
    for p in props:
        cmd += ["-p", p]
    cmd += [self_bin, args.what, "--out", str(STATE_ROOT / run_id), *rest]
    print(" ".join(cmd))
    rc = subprocess.run(cmd).returncode
    if rc == 0:
        print(f"follow: journalctl -fu {UNIT}\nresults: /var/lib/private/{UNIT}/{run_id}/")
    return rc


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="web-bench", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def sweep_opts(p):
        p.add_argument("--setups", nargs="+", metavar="SETUP",
                       help="setups in sweep order (default: all, see `plan`)")
        p.add_argument("--seed", type=int, default=None, help="plan seed (order and delays)")
        p.add_argument("--spread-hours", type=float, default=None,
                       help="stretch the pauses so the sweep spans this many hours")
        p.add_argument("--budget", type=int, default=None,
                       help=f"main-frame request budget (default 2 x loads, max {HARD_MAX_BUDGET})")

    p = sub.add_parser("plan", help="dry run: list planned loads, delays and exclusions (no network)")
    sweep_opts(p)
    p = sub.add_parser("run", help="one sweep (DynamicUser only; use `launch run`)")
    sweep_opts(p)
    p.add_argument("--out", required=True, help="new results directory")
    p = sub.add_parser("smoke", help=f"one load of {SMOKE_URL} per setup")
    p.add_argument("--setups", nargs="+", metavar="SETUP")
    p.add_argument("--out", default=None, help="new results directory (default: under $TMPDIR)")
    p = sub.add_parser("summarize", help="summary tables for a results directory")
    p.add_argument("dir")
    p = sub.add_parser("launch", help="as root: start `run`/`smoke` under a systemd DynamicUser")
    p.add_argument("what", choices=["run", "smoke"])
    p = sub.add_parser("_child")
    p.add_argument("--plan", required=True)
    p.add_argument("--setup", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--budget-left", type=int, required=True)
    return ap


def main() -> int:
    ap = build_parser()
    args, rest = ap.parse_known_args()
    if args.cmd == "launch":
        sys.exit(cmd_launch(args, rest))
    if rest:
        ap.error(f"unrecognized arguments: {' '.join(rest)}")
    if args.cmd == "plan" and args.seed is None:
        args.seed = random.SystemRandom().randrange(2**31)
    if args.cmd == "run" and args.seed is None:
        sys.exit("`run` needs --seed (launch picks one) so the plan is reproducible")
    handler = {"plan": cmd_plan, "run": cmd_run, "smoke": cmd_smoke,
               "summarize": cmd_summarize, "_child": cmd_child}[args.cmd]
    sys.exit(handler(args))
