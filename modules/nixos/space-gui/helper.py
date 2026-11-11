"""space-gui's root half: run one GUI command in a space container, shown on
the host user's Wayland session. Started by the `space-gui` launcher through
sudo (the host user only, this file's store path only); see ./default.nix
for the design and the security notes.

  space-gui-helper <container> <wayland-display> <command> [args...]

For the command's lifetime, a run directory /run/space-gui/<run>/ is bound
into the container with:
- wayland-0, a socket of the compositor's whose clients it puts in a
  security context (wp_security_context_v1);
- open.sock: the container's `xdg-open` (a shim on the command's PATH)
  sends URLs there. A URL is opened in the host user's browser only if it
  is https on one of the container's allowed origins. If it carries a
  redirect_uri of http://127.0.0.1:<port>/... (an OAuth native/PKCE
  sign-in: the app listens on its own loopback, in the container's network
  namespace), this host's 127.0.0.1:<port> is forwarded into the
  container's loopback for a few minutes, so the browser's redirect
  reaches the app.
"""

import json
import os
import re
import secrets
import signal
import shutil
import socket
import subprocess
import sys
import threading
import urllib.parse
from pathlib import Path

CONF = json.loads(Path(os.environ["SPACE_GUI_CONFIG"]).read_text())
FORWARD_SECONDS = 300


def log(msg: str) -> None:
    print(f"space-gui: {msg}", file=sys.stderr, flush=True)


def run(*args: str, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), check=check, **kw)


def leader(container: str) -> str:
    out = run("machinectl", "show", container, "-p", "Leader", "--value", capture_output=True, text=True)
    pid = out.stdout.strip()
    if not pid.isdigit() or pid == "0":
        raise SystemExit(f"space-gui: container {container} is not running")
    return pid


def in_guest(pid: str, *args: str) -> None:
    # All namespaces and the guest's root: `-m` alone resolves the path
    # against this host's root and fails.
    run("nsenter", "-t", pid, "-a", *args, check=False, stderr=subprocess.DEVNULL)


def restricted_socket(host_socket: str, path: Path, uid: int, container: str, run_id: str) -> int:
    """A new listening socket at `path` whose clients the compositor puts in
    a security context (wp_security_context_v1): it keeps privileged
    protocols (screencopy, data control, virtual input, foreign toplevel,
    ...) from them. Returns the fd whose close retires the socket."""
    from pywayland.client import Display
    from pywayland.protocol.security_context_v1 import WpSecurityContextManagerV1

    listen = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listen.bind(str(path))
    os.chown(path, uid, -1)
    os.chmod(path, 0o600)
    listen.listen(16)
    close_r, close_w = os.pipe()

    display = Display(host_socket)
    display.connect()
    found = {}

    def on_global(registry, name, interface, version):
        if interface == WpSecurityContextManagerV1.name:
            found["mgr"] = registry.bind(name, WpSecurityContextManagerV1, 1)

    registry = display.get_registry()
    registry.dispatcher["global"] = on_global
    display.roundtrip()
    if "mgr" not in found:
        raise SystemExit("space-gui: the compositor offers no wp_security_context_manager_v1")
    ctx = found["mgr"].create_listener(listen.fileno(), close_r)
    ctx.set_sandbox_engine("space-gui")
    ctx.set_app_id(container)
    ctx.set_instance_id(run_id)
    ctx.commit()
    ctx.destroy()
    display.roundtrip()
    display.disconnect()
    listen.close()
    os.close(close_r)
    return close_w


class Broker:
    """Accepts URLs from the container on open.sock and opens allowed ones."""

    def __init__(self, container: str, c: dict, pid: str, sock_path: Path, env: dict):
        self.container, self.c, self.pid, self.env = container, c, pid, env
        self.forwards: list[subprocess.Popen] = []
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(str(sock_path))
        os.chown(sock_path, c["uid"], -1)
        os.chmod(sock_path, 0o600)
        self.srv.listen(4)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self) -> None:
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            with conn:
                conn.settimeout(5)
                data = b""
                try:
                    while len(data) < 16384:
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                except OSError:
                    pass
                ok = self.handle(data.decode("utf-8", "replace").strip())
                try:
                    conn.sendall(b"ok\n" if ok else b"refused\n")
                except OSError:
                    pass

    def handle(self, url: str) -> bool:
        try:
            u = urllib.parse.urlsplit(url)
        except ValueError:
            u = None
        origin = f"{u.scheme}://{u.netloc}" if u else ""
        if not u or u.scheme != "https" or origin not in self.c["openOrigins"] or any(ch in url for ch in "\r\n\0 "):
            log(f"refused to open a URL outside {self.c['openOrigins']}: {url[:120]!r}")
            return False
        redirect = urllib.parse.parse_qs(u.query).get("redirect_uri", [""])[0]
        m = re.fullmatch(r"http://127\.0\.0\.1:(\d{4,5})/[A-Za-z0-9/_-]*", redirect)
        if redirect and not m:
            log(f"refused: redirect_uri is not the app's loopback: {redirect[:120]!r}")
            return False
        if m:
            port = int(m.group(1))
            if not 1024 <= port <= 65535:
                return False
            self.forward(port)
        log(f"opening {origin}{u.path} in {CONF['hostUser']}'s browser")
        # In the host user's own manager, with their session's environment.
        subprocess.run(
            ["systemd-run", "--user", f"--machine={CONF['hostUser']}@.host", "--collect", "--quiet",
             *[f"-E{k}={v}" for k, v in self.env.items()], CONF["opener"], url],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=False,
        )
        return True

    def forward(self, port: int) -> None:
        # Host 127.0.0.1:<port> -> the container's 127.0.0.1:<port>; socat
        # forks per connection, each child enters the container's netns.
        # (socat's address syntax: the inner colons escaped.)
        inner = f"nsenter -t {self.pid} -n socat STDIO TCP\\:127.0.0.1\\:{port}"
        p = subprocess.Popen(
            ["timeout", str(FORWARD_SECONDS), "socat",
             f"TCP-LISTEN:{port},bind=127.0.0.1,reuseaddr,fork", f"EXEC:{inner}"],
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        self.forwards.append(p)
        log(f"forwarding 127.0.0.1:{port} into {self.container} for {FORWARD_SECONDS}s")

    def close(self) -> None:
        self.srv.close()
        for p in self.forwards:
            p.kill()


def main() -> int:
    if len(sys.argv) < 4:
        raise SystemExit("usage: space-gui-helper <container> <wayland-display> <command> [args...]")
    container, display, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
    if os.environ.get("SUDO_UID") != str(CONF["hostUid"]):
        raise SystemExit(f"space-gui: only {CONF['hostUser']} may run this")
    c = CONF["containers"].get(container)
    if c is None:
        raise SystemExit(f"space-gui: {container} is not a GUI-enabled container ({', '.join(CONF['containers'])})")
    if not re.fullmatch(r"wayland-[0-9]+", display):
        raise SystemExit(f"space-gui: unexpected WAYLAND_DISPLAY {display!r}")
    runtime = f"/run/user/{CONF['hostUid']}"
    host_socket = f"{runtime}/{display}"
    st = os.stat(host_socket)
    if st.st_uid != CONF["hostUid"]:
        raise SystemExit(f"space-gui: {host_socket} is not {CONF['hostUser']}'s")

    def interrupt(*_):
        raise KeyboardInterrupt

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupt)

    pid = leader(container)
    run_id = secrets.token_hex(4)
    unit = f"space-gui-{run_id}"
    host_dir = Path("/run/space-gui") / container / run_id
    host_dir.mkdir(parents=True, mode=0o700)
    os.chown(host_dir, c["uid"], -1)
    guest_dir = f"/run/space-gui/{run_id}"
    close_w = restricted_socket(host_socket, host_dir / "wayland-0", c["uid"], container, run_id)
    run("machinectl", "bind", "--mkdir", container, str(host_dir), guest_dir)

    user_env = {"WAYLAND_DISPLAY": display}
    broker = Broker(container, c, pid, host_dir / "open.sock", user_env)
    rc = 1
    try:
        log(f"running {argv[0]} in {container} as {c['user']} ({unit})")
        rc = run(
            "systemd-run", "-M", container, f"--uid={c['user']}", f"--unit={unit}", "--collect", "--wait",
            "--quiet", "--service-type=exec",
            "-p", f"RuntimeDirectory={unit}", "-p", "RuntimeDirectoryMode=0700",
            "-E", f"XDG_RUNTIME_DIR=/run/{unit}",
            "-E", f"WAYLAND_DISPLAY={guest_dir}/wayland-0",
            "-E", f"SPACE_GUI_OPEN={guest_dir}/open.sock",
            "-E", f"PATH={CONF['shim']}/bin:/run/wrappers/bin:/etc/profiles/per-user/{c['user']}/bin:/run/current-system/sw/bin",
            "-E", f"HOME={c['home']}",
            "--", CONF["dbusRunSession"], f"--dbus-daemon={CONF['dbusDaemon']}",
            f"--config-file={CONF['dbusSessionConf']}", "--", *argv,
            check=False,
        ).returncode
    except KeyboardInterrupt:
        run("systemctl", "-M", container, "stop", f"{unit}.service", check=False)
    finally:
        broker.close()
        os.close(close_w)  # the compositor stops accepting on the socket
        in_guest(pid, "/run/current-system/sw/bin/umount", "-l", guest_dir)
        in_guest(pid, "/run/current-system/sw/bin/rmdir", guest_dir)
        shutil.rmtree(host_dir, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
