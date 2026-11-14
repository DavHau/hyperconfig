"""webcam-snap@ / vit-screen@ server: one request per socket connection.

Runs under systemd socket activation (Accept=yes): the connection is fd 0
and fd 1. Protocol: the client sends ONE line, the server answers with
`OK <n>\\n` + n bytes, or `ERR <message>\\n`.

  snap [WxH]           -> one JPEG frame from the webcam   (mode "snap")
  screen off|on|status -> blank/unblank the greeter's VT   (mode "screen")

The caller is identified by SO_PEERCRED and named in the journal lines
for errors and refusals; successful requests are not logged, and photos
are never written to disk (ffmpeg's stdout straight to the socket).
"""

import fcntl
import json
import os
import pwd
import socket
import struct
import subprocess
import sys
import time
from typing import NoReturn

CONF = json.load(open(sys.argv[1]))
MODE = sys.argv[2]

# TIOCLINUX subcodes (linux/tiocl.h), KDGETMODE (linux/kd.h).
TIOCLINUX = 0x541C
TIOCL_UNBLANKSCREEN = 4
TIOCL_BLANKSCREEN = 14
KDGETMODE = 0x4B3B
KD_TEXT = 0


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def reply_err(msg) -> NoReturn:
    os.write(1, f"ERR {msg}\n".encode())
    sys.exit(1)


def reply_ok(data: bytes):
    out = os.fdopen(1, "wb", closefd=False)
    out.write(f"OK {len(data)}\n".encode())
    out.write(data)
    out.flush()


def peer_name():
    sock = socket.socket(fileno=os.dup(0))
    try:
        creds = sock.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
        )
    finally:
        sock.close()
    _pid, uid, _gid = struct.unpack("3i", creds)
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return f"uid {uid}"


def read_request():
    buf = b""
    while b"\n" not in buf and len(buf) < 128:
        chunk = os.read(0, 128 - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf.split(b"\n", 1)[0].decode("ascii", "replace").split()


def snap(args, who):
    size = args[0] if args else CONF["defaultSize"]
    if size not in CONF["sizes"]:
        reply_err(f"unsupported size {size!r}; one of: {' '.join(CONF['sizes'])}")
    if not os.path.exists(CONF["device"]):
        reply_err("webcam not present")
    cmd = [
        CONF["ffmpeg"], "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "v4l2", "-input_format", "mjpeg", "-video_size", size,
        "-i", CONF["device"],
        # Drop the first frames so auto-exposure/white balance settle.
        "-ss", str(CONF["warmupSeconds"]),
        "-frames:v", "1", "-c:v", "copy", "-f", "mjpeg", "pipe:1",
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=CONF["timeoutSeconds"])
    except subprocess.TimeoutExpired:
        log(f"snapshot by {who} timed out")
        reply_err("capture timed out (camera busy?)")
    jpeg = p.stdout
    if p.returncode != 0 or not jpeg.startswith(b"\xff\xd8"):
        log(f"snapshot by {who} failed: rc={p.returncode} {p.stderr.decode(errors='replace')[-300:]}")
        reply_err("capture failed (camera busy or unplugged?)")
    reply_ok(jpeg)


def panel_state():
    states = []
    for name in sorted(os.listdir("/sys/class/drm")):
        if "-eDP-" in name:
            # Disconnected connectors (e.g. the dGPU's unused eDP) report On.
            try:
                with open(f"/sys/class/drm/{name}/status") as f:
                    if f.read().strip() != "connected":
                        continue
                with open(f"/sys/class/drm/{name}/dpms") as f:
                    states.append(f.read().strip())
            except OSError:
                pass
    return "on" if "On" in states else "off"


def greeter_active():
    """None if the greeter owns the seat on its own VT, else the reason not.

    Both must hold: the kernel's active VT is greetd's (`greeterVt`), and
    logind's active session on seat0 is of class greeter on that tty.
    """
    vt = CONF["greeterVt"]
    with open("/sys/class/tty/tty0/active") as f:
        active = f.read().strip()
    if active != vt:
        return f"the active console is {active}, not the login screen ({vt})"
    try:
        seat = parse_kv("/run/systemd/seats/seat0")
        sess = parse_kv(f"/run/systemd/sessions/{seat['ACTIVE']}")
    except (OSError, KeyError):
        return "no active session on seat0"
    if sess.get("CLASS") != "greeter" or sess.get("TTY") != vt:
        return "someone is logged in at vit"
    return None


def parse_kv(path):
    # logind's state files (KEY=value lines); read-only, for the class check.
    with open(path) as f:
        return dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line and not line.startswith("#"))


def screen(args, who):
    action = args[0] if args else ""
    if action not in ("off", "on", "status"):
        reply_err("usage: vit-screen off|on|status")
    if action != "status":
        vt = CONF["greeterVt"]
        why = greeter_active()
        if why:
            log(f"screen {action} by {who} refused: {why}")
            reply_err(f"{why}; not touching the screen")
        try:
            fd = os.open(f"/dev/{vt}", os.O_RDWR | os.O_NOCTTY)
        except OSError as e:
            reply_err(f"cannot open {vt}: {e.strerror}")
        try:
            mode = struct.unpack("i", fcntl.ioctl(fd, KDGETMODE, b"\0" * 4))[0]
            if mode != KD_TEXT:
                # A graphical session (someone logged in): not ours to blank.
                reply_err("a graphical session is active on vit; not touching it")
            code = TIOCL_BLANKSCREEN if action == "off" else TIOCL_UNBLANKSCREEN
            fcntl.ioctl(fd, TIOCLINUX, bytes([code]))
        finally:
            os.close(fd)
        # DPMS follows the blank asynchronously (2-3 s); wait up to 5 s.
        for _ in range(50):
            if panel_state() == action:
                break
            time.sleep(0.1)
    reply_ok(f"{panel_state()}\n".encode())


def main():
    who = peer_name()
    args = read_request()
    if not args or args[0] != MODE:
        reply_err(f"unknown request; this socket only does {MODE!r}")
    (snap if MODE == "snap" else screen)(args[1:], who)


main()
