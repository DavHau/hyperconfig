"""Stand-in residential proxy and page for the browser check (default.nix).

On 127.0.0.1:<port> it is both:
  - an HTTP proxy: a request in absolute-URI form (http://...) without
    Proxy-Authorization gets 407 with a Basic challenge, as the real gateway
    answers; with it, the page `via residential <username>`;
  - the page itself for direct requests (origin-form): `direct`.
So the page text says whether the browser went through the proxy and with
which proxy username (the country, and the sticky exit session). Every page
also names its own path and links to `<path>-next`, so a click on that link
proves which page a ref belonged to (concurrency.py).
"""
import base64
import html
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


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
            path = urlsplit(self.path).path
        else:
            text = "direct"
            path = urlsplit(self.path).path
        p = html.escape(path)
        body = (f"<html><body><p>{text}</p><p>page {p}</p>"
                f"<a href=\"{p}-next\">next {p}</a></body></html>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
