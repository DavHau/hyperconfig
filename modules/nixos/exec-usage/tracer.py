"""exec-usage tracer: which executables get exec'd, by whom, and when.

Runs bpftrace on sched:sched_process_exec (in-kernel map uid+path ->
count, printed and cleared every minute), resolves each path to the store
file it ends up at and keeps, per executable and user, the exec count and
the last exec time. The state goes to usage.json every few minutes
(renamed into place); nothing is logged per exec.

Executables are keyed by package name without hash and version
("<pname>/bin/x", see usage_key) so a package keeps its history across
rebuilds and bumps; infra-unused matches them the same way.
"""
import json
import os
import pwd
import re
import signal
import subprocess
import sys
import time

BPFTRACE, STATE = sys.argv[1], sys.argv[2]
FLUSH = int(os.environ.get("EXEC_USAGE_FLUSH", "300"))
PRUNE_DAYS = int(os.environ.get("EXEC_USAGE_PRUNE_DAYS", "180"))
STORE_RE = re.compile(r"^/nix/store/[0-9a-z]{32}-([^/]+)(/.*)?$")
# builtins.parseDrvName: the version starts at the first dash followed by
# a non-letter.
NAME_RE = re.compile(r"^(.*?)-[^A-Za-z]")


def usage_key(store_path):
    """/nix/store/<hash>-util-linux-2.42-bin/bin/x -> util-linux/bin/x."""
    m = STORE_RE.match(store_path)
    if not m:
        return None
    n = NAME_RE.match(m.group(1))
    return (n.group(1) if n else m.group(1)) + (m.group(2) or "")


HOST_MNTNS = os.stat("/proc/1/ns/mnt").st_ino

# Nix build users (nixbld*, 30000+) and auto-allocated build uids
# (872415232+) are dropped in the kernel: builds would drown everything.
PROG = """
config = { max_map_keys = 16384; max_strlen = 256 }
tracepoint:sched:sched_process_exec
/ !(uid >= 30000 && uid < 31000) && uid < 872415232 /
{
  @e[uid, curtask->nsproxy->mnt_ns->ns.inum, str(args.filename)] = count();
}
interval:s:60 { print(@e); clear(@e); }
"""


def load():
    try:
        with open(STATE) as f:
            s = json.load(f)
        if s.get("version") == 1:
            return s
    except (OSError, ValueError):
        pass
    return {"version": 1, "since": int(time.time()), "exes": {}}


state = load()
users = {}
resolved = {}


def user(uid):
    if uid not in users:
        try:
            users[uid] = pwd.getpwuid(uid).pw_name
        except KeyError:
            users[uid] = "uid:%d" % uid
    return users[uid]


def key(path, host):
    """Store-relative key for an exec'd path, or None if unresolvable."""
    if (path, host) in resolved:
        return resolved[(path, host)]
    k = None
    if path.startswith("/nix/store/"):
        # Store paths mean the same in every mount namespace.
        try:
            path = os.path.realpath(path)
        except OSError:
            pass
        k = usage_key(path)
    elif host and path.startswith("/") and not path.startswith("/proc/"):
        # Only in our mount namespace: a container's /run/current-system
        # is not ours, so there only store paths count.
        # Execs outside the store (venvs, ~/bin, /usr/bin/env) keep their path.
        k = usage_key(os.path.realpath(path)) or path
    resolved[(path, host)] = k
    return k


def merge(batch, now):
    exes = state["exes"]
    for raw, n in batch.items():
        uid, ns, path = raw.split(",", 2)
        k = key(path, int(ns) == HOST_MNTNS)
        if k is None:
            continue
        e = exes.setdefault(k, {}).setdefault(user(int(uid)), {"n": 0, "last": 0})
        e["n"] += n
        e["last"] = now


def flush():
    now = int(time.time())
    cut = now - PRUNE_DAYS * 86400
    for k in list(state["exes"]):
        us = state["exes"][k]
        for u in [u for u, e in us.items() if e["last"] < cut]:
            del us[u]
        if not us:
            del state["exes"][k]
    state["updated"] = now
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, separators=(",", ":"), sort_keys=True)
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATE)
    # Symlinks (/run/current-system/sw) move on a switch; uids get added.
    resolved.clear()
    users.clear()


def stop(*_):
    flush()
    sys.exit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

proc = subprocess.Popen([BPFTRACE, "-f", "json", "-q", "-e", PROG],
                        stdout=subprocess.PIPE, text=True)
flush()
last = time.time()
for line in proc.stdout:  # type: ignore[union-attr]
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("type") == "map":
        merge(msg["data"].get("@e", {}), int(time.time()))
    if time.time() - last >= FLUSH:
        flush()
        last = time.time()
flush()
sys.exit(proc.wait() or 1)
