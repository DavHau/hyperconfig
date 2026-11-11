#!/usr/bin/env python3
"""Benchmark the hyperconfig-map skill: fixed discovery tasks, fresh hermes runs.

    bench.py --variant B [--rev REV] [--skill on|off] [--tasks id,id] [--jobs 4]
    bench.py --report            # summary table of every variant so far

Per run: a fresh `hermes -z` oneshot with its own HERMES_HOME (bench
profile under $BENCH_DIR, never the agent's own), cwd = a read-only
snapshot of the repo at REV (default: the working copy's commit) with the
bench itself (its answers) removed; with --skill off without the skill, its
generator and AGENTS.md (by default it snapshots the parent of the
commit that added the skill). With --skill on the skill is preloaded (-s) from
the snapshot's skills/. Grading: regexes from tasks.json on the final answer.

Results: $BENCH_DIR/results.jsonl (one line per run) and summary.md.
BENCH_DIR defaults to $TMPDIR/skill-bench. The bench profile is made from
the calling agent's HERMES_HOME (config.yaml with skills and delegation
stripped; .env with only the ANTHROPIC_* keys) and its .env is deleted
when the bench ends.
"""

import argparse
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
BENCH_DIR = os.environ.get("BENCH_DIR") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "skill-bench")
SKILL = "hyperconfig-map"

PREAMBLE = (
    "You are answering a question about the hyperconfig repository (a clan-based NixOS fleet) "
    "in the current directory. It is a READ-ONLY snapshot: do not edit files, do not build, "
    "deploy, ssh or run VM tests; reading files, grep and `nix eval` are fine. Be efficient. "
    "Answer concisely with exact repo-relative file paths, option names and values.\n\n"
    "Question: "
)


def sh(*args, **kw):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kw).stdout.strip()


def hermes_bin():
    """The inner hermes binary and PATH (the system wrapper pins HERMES_HOME)."""
    wrapper = os.path.realpath(shutil.which("hermes") or sys.exit("no hermes on PATH"))
    text = open(wrapper, errors="replace").read()
    pm = re.search(r"'PATH=([^']*)'", text)
    if not pm:
        sys.exit(f"{wrapper}: no PATH= in the hermes wrapper; adapt hermes_bin()")
    path = pm.group(1)
    exe = re.findall(r"(/nix/store/[^ '\"]+/bin/hermes) \"\$@\"", text)[0]
    venv = re.search(r"'VIRTUAL_ENV=([^']*)'", text)
    return exe, path, venv.group(1) if venv else None


def make_home(home):
    """The bench profile: no skills/memory of the agent, only the model credentials."""
    src = os.environ["HERMES_HOME"]
    os.makedirs(home, mode=0o700, exist_ok=True)
    cfg = json.load(open(os.path.join(src, "config.yaml")))  # hermes' locked config is JSON
    cfg.setdefault("skills", {})["external_dirs"] = []
    for k in ("delegation", "desktop", "dashboard"):
        cfg.pop(k, None)
    dis = cfg.setdefault("agent", {}).setdefault("disabled_toolsets", [])
    for t in ("delegation", "todo", "memory", "session_search"):
        if t not in dis:
            dis.append(t)
    json.dump(cfg, open(os.path.join(home, "config.yaml"), "w"))
    env = [l for l in open(os.path.join(src, ".env")) if l.startswith(("ANTHROPIC_BASE_URL=", "ANTHROPIC_TOKEN="))]
    fd = os.open(os.path.join(home, ".env"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, "".join(env).encode())
    os.close(fd)


def set_skill_dir(home, skills_root):
    p = os.path.join(home, "config.yaml")
    cfg = json.load(open(p))
    cfg["skills"]["external_dirs"] = [skills_root] if skills_root else []
    json.dump(cfg, open(p, "w"))


def snapshot(rev, skill_on, dest):
    """Read-only git checkout of rev, without the bench (and without the skill when off)."""
    if os.path.exists(dest):
        subprocess.run(["chmod", "-R", "u+w", dest], check=False)
        shutil.rmtree(dest)
    os.makedirs(dest)
    tar = subprocess.run(["git", "-C", REPO, "archive", rev], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", dest], input=tar, check=True)
    drop = ["tools/skill-bench"]
    for d in drop:
        p = os.path.join(dest, d)
        if os.path.isdir(p):
            shutil.rmtree(p)
        elif os.path.exists(p):
            os.remove(p)
    # flake.nix may reference the dropped paths (the repo-map check): those
    # refs are text-only here, nix eval of nixosConfigurations never reads them
    env = dict(os.environ, GIT_AUTHOR_NAME="bench", GIT_AUTHOR_EMAIL="bench@localhost", GIT_COMMITTER_NAME="bench", GIT_COMMITTER_EMAIL="bench@localhost")
    subprocess.run(["git", "init", "-q", dest], check=True)
    subprocess.run(["git", "-C", dest, "add", "-A"], check=True)
    subprocess.run(["git", "-C", dest, "commit", "-qm", f"bench snapshot {rev}"], check=True, env=env)
    subprocess.run(["chmod", "-R", "a-w", dest], check=True)


def grade(task, answer):
    g = task["grade"]
    missing = [r for r in g.get("all", []) if not re.search(r, answer, re.I)]
    for group in g.get("any", []):
        if not any(re.search(r, answer, re.I) for r in group):
            missing.append("any(" + "|".join(group) + ")")
    return not missing, missing


def tool_calls(home, session_id):
    db = os.path.join(home, "state.db")
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30)
        n = con.execute("select count(*) from messages where session_id=? and role='tool'", (session_id,)).fetchone()[0]
        names = [r[0] for r in con.execute("select tool_name from messages where session_id=? and role='tool'", (session_id,))]
        con.close()
        return n, names
    except Exception as e:  # noqa: BLE001
        return None, [f"db error: {e}"]


def run_one(task, variant, snap, home, skill_on, runs_dir, exe, path, venv):
    rid = f"{variant}-{task['id']}"
    usage = os.path.join(runs_dir, rid + ".usage.json")
    args = [exe, "-z", PREAMBLE + task["prompt"], "-t", "terminal,file,skills", "--in", snap, "--usage-file", usage]
    if skill_on:
        args += ["-s", SKILL]
    env = {"HOME": os.environ.get("HOME", "/tmp"), "USER": os.environ.get("USER", ""), "LOGNAME": os.environ.get("USER", ""),
           "HERMES_HOME": home, "HERMES_SANDBOX": "none", "PATH": path, "TERM": "dumb", "TMPDIR": os.path.join(BENCH_DIR, "tmp")}
    if venv:
        env["VIRTUAL_ENV"] = venv
    t0 = time.monotonic()
    p = subprocess.run(args, env=env, cwd=snap, capture_output=True, text=True, timeout=1800)
    wall = time.monotonic() - t0
    answer = p.stdout.strip()
    with open(os.path.join(runs_dir, rid + ".answer.txt"), "w") as f:
        f.write(answer + ("\n--- stderr ---\n" + p.stderr[-4000:] if p.returncode else ""))
    u = {}
    try:
        u = json.load(open(usage))
    except Exception:  # noqa: BLE001
        pass
    ok, missing = grade(task, answer)
    n_tools, names = tool_calls(home, u.get("session_id", ""))
    return {
        "ts": dt.datetime.now().isoformat(timespec="seconds"),
        "variant": variant,
        "task": task["id"],
        "success": ok,
        "missing": missing,
        "wall_s": round(wall, 1),
        "tool_calls": n_tools,
        "tools": names,
        "api_calls": u.get("api_calls"),
        "input_tokens": u.get("input_tokens"),
        "output_tokens": u.get("output_tokens"),
        "cache_read_tokens": u.get("cache_read_tokens"),
        "cache_write_tokens": u.get("cache_write_tokens"),
        "total_tokens": u.get("total_tokens"),
        "cost_usd": u.get("estimated_cost_usd"),
        "exit": p.returncode,
        "session_id": u.get("session_id"),
    }


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def report():
    rows = [json.loads(l) for l in open(os.path.join(BENCH_DIR, "results.jsonl"))]
    variants = list(dict.fromkeys(r["variant"] for r in rows))
    tasks = list(dict.fromkeys(r["task"] for r in rows))
    # last run per (variant, task)
    last = {}
    for r in rows:
        last[(r["variant"], r["task"])] = r
    out = ["# skill-bench summary", "", f"{len(rows)} runs recorded; tokens = input+output (cache reads included in input).", ""]
    out += ["| variant | runs | success | median tokens | median wall s | median tool calls | total cost $ |", "|---|---|---|---|---|---|---|"]
    for v in variants:
        rs = [last[(v, t)] for t in tasks if (v, t) in last]
        succ = sum(r["success"] for r in rs)
        cost = sum(r["cost_usd"] or 0 for r in rs)
        out.append(f"| {v} | {len(rs)} | {succ}/{len(rs)} | {med([r['total_tokens'] for r in rs]):.0f} | {med([r['wall_s'] for r in rs]):.0f} | {med([r['tool_calls'] for r in rs])} | {cost:.2f} |")
    out += ["", "Per task (ok / total tokens / wall s / tool calls):", ""]
    out.append("| task | " + " | ".join(variants) + " |")
    out.append("|---|" + "---|" * len(variants))
    for t in tasks:
        cells = []
        for v in variants:
            r = last.get((v, t))
            cells.append("-" if not r else f"{'ok' if r['success'] else 'FAIL'} / {r['total_tokens'] or 0} / {r['wall_s']:.0f} / {r['tool_calls']}")
        out.append(f"| {t} | " + " | ".join(cells) + " |")
    fails = [r for r in last.values() if not r["success"]]
    if fails:
        out += ["", "Failures (missing regexes):", ""]
        out += [f"- {r['variant']} {r['task']}: {', '.join(r['missing'])}" for r in fails]
    text = "\n".join(out) + "\n"
    open(os.path.join(BENCH_DIR, "summary.md"), "w").write(text)
    print(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant")
    ap.add_argument("--rev", default=None, help="git revision to snapshot (default: the jj working copy's commit)")
    ap.add_argument("--skill", choices=["on", "off"], default=None, help="default: off for variant A, else on")
    ap.add_argument("--tasks", default=None)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()
    if a.report:
        report()
        return
    if not a.variant:
        ap.error("--variant is required")
    skill_on = (a.skill or ("off" if a.variant == "A" else "on")) == "on"
    rev = a.rev
    if rev is None:
        sh("jj", "--repository", REPO, "status")  # snapshot the working copy
        rev = sh("jj", "--repository", REPO, "log", "--no-graph", "-r", "@", "-T", "commit_id")
        if not skill_on:
            # the baseline: the parent of the commit that added the skill
            # (the repo's eval references the skill, so it can't just be
            # deleted from a snapshot)
            added = sh("git", "-C", REPO, "log", "--diff-filter=A", "--format=%H", rev, "--", "skills/hyperconfig-map/SKILL.md").splitlines()
            if added:
                rev = added[-1] + "^"
    tasks = json.load(open(os.path.join(HERE, "tasks.json")))["tasks"]
    if a.tasks:
        want = a.tasks.split(",")
        tasks = [t for t in tasks if t["id"] in want]
    os.makedirs(os.path.join(BENCH_DIR, "tmp"), exist_ok=True)
    runs_dir = os.path.join(BENCH_DIR, "runs")
    os.makedirs(runs_dir, exist_ok=True)
    home = os.path.join(BENCH_DIR, "home")
    snap = os.path.join(BENCH_DIR, f"repo-{a.variant}")
    make_home(home)
    try:
        snapshot(rev, skill_on, snap)
        set_skill_dir(home, os.path.join(snap, "skills") if skill_on else None)
        exe, path, venv = hermes_bin()
        print(f"variant {a.variant}: rev {rev[:12]}, skill {'on' if skill_on else 'off'}, {len(tasks)} tasks, {a.jobs} at once", flush=True)
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            futs = {ex.submit(run_one, t, a.variant, snap, home, skill_on, runs_dir, exe, path, venv): t for t in tasks}
            for f in cf.as_completed(futs):
                try:
                    r = f.result()
                except Exception as e:  # noqa: BLE001
                    r = {"variant": a.variant, "task": futs[f]["id"], "success": False, "missing": [f"runner error: {e}"],
                         "wall_s": 0, "tool_calls": None, "total_tokens": None, "cost_usd": None}
                r["rev"] = rev
                with open(os.path.join(BENCH_DIR, "results.jsonl"), "a") as out:
                    out.write(json.dumps(r) + "\n")
                print(f"  {r['task']}: {'ok' if r['success'] else 'FAIL'} tokens={r.get('total_tokens')} wall={r.get('wall_s')}s tools={r.get('tool_calls')}", flush=True)
    finally:
        # credentials never outlive the bench
        # (hermes copies the token into auth.json's credential pool too)
        for f in (".env", "auth.json"):
            try:
                os.remove(os.path.join(home, f))
            except FileNotFoundError:
                pass
    report()


if __name__ == "__main__":
    main()
