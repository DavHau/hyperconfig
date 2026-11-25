"""Give each named profile of an agent what its home has: .env blocks, plugins, skills.

usage: profile-env.py HERMES_HOME [SPEC.json]

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

Plugins: hermes discovers plugins only under the profile's own plugins/, and
`hermes profile create` copies the home's config.yaml (plugins.enabled with
it) but not plugins/. So every link in the home's plugins/ into the Nix store
(the plugins hyperhermes' features install) is linked the same in each
profile's plugins/ (created if missing), and the home's installer record
(.install-metadata.json) entry for it is copied along. A profile's own install
of that name (a real directory, or a link outside the store) stays with its
record, and so do its other plugins.

Skills (SPEC's "skills": {profile: {skill: {"source": dir, "managed": bool}}}):
a seeded skill's files are copied into profiles/<profile>/skills/<skill>/ only
while that directory does not exist; from then on it is the agent's, like any
skill it wrote itself. A managed one's files are rewritten from the store on
every run (files the agent added beside them stay).
"""

import errno
import fcntl
import json
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
NO_PROFILE = object()  # a directory without any marker, not new


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


def read_all(fd):
    data = b""
    while True:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            return data
        data += chunk


def read_lines(fd):
    data = read_all(fd)
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
            return WAITING if time.time() - os.fstat(dfd).st_mtime < 10 else NO_PROFILE
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


def write_at(dfd, name, data, mode):
    """Replace `name` in `dfd` with `data` through a temporary file and a rename, never following a link."""
    tmp = f".{name}.hyperhermes-{os.getpid()}"
    try:
        os.unlink(tmp, dir_fd=dfd)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, mode, dir_fd=dfd)
    try:
        try:
            os.fchmod(fd, mode)
            while data:
                data = data[os.write(fd, data):]
        finally:
            os.close(fd)
        os.rename(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dfd)
        except OSError:
            pass
        raise


class Skip(Exception):
    """A path in a profile that is not what it should be (a link, a FIFO): that part is left alone."""


def subdir(dfd, name, create):
    """An fd of directory `name` in `dfd` (made 0700 if missing and `create`), never through a link; None if absent.
    Skip when `name` is something else (a link, a file)."""
    try:
        return os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=dfd)
    except FileNotFoundError:
        if not create:
            return None
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Skip(f"{name} is no directory") from None
        raise
    os.mkdir(name, 0o700, dir_fd=dfd)
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=dfd)


def open_regular(dfd, name):
    """An fd of the regular file `name` in `dfd`, None if absent; Skip for a link, FIFO or other non-file."""
    try:
        fd = os.open(name, os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except FileNotFoundError:
        return None
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise Skip(f"{name} is a symlink") from None
        raise
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise Skip(f"{name} is no regular file")
    return fd


def read_json_at(dfd, name):
    """The JSON object in `name`: {} when absent; Skip when it is no regular file or no JSON object."""
    fd = open_regular(dfd, name)
    if fd is None:
        return {}
    try:
        value = json.loads(read_all(fd) or b"{}")
    except ValueError:
        raise Skip(f"{name} is no JSON") from None
    finally:
        os.close(fd)
    if not isinstance(value, dict):
        raise Skip(f"{name} is no JSON object")
    return value


def home_plugins(home):
    """{name: store target} of the home's plugin links into the Nix store, and the home's installer record."""
    links = {}
    try:
        dfd = os.open(os.path.join(home, "plugins"), os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
    except OSError:
        return links, {}
    try:
        for name in os.listdir(dfd):
            try:
                target = os.readlink(name, dir_fd=dfd)
            except OSError:
                continue
            if target.startswith("/nix/store/") and not name.startswith("."):
                links[name] = target
        try:
            record = read_json_at(dfd, ".install-metadata.json")
        except Skip:
            record = {}
    finally:
        os.close(dfd)
    return links, record


def sync_plugins(pdfd, name, links, record):
    """Link the home's store plugins into profile `name` (its fd `pdfd`); a message or None.

    Only an absent entry or a link into the store is ours to (re)point: a real directory or a link
    elsewhere is the profile's own install of that name, and keeps its own record."""
    if not links:
        return None
    dfd = subdir(pdfd, "plugins", True)
    changed, ours = [], []
    try:
        sweep(dfd)
        for plugin, target in sorted(links.items()):
            try:
                current = os.readlink(plugin, dir_fd=dfd)
            except FileNotFoundError:
                current = None
            except OSError:
                continue  # not a link: the profile's own install
            if current is not None and not current.startswith("/nix/store/"):
                continue  # a link of the profile's own
            ours.append(plugin)
            if current == target:
                continue
            tmp = f".{plugin}.hyperhermes-{os.getpid()}"
            try:
                os.unlink(tmp, dir_fd=dfd)
            except FileNotFoundError:
                pass
            os.symlink(target, tmp, dir_fd=dfd)
            os.rename(tmp, plugin, src_dir_fd=dfd, dst_dir_fd=dfd)
            changed.append(plugin)
        own = read_json_at(dfd, ".install-metadata.json")
        merged = dict(own)
        for plugin in ours:
            if plugin in record:
                merged[plugin] = record[plugin]
        if merged != own:
            write_at(dfd, ".install-metadata.json", json.dumps(merged, indent=2, sort_keys=True).encode() + b"\n", 0o600)
    finally:
        os.close(dfd)
    return f"{name}: linked plugins {', '.join(changed)}" if changed else None


def copy_tree(src, dfd, managed):
    """Copy the store tree `src` into the directory `dfd` (dirs 0700, files 0600, 0700 if executable in the
    store). Seeding (`managed` false) writes into a fresh directory; managed, only differing files are
    rewritten. Files dropped from a managed source stay behind."""
    for entry in sorted(os.listdir(src)):
        path = os.path.join(src, entry)
        if os.path.isdir(path):
            sub = subdir(dfd, entry, True)
            try:
                copy_tree(path, sub, managed)
            finally:
                os.close(sub)
            continue
        with open(path, "rb") as f:
            data = f.read()
        mode = 0o700 if os.stat(path).st_mode & stat.S_IXUSR else 0o600
        fd = open_regular(dfd, entry)
        if fd is not None:
            try:
                if not managed or (read_all(fd) == data and stat.S_IMODE(os.fstat(fd).st_mode) == mode):
                    continue
            finally:
                os.close(fd)
        write_at(dfd, entry, data, mode)


def remove_tree(dfd, name):
    """rm -r of `name` in `dfd`, never following a link."""
    try:
        sub = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=dfd)
    except OSError:
        os.unlink(name, dir_fd=dfd)
        return
    try:
        for entry in os.listdir(sub):
            remove_tree(sub, entry)
    finally:
        os.close(sub)
    os.rmdir(name, dir_fd=dfd)


def sweep(dfd):
    """Remove temporaries an earlier, killed run left in `dfd` (`.<name>.hyperhermes-<pid>`); runs under the flock."""
    for entry in os.listdir(dfd):
        if entry.startswith(".") and ".hyperhermes-" in entry:
            remove_tree(dfd, entry)


def sync_skills(pdfd, name, skills):
    """Seed (or, managed, rewrite) the skills `skills` of profile `name`; messages.

    A seeded skill is copied into a temporary directory and renamed into place, so a failed copy never
    leaves a half skill that counts as present. Any entry of that name (a link too) counts as present."""
    msgs = []
    if not skills:
        return msgs
    sdfd = subdir(pdfd, "skills", True)
    try:
        sweep(sdfd)
        for skill, spec in sorted(skills.items()):
            try:
                os.stat(skill, dir_fd=sdfd, follow_symlinks=False)
                present = True
            except FileNotFoundError:
                present = False
            try:
                if present:
                    if not spec.get("managed"):
                        continue
                    dfd = subdir(sdfd, skill, False)
                    if dfd is None:
                        continue  # gone since the stat
                    try:
                        copy_tree(spec["source"], dfd, True)
                    finally:
                        os.close(dfd)
                    continue
                tmp = f".{skill}.hyperhermes-{os.getpid()}"
                try:
                    remove_tree(sdfd, tmp)
                except FileNotFoundError:
                    pass
                dfd = subdir(sdfd, tmp, True)
                try:
                    try:
                        copy_tree(spec["source"], dfd, False)
                    finally:
                        os.close(dfd)
                    os.rename(tmp, skill, src_dir_fd=sdfd, dst_dir_fd=sdfd)
                except BaseException:
                    remove_tree(sdfd, tmp)
                    raise
                msgs.append(f"{name}: seeded skill {skill}")
            except Skip as e:
                msgs.append(f"skipped {name}'s skill {skill}: {e}")
    finally:
        os.close(sdfd)
    return msgs


def main():
    home = sys.argv[1]
    spec = {}
    if len(sys.argv) > 2:
        with open(sys.argv[2]) as f:
            spec = json.load(f)
    plugins = home_plugins(home)
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
            failed, waiting = sync_all(profiles_fd, blocks, said, plugins, spec.get("skills", {}))
            if not waiting and os.fstat(profiles_fd).st_mtime_ns == before:
                break
            time.sleep(0.5)
    finally:
        os.close(profiles_fd)
    return 1 if failed else 0


def sync_all(profiles_fd, blocks, said, plugins=({}, {}), skills=None):
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
        msgs = [msg]
        if msg is WAITING:
            waiting = True
        elif msg is not NO_PROFILE and not (msg or "").startswith("skipped"):
            # A profile (a marker present, its directory no link): plugins and skills.
            try:
                pdfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=profiles_fd)
            except OSError:
                pdfd = None
            if pdfd is not None:
                try:
                    for step in (lambda: [sync_plugins(pdfd, name, *plugins)],
                                 lambda: sync_skills(pdfd, name, (skills or {}).get(name, {}))):
                        try:
                            msgs.extend(step())
                        except Skip as e:
                            msgs.append(f"skipped part of {name}: {e}")
                except OSError as e:
                    msgs.append(f"could not update {name}'s plugins or skills: {e}")
                    failed = True
                finally:
                    os.close(pdfd)
        for m in msgs:
            if isinstance(m, str) and m not in said:
                said.add(m)
                print(f"hermes: profile {m}", file=sys.stderr)
    return failed, waiting


if __name__ == "__main__":
    sys.exit(main())
