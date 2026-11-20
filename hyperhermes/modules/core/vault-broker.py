"""The vault broker of one agent account (./vault-broker.nix): owns the agent's hermes vault.

Runs as a dynamic user of its own with its state in /var/lib/private (0700 root): the agent's
uid cannot read the key or the ciphertext. Socket-activated on /run/hermes-vault/<agent>.sock
(root's directory and socket, 0666: any uid may connect, this server decides). Requests are one
JSON line per connection, `{op, home, ...}`; the reply is one JSON object.

Who may do what (SO_PEERCRED, checked on every request, never the socket's mode):
  - only the agent's uid, anything else is refused;
  - list_items, get_meta, has_items, add_item, remove_item: any process of the agent (the CLI,
    the vault-request page, the desktop app's methods, browser_vault create_login);
  - resolve_secret (the values): only the main process of the agent's gateway or dashboard unit
    (or another unit the host names in BROKER_FILL_UNITS), checked against systemd's MainPID per
    request, and the connecting process pinned with a pidfd so a recycled pid cannot pass. A
    terminal command, a script, a kernel, a cron worker is another process and is refused.
  - no operation returns the key or exports the store.

`home` names whose vault: the agent's home (BROKER_AGENT_HOME), one of its profiles/<name>, or
another home of the account (kept apart, at most MAX_HOMES). The store per home is hermes' own
VaultStore (agent/vault_store.py) on files under $STATE_DIRECTORY, same format as before.

Every resolve, add and remove is logged (op, item id, kind, label, the peer's unit); never a value.
Resolves are capped per hour (logins and cards+addresses separately), so a harvest is slow and
visible. Each request has 10 s from connect to reply; at most 4 open requests per process, 32 in all
(a deliberate flood from many processes of the agent can still delay its own fills: visible, and
nothing leaks).
"""
from __future__ import annotations

import collections
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

STATE = Path(os.environ["STATE_DIRECTORY"].split(":")[0])
AGENT = os.environ["BROKER_AGENT"]
AGENT_UID = int(os.environ["BROKER_AGENT_UID"])
AGENT_HOME = os.path.normpath(os.environ["BROKER_AGENT_HOME"])
FILL_UNITS = [u for u in os.environ.get("BROKER_FILL_UNITS", "").split() if u]
SYSTEMCTL = os.environ.get("BROKER_SYSTEMCTL", "systemctl")
LIMITS = {"login": int(os.environ.get("BROKER_LOGIN_RESOLVES_PER_HOUR", "60")),
          "card": int(os.environ.get("BROKER_CARD_RESOLVES_PER_HOUR", "30"))}
MAX_REQUEST = 64 * 1024
MAX_IMPORT = 8 * 1024 * 1024  # root's migration request
MAX_SECRET = 8 * 1024
MAX_ITEMS = 1000
MAX_HOMES = 32
MAX_CONNECTIONS = 32
MAX_PER_PID = 4  # a slow or flooding process cannot take every slot from the gateway
TIMEOUT = 10.0  # per request, start to reply
SO_PEERPIDFD = getattr(socket, "SO_PEERPIDFD", 77)
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

# hermes' config loader reads $HERMES_HOME/config.yaml (vault.key_storage): an empty home of ours.
os.environ["HERMES_HOME"] = str(STATE / "config-home")

from agent.vault_store import VaultError, VaultStore  # noqa: E402


class Refused(Exception):
    """A refusal the client may see (no values, no paths of ours)."""


def log(msg: str, level: int = 6) -> None:
    print(f"<{level}>{msg}", flush=True)


def home_key(home: str) -> str:
    """The store directory for a home: `home`, `profiles/<name>`, or `other/<digest>`."""
    if not isinstance(home, str) or not home.startswith("/") or "\0" in home or len(home) > 4096:
        raise Refused("bad home")
    home = os.path.normpath(home)
    if home == AGENT_HOME:
        return "home"
    parent, name = os.path.split(home)
    if parent == os.path.join(AGENT_HOME, "profiles") and PROFILE_RE.match(name):
        return f"profiles/{name}"
    key = "other/" + hashlib.sha256(home.encode()).hexdigest()[:32]
    if not (STATE / key).exists():
        others = STATE / "other"
        if others.is_dir() and sum(1 for _ in others.iterdir()) >= MAX_HOMES:
            raise Refused("too many vault homes for this account")
    return key


def store_for(home: str) -> tuple[str, VaultStore]:
    key = home_key(home)
    return key, VaultStore(base_dir=STATE / key / "vault", direct=True)


def peer_of(conn: socket.socket) -> tuple[int, int]:
    pid, uid, _gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                        struct.calcsize("3i")))
    return pid, uid


def main_pid(unit: str) -> int:
    try:
        out = subprocess.run([SYSTEMCTL, "show", "-P", "MainPID", unit], capture_output=True, text=True,
                             timeout=5, check=False)
        return int(out.stdout.strip() or 0)
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0


def pidfd_pid(fd: int) -> int:
    """The pid a pidfd refers to now: -1 once that process is gone (its pid may be reused)."""
    with open(f"/proc/self/fdinfo/{fd}") as f:
        for line in f:
            if line.startswith("Pid:"):
                return int(line.split()[1])
    return -1


def filling_unit(conn: socket.socket, pid: int) -> str:
    """The unit whose main process this peer is, or Refused. Pinned by a pidfd taken from the
    connection: the pid is compared with systemd's MainPID, then the pidfd must still name that
    pid (the connecting process is alive, so the pid was not recycled in between)."""
    try:
        pidfd = struct.unpack("i", conn.getsockopt(socket.SOL_SOCKET, SO_PEERPIDFD, 4))[0]
    except OSError:
        raise Refused("this kernel gives no peer pidfd; values are not handed out") from None
    try:
        units = [f"hermes-agent-{AGENT}.service", f"hermes-dashboard-{AGENT}.service", *FILL_UNITS]
        unit = next((u for u in units if pid > 0 and main_pid(u) == pid), None)
        if unit is None or pidfd_pid(pidfd) != pid:
            raise Refused("values go only to the agent's gateway or dashboard process, for a fill; "
                          "not to a terminal command, a script or a worker")
        return unit
    finally:
        os.close(pidfd)


_rate_lock = threading.Lock()
_resolves: dict[str, collections.deque] = {"login": collections.deque(), "card": collections.deque()}


def take_resolve(kind: str) -> None:
    group = "login" if kind == "login" else "card"
    now = time.monotonic()
    with _rate_lock:
        q = _resolves[group]
        while q and now - q[0] > 3600:
            q.popleft()
        if len(q) >= LIMITS[group]:
            raise Refused(f"too many {group} fills this hour ({LIMITS[group]}); try again later")
        q.append(now)


def import_items(key: str, store: VaultStore, items: object) -> list[str]:
    """The migration's merge (root only): legacy records whose ids the store lacks, ids and
    fields kept as they were. Returns every id the store holds afterwards."""
    if not isinstance(items, list) or len(items) > MAX_ITEMS:
        raise Refused("bad import")
    with store._locked():
        have = store._read_all()
        ids = {r.get("id") for r in have}
        # the same shape and quotas as add_item: the agent can plant a legacy vault
        added = [r for r in items if isinstance(r, dict) and isinstance(r.get("id"), str)
                 and re.fullmatch(r"vault_[0-9a-f]{1,32}", r["id"])
                 and r.get("kind") in ("login", "payment", "address") and r["id"] not in ids
                 and isinstance(r.get("secret"), dict) and len(json.dumps(r)) <= MAX_SECRET + 1024]
        if len(have) + len(added) > MAX_ITEMS:
            raise Refused(f"the vault would hold more than {MAX_ITEMS} items")
        if added:
            store._write_all(have + added)
        held = [r.get("id") for r in store._read_all()]
    log(f"import home={key} added={len(added)} held={len(held)}")
    return held


def handle(conn: socket.socket, req: dict, pid: int, uid: int) -> object:
    op = req.get("op")
    if uid == 0 and op == "import":
        key, store = store_for(str(req.get("home") or ""))
        return import_items(key, store, req.get("items"))
    if uid != AGENT_UID:
        raise Refused("this vault belongs to another account")
    key, store = store_for(str(req.get("home") or ""))
    if op == "list_items":
        return [m.to_dict() | {"identifier_type": m.identifier_type} for m in store.list_items()]
    if op == "has_items":
        return store.has_items()
    if op == "get_meta":
        meta = store.get_meta(str(req.get("item_id", "")))
        return meta.to_dict() | {"identifier_type": meta.identifier_type} if meta else None
    if op == "add_item":
        secret = req.get("secret")
        if not isinstance(secret, dict) or len(json.dumps(secret)) > MAX_SECRET:
            raise Refused("bad or oversized item")
        if len(store.list_items()) >= MAX_ITEMS:
            raise Refused(f"the vault holds {MAX_ITEMS} items; remove some first")
        meta = store.add_item(str(req.get("kind", "")), str(req.get("label", "")), secret,
                              origin=req.get("origin") or None)
        log(f"add {meta.id} kind={meta.kind} label={meta.label!r} home={key} pid={pid}")
        return meta.to_dict() | {"identifier_type": meta.identifier_type}
    if op == "remove_item":
        item_id = str(req.get("item_id", ""))
        removed = store.remove_item(item_id)
        log(f"remove {item_id} home={key} pid={pid} removed={removed}")
        return removed
    if op == "resolve_secret":
        item_id = str(req.get("item_id", ""))
        try:
            unit = filling_unit(conn, pid)
        except Refused:
            global _refusal_logged
            if time.monotonic() - _refusal_logged > 10:  # at most one line per 10 s
                _refusal_logged = time.monotonic()
                log(f"REFUSED resolve {item_id} home={key} pid={pid} (not the gateway or dashboard)", 4)
            raise
        meta = store.get_meta(item_id)
        if meta is None:
            raise Refused(f"no vault item with id {item_id!r}")
        take_resolve(meta.kind)
        log(f"resolve {item_id} kind={meta.kind} label={meta.label!r} home={key} unit={unit}")
        return store.resolve_secret(item_id)
    raise Refused("unknown operation")


_per_pid: collections.Counter = collections.Counter()
_per_pid_lock = threading.Lock()
_refusal_logged = 0.0


def serve_one(conn: socket.socket, slots: threading.Semaphore) -> None:
    pid = -1
    try:
        deadline = time.monotonic() + TIMEOUT
        pid, uid = peer_of(conn)
        with _per_pid_lock:
            _per_pid[pid] += 1
            busy = _per_pid[pid] > MAX_PER_PID
        if busy:
            raise Refused("too many open requests from this process")
        limit = MAX_IMPORT if uid == 0 else MAX_REQUEST
        data = b""
        while b"\n" not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Refused("request too slow")
            conn.settimeout(remaining)
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > limit:
                raise Refused("request too large")
        try:
            req = json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
            if not isinstance(req, dict):
                raise ValueError
        except ValueError:
            raise Refused("bad request") from None
        reply = {"ok": True, "result": handle(conn, req, pid, uid)}
    except (Refused, TimeoutError) as exc:
        reply = {"ok": False, "error": str(exc) or "request too slow"}
    except VaultError as exc:
        reply = {"ok": False, "error": str(exc)[:300]}
    except Exception as exc:  # never a value: log the type only
        log(f"error {type(exc).__name__}", 3)
        reply = {"ok": False, "error": "the vault broker failed"}
    try:
        conn.settimeout(TIMEOUT)
        conn.sendall(json.dumps(reply).encode("utf-8"))
    except OSError:
        pass
    finally:
        conn.close()
        with _per_pid_lock:
            _per_pid[pid] -= 1
            if _per_pid[pid] <= 0:
                del _per_pid[pid]
        slots.release()


def main() -> None:
    if os.environ.get("LISTEN_FDS") != "1":
        sys.exit("hermes-vault-broker: socket activation only")
    os.umask(0o077)
    listener = socket.socket(fileno=3)
    slots = threading.Semaphore(MAX_CONNECTIONS)
    log(f"vault broker of {AGENT} ready")
    while True:
        slots.acquire()
        conn, _ = listener.accept()
        threading.Thread(target=serve_one, args=(conn, slots), daemon=True).start()


if __name__ == "__main__":
    main()
