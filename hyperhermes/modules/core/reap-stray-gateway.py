# Run as the agent's user before its gateway unit starts (./agents.nix,
# preStart): end every other gateway process of this HERMES_HOME.
#
# Only the unit runs the agent's gateway
# (patches/hermes-gateway-managed-unit-only.patch). A gateway started
# anyway (by an older hermes, with HERMES_GATEWAY_MANAGED_UNIT unset, or
# from the dashboard's restart fallback) holds the home's gateway lock,
# and the unit then "attaches" to it and exits 75 on every start, forever
# (som, stefan, 2026-11: 1900+ restarts behind a cron worker's
# `gateway run --idle-exit`). The unit takes over instead: SIGTERM (the
# gateway drains its adapters), SIGKILL after a grace period.
#
# A candidate is a process of this uid, outside this system unit's cgroup
# (0::/system.slice/<unit>; the previous main process is gone by now:
# KillMode=control-group), whose argv is hermes' `gateway` command (bare
# or `run`) and whose environment names this HERMES_HOME. Everything else
# (cron workers, the dashboard, `hermes gateway status`, a gateway of a
# profile under this home) is left alone. Each candidate is held by a
# pidfd from the scan on, so a PID the kernel reuses is never signalled.
import os
import select
import signal
import sys
import time

home = os.path.realpath(sys.argv[1])
unit = sys.argv[2]
grace = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
me = os.getpid()
uid = os.getuid()
own_cgroup = "0::/system.slice/" + unit
ENTRY = ("hermes", "hermes_cli.main", "hermes_cli/main.py")


def read(pid, name):
    try:
        with open(f"/proc/{pid}/{name}", "rb") as f:
            return f.read()
    except OSError:
        return None


def is_gateway_run(argv):
    """`<python> <.../bin/hermes | -m hermes_cli.main> gateway [run] [flags]`, selectors removed."""
    for i in range(1, len(argv)):
        prev = argv[i - 1]
        if argv[i] == "gateway" and any(prev == e or prev.endswith("/" + e) for e in ENTRY):
            rest = [a for a in argv[i + 1:] if not a.startswith("-")]
            return not rest or rest[0] == "run"
    return False


def is_stray(pid):
    try:
        if os.stat(f"/proc/{pid}").st_uid != uid:
            return False
    except OSError:
        return False
    cgroup = (read(pid, "cgroup") or b"").decode(errors="replace")
    if any(line.rstrip("/") == own_cgroup for line in cgroup.splitlines()):
        return False
    argv = [a.decode(errors="replace") for a in (read(pid, "cmdline") or b"").split(b"\0") if a]
    # `hermes -p default gateway run` puts the selector between the entry and `gateway`.
    argv = [a for j, a in enumerate(argv)
            if not (a in ("--profile", "-p") or (j > 0 and argv[j - 1] in ("--profile", "-p")))]
    if not is_gateway_run(argv):
        return False
    env = (read(pid, "environ") or b"").split(b"\0")
    homes = [e[len(b"HERMES_HOME="):].decode(errors="replace") for e in env
             if e.startswith(b"HERMES_HOME=")]
    return bool(homes) and os.path.realpath(homes[0]) == home


def strays():
    """(pid, pidfd) of each stray. The pidfd is opened first and the process checked after, so the
    fd refers to the process that was checked (a PID reused before the open fails the checks)."""
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == me:
            continue
        pid = int(entry)
        try:
            fd = os.pidfd_open(pid)
        except OSError:
            continue
        if is_stray(pid):
            found.append((pid, fd))
        else:
            os.close(fd)
    return found


def signal_fd(fd, sig):
    try:
        signal.pidfd_send_signal(fd, sig)
    except ProcessLookupError:
        pass


targets = strays()
for pid, fd in targets:
    # No argv: it may carry secrets passed on a command line.
    print(f"hermes: taking over from a stray gateway of {home}: PID {pid}", file=sys.stderr)
    signal_fd(fd, signal.SIGTERM)
deadline = time.monotonic() + grace
while targets:
    left = deadline - time.monotonic()
    if left <= 0:
        break
    poller = select.poll()
    for _, fd in targets:
        poller.register(fd, select.POLLIN)
    # A pidfd turns readable when its process exits.
    done = {fd for fd, _ in poller.poll(left * 1000)}
    for pid, fd in [t for t in targets if t[1] in done]:
        os.close(fd)
    targets = [t for t in targets if t[1] not in done]
for pid, fd in targets:
    print(f"hermes: stray gateway PID {pid} ignored SIGTERM for {grace:.0f}s; killing it", file=sys.stderr)
    signal_fd(fd, signal.SIGKILL)
    os.close(fd)
