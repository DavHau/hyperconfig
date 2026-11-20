"""Move an agent's legacy hermes vaults into its vault broker (./vault-broker.nix), as root.

Before every (re)start of the agent's gateway, dashboard and vault-request page (the unit being
started waits for this; the others may still run, but a patched hermes never writes the legacy
files), for the agent's home and each profiles/<name>: a legacy
vault/vault.json.enc + vault.key (hermes' file vault, readable by the agent's uid) is

  1. read without following any link the agent may have planted: every path component opened
     with O_NOFOLLOW from the root down, each file a regular file of the agent's uid, size capped;
     hermes' legacy lock taken for at most 10 s (the agent cannot stall this unit with it);
  2. backed up as read to /root/hermes-vault-backup/<agent>/<home>/<time>/ (0700/0600 root;
     the same content once; the oldest and the 4 newest per home are kept);
  3. decrypted with its key and merged into the broker's store for that home (the broker's
     root-only `import`: records whose ids it lacks, ids kept, so handles stay valid);
  4. once the broker holds every legacy id: vault.json.enc removed, then vault.key (that order:
     a key without ciphertext is harmless, ciphertext without its key would be lost), both through
     the directory handle and only if still the very files that were read.

Any doubt (a link, a foreign owner, a keychain-held key, a decrypt failure, a missing id) leaves
the legacy files untouched and is logged; the agent then starts on the broker without those items,
and the next start tries again. Idempotent: no legacy files, nothing to do.

usage: vault-migrate <agent> <agent uid> <agent home> <broker socket>
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import shutil
import socket
import stat
import sys
import time

AGENT, AGENT_UID, AGENT_HOME, SOCKET = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
BACKUP = f"/root/hermes-vault-backup/{AGENT}"
MAX_FILE = 256 * 1024
MAX_BACKUPS = 5  # per home; a new one only when the content differs from the newest
LOCK_WAIT = 10.0
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
failed = False


def log(msg: str, level: int = 6) -> None:
    print(f"<{level}>{msg}", flush=True)


class Skip(Exception):
    pass


def open_path(path: str) -> int:
    """A directory handle for an absolute path, no component followed if it is a link."""
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in [p for p in path.split("/") if p]:
            nfd = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd
    except OSError:
        os.close(fd)
        raise


def read_file(dirfd: int, name: str) -> tuple[bytes, os.stat_result] | None:
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dirfd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Skip(f"{name}: cannot open without following a link ({exc.strerror})") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != AGENT_UID or st.st_nlink != 1:
            raise Skip(f"{name}: not a plain file of {AGENT}")
        if st.st_size > MAX_FILE:
            raise Skip(f"{name}: too large")
        data = b""
        while len(data) <= MAX_FILE:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
        return data, st
    finally:
        os.close(fd)


def take_lock(dirfd: int) -> int | None:
    """hermes' legacy vault lock, which every writer takes (VaultStore._locked), bounded: the agent
    could hold it, or put a FIFO in its place, to stall this unit and with it its gateway."""
    try:
        fd = os.open(".vault.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dirfd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Skip(f".vault.lock: cannot open without following a link ({exc.strerror})") from None
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != AGENT_UID or st.st_nlink != 1:
        os.close(fd)
        raise Skip(".vault.lock is not a plain file of the agent; left in place")
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() > deadline:
                os.close(fd)
                raise Skip("a process of the agent holds the vault lock; left in place") from None
            time.sleep(0.5)


def broker(op: str, **args) -> object:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    try:
        s.settimeout(60)
        s.connect(SOCKET)
        s.sendall(json.dumps({"op": op, **args}).encode() + b"\n")
        s.shutdown(socket.SHUT_WR)
        data = b""
        while chunk := s.recv(65536):
            data += chunk
    finally:
        s.close()
    reply = json.loads(data)
    if not reply.get("ok"):
        raise Skip(f"broker: {reply.get('error')}")
    return reply["result"]


def write_backup(rel: str, files: dict[str, bytes]) -> str:
    """root's copy before anything is removed. The same content as the newest backup of this home is
    not written again (the agent can replant and restart at will); at most MAX_BACKUPS per home."""
    os.umask(0o077)
    home_dir = os.path.join(BACKUP, rel.replace("/", "_"))
    os.makedirs(home_dir, mode=0o700, exist_ok=True)
    for part in ("/root/hermes-vault-backup", BACKUP, home_dir):
        os.chmod(part, 0o700)
    digest = hashlib.sha256(b"".join(files[n] for n in sorted(files))).hexdigest()
    existing = sorted(d for d in os.listdir(home_dir) if not d.startswith("."))
    if existing:
        with contextlib.suppress(OSError), open(os.path.join(home_dir, existing[-1], "sha256")) as f:
            if f.read().strip() == digest:
                return os.path.join(home_dir, existing[-1])
    path = os.path.join(home_dir, f"{time.strftime('%Y%m%dT%H%M%S')}-{os.getpid()}")
    os.makedirs(path, mode=0o700, exist_ok=True)
    for name, data in [*files.items(), ("sha256", digest.encode())]:
        fd = os.open(os.path.join(path, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    for d in (path, home_dir):
        dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
        os.fsync(dfd)
        os.close(dfd)
    # the first backup (the real legacy vault) stays: replanting can push out only later ones
    for old in sorted(d for d in os.listdir(home_dir) if not d.startswith("."))[1:-(MAX_BACKUPS - 1)]:
        shutil.rmtree(os.path.join(home_dir, old), ignore_errors=True)
    return path


def unlink_if_same(dirfd: int, name: str, st: os.stat_result) -> None:
    now = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    if (now.st_ino, now.st_dev) != (st.st_ino, st.st_dev):
        raise Skip(f"{name} changed while it was migrated; left in place")
    os.unlink(name, dir_fd=dirfd)


def migrate(home: str, rel: str) -> None:
    from cryptography.fernet import Fernet, InvalidToken

    try:
        vfd = open_path(os.path.join(home, "vault"))
    except FileNotFoundError:
        return
    except OSError as exc:
        raise Skip(f"vault directory: cannot open without following a link ({exc.strerror})") from None
    lock = None
    try:
        if os.fstat(vfd).st_uid != AGENT_UID:
            raise Skip(f"vault directory is not {AGENT}'s")
        enc = read_file(vfd, "vault.json.enc")
        key = read_file(vfd, "vault.key")
        if key is None and read_file(vfd, "vault.keyref") is not None:
            raise Skip("its key is in the owner's OS keychain (vault.keyref), out of root's reach; "
                       "run `hermes vault key migrate --to file` as the agent, then restart it")
        if enc is None or not enc[0]:
            if key is not None:
                log(f"{rel!r}: a vault.key without items; left in place (nothing to migrate)")
            return
        if key is None:
            raise Skip("vault.json.enc without vault.key: cannot be decrypted, left in place")
        # Every writer of the legacy vault takes this lock (VaultStore._locked); the agent's
        # units are stopped, this guards a stray CLI.
        lock = take_lock(vfd)
        enc = read_file(vfd, "vault.json.enc") or enc  # re-read under the lock
        try:
            data = json.loads(Fernet(key[0].strip()).decrypt(enc[0]))
        except (InvalidToken, ValueError):
            raise Skip("vault.json.enc does not decrypt with vault.key; left in place") from None
        items = data.get("items") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise Skip("vault.json.enc has an unexpected shape; left in place")
        backup = write_backup(rel, {"vault.json.enc": enc[0], "vault.key": key[0]})
        ids = [r.get("id") for r in items if isinstance(r, dict)]
        held = set(broker("import", home=home, items=items))
        missing = [i for i in ids if i not in held]
        if missing:
            raise Skip(f"the broker lacks {len(missing)} of {len(ids)} items after the import; left in place")
        unlink_if_same(vfd, "vault.json.enc", enc[1])
        unlink_if_same(vfd, "vault.key", key[1])
        os.fsync(vfd)
        log(f"{rel!r}: {len(ids)} items moved into the vault broker; legacy files removed, backup in {backup}")
    finally:
        if lock is not None:
            os.close(lock)
        os.close(vfd)


def main() -> None:
    global failed
    homes = [(AGENT_HOME, "home")]
    try:
        pfd = open_path(os.path.join(AGENT_HOME, "profiles"))
        try:
            for name in sorted(os.listdir(pfd)):
                st = os.stat(name, dir_fd=pfd, follow_symlinks=False)
                if stat.S_ISDIR(st.st_mode):
                    homes.append((os.path.join(AGENT_HOME, "profiles", name), f"profiles/{name}"))
        finally:
            os.close(pfd)
    except OSError:
        pass
    for home, rel in homes:
        try:
            migrate(home, rel)
        except Skip as exc:
            failed = True
            log(f"{rel!r}: NOT migrated: {exc}", 3)
        except Exception as exc:  # never a value
            failed = True
            log(f"{rel!r}: NOT migrated: {type(exc).__name__}", 3)
    # Exit 0 even then: the agent starts on the broker; the legacy files wait for the next start.
    if failed:
        log(f"some legacy vaults of {AGENT} are not migrated (see above); they stay where they were", 3)


main()
