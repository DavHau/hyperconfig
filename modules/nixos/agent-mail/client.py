"""mailgate / mailgate-admin: thin clients of the mailgate sockets.

The daemon decides everything from the peer uid; these only build the
request and print the JSON answer.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import sys

AGENT_SOCK = "/run/mailgate/agent.sock"
ADMIN_SOCK = "/run/mailgate/admin.sock"


def fail(message: str):
    print(json.dumps({"error": message}, ensure_ascii=False))
    sys.exit(1)


def call(path: str, req: dict):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
    except OSError as e:
        fail(f"cannot reach mailgate at {path}: {e}")
    with s, s.makefile("rwb") as f:
        f.write(json.dumps(req).encode() + b"\n")
        f.flush()
        resp = json.loads(f.readline() or b'{"ok": false, "error": "no answer"}')
    if not resp.get("ok"):
        fail(resp.get("error") or "failed")
    return resp["result"]


def show(result) -> None:
    print(json.dumps(result, indent=2, ensure_ascii=False))


def agent_main(argv: list[str]) -> None:
    p = argparse.ArgumentParser(
        prog="mailgate",
        description="Your mailbox's quarantine, allowlist and aliases. Read the INBOX with the spaces mail tools (profile 'mailgate').",
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="address, quarantine count, pending requests")
    qp = sub.add_parser("quarantine", help="restricted view of quarantined mail")
    qp.add_argument("action", nargs="?", choices=["list", "show", "summarize", "open-link"], default="list")
    qp.add_argument("id", nargs="?")
    qp.add_argument("n", nargs="?", type=int, help="open-link: the link's number (`n` in the view)")
    qp.add_argument("--limit", type=int, default=20)
    ap = sub.add_parser("allowlist", help="list entries, or request a new one")
    ap.add_argument("action", nargs="?", choices=["list", "request"], default="list")
    ap.add_argument("entry", nargs="?", help="user@example.com or @example.com")
    ap.add_argument("--reason", default="")
    al = sub.add_parser("alias", help="per-service addresses")
    al.add_argument("action", choices=["list", "create", "revoke"])
    al.add_argument("address", nargs="?")
    al.add_argument("--tag")
    al.add_argument("--random", action="store_true")
    al.add_argument("--domain", help="only mail DMARC-aligned to this domain reaches the INBOX")
    al.add_argument("--note", default="")
    at = sub.add_parser("attachments", help="list the attachments of an INBOX message")
    at.add_argument("id")
    af = sub.add_parser("attachment", help="save one attachment of an INBOX message")
    af.add_argument("id")
    af.add_argument("index", type=int)
    af.add_argument("--out", required=True, help="file to create (never overwritten)")
    a = p.parse_args(argv)

    if a.cmd == "status":
        show(call(AGENT_SOCK, {"op": "status"}))
    elif a.cmd == "quarantine":
        if a.action != "list" and not a.id:
            p.error("quarantine show/summarize/open-link needs an id")
        if a.action == "open-link" and not a.n:
            p.error("quarantine open-link needs the link number")
        show(call(AGENT_SOCK, {"op": f"quarantine.{a.action}", "id": a.id, "n": a.n, "limit": a.limit}))
    elif a.cmd == "allowlist":
        if a.action == "request":
            if not a.entry:
                p.error("allowlist request needs an address")
            show(call(AGENT_SOCK, {"op": "allowlist.request", "entry": a.entry, "reason": a.reason}))
        else:
            show(call(AGENT_SOCK, {"op": "allowlist.list"}))
    elif a.cmd == "alias":
        if a.action == "list":
            show(call(AGENT_SOCK, {"op": "alias.list"}))
        elif a.action == "create":
            show(call(AGENT_SOCK, {"op": "alias.create", "tag": a.tag, "random": a.random, "domain": a.domain, "note": a.note}))
        else:
            if not a.address:
                p.error("alias revoke needs the address")
            show(call(AGENT_SOCK, {"op": "alias.revoke", "address": a.address}))
    elif a.cmd == "attachments":
        show(call(AGENT_SOCK, {"op": "attachments", "id": a.id}))
    elif a.cmd == "attachment":
        r = call(AGENT_SOCK, {"op": "attachment", "id": a.id, "index": a.index})
        data = base64.b64decode(r.pop("data"))
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        show(r | {"saved": os.path.abspath(a.out)})


def admin_main(argv: list[str]) -> None:
    p = argparse.ArgumentParser(prog="mailgate-admin", description="Operator side of the agents' mail (root).")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("requests", help="pending allowlist requests of every agent")
    for name in ("confirm", "deny"):
        sub.add_parser(name).add_argument("id", type=int)
    sub.add_parser("list").add_argument("agent")
    for name in ("allow", "remove"):
        sp = sub.add_parser(name)
        sp.add_argument("agent")
        sp.add_argument("entry")
    ac = sub.add_parser("alias-create")
    ac.add_argument("agent")
    ac.add_argument("--tag")
    ac.add_argument("--random", action="store_true")
    ac.add_argument("--domain")
    ac.add_argument("--note", default="")
    sub.add_parser("alias-revoke").add_argument("address")
    a = vars(p.parse_args(argv))
    op = a.pop("cmd")
    show(call(ADMIN_SOCK, {"op": op, **a}))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--admin":
        admin_main(sys.argv[2:])
    else:
        agent_main(sys.argv[1:])
