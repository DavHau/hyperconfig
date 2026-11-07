"""Install a locked agent's pinned $HERMES_HOME entries (./locked-config.nix).

argv: the spec (JSON) and the .env text file. The spec names HERMES_HOME,
its owner's uid, and per entry its type (file or dir), mode and, for
files, the content file; `.env` gets the credentials of the calling unit
appended. Every entry is root's: an entry the agent owned could be
chmod-ed and rewritten before it is immutable.

$HERMES_HOME is the agent's own directory, so every name in it can be
renamed, replaced or deleted by the agent at any moment, and only the
immutable flag (which the agent cannot clear) ends that. Each entry is
therefore built under a fresh name, swapped into place with
renameat2(RENAME_EXCHANGE) (or put there with RENAME_NOREPLACE), made
immutable through the descriptor root holds, and then checked to be the
inode under the pinned name. Whatever the agent did in between (renamed
the new entry away, put its own back) fails that check: the stray entry
loses its flag again and the next attempt starts over. Nothing here
follows a symlink: every lookup is relative to the directory descriptor
with O_NOFOLLOW, and what sat under a name before is removed with the
descriptor-based rmtree.
"""

import ctypes
import errno
import fcntl
import json
import os
import secrets
import shutil
import stat
import struct
import sys

FS_IOC_GETFLAGS = 0x80086601
FS_IOC_SETFLAGS = 0x40086602
FS_IMMUTABLE_FL = 0x10
RENAME_NOREPLACE = 1
RENAME_EXCHANGE = 2
ATTEMPTS = 20

libc = ctypes.CDLL(None, use_errno=True)


def renameat2(dfd, old, new, flags):
    if libc.renameat2(dfd, old.encode(), dfd, new.encode(), flags) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), new)


def get_flags(fd):
    return struct.unpack("i", fcntl.ioctl(fd, FS_IOC_GETFLAGS, struct.pack("i", 0)))[0]


def set_immutable(fd, on):
    flags = get_flags(fd)
    fcntl.ioctl(fd, FS_IOC_SETFLAGS, struct.pack("i", flags | FS_IMMUTABLE_FL if on else flags & ~FS_IMMUTABLE_FL))


def open_entry(home, name, kind):
    """A descriptor of `name` itself if it is a `kind` (never through a link), else None."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    if kind == "dir":
        flags |= os.O_DIRECTORY
    try:
        fd = os.open(name, flags, dir_fd=home)
    except OSError:
        return None
    st = os.fstat(fd)
    if not (stat.S_ISDIR(st.st_mode) if kind == "dir" else stat.S_ISREG(st.st_mode)):
        os.close(fd)
        return None
    return fd


def is_pinned(home, name, spec, content):
    fd = open_entry(home, name, spec["type"])
    if fd is None:
        return False
    try:
        st = os.fstat(fd)
        if st.st_uid != 0 or st.st_gid != 0 or stat.S_IMODE(st.st_mode) != spec["mode"]:
            return False
        if not get_flags(fd) & FS_IMMUTABLE_FL:
            return False
        if spec["type"] == "dir":
            return os.listdir(fd) == []
        return os.pread(fd, len(content) + 1, 0) == content
    finally:
        os.close(fd)


def unpin(home, name):
    """Drop the immutable flag of whatever root-owned entry is at `name`, so it can move."""
    for kind in ("file", "dir"):
        fd = open_entry(home, name, kind)
        if fd is not None:
            try:
                if os.fstat(fd).st_uid == 0 and get_flags(fd) & FS_IMMUTABLE_FL:
                    set_immutable(fd, False)
            finally:
                os.close(fd)
            return


def remove(home, name):
    try:
        st = os.stat(name, dir_fd=home, follow_symlinks=False)
    except FileNotFoundError:
        return
    unpin(home, name)
    try:
        if stat.S_ISDIR(st.st_mode):
            shutil.rmtree(name, dir_fd=home)
        else:
            os.unlink(name, dir_fd=home)
    except OSError as e:
        print(f"could not remove {name}: {e}", file=sys.stderr)


def build(home, spec, content):
    tmp = f".hermes-locked.{secrets.token_hex(8)}"
    try:
        if spec["type"] == "dir":
            os.mkdir(tmp, 0o700, dir_fd=home)
            fd = open_entry(home, tmp, "dir")
            if fd is None:
                raise OSError(errno.EAGAIN, "staging directory moved", tmp)
        else:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=home)
    except OSError:
        remove(home, tmp)
        raise
    try:
        if spec["type"] != "dir":
            os.write(fd, content)
            os.fsync(fd)
        os.fchown(fd, 0, 0)
        os.fchmod(fd, spec["mode"])
    except OSError:
        os.close(fd)
        remove(home, tmp)
        raise
    return tmp, fd


def pin(home, name, spec, content):
    for _ in range(ATTEMPTS):
        if is_pinned(home, name, spec, content):
            return
        tmp, fd = build(home, spec, content)
        try:
            unpin(home, name)
            try:
                renameat2(home, tmp, name, RENAME_EXCHANGE)
            except FileNotFoundError:
                renameat2(home, tmp, name, RENAME_NOREPLACE)
            set_immutable(fd, True)
            here = os.stat(name, dir_fd=home, follow_symlinks=False)
            mine = os.fstat(fd)
            if (here.st_dev, here.st_ino) == (mine.st_dev, mine.st_ino):
                continue  # is_pinned confirms on the next round
            set_immutable(fd, False)
        except OSError as e:
            print(f"{name}: {e}, retrying", file=sys.stderr)
        finally:
            os.close(fd)
            # Whatever is left under the staging name: the entry it
            # replaced, or the new one when a swap failed or it was moved
            # back there. Nothing once the new entry is pinned.
            remove(home, tmp)
    sys.exit(f"hermes-locked: could not pin {name}")


spec_path, env_path = sys.argv[1:]
with open(spec_path) as f:
    spec = json.load(f)
owner = spec["owner"]
home = os.open(spec["home"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
st = os.fstat(home)
if st.st_uid != owner or stat.S_IMODE(st.st_mode) & 0o022:
    sys.exit(f"hermes-locked: {spec['home']} is not {owner}'s own directory")

for name, entry in sorted(spec["entries"].items()):
    if entry["type"] == "dir":
        content = b""
    elif name == ".env":
        with open(env_path, "rb") as f:
            content = f.read()
        creds = os.environ.get("CREDENTIALS_DIRECTORY")
        for cred in sorted(os.listdir(creds)) if creds else []:
            with open(os.path.join(creds, cred), "rb") as f:
                content += cred.encode() + b"=" + f.read().rstrip(b"\n") + b"\n"
    else:
        with open(entry["source"], "rb") as f:
            content = f.read()
    pin(home, name, entry, content)
print(f"pinned {len(spec['entries'])} entries in {spec['home']}")
