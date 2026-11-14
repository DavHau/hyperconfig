"""Test probe run in scan-ocr@'s sandbox (./test.nix): which host sockets
and paths can the OCR worker reach?"""

import os
import socket

socket.socketpair()  # ocrmypdf's forkserver needs this
print("socketpair ok")
for p in ("/run/dbus/system_bus_socket", "/run/systemd/journal/stdout",
          "/run/nscd/socket", "/nix/var/nix/daemon-socket/socket"):
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect(p)
        print("CONNECTED", p)
    except OSError as e:
        print("refused", p, e)
    finally:
        s.close()
for p in ("/vault/misc", "/var/lib/scan-outbox", "/var/lib/scan-trigger"):
    print("SEES" if os.path.exists(p) else "hidden", p)
