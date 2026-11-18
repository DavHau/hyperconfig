"""Copy the hermes-native blocks of an agent's .env into each named profile's .env.

usage: profile-env.py HERMES_HOME

Hermes reads a named profile's own .env only (profiles/<name>/.env), never the
home's, so the blocks core and its features write into the home's .env before
every start (`# BEGIN hermes-native <block>` ... `# END hermes-native <block>`:
environment, credentials, camofox) would not reach a profile at all. Run as
the agent, after those writes (./agents.nix, the end of the gateway's
preStart) and whenever profiles/ changes (hermes-profile-env-<agent>.path).

Per profile: every hermes-native block goes (also one the home no longer
has, and an unterminated one up to the end of the file, as core's sed does),
then the interpreter and managed-scope keys core drops from the home's .env,
then the home's blocks are appended in their order. Everything else in the
file stays, and wins: a key the profile sets itself outside the hermes-native
blocks (its own ANTHROPIC_TOKEN, another provider's key, ANTHROPIC_BASE_URL,
or what `hermes setup`/`hermes auth` wrote there) is left out of the copied
blocks, whose comments and markers stay. The home's blocks fill in only what a
profile doesn't set itself (hermes' dotenv is last-wins, so a copied line
would override the profile's). On a failed write the temporary file, which
holds secrets, is removed. Only a file whose content changes is rewritten, through a 0600
temporary file in the profile's directory and a rename.

A profile is what hermes takes for one (hermes_constants.py): a directory
under profiles/ with a valid id, not `default`, not tombstoned
(profiles/.deleted/<name>), holding one of hermes' identity markers. A
marker-less directory (a cron or log write recreating a deleted profile's
directory) is left alone: a .env would turn it into a profile; one that gets a
marker within 5 s of the change is still caught. A symlinked
profile directory or .env, or a .env that is no regular file, is skipped
and never followed: the agent owns these paths. A lock on profiles/
serialises concurrent runs.
"""

import errno
import fcntl
import os
import re
import stat
import sys
import time

PROFILE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
MARKERS = ("config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db")
BEGIN = re.compile(rb"^# BEGIN hermes-native \S.*$")
END_PREFIX = b"# END hermes-native "
KEY = re.compile(rb"^(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_.]*)[ \t]*=")
DROP = re.compile(
    rb"^(export[ \t]+)?(PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|NIX_PYTHONPATH|HERMES_MANAGED|HERMES_MANAGED_DIR)="
)
NOFOLLOW = os.O_NOFOLLOW | os.O_CLOEXEC
WAITING = object()  # a directory without any marker (yet)


def split_blocks(lines):
    """(lines outside every hermes-native block, the blocks' lines)."""
    rest, blocks, end = [], [], None
    for line in lines:
        if end is None:
            if BEGIN.match(line):
                end = END_PREFIX + line[len(b"# BEGIN hermes-native "):]
                blocks.append(line)
            else:
                rest.append(line)
        else:
            blocks.append(line)
            if line == end:
                end = None
    return rest, blocks


def read_lines(fd):
    data = b""
    while True:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            break
        data += chunk
    lines = data.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    return lines


def sync_profile(profiles_fd, name, blocks):
    try:
        dfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=profiles_fd)
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR, errno.ENOENT):
            return f"skipped {name}: not a directory"
        raise
    try:
        def lexists(n):
            try:
                os.stat(n, dir_fd=dfd, follow_symlinks=False)
                return True
            except FileNotFoundError:
                return False

        if not any(lexists(m) for m in MARKERS):
            # Worth waiting for only while it is new.
            return WAITING if time.time() - os.fstat(dfd).st_mtime < 10 else None
        old = []
        if lexists(".env"):
            st = os.stat(".env", dir_fd=dfd, follow_symlinks=False)
            if not stat.S_ISREG(st.st_mode):
                return f"skipped {name}: .env is a symlink or no regular file"
            fd = os.open(".env", os.O_RDONLY | NOFOLLOW, dir_fd=dfd)
            try:
                old = read_lines(fd)
            finally:
                os.close(fd)
        rest, _ = split_blocks(old)
        rest = [line for line in rest if not DROP.match(line)]
        own = {m.group(1) for m in map(KEY.match, rest) if m}
        new = rest + [line for line in blocks if not ((m := KEY.match(line)) and m.group(1) in own)]
        if new == old and lexists(".env"):
            return None
        tmp = f".env.hyperhermes-{os.getpid()}"
        try:
            os.unlink(tmp, dir_fd=dfd)
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            try:
                os.fchmod(fd, 0o600)
                data = b"".join(line + b"\n" for line in new)
                while data:
                    data = data[os.write(fd, data):]
                os.fsync(fd)
            finally:
                os.close(fd)
            os.rename(tmp, ".env", src_dir_fd=dfd, dst_dir_fd=dfd)
        except BaseException:
            # It holds the secrets: never leave it behind.
            try:
                os.unlink(tmp, dir_fd=dfd)
            except OSError:
                pass
            raise
        return f"updated {name}/.env"
    finally:
        os.close(dfd)


def main():
    home = sys.argv[1]
    try:
        profiles_fd = os.open(os.path.join(home, "profiles"), os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
    except OSError:
        return 0
    fcntl.flock(profiles_fd, fcntl.LOCK_EX)
    try:
        fd = os.open(os.path.join(home, ".env"), os.O_RDONLY | NOFOLLOW)
    except OSError as e:
        print(f"hermes: no readable {home}/.env ({e.strerror}); profiles left alone", file=sys.stderr)
        os.close(profiles_fd)
        return 0
    try:
        _, blocks = split_blocks(read_lines(fd))
    finally:
        os.close(fd)
    failed = False
    try:
        # hermes publishes a new profile by renaming its staging directory
        # into profiles/, but a profile made by hand (a mkdir, then its
        # files) has no marker yet when the path unit fires, and its files
        # change nothing in profiles/ itself; neither does a profile that
        # lands while this runs. So look again, for up to 5 s, while
        # profiles/ changed or a new marker-less directory waits.
        said = set()
        for _ in range(10):
            before = os.fstat(profiles_fd).st_mtime_ns
            failed, waiting = sync_all(profiles_fd, blocks, said)
            if not waiting and os.fstat(profiles_fd).st_mtime_ns == before:
                break
            time.sleep(0.5)
    finally:
        os.close(profiles_fd)
    return 1 if failed else 0


def sync_all(profiles_fd, blocks, said):
    failed, waiting = False, False
    for name in sorted(os.listdir(profiles_fd)):
        if name == "default" or not PROFILE_ID.match(name):
            continue
        try:
            os.stat(os.path.join(".deleted", name), dir_fd=profiles_fd, follow_symlinks=False)
            continue
        except FileNotFoundError:
            pass
        try:
            msg = sync_profile(profiles_fd, name, blocks)
        except OSError as e:
            msg, failed = f"could not update {name}/.env: {e}", True
        if msg is WAITING:
            waiting = True
        elif msg and msg not in said:
            said.add(msg)
            print(f"hermes: profile {msg}", file=sys.stderr)
    return failed, waiting


if __name__ == "__main__":
    sys.exit(main())
