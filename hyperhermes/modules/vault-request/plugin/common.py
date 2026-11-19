"""Requests for a vault item, shared by the agent's tool (./__init__.py) and the page (./service.py).

One JSON file per request in the agent's request directory (HERMES_VAULT_REQUEST_DIR, 0700 the
agent, files 0600): a 128-bit id (the link), a separate form token (the page's CSRF token), what
the item is for (kind, label, origin, the agent's one-line reason), the profile home whose vault
gets the item, the expiry, the state and, once saved, the item's handle. Never a secret value: the
page writes those straight into hermes' encrypted vault and the request keeps the handle only.

States: pending -> saving -> done | error, pending -> cancelled; pending past its expiry reads as
expired. Every transition happens under an exclusive flock on the request's own lock file, so a
cancel and a submission, or two submissions, never both win. Readers need no lock: a request file
is replaced atomically.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import secrets
import time
import unicodedata
from pathlib import Path

KINDS = ("payment", "login", "address")
TTL = 30 * 60
MAX_PENDING = 10
MAX_ATTEMPTS = 5
MAX_LABEL = 80
MAX_REASON = 300
ID_RE = re.compile(r"^[0-9a-f]{32}$")


class RequestError(Exception):
    """A request that cannot be made or found."""


def request_dir() -> Path:
    value = os.environ.get("HERMES_VAULT_REQUEST_DIR", "").strip()
    if not value:
        raise RequestError("vault requests are not set up on this host (HERMES_VAULT_REQUEST_DIR)")
    return Path(value)


def public_url() -> str:
    value = os.environ.get("HERMES_VAULT_REQUEST_URL", "").strip().rstrip("/")
    if not value:
        raise RequestError("vault requests are not set up on this host (HERMES_VAULT_REQUEST_URL)")
    return value


def _path(rid: str) -> Path:
    if not ID_RE.match(rid or ""):
        raise RequestError("invalid request id")
    return request_dir() / f"{rid}.json"


@contextlib.contextmanager
def locked(rid: str):
    fd = os.open(_path(rid).with_suffix(".lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def load(rid: str) -> dict | None:
    try:
        fd = os.open(_path(rid), os.O_RDONLY | os.O_NOFOLLOW)
    except (OSError, RequestError):
        return None
    try:
        with os.fdopen(fd, encoding="utf-8") as f:
            req = json.load(f)
    except (OSError, ValueError):
        return None
    return req if isinstance(req, dict) and req.get("id") == rid else None


def save(req: dict) -> None:
    path = _path(req["id"])
    tmp = path.with_suffix(".tmp")
    with contextlib.suppress(FileNotFoundError):
        tmp.unlink()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(req, f)
    os.replace(tmp, path)


def state_of(req: dict) -> str:
    if req.get("state") == "pending" and time.time() > float(req.get("expires", 0)):
        return "expired"
    # the page died while saving (it sets error itself otherwise)
    if req.get("state") == "saving" and time.time() > float(req.get("expires", 0)) + 600:
        return "error"
    return str(req.get("state", "error"))


def prune() -> None:
    """Drop requests a day past their expiry, with their lock files."""
    for p in request_dir().glob("*.json"):
        try:
            req = json.loads(p.read_text(encoding="utf-8"))
            if time.time() > float(req["expires"]) + 86400:
                p.unlink()
                p.with_suffix(".lock").unlink(missing_ok=True)
        except (OSError, ValueError, KeyError, TypeError):
            pass


def one_line(value: str, limit: int, what: str) -> str:
    # no control or format characters (bidi overrides would make the page show other text)
    text = "".join(c for c in str(value or "") if unicodedata.category(c) not in ("Cc", "Cf") or c.isspace())
    text = " ".join(text.split())
    if len(text) > limit:
        raise RequestError(f"{what} is longer than {limit} characters")
    return text


def create(kind: str, label: str, origin: str, reason: str, hermes_home: str) -> dict:
    """A new pending request (no secrets in it). Raises RequestError."""
    from agent.vault_store import VaultError, normalize_origin

    if kind not in KINDS:
        raise RequestError(f"kind must be one of {', '.join(KINDS)}")
    label = one_line(label, MAX_LABEL, "label")
    if not label:
        raise RequestError("label is required (e.g. 'Visa for shop.example.com')")
    try:
        origin = normalize_origin(origin)
    except VaultError as exc:
        raise RequestError(f"origin: {exc} (the site the item is filled on, e.g. https://shop.example.com)") from None
    scheme, _, hostport = origin.partition("://")
    if scheme not in ("https", "http"):
        raise RequestError("origin must be an http(s) origin")
    # the host as the browser resolves it, ASCII (xn-- for an IDN): the page shows the user
    # exactly where the item will be filled, no look-alike letters
    host, colon, port = hostport.rpartition(":") if re.search(r":\d+$", hostport) else (hostport, "", "")
    # (Python's codec is IDNA 2003, browsers map these four differently: refused, not guessed)
    if any(c in host for c in "\u00df\u03c2\u200c\u200d"):
        raise RequestError("origin: give the host in its xn-- form")
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        raise RequestError("origin: not a valid host name") from None
    if not re.fullmatch(r"[a-z0-9.-]+", host):
        raise RequestError("origin: a host name or IPv4 address")
    origin = f"{scheme}://{host}{colon}{port}"
    reason = one_line(reason, MAX_REASON, "reason")
    d = request_dir()
    d.mkdir(mode=0o700, exist_ok=True)
    prune()
    pending = 0
    for p in d.glob("*.json"):
        try:
            if state_of(json.loads(p.read_text(encoding="utf-8"))) == "pending":
                pending += 1
        except (OSError, ValueError, TypeError):
            pass
    if pending >= MAX_PENDING:
        raise RequestError(f"{pending} vault requests are pending already; cancel some or wait for them")
    now = time.time()
    req = {
        "id": secrets.token_hex(16),
        "token": secrets.token_urlsafe(32),
        "kind": kind,
        "label": label,
        "origin": origin,
        "reason": reason,
        "hermes_home": str(hermes_home),
        "created": now,
        "expires": now + TTL,
        "state": "pending",
        "item_id": "",
        "error": "",
        "attempts": 0,
    }
    save(req)
    return req


def link(req: dict) -> str:
    return f"{public_url()}/vault/{req['id']}"


def public_view(req: dict) -> dict:
    """What the agent may see of a request: never the form token."""
    state = state_of(req)
    out = {"request_id": req["id"], "state": state, "kind": req["kind"], "label": req["label"],
           "origin": req["origin"]}
    if state == "pending":
        out["expires_in_seconds"] = max(0, int(float(req["expires"]) - time.time()))
    if state == "done":
        out["handle"] = req.get("item_id", "")
    if state == "error" and req.get("error"):
        out["error"] = req["error"]
    return out
