"""recurring-tasks: the freshness registry's probe, exporter and status
(./default.nix says what and why; tested by ./test_recurring_tasks.py).

    recurring-tasks probe  --config FILE   run the result probes, write their JSON
    recurring-tasks export --config FILE   write the textfile metrics

probe (unprivileged, network): each task's result command prints the unix
time its result was made (e.g. main's nixpkgs lastModified); the times go
to one JSON file, renamed into place.

export (root, every 5 min): per task of this host
  recurring_task_last_success_seconds{task}  unix time of the unit's last
      successful run: the newest of systemd's "Deactivated successfully"
      journal entry (PID 1's own, so no process can forge it) and the
      unit's current Result/ExecMainExitTimestamp. `container` reads the
      guest's units and journal from the host (systemctl/journalctl -M).
      Absent when no success is on record.
  recurring_task_result_age_seconds{task}  now minus the probe's time;
      absent when the probe failed or its file is older than 3 h.
  recurring_task_slo_seconds{task,kind=run|result}  the limits.
  recurring_tasks_exporter_last_run_seconds  the dead man's switch.
  hermes_cron_jobs_{enabled,failing}{agent}  hermes agents' own cron
      jobs (jobs.json of every profile; failing = enabled and the last
      run's status is not ok). Counts only, nothing alerts on them yet.
      Each agent's files are read by a child running as that agent's
      user (read_cron_as), so a path the agent controls can never lead
      root's reads elsewhere, and whatever its files hold can only lose
      that agent's own counts, never the metrics file.
"""

import argparse
import json
import os
import pwd
import select
import re
import subprocess
import sys
import time

# systemd's SD_MESSAGE_UNIT_SUCCESS ("<unit>: Deactivated successfully.")
MSG_UNIT_SUCCESS = "7ad2d189f7e94e70a38c781354912448"
PROBE_MAX_AGE = 3 * 3600
JOBS_MAX_BYTES = 1 << 20
CRON_TIMEOUT = 30
TS_RE = re.compile(r"^[0-9]{1,11}(\.[0-9]+)?$")


def log(msg):
    print(f"recurring-tasks: {msg}", file=sys.stderr)


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


# ---- export -------------------------------------------------------------

def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"{cmd[0]}: {e}")
        return None
    if p.returncode != 0:
        # journalctl -M exits 1 with no matches on some versions; not worth a line
        return None
    return p.stdout


def machine_args(machine):
    return ["-M", machine] if machine else []


def journal_last_success(unit, machine):
    out = run(["journalctl", *machine_args(machine), "-q", "--no-pager", "-o", "json", "-r", "-n", "1",
               "_PID=1", f"UNIT={unit}", f"MESSAGE_ID={MSG_UNIT_SUCCESS}"])
    for line in (out or "").splitlines():
        try:
            return int(json.loads(line)["__REALTIME_TIMESTAMP"]) / 1e6
        except (ValueError, KeyError, TypeError):
            continue
    return None


def parse_show(text):
    props = {}
    for line in (text or "").splitlines():
        k, sep, v = line.partition("=")
        if sep:
            props[k] = v
    return props


def show_last_success(unit, machine):
    """The unit's last run, if it is over and succeeded."""
    p = parse_show(run(["systemctl", *machine_args(machine), "show", "--timestamp=unix",
                        "-p", "ActiveState,Result,ExecMainStatus,ExecMainExitTimestamp", unit]))
    ts = p.get("ExecMainExitTimestamp", "")
    if p.get("ActiveState") != "inactive" or p.get("Result") != "success" or p.get("ExecMainStatus") != "0":
        return None
    if not ts.startswith("@") or not TS_RE.match(ts[1:]) or float(ts[1:]) <= 0:
        return None
    return float(ts[1:])


def last_success(unit, machine):
    ts = [t for t in (journal_last_success(unit, machine), show_last_success(unit, machine)) if t]
    return max(ts) if ts else None


def read_probe(path, now):
    try:
        with open(path) as f:
            data = json.load(f)
        at = float(data.get("at", 0))
        results = data.get("results", {})
    except (OSError, ValueError, AttributeError, TypeError):
        return {}
    if not isinstance(results, dict) or now - at > PROBE_MAX_AGE:
        return {}
    return {k: float(v) for k, v in results.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}


def read_jobs(home, rel):
    """jobs.json under an agent's HERMES_HOME, never through a symlink out
    of it, bounded; None when unreadable."""
    path = os.path.join(home, rel)
    real_home = os.path.realpath(home)
    if not os.path.realpath(path).startswith(real_home + os.sep):
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not (st.st_mode & 0o170000 == 0o100000) or st.st_size > JOBS_MAX_BYTES:
            return None
        with os.fdopen(fd, "rb", closefd=False) as f:
            raw = f.read(JOBS_MAX_BYTES + 1)
    finally:
        os.close(fd)
    try:
        data = json.loads(raw)
    except Exception:  # ValueError, RecursionError (deeply nested), MemoryError
        return None
    jobs = data.get("jobs") if isinstance(data, dict) else data
    return jobs if isinstance(jobs, list) else None


def cron_counts(home):
    rels = ["cron/jobs.json"]
    try:
        for p in sorted(os.listdir(os.path.join(home, "profiles")))[:200]:
            rels.append(os.path.join("profiles", p, "cron", "jobs.json"))
    except OSError:
        pass
    enabled = failing = 0
    seen = False
    for rel in rels:
        jobs = read_jobs(home, rel)
        if jobs is None:
            continue
        seen = True
        for j in jobs:
            if not isinstance(j, dict) or j.get("enabled") is not True:
                continue
            enabled += 1
            if j.get("last_status") not in (None, "ok"):
                failing += 1
    return (enabled, failing) if seen else None


def read_cron_as(user, home):
    """cron_counts(home) in a forked child running as `user` (when we are
    root; the unit tests run unprivileged and skip the drop). The child
    reads only what the agent itself can read, so the path walk needs no
    symlink or ownership checks to be safe. None on any failure."""
    if os.geteuid() == 0:
        try:
            pw = pwd.getpwnam(user)
        except KeyError:
            log(f"cron {user}: no such user")
            return None
        if pw.pw_uid == 0:
            return None
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        code = 1
        try:
            os.close(r)
            if os.geteuid() == 0:
                os.setgroups([])
                os.setresgid(pw.pw_gid, pw.pw_gid, pw.pw_gid)
                os.setresuid(pw.pw_uid, pw.pw_uid, pw.pw_uid)
            os.write(w, json.dumps(cron_counts(home)).encode())
            code = 0
        except BaseException:
            pass
        finally:
            os._exit(code)
    os.close(w)
    buf = b""
    deadline = time.monotonic() + CRON_TIMEOUT
    try:
        while len(buf) < 4096:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([r], [], [], left)[0]:
                log(f"cron {user}: timed out")
                os.kill(pid, 9)
                break
            chunk = os.read(r, 4096)
            if not chunk:
                break
            buf += chunk
    finally:
        os.close(r)
        _, status = os.waitpid(pid, 0)
    if status != 0:
        return None
    try:
        c = json.loads(buf)
    except ValueError:
        return None
    if isinstance(c, list) and len(c) == 2 and all(type(x) is int for x in c):
        return tuple(c)
    return None


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def num(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")


def render(cfg, now, last, probe, cron):
    out = []

    def family(name, help_, samples):
        out.append(f"# HELP {name} {help_}")
        out.append(f"# TYPE {name} gauge")
        for labels, v in samples:
            ls = ",".join(f'{k}="{esc(x)}"' for k, x in labels.items())
            out.append(f"{name}{{{ls}}} {num(v)}")

    tasks = cfg["tasks"]
    family("recurring_task_slo_seconds", "Freshness limit per task: kind=run (last success), kind=result (result age).",
           [({"task": t["name"], "kind": k}, t[f"{k}_slo"]) for t in tasks for k in ("run", "result") if t.get(f"{k}_slo")])
    family("recurring_task_last_success_seconds", "Unix time of the task unit's last successful run.",
           [({"task": t["name"]}, last[t["name"]]) for t in tasks if last.get(t["name"])])
    family("recurring_task_result_age_seconds", "Age of the task's result as its probe measured it.",
           [({"task": t["name"]}, max(0.0, now - probe[t["name"]])) for t in tasks
            if t.get("result_slo") and t["name"] in probe])
    family("hermes_cron_jobs_enabled", "Enabled hermes cron jobs per agent (all profiles).",
           [({"agent": a}, c[0]) for a, c in sorted(cron.items())])
    family("hermes_cron_jobs_failing", "Enabled hermes cron jobs whose last run did not end ok.",
           [({"agent": a}, c[1]) for a, c in sorted(cron.items())])
    out.append("# HELP recurring_tasks_exporter_last_run_seconds Unix time this exporter last ran.")
    out.append("# TYPE recurring_tasks_exporter_last_run_seconds gauge")
    out.append(f"recurring_tasks_exporter_last_run_seconds {int(now)}")
    return "\n".join(out) + "\n"


def cmd_export(cfg, now=None):
    now = now or time.time()
    last = {t["name"]: last_success(t["unit"], t.get("machine")) for t in cfg["tasks"] if t.get("unit")}
    probe = read_probe(cfg["probe"], now)
    cron = {}
    for agent, home in cfg.get("hermes_homes", {}).items():
        try:
            c = read_cron_as(agent, home)
        except Exception as e:  # one agent never costs the metrics file
            log(f"cron {agent}: {e!r}")
            c = None
        if c is not None:
            cron[agent] = c
    write_atomic(cfg["out"], render(cfg, now, last, probe, cron))
    return 0


# ---- probe --------------------------------------------------------------

def cmd_probe(cfg, now=None):
    results = {}
    for t in cfg["tasks"]:
        try:
            p = subprocess.run(["bash", "-euo", "pipefail", "-c", t["command"]], capture_output=True, text=True,
                               timeout=cfg.get("timeout", 120))
        except (OSError, subprocess.TimeoutExpired) as e:
            log(f"probe {t['name']}: {e}")
            continue
        v = p.stdout.strip()
        if p.returncode != 0 or not TS_RE.match(v):
            log(f"probe {t['name']}: exit {p.returncode}, output {v[:80]!r}, {p.stderr.strip()[:200]}")
            continue
        results[t["name"]] = float(v)
    write_atomic(cfg["out"], json.dumps({"at": now or time.time(), "results": results}, sort_keys=True) + "\n")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="recurring-tasks")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("probe", "export"):
        sub.add_parser(c).add_argument("--config", required=True)
    args = ap.parse_args(argv)
    with open(args.config) as f:
        cfg = json.load(f)
    return cmd_probe(cfg) if args.cmd == "probe" else cmd_export(cfg)


if __name__ == "__main__":
    sys.exit(main())
