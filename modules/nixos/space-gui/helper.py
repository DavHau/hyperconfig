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
  is https on one of the container's allowed origins (any https URL with
  the container's openAnyHttps, opened as a plain link: no forward). If an
  allowed origin's URL carries a
  redirect_uri of http://127.0.0.1:<port>/... (an OAuth native/PKCE
  sign-in: the app listens on its own loopback, in the container's network
  namespace), this host's 127.0.0.1:<port> is forwarded into the
  container's loopback, so the browser's redirect reaches the app: one
  shot, closed after the first callback request (`<path>?code=` or
  `?error=`) has been answered, after FORWARD_SECONDS at the latest, and
  only for a port of the ephemeral range the app's listen(0) draws from.
"""

import fcntl
import json
import os
import pwd
import re
import secrets
import signal
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

CONF = json.loads(Path(os.environ["SPACE_GUI_CONFIG"]).read_text())
# The sign-in in the browser (pocket-id, a passkey) takes seconds to a
# minute; the app itself gives up after five.
FORWARD_SECONDS = 180
# The app's loopback listeners (hermes-desktop's native-oauth-login and its
# MCP OAuth callback) bind port 0: a port of Linux's default ephemeral range
# (net.ipv4.ip_local_port_range, per network namespace; the container's is
# the default).
LOOPBACK_PORTS = range(32768, 61000)
# Longest URL the broker opens (well under what open.sock reads, so a cut
# URL is never taken for a whole one).
MAX_URL = 8192
# At most OPEN_BURST opens per OPEN_WINDOW seconds per container, across
# its runs (separate helper processes: the timestamps live in a root-only
# file under flock, /run/space-gui/<container>.opens, outside the directory
# bound into the container); more are refused, so an app cannot flood the
# host user's browser with tabs.
OPEN_BURST = 5
OPEN_WINDOW = 10.0


def log(msg: str) -> None:
    print(f"space-gui: {msg}", file=sys.stderr, flush=True)


def run(*args: str, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), check=check, **kw)


class ColorScheme:
    """The host session's light/dark preference for the run (dark unless the
    host says light). ./color-scheme.py host-watch runs as the host user on
    their session bus and prints the portal's value and every change; each
    one goes to the run directory's `color-scheme` file, which the run's own
    portal in the container (./color-scheme.py portal) serves and announces.
    The run's settings.ini (gtk-3.0, gtk-4.0) under xdg/ carries the value
    at launch for apps that read no portal."""

    def __init__(self, host_dir: Path):
        self.host_dir = host_dir
        self.word = "dark"
        self.lock = threading.Lock()
        self.ready = False
        self.proc: subprocess.Popen | None = None
        bus = f"/run/user/{CONF['hostUid']}/bus"
        first = threading.Event()
        if os.path.exists(bus):
            try:
                self.proc = subprocess.Popen(
                    [CONF["colorScheme"], "host-watch"],
                    user=CONF["hostUid"], group=pwd.getpwuid(CONF["hostUid"]).pw_gid, extra_groups=[],
                    env={"DBUS_SESSION_BUS_ADDRESS": f"unix:path={bus}", "PATH": "/var/empty"},
                    cwd="/", stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    text=True,
                )
            except OSError as e:
                log(f"cannot read the session's color scheme: {e}")
        if self.proc:
            threading.Thread(target=self.follow, args=(first,), daemon=True).start()
            first.wait(3)  # no answer by then: dark, and a later one still counts
        with self.lock:
            self.ready = True
            self.write(self.word)
            self.write_settings()

    def follow(self, first: threading.Event) -> None:
        out = self.proc.stdout if self.proc else None
        assert out
        # short reads: the watcher runs as the host user, nothing it
        # prints but `dark` or `light` counts
        for line in iter(lambda: out.readline(16), ""):
            word = line.strip()
            if word in ("dark", "light"):
                with self.lock:
                    self.word = word
                    if self.ready:
                        self.write(word)
                first.set()
        first.set()

    def _put(self, path: Path, text: str) -> None:
        tmp = path.with_name(f".{path.name}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)

    def write(self, word: str) -> None:
        self._put(self.host_dir / "color-scheme", word + "\n")

    def write_settings(self) -> None:
        dark = int(self.word == "dark")
        for gtk in ("gtk-3.0", "gtk-4.0"):
            d = self.host_dir / "xdg" / gtk
            d.mkdir(parents=True, mode=0o755)
            self._put(d / "settings.ini", f"[Settings]\ngtk-application-prefer-dark-theme={dark}\n")

    def close(self) -> None:
        if self.proc:
            self.proc.kill()
            self.proc.wait()
        with self.lock:  # a follow thread mid-write can't recreate a file now
            self.ready = False


def leader(container: str) -> str:
    out = run("machinectl", "show", container, "-p", "Leader", "--value", capture_output=True, text=True)
    pid = out.stdout.strip()
    if not pid.isdigit() or pid == "0":
        raise SystemExit(f"space-gui: container {container} is not running")
    return pid


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
        self.forwards: set[int] = set()
        self.opens_file = Path("/run/space-gui") / f"{container}.opens"
        self.closing = threading.Event()
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
                try:
                    ok = self.handle(data.decode("utf-8", "replace").strip())
                except OSError as e:
                    log(f"open refused: {e}")
                    ok = False
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
        # https only, whatever the origin gate: the URL must literally start
        # with https:// (so the opener can never take it for an option) and
        # carry no whitespace or control characters (which urlsplit would
        # silently strip).
        if (not u or u.scheme != "https" or not u.netloc or not url[:8].lower() == "https://"
                or len(url) > MAX_URL or any(ord(ch) <= 0x20 or ord(ch) == 0x7F for ch in url)):
            log(f"refused to open a URL that is not plain https: {url[:120]!r}")
            return False
        allowed = origin in self.c["openOrigins"]
        if not allowed and not self.c["openAnyHttps"]:
            log(f"refused to open a URL outside {self.c['openOrigins']}: {url[:120]!r}")
            return False
        # The sign-in's loopback forward is for the allowed origins only;
        # any other https URL (openAnyHttps) opens as a plain link, its
        # redirect_uri, if any, is none of ours.
        redirect = urllib.parse.parse_qs(u.query).get("redirect_uri", [""])[0] if allowed else ""
        m = re.fullmatch(r"http://127\.0\.0\.1:(\d{5})(/[A-Za-z0-9/_-]*)", redirect)
        if redirect and not (m and int(m.group(1)) in LOOPBACK_PORTS):
            log(f"refused: redirect_uri is not the app's loopback: {redirect[:120]!r}")
            return False
        if not self.rate_ok():
            log(f"refused: more than {OPEN_BURST} opens in {OPEN_WINDOW:g}s from {self.container}: {url[:120]!r}")
            return False
        if m:
            self.forward(int(m.group(1)), m.group(2))
        log(f"opening {origin}{u.path} in {CONF['hostUser']}'s browser")
        # In the host user's own manager, with their session's environment.
        subprocess.run(
            ["systemd-run", "--user", f"--machine={CONF['hostUser']}@.host", "--collect", "--quiet",
             *[f"-E{k}={v}" for k, v in self.env.items()], "--", CONF["opener"], url],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=False,
        )
        return True

    def rate_ok(self) -> bool:
        """Count this open against the container's OPEN_BURST per
        OPEN_WINDOW; False (not counted) beyond it."""
        try:
            fd = os.open(
                self.opens_file, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600
            )
        except OSError as e:
            log(f"open refused: rate file unusable ({e})")
            return False
        with os.fdopen(fd, "r+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            now = time.clock_gettime(time.CLOCK_BOOTTIME)
            opens = []
            for line in f.read().split():
                try:
                    t = float(line)
                except ValueError:
                    continue
                if 0 <= now - t < OPEN_WINDOW:
                    opens.append(t)
            ok = len(opens) < OPEN_BURST
            if ok:
                opens.append(now)
            f.seek(0)
            f.truncate()
            f.write("".join(f"{t}\n" for t in opens))
            return ok

    def forward(self, port: int, path: str) -> None:
        """This host's 127.0.0.1:<port> -> the container's 127.0.0.1:<port>,
        one shot: the listener closes once a callback request on `path`
        (with code= or error=) has had its answer, or after
        FORWARD_SECONDS."""
        if port in self.forwards:
            return
        try:
            lst = socket.create_server(("127.0.0.1", port), backlog=8)
        except OSError as e:
            log(f"cannot forward 127.0.0.1:{port}: {e}")
            return
        self.forwards.add(port)
        threading.Thread(target=self._accept, args=(lst, port, path), daemon=True).start()
        log(f"forwarding 127.0.0.1:{port} into {self.container}, one callback, at most {FORWARD_SECONDS}s")

    def _accept(self, lst: socket.socket, port: int, path: str) -> None:
        done = threading.Event()
        deadline = time.monotonic() + FORWARD_SECONDS
        lst.settimeout(0.5)
        try:
            while not done.is_set() and not self.closing.is_set() and time.monotonic() < deadline:
                try:
                    conn, _ = lst.accept()
                except TimeoutError:
                    continue
                except OSError:
                    break
                threading.Thread(target=self._relay, args=(conn, port, path, done), daemon=True).start()
        finally:
            lst.close()
            self.forwards.discard(port)
            log(f"closed the forward of 127.0.0.1:{port} ({'callback answered' if done.is_set() else 'timeout'})")

    def _guest_socket(self) -> socket.socket:
        """A TCP socket in the container's network namespace: created by a
        thread that joined it (setns of a network namespace is per thread;
        the socket keeps its namespace)."""
        out: dict = {}

        def enter():
            try:
                fd = os.open(f"/proc/{self.pid}/ns/net", os.O_RDONLY)
                try:
                    os.setns(fd, os.CLONE_NEWNET)
                finally:
                    os.close(fd)
                out["sock"] = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            except OSError as e:
                out["err"] = e

        t = threading.Thread(target=enter)
        t.start()
        t.join()
        if "err" in out:
            raise out["err"]
        return out["sock"]

    def _relay(self, conn: socket.socket, port: int, path: str, done: threading.Event) -> None:
        callback = False
        with conn:
            try:
                conn.settimeout(30)
                first = conn.recv(65536)
                if not first:
                    return
                line = first.split(b"\r\n", 1)[0].decode("latin-1")
                callback = re.match(rf"GET {re.escape(path)}\?(\S*&)?(code|error)=", line) is not None
                up = self._guest_socket()
            except OSError:
                return
            with up:
                try:
                    up.settimeout(30)
                    up.connect(("127.0.0.1", port))
                    up.sendall(first)
                except OSError:
                    return

                def forth():
                    try:
                        while chunk := conn.recv(65536):
                            up.sendall(chunk)
                        up.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass

                threading.Thread(target=forth, daemon=True).start()
                # The app's answer; its end (the app closes, or its
                # keep-alive times out) ends the relay.
                try:
                    while chunk := up.recv(65536):
                        conn.sendall(chunk)
                        if callback:
                            done.set()
                except OSError:
                    pass

    def close(self) -> None:
        self.closing.set()
        self.srv.close()


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
    # no `machinectl bind` (refused for a container with its own user
    # namespace): /run/space-gui/<container> is bound at /run/space-gui in
    # the guest from its start (./default.nix), so the run directory is
    # there already

    user_env = {"WAYLAND_DISPLAY": display}
    broker = Broker(container, c, pid, host_dir / "open.sock", user_env)
    scheme: ColorScheme | None = None
    rc = 1
    try:
        # inside the try: a stop during its up-to-3 s wait still cleans up
        scheme = ColorScheme(host_dir)
        log(f"{CONF['hostUser']}'s session prefers {scheme.word}")
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
            # the host session's light/dark preference (ColorScheme): the
            # run's portal (started in front of the command) serves and
            # follows the file; the env and the run's gtk settings.ini
            # carry the launch-time value for apps that ask no portal
            "-E", f"SPACE_GUI_COLOR_SCHEME={scheme.word}",
            "-E", f"SPACE_GUI_COLOR_SCHEME_FILE={guest_dir}/color-scheme",
            "-E", f"XDG_CONFIG_DIRS={guest_dir}/xdg:/etc/xdg:/etc/profiles/per-user/{c['user']}/etc/xdg:/run/current-system/sw/etc/xdg",
            "--", CONF["dbusRunSession"], f"--dbus-daemon={CONF['dbusDaemon']}",
            f"--config-file={CONF['dbusSessionConf']}", "--", CONF["colorScheme"], "portal", "--", *argv,
            check=False,
        ).returncode
    except KeyboardInterrupt:
        run("systemctl", "-M", container, "stop", f"{unit}.service", check=False)
    finally:
        if scheme:
            scheme.close()
        broker.close()
        os.close(close_w)  # the compositor stops accepting on the socket
        shutil.rmtree(host_dir, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
