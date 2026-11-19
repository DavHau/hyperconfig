"""The vault-request page: the user adds the vault item an agent asked for (./plugin).

Runs as the agent's uid, socket-activated per agent on a unix socket only nginx may connect to
(../default.nix). nginx lets a request through only with a session the agent's dashboard accepts
(an auth subrequest to its /api/auth/me), so only the agent's owners reach it.

  GET  /vault/<id>   the form for that request: what it is for (kind, label, site, the agent's
                     reason), the fields of its kind with autocomplete hints, so a browser's saved
                     card, password or address fills them
  POST /vault/<id>   the values, straight into the agent's encrypted vault
                     (agent/vault_store.py VaultStore.add_item, the store `hermes vault add` and
                     the desktop app write); the request keeps the item's handle only

A request is single use, expires (30 minutes), is bound to this agent's request directory and
names the profile home whose vault gets the item. POSTs need Sec-Fetch-Site same-origin, or
without Fetch Metadata an Origin equal to the dashboard's; plus the request's own form token.
Values travel in the POST body only: never in a URL, a log line, a response or a file of ours.
Pages are not cacheable, not frameable, and load nothing (CSP default-src 'none').
"""
from __future__ import annotations

import contextlib
import hmac
import html
import os
import re
import socket
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "plugin"))
import common  # noqa: E402

MAX_BODY = 16 * 1024
MAX_FIELD = 512
IDLE_EXIT = 600
CSP = ("default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; "
       "base-uri 'none'")
PATH_RE = re.compile(r"^/vault/([0-9a-f]{32})$")

# name, label, autocomplete, required, input attributes
FIELDS = {
    "payment": [
        ("cardholder_name", "Name on card", "cc-name", False, 'autocapitalize="characters"'),
        ("card_number", "Card number", "cc-number", True, 'inputmode="numeric"'),
        ("exp_month", "Expiry month (MM)", "cc-exp-month", True, 'inputmode="numeric" maxlength="2"'),
        ("exp_year", "Expiry year (YYYY)", "cc-exp-year", True, 'inputmode="numeric" maxlength="4"'),
        ("cvc", "Security code (CVC)", "cc-csc", True, 'inputmode="numeric" maxlength="4"'),
        ("billing_postal_code", "Billing postal code", "billing postal-code", False, ""),
    ],
    "login": [
        ("identifier", "Email, phone or username", "username", True, 'autocapitalize="none" spellcheck="false"'),
        ("password", "Password", "current-password", True, ""),
        ("otp_secret", "Authenticator key (optional: the TOTP setup key)", "off", False,
         'autocapitalize="none" spellcheck="false"'),
    ],
    "address": [
        ("address_line1", "Street and number", "address-line1", True, ""),
        ("address_line2", "Address line 2", "address-line2", False, ""),
        ("postal_code", "Postal code", "postal-code", True, ""),
        ("city", "City", "address-level2", True, ""),
        ("state", "State / region", "address-level1", False, ""),
        ("country", "Country", "country-name", True, ""),
    ],
}
SECRET_FIELDS = {"card_number", "cvc", "password", "otp_secret"}
KIND_NAMES = {"payment": "a payment card", "login": "a login", "address": "an address"}


class Invalid(Exception):
    pass


def _luhn(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def _payment(form: dict) -> dict:
    number = re.sub(r"[\s-]", "", form.get("card_number", ""))
    if not re.fullmatch(r"\d{12,19}", number) or not _luhn(number):
        raise Invalid("The card number is not valid.")
    month = form.get("exp_month", "").strip()
    if not re.fullmatch(r"\d{1,2}", month) or not 1 <= int(month) <= 12:
        raise Invalid("The expiry month must be 1 to 12.")
    year = form.get("exp_year", "").strip()
    if re.fullmatch(r"\d{2}", year):
        year = "20" + year
    if not re.fullmatch(r"20\d{2}", year):
        raise Invalid("The expiry year must look like 2029.")
    if (int(year), int(month)) < time.localtime()[:2]:
        raise Invalid("This card has expired.")
    cvc = form.get("cvc", "").strip()
    if not re.fullmatch(r"\d{3,4}", cvc):
        raise Invalid("The security code must be 3 or 4 digits.")
    out = {"card_number": number, "exp_month": month.zfill(2), "exp_year": year, "cvc": cvc}
    for name in ("cardholder_name", "billing_postal_code"):
        if form.get(name, "").strip():
            out[name] = " ".join(form[name].split())
    return out


def _login(form: dict) -> dict:
    identifier = form.get("identifier", "").strip()
    if not identifier or any(c.isspace() for c in identifier):
        raise Invalid("Enter the email, phone number or username, without spaces.")
    if not form.get("password"):
        raise Invalid("Enter the password.")
    kind = ("email" if "@" in identifier else "phone" if re.fullmatch(r"\+?[\d ()./-]{6,}", identifier)
            else "username")
    out = {"identifier_type": kind, "identifier": identifier, "password": form["password"]}
    if form.get("otp_secret", "").strip():
        # checked here, before the request turns "saving": the vault would refuse a bad key only
        # after that and burn the link
        from agent.vault_store import VaultError, normalize_otp_secret
        try:
            normalize_otp_secret(form["otp_secret"])
        except VaultError:
            raise Invalid("The authenticator key is not a valid TOTP key (base32 or otpauth://totp link).") from None
        out["otp_secret"] = form["otp_secret"].strip()
    return out


def _address(form: dict) -> dict:
    out = {}
    for name, _label, _ac, required, _attrs in FIELDS["address"]:
        value = " ".join(form.get(name, "").split())
        if required and not value:
            raise Invalid("Fill in street, postal code, city and country.")
        if value:
            out[name] = value
    return out


VALIDATE = {"payment": _payment, "login": _login, "address": _address}


def _home_of(req: dict) -> Path:
    """The vault's home: the agent's own, or one of its profiles. Nothing else."""
    root = Path(os.environ["HERMES_HOME"]).resolve()
    home = Path(str(req.get("hermes_home") or root)).resolve()
    if home == root or (home.parent == root / "profiles" and home.is_dir()):
        return home
    raise Invalid("This request names a profile this page does not know.")


def _store(req: dict, label: str, secret: dict) -> str:
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    from agent.vault_store import VaultStore

    home = _home_of(req)
    token = set_hermes_home_override(str(home))
    try:
        meta = VaultStore(base_dir=home / "vault").add_item(
            kind=req["kind"], label=label, secret=secret, origin=req["origin"])
    finally:
        reset_hermes_home_override(token)
    return meta.id


def _page(title: str, body: str) -> bytes:
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light"><meta name="referrer" content="no-referrer">
<title>{html.escape(title)}</title>
<style>
:root{{--bg:#111418;--fg:#e6e8eb;--muted:#9aa3ad;--box:#1b2027;--line:#333b45;--accent:#4c8dff;--warn:#ff7b72;--ok:#56d364}}
@media (prefers-color-scheme: light){{:root{{--bg:#fff;--fg:#1f2328;--muted:#59636e;--box:#f6f8fa;--line:#d0d7de;--accent:#0969da;--warn:#cf222e;--ok:#1a7f37}}}}
body{{background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:2rem auto;padding:0 1rem}}
.box{{background:var(--box);border:1px solid var(--line);border-radius:8px;padding:.8rem 1rem}}
.box td{{padding:.15rem .8rem .15rem 0;vertical-align:top}} .box td:first-child{{color:var(--muted)}}
label{{display:block;margin-top:.9rem;font-weight:600}}
input{{width:100%;box-sizing:border-box;padding:.55rem;font-size:1rem;border-radius:6px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}}
.row{{display:flex;gap:.8rem}} .row>div{{flex:1}}
button{{margin-top:1.4rem;padding:.65rem 1.4rem;font-size:1rem;border:0;border-radius:6px;background:var(--accent);color:#fff}}
.muted{{color:var(--muted);font-size:.9rem}} .warn{{color:var(--warn)}} .ok{{color:var(--ok)}}
</style></head><body>{body}</body></html>""".encode()


def _summary(req: dict) -> str:
    e = html.escape
    rows = [("What", KIND_NAMES[req["kind"]]), ("Label", e(req["label"])),
            ("Filled only on", f"<b>{e(req['origin'])}</b>"),
            ("Link expires", time.strftime("%H:%M %Z", time.localtime(float(req["expires"]))))]
    if req.get("reason"):
        rows.append(("Agent's reason", f"<i>{e(req['reason'])}</i>"))
    return '<div class="box"><table>' + "".join(f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in rows) + "</table></div>"


def _form(req: dict, error: str = "") -> bytes:
    e = html.escape
    parts = [f"<h1>Add {KIND_NAMES[req['kind']]} to your agent's vault</h1>",
             "<p>Your agent asked for this. What you enter goes straight into its encrypted vault: the "
             "agent never sees the values, it can only fill them into the site below. Only continue if "
             "you expected this request.</p>", _summary(req)]
    if error:
        parts.append(f'<p class="warn"><b>{e(error)}</b> Nothing was saved.</p>')
    parts.append('<form method="post" autocomplete="on">'
                 f'<input type="hidden" name="token" value="{e(req["token"])}">'
                 f'<label for="label">Name in the vault</label>'
                 f'<input id="label" name="label" value="{e(req["label"])}" maxlength="{common.MAX_LABEL}" '
                 'autocomplete="off" required>')
    if req["kind"] == "login":
        parts.append(f'<input type="hidden" name="site" value="{e(req["origin"])}" autocomplete="url">')
    fields = FIELDS[req["kind"]]
    i = 0
    while i < len(fields):
        name, label, ac, required, attrs = fields[i]
        if name == "exp_month":  # month and year side by side
            group = fields[i:i + 2]
            i += 2
        else:
            group = [fields[i]]
            i += 1
        cells = []
        for name, label, ac, required, attrs in group:
            kind = "password" if name in ("password", "cvc") else "text"
            cells.append(f'<div><label for="{name}">{e(label)}</label>'
                         f'<input id="{name}" name="{name}" type="{kind}" autocomplete="{ac}" '
                         f'maxlength="{MAX_FIELD}" {attrs}{" required" if required else ""}></div>')
        parts.append(cells[0] if len(cells) == 1 else '<div class="row">' + "".join(cells) + "</div>")
    parts.append('<button type="submit">Save to vault</button></form>'
                 '<p class="muted">Your browser may offer a saved card, password or address for these '
                 "fields. If this page was open for long, reload it first: an expired sign-in drops what "
                 "you typed.</p>")
    return _page("Add to vault", "".join(parts))


class Handler(BaseHTTPRequestHandler):
    server_version = "hermes-vault-request"
    sys_version = ""
    timeout = 30

    def log_message(self, format, *args):  # nothing: nginx logs the request line, no values
        pass

    def _send(self, code: int, body: bytes) -> None:
        self.send_response(code)
        for k, v in (("Content-Type", "text/html; charset=utf-8"), ("Content-Length", str(len(body))),
                     ("Cache-Control", "no-store"), ("Pragma", "no-cache"), ("Content-Security-Policy", CSP),
                     ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
                     ("X-Content-Type-Options", "nosniff"), ("Cross-Origin-Opener-Policy", "same-origin")):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _message(self, code: int, text: str) -> None:
        self._send(code, _page("Vault", f"<p>{html.escape(text)}</p>"))

    def _gone(self, state: str) -> None:
        self._message(410 if state != "missing" else 404, {
            "done": "This request was answered already: the item is saved. You can close this page.",
            "expired": "This link has expired. Ask your agent for a new one.",
            "cancelled": "Your agent cancelled this request.",
            "saving": "This request is being saved right now.",
            "error": "This request failed. Ask your agent for a new one.",
        }.get(state, "Unknown or old link. Ask your agent for a new one."))

    def _request(self) -> str | None:
        m = PATH_RE.match(self.path)
        if not m or common.load(m.group(1)) is None:
            self._gone("missing")
            return None
        return m.group(1)

    def do_GET(self):
        rid = self._request()
        if rid is None:
            return
        req = common.load(rid)
        state = common.state_of(req)
        if state != "pending":
            self._gone(state)
            return
        self._send(200, _form(req))

    def do_POST(self):
        # Same-origin only: a browser's own verdict when it sends one (the page's no-referrer policy
        # makes a form post carry Origin: null), else an exact Origin. nginx's Fetch Metadata gate
        # refuses cross-site posts before this already.
        site = self.headers.get("Sec-Fetch-Site")
        origin = self.headers.get("Origin")
        allowed = site == "same-origin" if site else origin == common.public_url()
        if not allowed:
            self._message(403, "Refused: this form must be sent from its own page.")
            return
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/x-www-form-urlencoded":
            self._message(415, "Unsupported form encoding.")
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_BODY:
            self._message(413, "Too large.")
            return
        body = self.rfile.read(length)
        rid = self._request()
        if rid is None:
            return
        with common.locked(rid):
            self._submit(rid, body)

    def _submit(self, rid: str, body: bytes) -> None:
        req = common.load(rid)
        state = common.state_of(req)
        if state != "pending":
            self._gone(state)
            return
        try:
            pairs = urllib.parse.parse_qsl(body.decode("utf-8"), keep_blank_values=True, max_num_fields=20)
        except (UnicodeDecodeError, ValueError):
            pairs = []
        form = {}
        for k, v in pairs:
            form.setdefault(k, v)
        del body, pairs
        if not hmac.compare_digest(form.get("token", "").encode(), req["token"].encode()):
            self._attempt(req, "This form is stale: reload the page.")
            return
        try:
            if any(len(v) > MAX_FIELD for v in form.values()):
                raise Invalid("A field is too long.")
            label = common.one_line(form.get("label", ""), common.MAX_LABEL, "The name") or req["label"]
            secret = VALIDATE[req["kind"]](form)
        except (Invalid, common.RequestError) as exc:
            self._attempt(req, str(exc))
            return
        finally:
            form.clear()
        req["state"] = "saving"
        common.save(req)
        try:
            req["item_id"] = _store(req, label, secret)
            req["state"], req["error"] = "done", ""
        except Exception as exc:  # never stuck in saving; the vault's own errors carry no values
            req["state"] = "error"
            req["error"] = (str(exc)[:200] if type(exc).__name__ in ("VaultError", "Invalid")
                            else f"internal error ({type(exc).__name__})")
        finally:
            secret.clear()
            common.save(req)
        print(f"request {rid[:8]}: {req['kind']}: {req['state']}", flush=True)
        if req["state"] == "done":
            self._send(200, _page("Saved", '<p class="ok"><b>Saved.</b> Your agent can use it now; you can '
                                  "close this page.</p>" + _summary(req)))
        else:
            self._send(500, _page("Not saved", f'<p class="warn"><b>Not saved: {html.escape(req["error"])}</b> '
                                  "Ask your agent for a new link.</p>"))

    def _attempt(self, req: dict, msg: str) -> None:
        req["attempts"] = int(req.get("attempts", 0)) + 1
        if req["attempts"] >= common.MAX_ATTEMPTS:
            req["state"], req["error"] = "error", "too many failed submissions"
            common.save(req)
            self._gone("error")
            return
        common.save(req)
        self._send(400, _form(req, msg))


class Server(HTTPServer):
    """One request at a time (nginx is the only client; Handler.timeout bounds a slow one). Exits
    after IDLE_EXIT seconds without a connection; systemd keeps the socket and starts it again."""

    address_family = socket.AF_UNIX  # the unit allows no other family
    idle = False

    def server_bind(self):  # the socket is systemd's, bound already
        pass

    def handle_timeout(self):
        self.idle = True


def main() -> None:
    if os.environ.get("LISTEN_FDS") != "1" or os.environ.get("LISTEN_PID") != str(os.getpid()):
        sys.exit("hermes-vault-request: run me from the socket unit")
    server = Server("", Handler, bind_and_activate=False)
    server.socket.close()
    server.socket = socket.socket(fileno=3)
    server.timeout = IDLE_EXIT
    with contextlib.suppress(KeyboardInterrupt):
        while not server.idle:
            server.handle_request()


if __name__ == "__main__":
    main()
