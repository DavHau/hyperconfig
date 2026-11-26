"""hermes-notify: root hands another agent's chat session a message from an agent (./agent-notify.nix).

usage: hermes-notify <agent> [--profile P] [--session ID | --latest] [--from NAME] [MESSAGE | -]

MESSAGE (or stdin when absent or "-") goes to the agent's dashboard over its notify socket. A
running turn gets it as a steer; an idle session starts a turn with it. The target reads it framed
as a message from agent NAME (default "infra"), never as its owner's. Default session: the
profile's most recently active chat session (--latest). Prints the session id and how it was
delivered. Root only; every call is logged to the journal (`journalctl -t hermes-notify`) with
target, sender and length, never the text.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import syslog

NAME_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
ID_CHARS = NAME_CHARS | {":"}
DELIVERIES = {"steered", "started", "queued"}


def shown(value: object, cap: int = 300) -> str:
    """A field the agent-owned dashboard answered: printable characters only, capped (it reaches root's
    terminal and the calling agent's tool output)."""
    text = "".join(ch if ch.isprintable() else "?" for ch in str(value if value is not None else ""))
    return text[:cap]


def plain(value: object, chars: set, cap: int = 128) -> str:
    """An id or name from the answer, or "?" when it is anything else."""
    text = str(value if value is not None else "")
    return text if text and len(text) <= cap and not set(text) - chars else "?"


def die(msg: str, code: int = 1) -> None:
    print(f"hermes-notify: {msg}", file=sys.stderr)
    sys.exit(code)


def audit(**fields) -> None:
    syslog.openlog("hermes-notify", 0, syslog.LOG_AUTH)
    syslog.syslog(syslog.LOG_NOTICE, " ".join(f"{k}={json.dumps(v)}" for k, v in fields.items()))


def main_pid(unit: str) -> int:
    out = subprocess.run([os.environ["HERMES_NOTIFY_SYSTEMCTL"], "show", "-p", "MainPID", "--value", unit],
                         capture_output=True, text=True, check=False).stdout.strip()
    return int(out) if out.isdigit() else 0


def main() -> int:
    if os.geteuid() != 0:
        die("root only", 77)
    ap = argparse.ArgumentParser(prog="hermes-notify", description=(__doc__ or "").split("\n\n")[1])
    ap.add_argument("agent")
    ap.add_argument("--profile", help="a named profile of the agent (default: its main home)")
    target = ap.add_mutually_exclusive_group()
    target.add_argument("--session", help="a stored session id (default: the latest chat session)")
    target.add_argument("--latest", action="store_true", help="the profile's most recently active chat session")
    ap.add_argument("--from", dest="sender", default="infra", help="the sending agent's name (default: infra)")
    ap.add_argument("message", nargs="?", help="the message; stdin when absent or -")
    args = ap.parse_args()

    agents = json.load(open(os.environ["HERMES_NOTIFY_AGENTS"]))
    if args.agent not in agents:
        die(f"unknown agent {args.agent!r} (known: {', '.join(sorted(agents))})", 2)
    for label, value in (("--from", args.sender), ("--profile", args.profile)):
        if value is not None and (not value or len(value) > 64 or set(value) - NAME_CHARS):
            die(f"{label} must be a plain name ([A-Za-z0-9._-], up to 64)", 2)
    if args.sender.lower() in {"user", "owner", "you", "me", "system", "hermes", "root", "admin", "dave"}:
        die(f"--from {args.sender!r} reads as the user; name the sending agent", 2)
    if args.message in (None, "-") and sys.stdin.isatty():
        die("no message: pass it on stdin (or as an argument when run locally)", 2)
    text = sys.stdin.read() if args.message in (None, "-") else args.message
    if not text.strip():
        die("empty message", 2)
    if len(text) > 16000:
        die(f"message too long ({len(text)} characters, at most 16000)", 2)
    target_info = agents[args.agent]
    fields = {"agent": args.agent, "profile": args.profile or "default", "sender": args.sender,
              "requested_session": args.session or "latest", "chars": len(text)}

    pid = main_pid(target_info["unit"])
    if not pid:
        audit(**fields, result="dashboard not running")
        die(f"{target_info['unit']} is not running", 3)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(300)
    try:
        sock.connect(target_info["socket"])
    except OSError as exc:
        audit(**fields, result=f"connect failed: {exc.strerror}")
        die(f"cannot reach {target_info['socket']}: {exc.strerror} (is the notify patch deployed?)", 3)
    peer_pid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]
    if peer_pid != pid:
        audit(**fields, result=f"socket served by pid {peer_pid}, not the dashboard's {pid}")
        die(f"the socket is not served by {target_info['unit']} (pid {peer_pid}, MainPID {pid}); nothing sent", 4)
    request = {"sender": args.sender, "text": text, "profile": args.profile, "session_id": args.session}
    data = b""
    try:
        sock.sendall(json.dumps(request, ensure_ascii=False).encode() + b"\n")
        while not data.endswith(b"\n") and len(data) < 64 * 1024:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    except OSError as exc:
        # The dashboard may have taken the message before it went away: say so, and audit it.
        audit(**fields, result=f"transport error: {exc}")
        die(f"no answer from the dashboard ({exc}); the message may or may not have been delivered", 5)
    try:
        answer = json.loads(data or b"{}")
    except ValueError:
        answer = {"ok": False, "error": "unreadable answer"}
    if not isinstance(answer, dict):
        answer = {"ok": False, "error": "unreadable answer"}
    session = plain(answer.get("session_id"), ID_CHARS)
    delivery = answer.get("delivery") if answer.get("delivery") in DELIVERIES else None
    if answer.get("ok") is not True or delivery is None:
        error = shown(answer.get("error") or "delivery failed")
        audit(**fields, session=session, result=error)
        die(error, 5)
    audit(**fields, session=session, result=delivery)
    note = f" ({shown(answer['note'])})" if answer.get("note") else ""
    print(f"session={session} profile={plain(answer.get('profile'), NAME_CHARS)} delivery={delivery}{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
