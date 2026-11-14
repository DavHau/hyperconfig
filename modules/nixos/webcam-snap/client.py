"""Client for the webcam-snap / vit-screen sockets (see ./server.py).

  webcam-snap [WxH] > shot.jpg
  vit-screen off|on|status
"""

import os
import socket
import sys

SOCKETS = {"webcam-snap": ("@snapSocket@", "snap"), "vit-screen": ("@screenSocket@", "screen")}
prog = os.path.basename(sys.argv[0])
path, verb = SOCKETS[prog]

if prog == "webcam-snap" and os.isatty(1):
    sys.exit("webcam-snap: refusing to write a JPEG to a terminal; redirect it: webcam-snap > shot.jpg")

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
# Longer than the server units' RuntimeMaxSec (30 s), so the server
# always answers or closes first.
s.settimeout(35)
try:
    s.connect(path)
except PermissionError:
    sys.exit(f"{prog}: permission denied (only members of group webcam-snap may use it)")
except (FileNotFoundError, ConnectionRefusedError):
    sys.exit(f"{prog}: service socket {path} missing")
s.sendall((" ".join([verb] + sys.argv[1:2]) + "\n").encode())
f = s.makefile("rb")
head = f.readline().decode(errors="replace").strip()
if not head.startswith("OK "):
    sys.exit(f"{prog}: {head.removeprefix('ERR ') or 'no answer (busy: another shot is in progress?)'}")
n = int(head.split()[1])
data = f.read(n)
if len(data) != n:
    sys.exit(f"{prog}: short reply ({len(data)} of {n} bytes)")
sys.stdout.buffer.write(data)
sys.stdout.flush()
