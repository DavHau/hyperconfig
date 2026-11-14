"""fleet-telegram-send: stdin -> one Telegram message (plain text) to the
alert chat, with the alert bot (./default.nix says who runs it and how).

Credentials from $CREDENTIALS_DIRECTORY (telegram-bot-token,
telegram-chat-id), state in $STATE_DIRECTORY. Neither token nor URL is
ever printed (the URL holds the token).

Bounds: at most DAILY_MAX messages a day (Asia/Bangkok date; a request
that went out counts, sent or not), each cut to MAX_UNITS UTF-16 code
units (Telegram's 4096 limit is counted in those, not code points).

Exit codes, as fleet-alert-digest's: 0 sent; EXIT_NOT_SENT (1) surely
not sent (DNS/connect/TLS error before the request, or a 4xx refusal):
a retry is safe; EXIT_MAYBE_SENT (3) the request went out without a
good answer (timeout, 5xx): a retry could send it twice;
EXIT_RATE_LIMITED (4) today's cap is used up. --mark-brief writes
$STATE_DIRECTORY/brief-sent (today's date) once Telegram accepted: edi's
own warning digest skips a day that has it (the brief carried them).
After a 200 every error (the stamp, stdout) exits 3, never 1.
"""

import argparse
import fcntl
import http.client
import json
import os
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone
from typing import NoReturn

API_HOST = "api.telegram.org"
MAX_UNITS = 4096
DAILY_MAX = 20
MAX_INPUT = 64 * 1024
BKK = timezone(timedelta(hours=7))
EXIT_NOT_SENT = 1
EXIT_MAYBE_SENT = 3
EXIT_RATE_LIMITED = 4


def connect():
    return http.client.HTTPSConnection(API_HOST, timeout=30)


def die(code, msg) -> NoReturn:
    print(f"fleet-telegram-send: {msg}", file=sys.stderr)
    sys.exit(code)


def credential(name):
    d = os.environ.get("CREDENTIALS_DIRECTORY")
    if not d:
        die(EXIT_NOT_SENT, f"no credential {name} (run under systemd with LoadCredential)")
    with open(os.path.join(d, name)) as f:
        return f.read().strip()


def utf16_units(text):
    return len(text.encode("utf-16-le")) // 2


def cap(text, limit=MAX_UNITS):
    """At most `limit` UTF-16 units, cut at a code point, with an ellipsis."""
    if utf16_units(text) <= limit:
        return text
    out, units = [], 0
    for c in text:
        u = 2 if ord(c) > 0xFFFF else 1
        if units + u > limit - 1:
            break
        out.append(c)
        units += u
    return "".join(out) + "…"


def today(at=None):
    return (at or datetime.now(timezone.utc)).astimezone(BKK).strftime("%Y-%m-%d")


def write_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(data)
    os.replace(tmp, path)


def count_today(state, day):
    try:
        with open(os.path.join(state, "count.json")) as f:
            c = json.load(f)
        return int(c["n"]) if c.get("date") == day else 0
    except (OSError, ValueError, KeyError, TypeError):
        return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="fleet-telegram-send", description="stdin -> one Telegram message to the alert chat")
    p.add_argument("--mark-brief", action="store_true", help="once sent, stamp today as 'morning brief sent'")
    args = p.parse_args(argv)
    state = os.environ.get("STATE_DIRECTORY")
    if not state:
        die(EXIT_NOT_SENT, "no state directory (run under systemd with StateDirectory)")

    text = sys.stdin.buffer.read(MAX_INPUT).decode("utf-8", "replace").strip()
    if not text:
        die(EXIT_NOT_SENT, "empty message, nothing sent")
    text = cap(text)

    with open(os.path.join(state, ".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        day = today()
        n = count_today(state, day)
        if n >= DAILY_MAX:
            die(EXIT_RATE_LIMITED, f"{n} messages today already (cap {DAILY_MAX}), nothing sent")
        body = urllib.parse.urlencode({
            "chat_id": credential("telegram-chat-id"),
            "text": text,
            "disable_web_page_preview": "true",
        }).encode()
        token = credential("telegram-bot-token")
        conn = connect()
        try:
            conn.connect()
            conn.request("POST", f"/bot{token}/sendMessage", body=body,
                         headers={"Content-Type": "application/x-www-form-urlencoded"})
        except (OSError, http.client.HTTPException) as e:
            conn.close()
            die(EXIT_NOT_SENT, f"Telegram unreachable, not sent: {type(e).__name__} {getattr(e, 'errno', '') or ''}".rstrip())
        # The request is out: it counts, and from here on no retry (no
        # error below may exit 1).
        try:
            write_atomic(os.path.join(state, "count.json"), json.dumps({"date": day, "n": n + 1}) + "\n")
        except Exception as e:
            print(f"fleet-telegram-send: counting the message failed ({type(e).__name__})", file=sys.stderr)
        try:
            r = conn.getresponse()
            status = r.status
            detail = r.read(2000).decode(errors="replace")[:300]
        except Exception as e:
            die(EXIT_MAYBE_SENT, f"sent, but no answer from Telegram ({type(e).__name__}); it may have arrived")
        finally:
            conn.close()
        if status == 200:
            # Delivered: whatever fails now must not look retryable.
            try:
                if args.mark_brief:
                    write_atomic(os.path.join(state, "brief-sent"), day + "\n")
                print("fleet-telegram-send: sent")
            except Exception as e:
                die(EXIT_MAYBE_SENT, f"sent, but recording it failed ({type(e).__name__}); not retrying")
            return 0
        if 400 <= status < 500 and status != 408:
            die(EXIT_NOT_SENT, f"Telegram refused: HTTP {status} {detail}")
        die(EXIT_MAYBE_SENT, f"sent, but Telegram answered HTTP {status} {detail}; it may have arrived")


if __name__ == "__main__":
    sys.exit(main())
