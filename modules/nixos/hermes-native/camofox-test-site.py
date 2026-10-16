"""Download site for camofox-test.nix: pages that start downloads by a link, a form
POST answered with an attachment, a form POST answered with a 302 to a file on
another origin (APKSum's shape), and a script-built blob; plus a fetch() re-POST
of the redirecting form and a file over browser_downloads' 50 MiB limit.

Files are deterministic bytes; `site.py --sha <name>` prints a file's sha256.
"""
import hashlib
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def payload(name: str, size: int) -> bytes:
    seed = hashlib.sha256(name.encode()).digest()
    out = bytearray()
    block = seed
    while len(out) < size:
        block = hashlib.sha256(block).digest()
        out += block
    return bytes(out[:size])


FILES = {
    "link.bin": 300_000,
    "form.bin": 1_234_567,
    "js.bin": 77_777,
    "redirect.bin": 1_678_318,
}
BIG = 60 * 1024 * 1024  # over the 50 MiB save limit

INDEX = b"""<!doctype html><html><head><title>downloads</title></head><body>
<h1>Downloads</h1>
<a id="link" href="/files/link.bin">Direct link download</a>
<form id="f" method="post" action="/submit">
  <input type="hidden" name="token" value="abc123">
  <button id="formbtn" type="submit">Form download</button>
</form>
<form id="f2" method="post" action="/submit-redirect">
  <input type="hidden" name="token" value="abc123">
  <button id="redirbtn" type="submit">Redirect form download</button>
</form>
<button id="jsbtn" onclick="go()">JS download</button>
<button id="fetchbtn" onclick="refetch()">Fetch re-POST</button>
<p id="fetchresult">none</p>
<a id="big" href="/files/big.bin">Big download</a>
<script>
async function go() {
  const r = await fetch('/raw/js.bin');
  const b = await r.blob();
  const a = document.createElement('a');
  a.href = URL.createObjectURL(b);
  a.download = 'js.bin';
  document.body.appendChild(a);
  a.click();
}
async function refetch() {
  const el = document.getElementById('fetchresult');
  try {
    const r = await fetch('/submit-redirect', {method: 'POST', body: new URLSearchParams(new FormData(document.getElementById('f2'))), credentials: 'include'});
    el.textContent = 'status ' + r.status;
  } catch (e) {
    el.textContent = 'err ' + e;
  }
}
</script>
</body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("site: " + fmt % args + "\n")

    def _file(self, name, data, attach=True):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        if attach:
            self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(INDEX)))
            self.end_headers()
            self.wfile.write(INDEX)
        elif self.path == "/files/big.bin":
            self._file("big.bin", payload("big.bin", BIG))
        elif self.path.startswith("/files/") and self.path[7:] in FILES:
            n = self.path[7:]
            self._file(n, payload(n, FILES[n]))
        elif self.path.startswith("/raw/") and self.path[5:] in FILES:
            n = self.path[5:]
            self._file(n, payload(n, FILES[n]), attach=False)
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if self.path == "/submit-redirect" and b"token=abc123" in body:
            # Like APKSum: the POST answers 302 to a file on another origin.
            port = self.server.server_address[1]
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{port}/files/redirect.bin")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/submit" and b"token=abc123" in body:
            self._file("form.bin", payload("form.bin", FILES["form.bin"]))
        else:
            self.send_error(403)


class DualStack(ThreadingHTTPServer):
    # localhost may resolve to ::1 first, so listen on both families.
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--sha":
        n = sys.argv[2]
        print(hashlib.sha256(payload(n, BIG if n == "big.bin" else FILES[n])).hexdigest())
        sys.exit(0)
    DualStack(("::", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
