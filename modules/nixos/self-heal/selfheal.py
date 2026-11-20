"""selfheal: the self-heal CLI (./default.nix builds it, docs/self-heal.md).

One CLI for every self-heal part. Part 1, the deploy guard
(./deploy-guard.nix): the pre-switch check arms a transient timer; when it
fires, `deploy-guard assess` confirms a healthy machine, or restores stopped
units, then rolls back to the previous generation and reboots. Part 3, boot
counting (./boot-counting.nix): `boot-health` gates boot-complete.target on
local health and reboots a try-counted entry that stays unhealthy.

Called as `selfheal.py --config <json> <command> ...`; the json (built by
./default.nix) holds every path and setting, so the CLI of the NEW system
works inside its own pre-switch check, before /etc is switched.
"""

import argparse
import datetime
import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

CFG = {}
BLOCKED_EXIT = 3


# ---------------------------------------------------------------- helpers

def now():
    return time.time()


def iso(t):
    return datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def log(msg):
    print(f"selfheal: {msg}", file=sys.stderr, flush=True)


def state_dir():
    return CFG["stateDir"]


def guard_dir():
    return os.path.join(state_dir(), "deploy-guard")


def path(name):
    return os.path.join(guard_dir(), name)


def hold_path():
    return os.path.join(state_dir(), "hold.json")


def ensure_dirs():
    os.makedirs(guard_dir(), mode=0o700, exist_ok=True)


def write_atomic(dest, text):
    ensure_dirs()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = f"{dest}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, dest)


def write_json(dest, obj):
    write_atomic(dest, json.dumps(obj, indent=1, sort_keys=True) + "\n")


def read_json(src):
    try:
        with open(src) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        log(f"unreadable {src}: {e}")
        return None


def remove(src):
    try:
        os.remove(src)
    except FileNotFoundError:
        pass


class Lock:
    """Serialises state changes between the CLI and the timer's assess."""

    def __enter__(self):
        ensure_dirs()
        self.f = open(os.path.join(state_dir(), ".lock"), "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def event(kind, **fields):
    """Append one line to the action log (status shows the last ones)."""
    entry = {"time": iso(now()), "event": kind, **fields}
    log(f"{kind} " + " ".join(f"{k}={v}" for k, v in fields.items()))
    try:
        ensure_dirs()
        logf = os.path.join(state_dir(), "log.jsonl")
        with open(logf, "a") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")
        if os.path.getsize(logf) > 256 * 1024:
            with open(logf) as f:
                tail = f.readlines()[-200:]
            write_atomic(logf, "".join(tail))
    except OSError as e:
        log(f"cannot write the log: {e}")


def run(cmd, timeout=60, check=False, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        if check:
            raise
        return subprocess.CompletedProcess(cmd, 255, "", str(e))
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed ({p.returncode}): {p.stderr.strip()}")
    return p


def realpath(p):
    return os.path.realpath(p)


def current_system():
    return realpath("/run/current-system")


def boot_id():
    with open("/proc/sys/kernel/random/boot_id") as f:
        return f.read().strip()


def short(p):
    return os.path.basename(p) if p else "?"


def host():
    return CFG["hostName"]


# ---------------------------------------------------------------- health

def unit_active(unit):
    return run(["systemctl", "is-active", "--quiet", unit], timeout=10).returncode == 0


def listening_ports():
    p = run(["ss", "-Hltn"], timeout=10)
    ports = set()
    for line in p.stdout.splitlines():
        cols = line.split()
        if len(cols) >= 4:
            port = cols[3].rsplit(":", 1)[-1]
            if port.isdigit():
                ports.add(int(port))
    return ports


def reachable(addr, timeout=2, port=22, icmp=True):
    """ICMP echo or a TCP connect to `port`: either counts (firewalls differ).
    icmp=False: only the TCP connect counts."""
    result = []

    def tcp():
        try:
            socket.create_connection((addr, port), timeout=timeout).close()
            result.append("tcp")
        except OSError:
            pass

    t = threading.Thread(target=tcp)
    t.start()
    if icmp and run(["ping", "-n", "-c", "1", "-W", str(timeout), addr], timeout=timeout + 3).returncode == 0:
        result.append("icmp")
    t.join(timeout + 1)
    return result


def reachable_set(addrs, port=22, icmp=True):
    """The addresses of `addrs` that answer, probed in parallel (~2 s)."""
    results = {}

    def probe(a):
        results[a] = reachable(a, port=port, icmp=icmp)

    threads = [threading.Thread(target=probe, args=(a,)) for a in addrs]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)
    return [a for a in addrs if results.get(a)]


def check_sshd(items):
    """One item for the unit, one per configured port, so a baseline that
    lacks one port (sgp: 21) still judges the unit and the other ports."""
    unit = CFG["sshUnit"]
    active = unit_active(unit)
    items.append({"name": "sshd", "ok": active, "detail": f"{unit} {'active' if active else 'not active'}"})
    ports = listening_ports()
    for p in CFG["sshPorts"]:
        ok = p in ports
        items.append({"name": f"sshd:{p}", "ok": ok, "detail": "listening" if ok else "not listening"})


def check_mesh(items):
    for unit in CFG["meshUnits"]:
        ok = unit_active(unit)
        items.append({"name": f"mesh:{unit}", "ok": ok, "detail": "active" if ok else "not active"})


def check_anchors(items):
    anchors = CFG["anchors"]
    if not anchors:
        items.append({"name": "anchors", "ok": True, "detail": "no anchors configured"})
        return
    results = {}

    def probe(a):
        results[a] = reachable(a)

    threads = [threading.Thread(target=probe, args=(a,)) for a in anchors]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)
    up = [a for a in anchors if results.get(a)]
    ok = bool(up)
    detail = (f"{len(up)}/{len(anchors)} reachable" + (f" (e.g. {up[0]})" if up else ""))
    items.append({"name": "anchors", "ok": ok, "detail": detail})


def check_link(items):
    up = []
    for dev in sorted(os.listdir("/sys/class/net")):
        if dev == "lo":
            continue
        try:
            with open(f"/sys/class/net/{dev}/operstate") as f:
                if f.read().strip() == "up":
                    up.append(dev)
        except OSError:
            pass
    items.append({"name": "link", "ok": bool(up), "detail": ",".join(up) or "no interface up"})


def default_gateways():
    """(gateway, dev) of every default route, v4 and v6, multipath
    included (`nexthop via ... dev ...` lines)."""
    gws = []
    for fam in ("-4", "-6"):
        for line in run(["ip", fam, "route", "show", "default"], timeout=5).stdout.splitlines():
            cols = line.split()
            if "via" in cols:
                gw = cols[cols.index("via") + 1]
                dev = cols[cols.index("dev") + 1] if "dev" in cols and cols.index("dev") + 1 < len(cols) else None
                gws.append((gw, dev))
    return gws


def gateway_answers(gw, dev):
    """ICMP, or ARP for IPv4 (a router may drop pings but must answer ARP)."""
    target = f"{gw}%{dev}" if dev and gw.startswith("fe80") else gw
    if run(["ping", "-n", "-c", "1", "-W", "2", target], timeout=5).returncode == 0:
        return True
    if dev and ":" not in gw:
        return run(["arping", "-q", "-c", "1", "-w", "2", "-I", dev, gw], timeout=5).returncode == 0
    return False


def check_gateway(items):
    """Any default route's gateway answering is enough (several uplinks)."""
    gws = default_gateways()
    ok_gw = [g for g, d in gws if gateway_answers(g, d)]
    detail = (f"{ok_gw[0]} answers" if ok_gw else ("no default route" if not gws else f"{','.join(g for g, _ in gws)} silent"))
    items.append({"name": "gateway", "ok": bool(ok_gw), "detail": detail})


def health(level):
    """deploy: what we need to get in (sshd, mesh daemons, a mesh anchor).
    local: this machine's own side only (sshd, link, gateway), so an
    upstream outage never looks like a local fault.
    boot: the boot counting gate (./boot-counting.nix): local, minus link
    and gateway where `bootRequireGateway` is off (laptops boot offline)."""
    items = []
    check_sshd(items)
    if level == "deploy":
        check_mesh(items)
        check_anchors(items)
    elif level == "local" or CFG.get("bootRequireGateway", True):
        check_link(items)
        check_gateway(items)
    return {"level": level, "healthy": all(i["ok"] for i in items), "items": items}


def failing(h):
    return [i for i in h["items"] if not i["ok"]]


def reason_of(h):
    """Low-cardinality reason: the failing categories, e.g. sshd+mesh."""
    cats = []
    for i in failing(h):
        cat = i["name"].split(":")[0]
        if cat not in cats:
            cats.append(cat)
    return "+".join(cats) or "unknown"


def judged(h, p):
    """Only what worked when the guard was armed can be broken by the
    switch: drop items that already failed then (baseline None = judge
    everything)."""
    base = (p or {}).get("baseline")
    if base is None:
        return h
    items = [i for i in h["items"] if i["name"] in base]
    return {**h, "items": items, "healthy": all(i["ok"] for i in items)}


def healthy_judged(p):
    """Healthy on `stableChecks` consecutive checks, 1 s apart (a flapping
    unit is not confirmed), judged against the baseline. Returns
    (healthy, last result)."""
    checks = CFG["stableChecks"]
    h = None
    for n in range(checks):
        if n:
            time.sleep(1)
        h = judged(health("deploy"), p)
        if not h["healthy"]:
            return False, h
    return True, h


def upstream_only(h):
    """Dave's definition: the gateway answers, the internet AND the mesh
    don't. Judged items: only the anchors fail (sshd, mesh daemons fine).
    Then, from the local level, only link + gateway count (sshd is already
    judged against the baseline in h). Internet up while the anchors answer
    on their public addresses = this machine's overlays are broken
    (firewall, routes, mesh config): a local fault, not upstream. Internet
    up but the anchors' public addresses silent too = the anchors are down:
    upstream.
    Roaming machines (laptops): sshd + mesh daemons fine is enough, a
    missing link/gateway/internet is the laptop being offline on purpose
    (docs/self-heal.md)."""
    if h["healthy"] or set(reason_of(h).split("+")) != {"anchors"}:
        return False
    if CFG.get("roaming"):
        return True
    loc = health("local")
    if not all(i["ok"] for i in loc["items"] if i["name"] in ("link", "gateway")):
        return False
    inet = reachable_set(CFG.get("internetProbes", []), port=443)
    # TCP 22 only: proves the anchor itself, not a CDN in front of its name
    if inet and reachable_set(CFG.get("anchorsPublic", []), port=22, icmp=False):
        event("local-overlay-fault", internet=inet[0],
              why="anchors answer on their public addresses: the overlays are broken here, not upstream")
        return False
    return True


def elapsed(p):
    """Seconds since arming, on CLOCK_MONOTONIC within the arming boot (a
    clock set by NTP after boot, e.g. cm-pi without RTC, can't skew it)."""
    if p.get("bootId") == boot_id() and "armedMono" in p:
        return time.monotonic() - p["armedMono"]
    return now() - p["armed"]


def print_health(h):
    print(f"{host()}: {h['level']} health: {'healthy' if h['healthy'] else 'UNHEALTHY'}")
    for i in h["items"]:
        print(f"  {'ok  ' if i['ok'] else 'FAIL'} {i['name']}: {i['detail']}")


# ---------------------------------------------------------------- state

def pending():
    return read_json(path("pending.json"))


def flag():
    return read_json(path("rolled-back"))


def hold():
    h = read_json(hold_path())
    if h and h.get("until", 0) > now():
        return h
    return None


def write_metrics():
    """Textfile for Alloy (./deploy-guard.nix); rewritten on every change
    and at boot (the flag persists, the metrics dir is /run)."""
    try:
        p = pending()
        fl = flag()
        conf = read_json(path("last-confirm.json"))
        lines = [
            "# TYPE selfheal_deploy_guard_pending gauge",
            f"selfheal_deploy_guard_pending {1 if p else 0}",
            "# TYPE selfheal_deploy_guard_rolled_back gauge",
        ]
        if fl:
            reason = str(fl.get("reason", "unknown")).replace('"', "")
            lines.append(f'selfheal_deploy_guard_rolled_back{{reason="{reason}"}} 1')
        else:
            lines.append("selfheal_deploy_guard_rolled_back 0")
        if conf and "timestamp" in conf:
            lines += [
                "# TYPE selfheal_deploy_guard_last_confirm_timestamp_seconds gauge",
                f"selfheal_deploy_guard_last_confirm_timestamp_seconds {int(conf['timestamp'])}",
            ]
        lines += [
            "# TYPE selfheal_hold_active gauge",
            f"selfheal_hold_active {1 if hold() else 0}",
        ]
        mdir = CFG["metricsDir"]
        os.makedirs(mdir, exist_ok=True)
        write_atomic(os.path.join(mdir, "selfheal.prom"), "\n".join(lines) + "\n")
    except Exception as e:  # noqa: BLE001 -- metrics never break an action
        log(f"cannot write metrics: {e}")


# ---------------------------------------------------------------- timers

def self_cmd():
    return [sys.executable, os.path.realpath(__file__), "--config", CFG["_configPath"]]


def guard_timers():
    p = run(["systemctl", "list-units", "--all", "--plain", "--no-legend",
             "selfheal-deploy-guard-*.timer"], timeout=15)
    return [line.split()[0] for line in p.stdout.splitlines() if line.split()]


def arm_timer(token, delay):
    """A transient timer (in /run/systemd/transient, not /etc/systemd/system,
    so switch-to-configuration never stops it). One per arming, named by
    token: assess re-arms from inside its own service, which still holds
    the older name."""
    # Stopping a timer leaves a service it started (an assess in progress,
    # maybe this very process) running.
    for t in guard_timers():
        run(["systemctl", "stop", t], timeout=15)
    unit = f"selfheal-deploy-guard-{token}"
    run(["systemd-run", "--no-block", "--collect", f"--unit={unit}",
         f"--on-active={max(1, int(delay))}s", "--timer-property=AccuracySec=1s",
         "--description=selfheal deploy guard: confirm or roll back",
         "--", *self_cmd(), "deploy-guard", "assess", "--token", token],
        timeout=30, check=True)
    return unit


def rearm(p, delay, why):
    """Re-arm the pending deploy's timer `delay` s from now (new token)."""
    p["token"] = uuid.uuid4().hex[:12]
    p["deadline"] = now() + delay
    write_json(path("pending.json"), p)
    arm_timer(p["token"], delay)
    event("rearm", why=why, at=iso(p["deadline"]))


def switch_units():
    p = run(["systemctl", "list-units", "--plain", "--no-legend", "--state=active,activating,deactivating",
             "clan-switch-*", "clan-boot-*"], timeout=15)
    return [line.split()[0] for line in p.stdout.splitlines() if line.split()]


def switch_pids():
    me = os.getpid()
    pids = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        # the wrapper (bin/switch-to-configuration) or the binary it execs
        # (bin/.switch-to-configuration-wrapped, switch-to-configuration-ng)
        if any(b"switch-to-configuration" in os.path.basename(a) for a in argv[:2]):
            pids.append(int(pid))
    return pids


def switch_running():
    """A clan deploy unit or any switch-to-configuration process."""
    units = switch_units()
    if units:
        return units[0]
    pids = switch_pids()
    return f"pid {pids[0]}" if pids else None


def kill_switches():
    """A switch hung past maxExtend holds switch-to-configuration's lock,
    which the rollback's own `boot` needs."""
    killed = []
    for u in switch_units():
        run(["systemctl", "kill", "--signal=KILL", u], timeout=15)
        killed.append(u)
    for pid in switch_pids():
        try:
            os.kill(pid, 9)
            killed.append(f"pid {pid}")
        except OSError:
            pass
    return killed


# ---------------------------------------------------------------- deploy guard

def block_line(fl):
    return (f"selfheal: {host()} rolled back {short(fl.get('from'))} -> {short(fl.get('to'))} "
            f"at {fl.get('time', '?')} ({fl.get('reason', '?')}); inspect, then run "
            f"`selfheal clear` on {host()} (if not on PATH: {' '.join(self_cmd())} clear)")


def cmd_pre_switch(args):
    """system.preSwitchChecks: exit BLOCKED_EXIT only to block; the shell
    wrapper in ./deploy-guard.nix maps everything else (crashes too) to 0."""
    action = args.action
    fl = flag()
    if fl and action in ("switch", "boot"):
        print(block_line(fl), file=sys.stderr)
        return BLOCKED_EXIT
    if action != "switch":
        return 0
    if CFG.get("bootCounting") and realpath(args.toplevel) == realpath("/nix/var/nix/profiles/system"):
        try:
            retry_profile_entry()
        except Exception as e:  # noqa: BLE001 -- never block a deploy on our bug
            event("boot-entry-retry-failed", error=str(e))
    boot_fallback(at_boot=False)
    try:
        arm(realpath(args.toplevel))
    except Exception as e:  # noqa: BLE001 -- never block a deploy on our bug
        event("arm-failed", error=str(e))
    return 0


def baseline():
    """Deploy health before the switch touches anything (~2-3 s: the
    anchor probes run in parallel with 2 s timeouts); None on any error,
    which judges every item later."""
    try:
        return [i["name"] for i in health("deploy")["items"] if i["ok"]]
    except Exception as e:  # noqa: BLE001
        log(f"no baseline: {e}")
        return None


def arm(new):
    cur = current_system()
    if cur == new:
        log("switch to the running system: nothing to guard")
        return
    base = baseline()
    with Lock():
        old = pending()
        prev = cur
        # A deploy on top of an unconfirmed one rolls back to the last
        # confirmed system, not to the unconfirmed one.
        if old and old.get("new") == cur and os.path.exists(f"{old.get('prev')}/bin/switch-to-configuration"):
            prev = old["prev"]
            if old.get("baseline") is not None and base is not None:
                # judge what worked before the first unconfirmed switch,
                # not what the unconfirmed one left (e.g. its mesh down)
                base = sorted(set(base) | set(old["baseline"]))
        p = {
            "prev": prev,
            "new": new,
            "armed": now(),
            "armedMono": time.monotonic(),
            "deadline": now() + CFG["deadline"],
            "bootId": boot_id(),
            "token": uuid.uuid4().hex[:12],
            "baseline": base,
        }
        write_json(path("pending.json"), p)
        try:
            arm_timer(p["token"], CFG["deadline"])
        except Exception:
            # no timer = nothing pending (else pending=1 forever and the
            # next arm inherits a stale prev)
            remove(path("pending.json"))
            raise
        event("armed", prev=short(prev), new=short(new), deadline=iso(p["deadline"]),
              baseline=",".join(base) if base is not None else "none (judge all)")
    write_metrics()
    log(f"deploy guard armed: run `selfheal confirm` on {host()} (or it assesses itself at "
        f"{iso(p['deadline'])}); unhealthy then = roll back to {short(prev)} and reboot")


def confirm(p, how, h=None):
    remove(path("pending.json"))
    write_json(path("last-confirm.json"), {"timestamp": now(), "time": iso(now()), "system": p.get("new"), "how": how})
    # Stopping a timer leaves its service (an assess in progress) running;
    # that one sees nothing pending and returns.
    for t in guard_timers():
        run(["systemctl", "stop", t], timeout=15)
    event("confirmed", how=how, system=short(p.get("new")))


def restore(h):
    """Step 1: start what the switch left stopped."""
    units = CFG["restoreUnits"]
    for u in units:
        run(["systemctl", "reset-failed", u], timeout=15)
    started = []
    for u in units:
        r = run(["systemctl", "start", "--no-block", u], timeout=30)
        started.append(u if r.returncode == 0 else f"{u}(failed: {r.stderr.strip()[:80]})")
    event("restore", failing=",".join(i["name"] for i in failing(h)), started=",".join(started))


def rollback(p, h):
    prev, new = p.get("prev"), p.get("new")
    notes = []
    boot_ok = False
    killed = kill_switches()
    if killed:
        notes.append(f"killed the still running switch: {', '.join(killed)}")
        time.sleep(1)
    if prev and os.path.exists(f"{prev}/bin/switch-to-configuration"):
        r = run(["nix-env", "-p", "/nix/var/nix/profiles/system", "--set", prev], timeout=300)
        if r.returncode != 0:
            notes.append(f"nix-env --set failed: {r.stderr.strip()[-200:]}")
        env = dict(os.environ, NIXOS_NO_CHECK="1")
        r = run([f"{prev}/bin/switch-to-configuration", "boot"], timeout=900, env=env)
        boot_ok = r.returncode == 0
        if not boot_ok:
            notes.append(f"switch-to-configuration boot failed ({r.returncode}): {r.stderr.strip()[-300:]}")
    else:
        notes.append(f"previous system {prev} is gone from the store")
    if not boot_ok:
        notes.append("rebooting into the default boot entry (the new generation) anyway")
    fl = {
        "time": iso(now()),
        "timestamp": now(),
        "from": new,
        "to": prev,
        "reason": reason_of(h),
        "failing": [f"{i['name']}: {i['detail']}" for i in failing(h)],
        "bootEntry": boot_ok,
        "notes": notes,
    }
    write_json(path("rolled-back"), fl)
    remove(path("pending.json"))
    event("rolled-back", frm=short(new), to=short(prev), reason=fl["reason"], boot_entry=boot_ok,
          notes="; ".join(notes))
    write_metrics()
    os.sync()
    run(["systemctl", "reboot"], timeout=60)
    # A hung stop job is covered by reboot.target's JobTimeoutSec=30min /
    # reboot-force. This loop only helps when `systemctl reboot` could not
    # queue the job at all (we are not stopped then).
    end = time.monotonic() + 600
    while time.monotonic() < end:
        time.sleep(1)
    event("reboot-forced")
    run(["systemctl", "reboot", "--force"], timeout=60)


def switch_wait(p):
    """A switch still running, and less than maxExtend since arming: the
    destructive steps (kill it, roll back, restart the machine) and a
    confirmation wait for it to finish."""
    sw = switch_running()
    if sw and elapsed(p) < CFG["maxExtend"]:
        return sw
    return None


def extend(p, why):
    rearm(p, max(1, min(CFG["extendStep"], CFG["maxExtend"] - elapsed(p) + 1)), why)
    write_metrics()


def upstream_wait(p):
    """An upstream-only failure re-checks until maxExtend, then confirms
    (how=upstream); it never restores or rolls back."""
    if elapsed(p) < CFG["maxExtend"]:
        extend(p, "roaming and offline (upstream)" if CFG.get("roaming")
               else "anchors unreachable, gateway answers (upstream)")
    else:
        confirm(p, "upstream")
        write_metrics()


def cmd_assess(args):
    with Lock():
        p = pending()
        if not p or p.get("token") != args.token:
            log("stale timer: nothing pending for it")
            return 0
    ok, h = healthy_judged(p)
    with Lock():
        p = pending()
        if not p or p.get("token") != args.token:
            return 0
        if ok:
            # A long switch may still stop units in a later phase: confirm
            # only once it finished (or maxExtend passed).
            sw = switch_wait(p)
            if sw:
                extend(p, f"healthy, but the switch still runs ({sw})")
            else:
                confirm(p, "timer")
                write_metrics()
            return 0
        hd = hold()
        if hd:
            rearm(p, hd["until"] - now() + 5, f"hold until {iso(hd['until'])}")
            write_metrics()
            return 0
        if upstream_only(h):
            upstream_wait(p)
            return 0
        event("unhealthy", failing="; ".join(f"{i['name']}: {i['detail']}" for i in failing(h)))
        # Restore at the first deadline, even while a switch still runs:
        # starting units is cheap (the 2026-11-19 switch hung with sshd and
        # the mesh stopped). If the switch later completes, units started
        # here may run their old definition until restarted (a restart or
        # the next deploy fixes it). Only once per pending deploy.
        first = not p.get("restored")
        if first:
            restore(h)
            p["restored"] = now()
            write_json(path("pending.json"), p)
    if first:
        # Monotonic, and at least 5 checks: a laptop suspended inside the
        # window gets its checks after resume, not a rollback at once.
        end = time.monotonic() + CFG["restoreWindow"]
        checks = 0
        while time.monotonic() < end or checks < 5:
            time.sleep(1)
            checks += 1
            ok, h = healthy_judged(p)
            with Lock():
                p = pending()
                if not p or p.get("token") != args.token:
                    log("confirmed or replaced meanwhile")
                    return 0
            if ok:
                break
    with Lock():
        p = pending()
        if not p or p.get("token") != args.token:
            return 0
        hd = hold()
        if hd:
            rearm(p, hd["until"] - now() + 5, "hold set during the restore")
            return 0
        sw = switch_wait(p)
        if h["healthy"]:
            if sw:
                extend(p, f"restored, but the switch still runs ({sw})")
            else:
                confirm(p, "restored")
                write_metrics()
            return 0
        if upstream_only(h):
            upstream_wait(p)
            return 0
        if sw:
            extend(p, f"restored, still unhealthy, switch still running ({sw})")
            return 0
    rollback(p, h)
    return 0


def cmd_arm(args):
    arm(realpath(args.toplevel or "/nix/var/nix/profiles/system"))
    return 0


def cmd_boot(args):
    """At boot: re-arm a deploy that was pending when the machine went
    down (deadline from now), drop it if another system booted."""
    try:
        with Lock():
            p = pending()
            if p and p.get("bootId") != boot_id():
                cur = current_system()
                if cur == p.get("new"):
                    p["bootId"] = boot_id()
                    p["armed"] = now()
                    p["armedMono"] = time.monotonic()
                    rearm(p, CFG["deadline"], "rebooted into the pending system")
                else:
                    remove(path("pending.json"))
                    event("dropped", why=f"booted {short(cur)}, not the pending {short(p.get('new'))}")
    finally:
        write_metrics()
        boot_fallback()
    return 0


# ---------------------------------------------------------------- boot counting

LOADER_GUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"


def boot_count_path():
    """LoaderBootCountPath: set by systemd-boot only when it booted an entry
    with a counter (after decrementing it), e.g. \\loader\\entries\\x+1-1.conf.
    None = a blessed or uncounted entry."""
    try:
        with open(f"/sys/firmware/efi/efivars/LoaderBootCountPath-{LOADER_GUID}", "rb") as f:
            raw = f.read()[4:]  # 4 bytes of attributes, then UTF-16LE
    except OSError:
        return None
    return raw.decode("utf-16-le", errors="replace").rstrip("\0") or None


def parse_counter(cpath):
    """(entry id without counter, tries left, tries done) of a counted path."""
    name = cpath.replace("\\", "/").rsplit("/", 1)[-1]
    stem, dot, ext = name.rpartition(".")
    base, plus, counter = stem.rpartition("+")
    if not plus:
        return None
    left, _, done = counter.partition("-")
    if not left.isdigit() or (done and not done.isdigit()):
        return None
    return base + dot + ext, int(left), int(done or 0)


def bless_status():
    """systemd-bless-boot status: clean (no counter), indeterminate (counted,
    not decided yet), dirty (counted, no tries left), good, bad."""
    r = run([CFG["blessBoot"], "status"], timeout=15)
    return r.stdout.strip() or f"unknown ({r.stderr.strip()[:80]})"


def boot_metrics(**values):
    """/run/selfheal/boot.prom, next to the deploy guard's file."""
    try:
        lines = []
        for k, v in values.items():
            lines += [f"# TYPE selfheal_boot_{k} gauge", f"selfheal_boot_{k} {int(v)}"]
        mdir = CFG["metricsDir"]
        os.makedirs(mdir, exist_ok=True)
        write_atomic(os.path.join(mdir, "boot.prom"), "\n".join(lines) + "\n")
    except Exception as e:  # noqa: BLE001
        log(f"cannot write boot metrics: {e}")


def boot_reboot_blocker(counter, status):
    """Why a failed boot must NOT reboot, or None. Never on a blessed or
    uncounted entry (that is what makes a loop impossible), and never on an
    entry booted again after its tries ran out (every entry bad: it would
    just be picked again). So at most `tries` reboots per entry."""
    if counter is None:
        return "not a counted boot entry"
    if status not in ("indeterminate", "dirty"):
        return f"boot entry is {status}"
    entry, left, done = counter
    if done > CFG["bootTries"]:
        return f"entry {entry} has no tries left (try {done} of {CFG['bootTries']}): nothing better to boot"
    hd = hold()
    if hd:
        return f"held until {iso(hd['until'])}"
    sw = switch_running()
    if sw:
        return f"a switch is running ({sw})"
    peers = CFG.get("bootTangPeers") or []
    if peers and not any(tcp_answers(p["address"], p.get("dev"), TANG_PORT) for p in peers):
        names = ",".join(f"{p['address']}%{p.get('dev')}" for p in peers)
        return f"{NO_TANG_PEER} ({names}): after a reboot nobody could unlock this machine"
    return None


TANG_PORT = 7654
NO_TANG_PEER = "no tang peer answers"
RECOVERED = "recovered"


def tcp_answers(addr, dev, port, timeout=3):
    """A TCP connect to addr (link-local: scoped to dev) on port."""
    target = f"{addr}%{dev}" if dev and addr.lower().startswith("fe80") else addr
    try:
        socket.create_connection((target, port), timeout=timeout).close()
        return True
    except OSError:
        return False


def healthy_now():
    """Boot health, healthy twice in a row 1 s apart (a flapping sshd is
    not blessed). Returns (healthy, last result)."""
    h = health("boot")
    if h["healthy"]:
        time.sleep(1)
        h = health("boot")
    return h["healthy"], h


def bless(counter, **extra):
    event("boot-healthy", entry=counter[0] if counter else "?",
          tries_done=counter[2] if counter else "?", **extra)
    boot_metrics(health_ok=1)
    return 0


def cmd_boot_health(args):
    """selfheal-boot-healthy.service (./boot-counting.nix): gate
    boot-complete.target on local health; on a counted entry that never
    gets healthy, reboot so systemd-boot spends the next try."""
    cpath = boot_count_path()
    counter = parse_counter(cpath) if cpath else None
    status = bless_status()
    log(f"boot entry: {cpath or 'uncounted'}, bless status {status}")
    if status in ("clean", "good", "bad"):
        # nothing to decide (a switch may start this unit on a running,
        # already assessed boot)
        return 0
    # monotonic: the gate starts right when timesyncd may step the clock
    end = time.monotonic() + CFG["bootHealthTimeout"]
    while True:
        ok, h = healthy_now()
        if ok:
            return bless(counter)
        if time.monotonic() >= end:
            break
        nxt = min(end, time.monotonic() + CFG["bootHealthInterval"])
        while time.monotonic() < nxt:
            time.sleep(1)
    boot_metrics(health_ok=0)
    # Blocked only because no Tang peer answers (vit/som after a power cut:
    # the peer's Wi-Fi or unlock may come late): poll the peer for a while
    # before giving up, and re-check health each time (a boot that recovers
    # meanwhile, e.g. the gateway back after the power cut, is blessed,
    # never restarted). Hold, a running switch and the tries cap still win.
    poll_end = time.monotonic() + CFG.get("bootTangPollTimeout", 3600)
    logged = False
    while True:
        why = "; ".join(f"{i['name']}: {i['detail']}" for i in failing(h))
        with Lock():
            blocker = boot_reboot_blocker(counter, status)
            withdrawn = False
            if not blocker and CFG.get("bootTangPeers"):
                blocker = withdraw_and_recheck(counter, status)
                withdrawn = not blocker
            if blocker == RECOVERED:
                return bless(counter, after="tang withdraw")
            if not blocker:
                assert counter is not None  # boot_reboot_blocker refuses uncounted boots
                try:
                    event("boot-unhealthy", failing=why, reboot="yes", entry=counter[0],
                          tries_left=counter[1], tries_done=counter[2])
                    os.sync()
                    # Under the lock, right after the switch check: narrows the
                    # window for a deploy starting now (clan-boot-* does not take
                    # this lock; the builder writes tmp + rename anyway).
                    r = run(["systemctl", "reboot"], timeout=60)
                except BaseException:
                    if withdrawn:
                        run(["systemctl", "start", "tangd.socket"], timeout=30)
                    raise
                if r.returncode != 0:
                    # never leave our Tang withdrawn on a boot that stays up:
                    # the peer could not be unlocked at its next boot
                    if CFG.get("bootTangPeers"):
                        run(["systemctl", "start", "tangd.socket"], timeout=30)
                    event("boot-reboot-failed", error=(r.stderr or "").strip()[:200])
                return 1
            tang_only = blocker.startswith(NO_TANG_PEER)
            if not tang_only or time.monotonic() >= poll_end:
                event("boot-unhealthy", failing=why, reboot="no", why=blocker)
                return 1
            if not logged:
                event("boot-unhealthy-waiting", failing=why, why=blocker,
                      poll=f"every {CFG.get('bootTangPollInterval', 30)} s for up to {CFG.get('bootTangPollTimeout', 3600)} s")
                logged = True
        nxt = time.monotonic() + CFG.get("bootTangPollInterval", 30)
        while time.monotonic() < nxt:
            time.sleep(1)
        ok, h = healthy_now()
        if ok:
            return bless(counter, after="tang wait")


def withdraw_and_recheck(counter, status):
    """Two-phase Tang check before a restart: stop answering as a Tang peer
    ourselves, wait longer than a peer's check-to-restart latency, then look
    at the peers again. A peer whose gate expires at the same moment then
    sees us gone, so of two simultaneous gates neither restarts (both stay
    up, safe). Our Tang comes back whenever we stay up, also on an error.
    Returns a blocker (NO_TANG_PEER-prefixed ones are retried by the poll)
    or None."""
    load = run(["systemctl", "show", "-P", "LoadState", "tangd.socket"], timeout=15).stdout.strip()
    if load in ("not-found", "masked"):
        # nothing to withdraw (no Tang server here)
        return boot_reboot_blocker(counter, status)
    if load != "loaded":
        # fail closed: a failed read must not fall back to check-then-act
        return f"{NO_TANG_PEER} check impossible: tangd.socket load state {load or 'unknown'}"
    # n2: a `systemctl stop` of the gate during the withdraw becomes an
    # exception, so the finally below brings our Tang back
    old = signal.signal(signal.SIGTERM, _term)
    blocker = None
    try:
        r = run(["systemctl", "stop", "tangd.socket"], timeout=30)
        if r.returncode != 0 or unit_active("tangd.socket"):
            blocker = (f"{NO_TANG_PEER} check impossible: cannot withdraw our own tang "
                       f"({(r.stderr or '').strip()[:80]})")
            return blocker
        t = time.monotonic() + CFG.get("bootTangWithdraw", 15)
        while time.monotonic() < t:
            time.sleep(1)
        blocker = boot_reboot_blocker(counter, status)
        # the boot may have recovered while we waited: bless, don't restart
        if not blocker and healthy_now()[0]:
            blocker = RECOVERED
        # Something (a switch through sockets.target) may have started our
        # Tang again meanwhile: then a peer re-checking now sees us.
        if not blocker and unit_active("tangd.socket"):
            blocker = f"{NO_TANG_PEER} check impossible: our own tang came back during the withdraw"
        return blocker
    except BaseException:
        blocker = blocker or "error"
        raise
    finally:
        signal.signal(signal.SIGTERM, old)
        if blocker:
            # refused by systemd while a shutdown is queued (Conflicts=shutdown.target)
            run(["systemctl", "start", "tangd.socket"], timeout=30)


def _term(signum, frame):
    raise SystemExit(143)


def profile_entry():
    """(path, counter) of the system profile's boot entry, or None: the
    entry of the profile's generation number whose kernel line boots the
    profile's toplevel (never a specialisation)."""
    link = os.readlink("/nix/var/nix/profiles/system")  # system-<N>-link
    gen = link.split("-")[1] if link.startswith("system-") else None
    top = realpath("/nix/var/nix/profiles/system")
    edir = os.path.join(CFG["bootMountPoint"], "loader", "entries")
    for name in sorted(os.listdir(edir)):
        if not (name.startswith("nixos-") and name.endswith(".conf")):
            continue
        try:
            with open(os.path.join(edir, name)) as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        version = any(x.startswith(f"version Generation {gen} ") for x in lines)
        boots = any(x.startswith("options ") and f"init={top}/init" in x.split() for x in lines)
        if version and boots:
            return os.path.join(edir, name), parse_counter(name)
    return None


def retry_profile_entry():
    """Before a live switch to the system profile: if its entry was marked
    bad (+0-N, by a failed boot or an outage), the operator just chose it
    again, so give it fresh tries (+<tries>). Without this the builder keeps
    the bad name (same contents) and the next boot silently takes an older
    entry. The new name comes only from the entry's own file name."""
    pe = profile_entry()
    if not pe or not pe[1] or pe[1][1] != 0:
        return
    path_, (entry, _left, done) = pe
    stem = os.path.basename(path_).rsplit("+", 1)[0]
    new = os.path.join(os.path.dirname(path_), f"{stem}+{CFG['bootTries']}.conf")
    os.rename(path_, new)
    fd = os.open(os.path.dirname(path_), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    event("boot-entry-retry", entry=entry, was=f"+0-{done}", now=f"+{CFG['bootTries']}")


def boot_fallback(at_boot=True):
    """selfheal_boot_fallback: 1 while the next boot would not boot the
    system profile (its entry is bad: boot counting gave up on it) or, at
    boot, while an older entry is running (fallback, or picked in the
    menu). Written at boot (selfheal-boot.service) and by the pre-switch
    check of every live switch (after retry_profile_entry)."""
    if not CFG.get("bootCounting"):
        return
    try:
        pe = profile_entry()
        entry_bad = bool(pe and pe[1] and pe[1][1] == 0)
        profile = realpath("/nix/var/nix/profiles/system")
        booted = realpath("/run/booted-system")
        fell_back = entry_bad or (at_boot and booted != profile)
        if fell_back and at_boot:
            event("boot-fallback", booted=short(booted), profile=short(profile), profile_entry_bad=entry_bad)
        mdir = CFG["metricsDir"]
        os.makedirs(mdir, exist_ok=True)
        write_atomic(os.path.join(mdir, "boot-fallback.prom"),
                     "# TYPE selfheal_boot_fallback gauge\n"
                     f"selfheal_boot_fallback {1 if fell_back else 0}\n")
    except Exception as e:  # noqa: BLE001 -- metrics never break an action
        log(f"cannot write the fallback metric: {e}")


# ---------------------------------------------------------------- user commands

def cmd_health(args):
    h = health(args.level)
    if args.json:
        print(json.dumps(h, indent=1))
    else:
        print_health(h)
    return 0 if h["healthy"] else 1


def cmd_confirm(args):
    p = pending()
    if not p:
        print(f"{host()}: no deploy pending")
        return 0
    if not args.force:
        # judged like the timer: an item already failing before the switch
        # doesn't hold up the confirmation
        ok, h = healthy_judged(p)
        if not ok:
            print_health(h)
            print(f"{host()}: not confirmed (unhealthy); `selfheal confirm --force` disarms anyway")
            return 1
    with Lock():
        p = pending()
        if p:
            confirm(p, "forced" if args.force else "cli")
    write_metrics()
    print(f"{host()}: confirmed {short(p.get('new') if p else None)}")
    return 0


def cmd_hold(args):
    minutes = args.minutes
    if minutes <= 0:
        return cmd_release(args)
    secs = min(minutes * 60, CFG["holdMax"])
    with Lock():
        write_json(hold_path(), {"until": now() + secs, "set": iso(now())})
        event("hold", until=iso(now() + secs))
    write_metrics()
    print(f"{host()}: deploy guard held until {iso(now() + secs)} (no restore, no rollback)")
    return 0


def cmd_release(args):
    with Lock():
        had = os.path.exists(hold_path())
        remove(hold_path())
        if had:
            event("release")
        p = pending()
        # A hold pushed the pending assessment out to its expiry: bring it in.
        if p and had:
            rearm(p, CFG["extendStep"], "hold released")
    write_metrics()
    print(f"{host()}: hold released" + (f"; pending deploy assessed in {CFG['extendStep']} s" if p and had else ""))
    return 0


def cmd_clear(args):
    fl = flag()
    with Lock():
        remove(path("rolled-back"))
        if fl:
            event("cleared", was=block_line(fl))
    write_metrics()
    print(f"{host()}: " + ("rollback flag cleared, deploys allowed again" if fl else "no rollback flag"))
    return 0


def cmd_status(args):
    fl = flag()
    if args.blocked:
        if fl:
            print(block_line(fl))
            return BLOCKED_EXIT
        return 0
    p = pending()
    hd = hold()
    lines = []
    try:
        with open(os.path.join(state_dir(), "log.jsonl")) as f:
            lines = [json.loads(x) for x in f.readlines()[-10:]]
    except (OSError, ValueError):
        pass
    if args.json:
        print(json.dumps({"pending": p, "hold": hd, "rolledBack": fl, "log": lines}, indent=1))
        return 0
    print(f"{host()}: running {short(current_system())}")
    if p:
        print(f"  pending deploy: {short(p.get('prev'))} -> {short(p.get('new'))}, "
              f"armed {iso(p['armed'])}, assessed at {iso(p['deadline'])}")
        base = p.get("baseline")
        print("  judged items (healthy when armed): " + (", ".join(base) if base is not None else "all"))
    else:
        print("  pending deploy: none")
    print(f"  hold: {'until ' + iso(hd['until']) if hd else 'none'}")
    print(f"  rollback flag: {block_line(fl) if fl else 'none'}")
    if lines:
        print("  last actions:")
        for e in lines:
            extra = " ".join(f"{k}={v}" for k, v in e.items() if k not in ("time", "event"))
            print(f"    {e['time']} {e['event']} {extra}")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="selfheal", description="self-heal: deploy guard, boot counting (docs/self-heal.md)")
    ap.add_argument("--config", required=True, help=argparse.SUPPRESS)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("health", help="check health")
    s.add_argument("--level", choices=["deploy", "local", "boot"], default="deploy")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_health)
    s = sub.add_parser("status", help="pending deploy, hold, rollback flag, last actions")
    s.add_argument("--blocked", action="store_true", help=f"only the rollback flag: exit {BLOCKED_EXIT} if set")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_status)
    s = sub.add_parser("confirm", help="confirm the pending deploy (if healthy)")
    s.add_argument("--force", action="store_true", help="disarm without the health check")
    s.set_defaults(fn=cmd_confirm)
    s = sub.add_parser("hold", help="suspend restore/rollback for <minutes> (0 = release)")
    s.add_argument("minutes", type=int)
    s.set_defaults(fn=cmd_hold)
    s = sub.add_parser("release", help="end a hold")
    s.set_defaults(fn=cmd_release)
    s = sub.add_parser("clear", help="clear the rollback flag (deploys allowed again)")
    s.set_defaults(fn=cmd_clear)
    s = sub.add_parser("boot", help=argparse.SUPPRESS)
    s.set_defaults(fn=cmd_boot)
    s = sub.add_parser("boot-health", help="gate boot-complete.target; reboot a counted entry that stays unhealthy")
    s.set_defaults(fn=cmd_boot_health)
    dg = sub.add_parser("deploy-guard", help="deploy guard internals")
    dgs = dg.add_subparsers(dest="dgcmd", required=True)
    s = dgs.add_parser("assess")
    s.add_argument("--token", required=True)
    s.set_defaults(fn=cmd_assess)
    s = dgs.add_parser("arm", help="arm for a toplevel (default: the system profile)")
    s.add_argument("toplevel", nargs="?")
    s.set_defaults(fn=cmd_arm)
    s = dgs.add_parser("pre-switch", help=argparse.SUPPRESS)
    s.add_argument("toplevel")
    s.add_argument("action")
    s.set_defaults(fn=cmd_pre_switch)
    args = ap.parse_args()
    with open(args.config) as f:
        CFG.update(json.load(f))
    CFG["_configPath"] = args.config
    os.environ["PATH"] = CFG["path"]
    if os.geteuid() != 0:
        print("selfheal: run as root", file=sys.stderr)
        return 2
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
