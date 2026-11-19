"""Stand-in residential proxy and page for the browser check (default.nix).

On 127.0.0.1:<port> it is both:
  - an HTTP proxy: a request in absolute-URI form (http://...) without
    Proxy-Authorization gets 407 with a Basic challenge, as the real gateway
    answers; with it, the page `via residential <username>`;
  - the page itself for direct requests (origin-form): `direct`.
So the page text says whether the browser went through the proxy and with
which proxy username (the country).
"""
import base64
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("http://"):
            auth = self.headers.get("Proxy-Authorization", "")
            if not auth.startswith("Basic "):
                self.send_response(407)
                self.send_header("Proxy-Authenticate", 'Basic realm="residential"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            user = base64.b64decode(auth[6:]).decode().partition(":")[0]
            text = f"via residential {user}"
        else:
            text = "direct"
        body = f"<html><body><p>{text}</p></body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
