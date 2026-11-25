"""The owner's vault page of one agent (./owner.nix): what the agent stored, and its logins' passwords.

Runs as a dynamic user of its own (never the agent's uid), socket-activated on a unix socket only
nginx may connect to. nginx serves it on the front door (the deployment's own site, behind the
front door's sign-in) and passes the signed-in account in X-Hermes-Account, which it always
overwrites; this page admits only the agent's owning accounts (HERMES_VAULT_OWNERS).

  GET  /vault/<agent>/   the items of every vault of the agent (home and profiles): label, kind,
                         site, login name, created; a card's brand and last 4 digits only
  POST /vault/<agent>/   action=reveal: a login's password, in this response only (no-store),
                         with a copy button; action=delete: a confirmation, then (confirm=yes)
                         the item is removed

The values come from the agent's vault broker (../core/vault-broker.py owner_*), which answers
these operations for this unit's main process only, audits every reveal and delete in its journal
and caps reveals per hour. POSTs need Sec-Fetch-Site same-origin (or without Fetch Metadata an
Origin equal to the front door's) and a form token bound to the account (HMAC, 2 hours). Nothing
of a value is logged, put in a URL, cached or written anywhere.
"""
from __future__ import annotations

import contextlib
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import socket
import struct
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

AGENT = os.environ["HERMES_VAULT_AGENT"]
OWNERS = set(os.environ.get("HERMES_VAULT_OWNERS", "").split())
PUBLIC_URL = os.environ["HERMES_VAULT_OWNER_URL"].rstrip("/")
BROKER = os.environ["HERMES_VAULT_BROKER_SOCKET"]
DASHBOARD = os.environ.get("HERMES_VAULT_DASHBOARD_URL", "")
STATE = Path(os.environ["STATE_DIRECTORY"].split(":")[0])
PATH = f"/vault/{AGENT}/"
MAX_BODY = 4096
IDLE_EXIT = 600
ID_RE = re.compile(r"^vault_[0-9a-f]{1,32}$")
STORE_RE = re.compile(r"^(?:home|profiles/[a-z0-9][a-z0-9_-]{0,63}|other/[0-9a-f]{32})$")
KIND_NAMES = {"payment": "Card", "login": "Login", "address": "Address"}


class BrokerError(Exception):
    pass


def broker(op: str, **args) -> object:
    """One request to the agent's vault broker; it checks that we are this unit's main process."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    try:
        sock.settimeout(15)
        sock.connect(BROKER)
        _pid, uid, _gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                              struct.calcsize("3i")))
        if uid == os.getuid():
            raise BrokerError("the vault broker socket is not the host's")
        sock.sendall(json.dumps({"op": op, **args}).encode() + b"\n")
        sock.shutdown(socket.SHUT_WR)
        data = b""
        while chunk := sock.recv(65536):
            data += chunk
            if len(data) > 4 * 1024 * 1024:
                raise BrokerError("the vault broker's reply is too large")
    except OSError as exc:
        raise BrokerError(f"the vault broker is not reachable ({type(exc).__name__})") from None
    finally:
        sock.close()
    try:
        reply = json.loads(data)
    except ValueError:
        raise BrokerError("the vault broker sent no valid reply") from None
    if not isinstance(reply, dict) or not reply.get("ok"):
        raise BrokerError(str((reply or {}).get("error") or "the vault broker refused")[:300])
    return reply.get("result")


def _form_key() -> bytes:
    path = STATE / "form-key"
    with contextlib.suppress(FileExistsError):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(secrets.token_bytes(32))
    return path.read_bytes()


FORM_KEY = b""


def token_for(account: str, hour: int | None = None) -> str:
    hour = int(time.time() // 3600) if hour is None else hour
    return hmac.new(FORM_KEY, f"{AGENT}\n{account}\n{hour}".encode(), hashlib.sha256).hexdigest()


def token_ok(account: str, token: str) -> bool:
    now = int(time.time() // 3600)
    return any(hmac.compare_digest(token.encode(), token_for(account, h).encode()) for h in (now, now - 1))


def _page(title: str, body: str, nonce: str = "") -> bytes:
    script = ""
    if nonce:
        # the copy button: the only script, allowed by its nonce
        script = (f'<script nonce="{nonce}">document.querySelectorAll("button[data-copy]").forEach(function(b){{'
                  'b.addEventListener("click",function(){var t=document.getElementById(b.dataset.copy);'
                  'navigator.clipboard.writeText(t.value).then(function(){b.textContent="Copied";},'
                  'function(){t.select();b.textContent="Press Ctrl+C";});});});</script>')
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light"><meta name="referrer" content="no-referrer">
<title>{html.escape(title)}</title>
<style>
:root{{--bg:#111418;--fg:#e6e8eb;--muted:#9aa3ad;--box:#1b2027;--line:#333b45;--accent:#4c8dff;--warn:#ff7b72}}
@media (prefers-color-scheme: light){{:root{{--bg:#fff;--fg:#1f2328;--muted:#59636e;--box:#f6f8fa;--line:#d0d7de;--accent:#0969da;--warn:#cf222e}}}}
body{{background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif;max-width:52rem;margin:2rem auto;padding:0 1rem}}
table{{border-collapse:collapse;width:100%}} td,th{{text-align:left;padding:.4rem .6rem;border-bottom:1px solid var(--line);vertical-align:top}}
th{{color:var(--muted);font-weight:600}} .muted{{color:var(--muted);font-size:.9rem}} .warn{{color:var(--warn)}}
form{{display:inline}} button{{padding:.35rem .8rem;border:0;border-radius:6px;background:var(--accent);color:#fff;font-size:.9rem;cursor:pointer}}
button.del{{background:transparent;color:var(--warn);border:1px solid var(--warn)}}
.box{{background:var(--box);border:1px solid var(--line);border-radius:8px;padding:.8rem 1rem;margin:1rem 0}}
input{{font:1rem monospace;width:100%;box-sizing:border-box;padding:.5rem;border-radius:6px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}}
</style></head><body>{body}{script}</body></html>""".encode("utf-8", "replace")


def _hidden(account: str, store: str, item_id: str) -> str:
    e = html.escape
    return (f'<input type="hidden" name="token" value="{e(token_for(account))}">'
            f'<input type="hidden" name="store" value="{e(store)}">'
            f'<input type="hidden" name="item_id" value="{e(item_id)}">')


def _created(value: str) -> str:
    return html.escape((value or "")[:10])


def list_page(account: str, stores: list) -> bytes:
    e = html.escape
    parts = [f"<h1>Vault of {e(AGENT)}</h1>",
             "<p>What your agent keeps in its encrypted vault. It fills these into web pages itself and "
             "never sees passwords or card numbers. Show a login's password to sign in yourself; cards "
             "show only their last 4 digits.</p>"]
    if not any(s.get("items") for s in stores):
        parts.append('<p class="muted">The vault is empty.</p>')
    for s in stores:
        items = s.get("items") or []
        if s.get("error"):
            parts.append(f'<p class="warn">{e(str(s.get("title", "")))}: {e(str(s["error"]))}.</p>')
        if not items:
            continue
        if len(stores) > 1:
            parts.append(f"<h2>{e(str(s.get('title', '')))}</h2>")
        parts.append("<table><tr><th>Label</th><th>Kind</th><th>Site</th><th>Login / card</th>"
                     "<th>Created</th><th></th></tr>")
        for it in items:
            kind = str(it.get("kind", ""))
            if kind == "payment":
                what = f"{e(str(it.get('brand') or 'Card'))} &bull;&bull;&bull;&bull; {e(str(it.get('last4') or '????'))}"
            elif kind == "login":
                what = e(str(it.get("identifier") or ""))
            else:
                what = ""
            actions = ""
            if kind == "login":
                actions += (f'<form method="post" action="{PATH}">{_hidden(account, s["store"], it["id"])}'
                            '<input type="hidden" name="action" value="reveal">'
                            '<button type="submit">Show password</button></form> ')
            actions += (f'<form method="post" action="{PATH}">{_hidden(account, s["store"], it["id"])}'
                        '<input type="hidden" name="action" value="delete">'
                        '<button class="del" type="submit">Delete</button></form>')
            origin = it.get("origin") or ("any site" if kind != "login" else "")
            parts.append(f"<tr><td>{e(str(it.get('label', '')))}</td><td>{KIND_NAMES.get(kind, e(kind))}</td>"
                         f"<td>{e(str(origin))}</td><td>{what}</td><td>{_created(str(it.get('created_at', '')))}</td>"
                         f"<td>{actions}</td></tr>")
        parts.append("</table>")
    parts.append('<p class="muted">Every password shown and every delete is recorded (which item, never the '
                 "value). Add a card or login when your agent sends you a request link.</p>")
    if DASHBOARD:
        parts.append(f'<p class="muted"><a href="{e(DASHBOARD)}/">Back to the dashboard</a></p>')
    return _page(f"Vault of {AGENT}", "".join(parts))


def reveal_page(item: dict) -> tuple[bytes, str]:
    e = html.escape
    nonce = secrets.token_urlsafe(16)
    rows = [("Label", e(str(item.get("label") or ""))), ("Site", e(str(item.get("origin") or "")))]
    body = [f"<h1>{e(str(item.get('label') or 'Login'))}</h1>", '<div class="box"><table>']
    body += [f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in rows]
    body.append("</table></div>")
    for field, title in (("identifier", item.get("identifier_type") or "login"), ("password", "password")):
        body.append(f"<p><b>{e(str(title).capitalize())}</b></p>"
                    f'<input id="{field}" readonly autocomplete="off" spellcheck="false" value="{e(str(item.get(field) or ""))}">'
                    f'<p><button type="button" data-copy="{field}">Copy {e(str(title))}</button></p>')
    body.append(f'<p class="muted">Shown once, for this page only: it is not stored in your browser\'s cache. '
                f'<a href="{PATH}">Back to the vault</a></p>')
    return _page("Password", "".join(body), nonce), nonce


def confirm_page(account: str, store: str, item: dict) -> bytes:
    e = html.escape
    return _page("Delete?", f"<h1>Delete {e(str(item.get('label') or item['id']))}?</h1>"
                 f"<p>Your agent can no longer fill it ({KIND_NAMES.get(str(item.get('kind')), '')}"
                 f"{', ' + e(str(item['origin'])) if item.get('origin') else ''}). This cannot be undone.</p>"
                 f'<form method="post" action="{PATH}">{_hidden(account, store, item["id"])}'
                 '<input type="hidden" name="action" value="delete"><input type="hidden" name="confirm" value="yes">'
                 '<button class="del" type="submit">Delete</button></form> '
                 f'<a href="{PATH}">Cancel</a>')


class Handler(BaseHTTPRequestHandler):
    server_version = "hermes-vault-owner"
    sys_version = ""
    timeout = 30

    def log_message(self, format, *args):  # nothing: nginx logs the request line, which has no values
        pass

    def _send(self, code: int, body: bytes, nonce: str = "") -> None:
        csp = ("default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; "
               "base-uri 'none'" + (f"; script-src 'nonce-{nonce}'" if nonce else ""))
        self.send_response(code)
        for k, v in (("Content-Type", "text/html; charset=utf-8"), ("Content-Length", str(len(body))),
                     ("Cache-Control", "no-store"), ("Pragma", "no-cache"), ("Content-Security-Policy", csp),
                     ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
                     ("X-Content-Type-Options", "nosniff"), ("Cross-Origin-Opener-Policy", "same-origin"),
                     ("Cross-Origin-Resource-Policy", "same-origin")):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _message(self, code: int, text: str) -> None:
        self._send(code, _page("Vault", f'<p class="warn">{html.escape(text)}</p>'
                                        f'<p><a href="{PATH}">Back to the vault</a></p>'))

    def _account(self) -> str | None:
        """The signed-in account nginx vouches for, if it owns this agent."""
        if self.path.split("?", 1)[0] != PATH:
            self._message(404, "Not found.")
            return None
        account = self.headers.get("X-Hermes-Account", "")
        if account not in OWNERS:
            self._message(403, "This vault belongs to an agent your account does not own.")
            return None
        return account

    def do_GET(self):
        account = self._account()
        if account is None:
            return
        try:
            stores = broker("owner_list", account=account)
        except BrokerError as exc:
            self._message(503, f"The vault is not available: {exc}")
            return
        self._send(200, list_page(account, stores if isinstance(stores, list) else []))

    def do_POST(self):
        account = self._account()
        if account is None:
            return
        site = self.headers.get("Sec-Fetch-Site")
        origin = self.headers.get("Origin")
        if not (site == "same-origin" if site else origin == PUBLIC_URL):
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
        try:
            form = dict(urllib.parse.parse_qsl(self.rfile.read(length).decode("utf-8"), max_num_fields=10))
        except (UnicodeDecodeError, ValueError):
            form = {}
        if not token_ok(account, form.get("token", "")):
            self._message(403, "This page is stale: go back to the vault and try again.")
            return
        store, item_id, action = form.get("store", ""), form.get("item_id", ""), form.get("action", "")
        if not STORE_RE.match(store) or not ID_RE.match(item_id) or action not in ("reveal", "delete"):
            self._message(400, "Bad request.")
            return
        try:
            if action == "reveal":
                item = broker("owner_reveal", account=account, store=store, item_id=item_id)
                if not isinstance(item, dict):
                    raise BrokerError("the vault broker sent no item")
                body, nonce = reveal_page(item)
                item.clear()
                self._send(200, body, nonce)
            elif form.get("confirm") != "yes":
                listed = broker("owner_list", account=account)
                if not isinstance(listed, list):
                    raise BrokerError("the vault broker sent no list")
                item = next((i for s in listed if s.get("store") == store for i in s.get("items") or []
                             if i.get("id") == item_id), None)
                if item is None:
                    self._message(404, "No such item (deleted already?).")
                    return
                self._send(200, confirm_page(account, store, item))
            else:
                removed = broker("owner_remove", account=account, store=store, item_id=item_id)
                self._send(200, _page("Deleted", f"<p>{'Deleted.' if removed else 'Already gone.'}</p>"
                                                 f'<p><a href="{PATH}">Back to the vault</a></p>'))
        except BrokerError as exc:
            self._message(400 if "no vault item" in str(exc) or "only a login" in str(exc) else 503, str(exc))


class Server(HTTPServer):
    """One request at a time (nginx is the only client). Exits after IDLE_EXIT idle seconds."""

    address_family = socket.AF_UNIX
    idle = False

    def server_bind(self):
        pass

    def handle_timeout(self):
        self.idle = True


def main() -> None:
    global FORM_KEY
    if os.environ.get("LISTEN_FDS") != "1" or os.environ.get("LISTEN_PID") != str(os.getpid()):
        sys.exit("hermes-vault-owner: run me from the socket unit")
    FORM_KEY = _form_key()
    server = Server("", Handler, bind_and_activate=False)
    server.socket.close()
    server.socket = socket.socket(fileno=3)
    server.timeout = IDLE_EXIT
    with contextlib.suppress(KeyboardInterrupt):
        while not server.idle:
            server.handle_request()


if __name__ == "__main__":
    main()
