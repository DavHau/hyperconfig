"""scan-deliver: move finished scans from the outbox into the vault.

Runs as the vault owner (Dave), with the scan-outbox group only to read
and unlink the outbox's entries (./default.nix). The scan service never
gets write access to the vault, and this side never parses a PDF: it only
copies <outbox>/<YYYY-MM-DD_HHMMSS[_n]>.pdf to <output>/<YYYY>/ as a new
0600 file and then removes the outbox entry.

The outbox is root:scan-outbox 2770 without the sticky bit, so the scan
service can neither change its mode nor keep us from unlinking what it put
there. Everything in it is treated as hostile: opened O_NOFOLLOW |
O_NONBLOCK (no symlink tricks, no hanging on a FIFO), regular files only,
at most maxDocBytes, must start with "%PDF-"; anything else is removed and
logged. The source is unlinked BEFORE the copy is renamed into place, so a
name is never filed twice (a failed unlink drops the copy instead), and a
name that already exists in the vault with the same content is only
removed from the outbox.

<output> and its year directories carry no POSIX ACLs (the vault's
default ACL on the parent would otherwise give the vault group rwx on
every scan): they are stripped when created and on every hourly sweep, so
a later `setfacl -R` over the dataset is undone (../vault-ids.nix).

The vault's dataset is a `nofail` mount: while it isn't mounted, files
wait in the outbox (nothing is created on the placeholder directory below
it), and are delivered once it is.

The output file system is shared (/vault/misc), so a compromised scan
service must not be able to fill it: a scan is filed only while
<output> keeps minFreeBytes free after it, and at most dailyBytes are
filed per (local) day (counted in <state>/budget.json). Otherwise it
waits in the outbox, whose cap (outboxMaxBytes) then stops new scans.
A copy that fails is removed; `.*.part` older than a day in the year
directories (a crash mid-copy) are swept.
"""

import json
import os
import re
import stat
import sys
import time

CFG = json.load(open(sys.argv[1]))
OUTBOX = CFG["outboxDir"]
OUTPUT = CFG["outputDir"]
MOUNT = CFG["requireMount"]
MAX_BYTES = CFG["maxDocBytes"]
MIN_FREE = CFG["minFreeBytes"]
DAILY = CFG["dailyBytes"]
BUDGET = os.path.join(CFG["deliverStateDir"], "budget.json")
NAME_RE = re.compile(r"^(\d{4})-\d\d-\d\d_\d{6}(_\d+)?\.pdf$")
ACL_XATTRS = ("system.posix_acl_access", "system.posix_acl_default")
SWEEP_SECONDS = 3600
# Entries we failed to remove (e.g. a directory): don't retry every poll.
STUCK = set()


def log(*a):
    print(*a, flush=True)


class Wait(Exception):
    """Leave the outbox as it is for now (no room, over the day's budget)."""


def today():
    return time.strftime("%Y-%m-%d")


def budget_used():
    try:
        with open(BUDGET) as f:
            b = json.load(f)
        if b.get("day") == today():
            return int(b.get("bytes", 0))
    except (OSError, ValueError, TypeError, AttributeError, OverflowError):
        pass
    return 0


def budget_add(n):
    b = {"day": today(), "bytes": budget_used() + n}
    tmp = BUDGET + ".tmp"
    with open(tmp, "w") as f:
        json.dump(b, f)
    os.replace(tmp, BUDGET)


def check_room(size):
    st = os.statvfs(OUTPUT)
    free = st.f_bavail * st.f_frsize
    if free - size < MIN_FREE:
        raise Wait("room", f"{OUTPUT}: {free >> 20} MiB free, a {size >> 20} MiB "
                   f"scan would leave less than {MIN_FREE >> 20} MiB")
    used = budget_used()
    if used + size > DAILY:
        raise Wait("budget", f"{used >> 20} MiB filed today, a {size >> 20} MiB scan "
                   f"would exceed the daily {DAILY >> 20} MiB")


def mounted():
    return MOUNT is None or os.path.ismount(MOUNT)


def strip_acl(target):
    """setfacl -b: drop access and default ACLs (path or fd)."""
    for x in ACL_XATTRS:
        try:
            if isinstance(target, str):
                os.removexattr(target, x, follow_symlinks=False)
            else:
                os.removexattr(target, x)
        except OSError:
            pass  # ENODATA: none set (ENOTSUP: no ACLs at all)


def private_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, mode=0o700, exist_ok=True)
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise OSError(f"{path}: not our directory")
    strip_acl(path)
    os.chmod(path, 0o700)


def same_content(fd, path, size):
    try:
        with open(path, "rb") as f:
            if os.fstat(f.fileno()).st_size != size:
                return False
            os.lseek(fd, 0, os.SEEK_SET)
            while True:
                a = os.read(fd, 1 << 20)
                b = f.read(1 << 20)
                if a != b:
                    return False
                if not a:
                    return True
    except OSError:
        return False


def drop(src, why):
    try:
        os.unlink(src)
        log(f"removed {os.path.basename(src)} from the outbox: {why}")
    except OSError as e:
        log(f"cannot remove {src} ({why}): {e}")
        if len(STUCK) < 1000:
            STUCK.add(os.path.basename(src))


def deliver(name):
    year = NAME_RE.match(name).group(1)
    src = os.path.join(OUTBOX, name)
    try:
        sfd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        return drop(src, f"cannot open: {e}")
    try:
        st = os.fstat(sfd)
        if not stat.S_ISREG(st.st_mode):
            return drop(src, "not a regular file")
        if st.st_size > MAX_BYTES:
            return drop(src, f"{st.st_size} bytes, over {MAX_BYTES}")
        if os.pread(sfd, 5, 0) != b"%PDF-":
            return drop(src, "not a PDF")
        check_room(st.st_size)
        ydir = os.path.join(OUTPUT, year)
        private_dir(ydir)
        dst = os.path.join(ydir, name)
        if os.path.lexists(dst):
            if same_content(sfd, dst, st.st_size):
                return drop(src, "already filed")
            base, i = name[:-4], 2
            while os.path.lexists(dst):
                if i > 20:
                    return drop(src, "too many files of that name")
                dst = os.path.join(ydir, f"{base}_dup{i}.pdf")
                i += 1
        tmp = os.path.join(ydir, f".{os.path.basename(dst)}.part")
        dfd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC
                      | os.O_NOFOLLOW, 0o600)
        try:
            try:
                os.lseek(sfd, 0, os.SEEK_SET)
                copied = 0
                while copied <= MAX_BYTES:
                    chunk = os.read(sfd, 1 << 20)
                    if not chunk:
                        break
                    os.write(dfd, chunk)
                    copied += len(chunk)
                strip_acl(dfd)
                os.fchmod(dfd, 0o600)
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        if copied > MAX_BYTES:
            os.unlink(tmp)
            return drop(src, "grew while copying")
        # Unlink first: if that fails, nothing is filed, so the same entry
        # can never come out as a second copy on the next pass.
        try:
            os.unlink(src)
        except OSError as e:
            os.unlink(tmp)
            raise OSError(f"cannot remove {src}: {e}")
        try:
            os.rename(tmp, dst)
        except OSError as e:
            # The source is gone: tmp is now the only copy. Keep it under a
            # visible name the stale-.part sweep never touches.
            keep = os.path.join(os.path.dirname(tmp), "RESCUED_" + name)
            try:
                os.rename(tmp, keep)
            except OSError:
                keep = tmp
            log(f"FAILED to file {name}: {e}; the scan is kept as {keep}")
            raise
        budget_add(copied)
        log(f"delivered {name} -> {dst}")
    finally:
        os.close(sfd)


def sweep():
    """Undo ACLs a recursive setfacl over the dataset may have added;
    remove copies left half-done by a crash."""
    private_dir(OUTPUT)
    old = time.time() - 86400
    for e in os.scandir(OUTPUT):
        if e.is_dir(follow_symlinks=False) and re.fullmatch(r"\d{4}", e.name):
            private_dir(e.path)
            for f in os.scandir(e.path):
                if f.name.startswith(".") and f.name.endswith(".part") \
                        and f.is_file(follow_symlinks=False) \
                        and f.stat(follow_symlinks=False).st_mtime < old:
                    os.unlink(f.path)
                    log(f"removed stale {f.path}")
                elif f.is_file(follow_symlinks=False):
                    strip_acl(f.path)
                    os.chmod(f.path, 0o600)


def main():
    waiting_logged = False
    wait_reason = None
    skipped = set()
    last_sweep = None
    while True:
        entries = sorted(os.listdir(OUTBOX))
        names = [n for n in entries if NAME_RE.match(n) and n not in STUCK]
        for n in entries:
            # Anything else (no .part: in-progress writes) is not ours.
            if not NAME_RE.match(n) and not n.endswith(".part") \
                    and n not in skipped and len(skipped) < 1000:
                log(f"ignoring unexpected outbox entry {n!r}")
                skipped.add(n)
        if not mounted():
            if names and not waiting_logged:
                log(f"{MOUNT} not mounted; {len(names)} scan(s) wait "
                    "in the outbox")
                waiting_logged = True
        else:
            waiting_logged = False
            try:
                if last_sweep is None or \
                        time.monotonic() - last_sweep > SWEEP_SECONDS:
                    sweep()
                    last_sweep = time.monotonic()
                else:
                    private_dir(OUTPUT)
                for n in names:
                    deliver(n)
                wait_reason = None
            except Wait as e:
                # Logged once per reason; files stay in the outbox.
                if e.args[0] != wait_reason:
                    log("not delivering, scans wait in the outbox: "
                        + e.args[1])
                    wait_reason = e.args[0]
            except OSError as e:
                log(f"delivery failed, retrying: {e}")
                time.sleep(30)
        time.sleep(CFG["pollSeconds"])


if __name__ == "__main__":
    main()
