"""mailgate's worker: the only process that parses a hostile message.

mailgate runs one of these per job with a hard timeout and kills it when
the time is up, so no message can stall the daemon's event loop (the RCPT
hook, LMTP, the sockets, the owner page). Protocol: one JSON request line
on stdin, then the raw message until EOF; one JSON answer on stdout.

  {"op": "analyze", "authserv_id": ..., "psl": path} -> sanitize.analyze()
  {"op": "attachment", "index": n}                   -> {name, type, data(b64)}
  {"op": "read"}                                     -> sanitize.reading()
"""

from __future__ import annotations

import base64
import json
import resource
import sys

import sanitize


def main() -> None:
    # An address-space cap on top of the service's MemoryMax: one runaway
    # parse fails here, not the whole daemon.
    limit = int(sys.argv[1])
    resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    req = json.loads(sys.stdin.buffer.readline())
    raw = sys.stdin.buffer.read()
    msg = sanitize.parse(raw)
    if req["op"] == "analyze":
        out = sanitize.analyze(msg, raw, req["authserv_id"], sanitize.Psl(req.get("psl")))
    elif req["op"] == "attachment":
        got = sanitize.attachment_bytes(msg, int(req["index"]))
        out = None
        if got is not None:
            name, ctype, data = got
            out = {"name": name, "type": ctype, "size": len(data), "data": base64.b64encode(data).decode()}
    elif req["op"] == "read":
        out = sanitize.reading(msg)
    else:
        raise SystemExit(f"unknown op {req['op']!r}")
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
