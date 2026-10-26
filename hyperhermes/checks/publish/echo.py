"""A published app: answers every request with `<label> <port>`, plants a
cookie on the whole domain, and logs what it saw, one JSON line per request.

usage: echo.py <port> <log file> [label]
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, log = int(sys.argv[1]), sys.argv[2]
label = sys.argv[3] if len(sys.argv) > 3 else "backend"


class H(BaseHTTPRequestHandler):
    def handle_any(self):
        seen = {
            "path": self.path,
            "cookie": self.headers.get_all("Cookie") or [],
            "origin": self.headers.get("Origin"),
            "host": self.headers.get("Host"),
            "forwarded_host": self.headers.get("X-Forwarded-Host"),
            "forwarded_proto": self.headers.get("X-Forwarded-Proto"),
        }
        with open(log, "a") as f:
            f.write(json.dumps(seen) + "\n")
        body = f"{label} {port}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        # The agent tries the whole domain; nginx pins it to the port host.
        self.send_header("Set-Cookie", "planted=1; Domain=hermes.localhost; Path=/")
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = handle_any

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
