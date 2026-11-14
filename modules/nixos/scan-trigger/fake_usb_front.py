"""Fake ipp-usb front for the scan-trigger VM test.

ipp-usb serves a USB MFP's IPP (print), eSCL (scan) and web page on one
loopback port. This stands in for it without USB: it listens on
127.0.0.1:<port> and splices each connection, by the path of its first
request, to ippeveprinter (/ipp/...) or to ./fake_escl.py (everything
else). Per connection, not per request: CUPS keeps one connection for its
IPP requests, scan-trigger opens one per eSCL request.

    fake_usb_front.py <port> <ipp-port> <escl-port>
"""

import socket
import sys
import threading

PORT, IPP, ESCL = (int(a) for a in sys.argv[1:4])


def pump(src, dst):
    try:
        while True:
            b = src.recv(1 << 16)
            if not b:
                break
            dst.sendall(b)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(c):
    head = b""
    while b"\r\n" not in head and len(head) < 8192:
        b = c.recv(4096)
        if not b:
            c.close()
            return
        head += b
    parts = head.split(b"\r\n", 1)[0].split(b" ")
    path = parts[1] if len(parts) > 1 else b"/"
    port = IPP if path.startswith(b"/ipp") else ESCL
    u = socket.create_connection(("127.0.0.1", port))
    u.sendall(head)
    t = threading.Thread(target=pump, args=(u, c), daemon=True)
    t.start()
    pump(c, u)
    t.join()
    c.close()
    u.close()


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT))
s.listen(16)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
