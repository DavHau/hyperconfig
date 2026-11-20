"""vault_request: ask the user to add a missing vault item (a card, a login, an address) on a page.

The agent gets a one-time link to a page behind its own dashboard's sign-in
(https://<dashboard>/vault/<id>, hyperhermes' vault-request module). The user types the item
there; the page writes it straight into this agent's encrypted vault (agent/vault_store.py). The
agent never sees a value: it learns the state of the request and, once saved, the item's handle,
which browser_vault fills with. Works from any chat (Telegram, WhatsApp, the dashboard): the link
is plain text.
"""
from __future__ import annotations

import json
import time

from . import common

TOOLSET = "vault-request"
MAX_WAIT = 600

SCHEMA = {
    "name": "vault_request",
    "description": (
        "Ask the user to add a missing card, login or address to your vault on a secure web page, "
        "never in chat. Use it when a task needs an item browser_vault list does not have (e.g. a "
        "checkout needs a card and the vault has none). Actions: create (kind, label, origin for a login, reason) "
        "returns a one-time link valid 30 minutes: send it to the user with one sentence of what it is "
        "for and wait; wait (request_id) blocks until the user saved it (up to timeout_seconds) and "
        "returns the item's handle for browser_vault fill; status (request_id); cancel (request_id). "
        "Never ask for or accept card numbers, CVCs or passwords in chat: if the user pastes one, tell "
        "them to use the link instead."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["create", "wait", "status", "cancel"]},
            "kind": {"type": "string", "enum": list(common.KINDS),
                     "description": "create: payment (a card), login (site account) or address."},
            "label": {"type": "string",
                      "description": "create: short name shown to the user and in the vault, e.g. 'Card for shop.example.com'."},
            "origin": {"type": "string",
                       "description": "create: a login's exact site, e.g. https://shop.example.com (the vault "
                                      "fills it there only). Omit for a card or address: they fill on any "
                                      "site, the user confirms each fill."},
            "reason": {"type": "string",
                       "description": "create: one line the page shows the user: why you need it."},
            "request_id": {"type": "string", "description": "wait / status / cancel: the id create returned."},
            "timeout_seconds": {"type": "integer",
                                "description": f"wait: how long to wait (default 300, at most {MAX_WAIT})."},
        },
        "required": ["action"],
    },
}


def _ok(**fields) -> str:
    return json.dumps({"success": True, **fields})


def _fail(msg: str) -> str:
    return json.dumps({"success": False, "error": msg})


def _create(args: dict) -> str:
    from hermes_constants import get_hermes_home

    req = common.create(str(args.get("kind") or ""), str(args.get("label") or ""),
                        str(args.get("origin") or ""), str(args.get("reason") or ""),
                        str(get_hermes_home()))
    return _ok(**common.public_view(req), link=common.link(req), next=(
        "Send the user this link with one sentence saying what it is for (the page shows the kind, "
        "label and site). They sign in with their usual dashboard login. Then call vault_request "
        "action=wait with this request_id; when it returns state done, use browser_vault fill with the "
        "handle. Do not repeat the link's contents or ask for the values in chat."))


def _wait(rid: str, timeout: int) -> str:
    from tools.interrupt import is_interrupted

    deadline = time.monotonic() + max(1, min(MAX_WAIT, timeout))
    while True:
        req = common.load(rid)
        if req is None:
            return _fail("no such request")
        view = common.public_view(req)
        if view["state"] not in ("pending", "saving"):
            break
        if time.monotonic() >= deadline or is_interrupted():
            view["hint"] = "Still waiting for the user. Call wait again, or ask them whether the link worked."
            break
        time.sleep(1)
    if view["state"] == "done":
        view["next"] = ("Use browser_vault fill with this handle: a login on its site; a card or address "
                        "on the checkout page, after the user confirms that fill.")
    elif view["state"] in ("expired", "error", "cancelled"):
        view["next"] = "Create a new request if the user still wants to add it."
    return _ok(**view)


def _cancel(rid: str) -> str:
    if common.load(rid) is None:
        return _fail("no such request")
    with common.locked(rid):
        req = common.load(rid)
        if req is None:
            return _fail("no such request")
        if common.state_of(req) == "pending":
            req["state"] = "cancelled"
            common.save(req)
    return _ok(**common.public_view(req))


def handle(args: dict, **_kwargs) -> str:
    action = str(args.get("action") or "")
    rid = str(args.get("request_id") or "").strip().lower()
    try:
        if action == "create":
            return _create(args)
        if action in ("wait", "status", "cancel") and not common.ID_RE.match(rid):
            return _fail("request_id: the 32-character id create returned")
        if action == "wait":
            return _wait(rid, int(args.get("timeout_seconds") or 300))
        if action == "status":
            req = common.load(rid)
            return _ok(**common.public_view(req)) if req else _fail("no such request")
        if action == "cancel":
            return _cancel(rid)
    except common.RequestError as exc:
        return _fail(str(exc))
    except (TypeError, ValueError) as exc:
        return _fail(f"invalid argument: {exc}")
    return _fail("action must be create, wait, status or cancel")


def _available() -> bool:
    try:
        common.request_dir()
        common.public_url()
    except common.RequestError:
        return False
    return True


def register(ctx) -> None:
    ctx.register_tool(name=SCHEMA["name"], toolset=TOOLSET, schema=SCHEMA, handler=handle,
                      check_fn=_available, emoji="🔑")
