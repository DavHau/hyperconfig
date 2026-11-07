"""Run as the locked agent's uid: every way to change what hermes reads
must fail, and what can be written (names hermes does not read, a
.container-mode file, the workspace, the account's own ~/.hermes) is
planted for the test to show it has no effect after a restart.

argv: HERMES_HOME, workspace, home.
"""

import errno
import os
import sys
import tempfile

home_dir, workspace, home = sys.argv[1:]
H = lambda *p: os.path.join(home_dir, *p)  # noqa: E731
files = [".env", "config.yaml", ".op.env", "active_profile", "gateway.json"]
dirs = ["plugins", "hooks", "profiles", "lib", "patches"]
BASIC = (
    "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=evil\n"
    "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=evil\n"
    "HERMES_DESKTOP=1\n"
    "HERMES_DASHBOARD_SESSION_TOKEN=evil\n"
    "HERMES_ENABLE_PROJECT_PLUGINS=1\n"
    "HERMES_MANAGED_DIR=/nonexistent\n"
    "OPENAI_API_KEY=sk-planted\n"
)
CONFIG = (
    "dashboard:\n  basic_auth:\n    username: evil\n    password: evil\n"
    "plugins:\n  enabled: [evil-auth]\n"
    "secrets:\n  command:\n    enabled: true\n    command: [echo, HERMES_DASHBOARD_BASIC_AUTH_USERNAME=evil]\n"
)
failures = []


def snapshot():
    out = {}
    for name in files + dirs:
        st = os.lstat(H(name))
        out[name] = (st.st_ino, st.st_uid, st.st_mode, st.st_size)
    return out


def refused(what, fn):
    try:
        fn()
    except OSError as e:
        print(f"refused ({errno.errorcode.get(e.errno, e.errno)}): {what}")
        return
    failures.append(what)
    print(f"ALLOWED: {what}")


def write(path, text, mode="w"):
    with open(path, mode) as f:
        f.write(text)


def evil_plugin(root):
    d = os.path.join(root, "evil-auth")
    os.makedirs(d, exist_ok=True)
    write(os.path.join(d, "plugin.yaml"), "name: evil-auth\nversion: 1.0.0\nkind: backend\n")
    write(os.path.join(d, "__init__.py"),
          f"open({os.path.join(home, 'evil-loaded')!r}, 'a').write('plugin\\n')\n"
          "def register(ctx):\n    pass\n")


before = snapshot()

for name in files + dirs:
    p = H(name)
    refused(f"append to {name}", lambda: write(p, BASIC, "a"))
    refused(f"truncate {name}", lambda: write(p, BASIC))
    refused(f"unlink {name}", lambda: os.rmdir(p) if name in dirs else os.unlink(p))
    refused(f"rename {name} away", lambda: os.rename(p, H(name + ".old")))
    refused(f"symlink over {name}", lambda: os.symlink("/tmp/evil", p))
    refused(f"chmod {name}", lambda: os.chmod(p, 0o777))
    fd, tmp = tempfile.mkstemp(dir=home_dir)
    os.write(fd, BASIC.encode())
    os.close(fd)
    refused(f"replace {name} with an own file", lambda: os.replace(tmp, p))
    os.unlink(tmp)
    tmpdir = tempfile.mkdtemp(dir=home_dir)
    refused(f"replace {name} with an own directory", lambda: os.rename(tmpdir, p))
    os.rmdir(tmpdir)

for name in dirs:
    refused(f"create in {name}/", lambda: evil_plugin(H(name)))

refused("rename HERMES_HOME away", lambda: os.rename(home_dir, home_dir + ".old"))

# Allowed, and without effect: names hermes does not read, .container-mode
# (ignored under HERMES_DEV), the workspace (the units' cwd: project .env
# and ./.hermes/plugins), and the account's own ~/.hermes (hermes' default
# home).
write(H(".env.local"), BASIC)
write(H("config.yml"), CONFIG)
write(H(".container-mode"), f"backend={home}/evil-runtime\ncontainer_name=evil\n")
write(os.path.join(workspace, ".env"), BASIC)
evil_plugin(os.path.join(workspace, ".hermes", "plugins"))
os.makedirs(os.path.join(home, ".hermes"), exist_ok=True)
write(os.path.join(home, ".hermes", ".env"), BASIC)
write(os.path.join(home, ".hermes", "config.yaml"), CONFIG)
evil_plugin(os.path.join(home, ".hermes", "plugins"))
write(os.path.join(home, "evil-runtime"), f"#!/bin/sh\necho container >> {home}/evil-loaded\n")
os.chmod(os.path.join(home, "evil-runtime"), 0o755)

after = snapshot()
assert before == after, (before, after)
assert not failures, failures
print("all refused; pins unchanged")
