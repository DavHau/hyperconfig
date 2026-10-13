"""Print the SimpleX contact address of the daemon, creating it if absent.

Idempotent: `/show_address` reads an existing address, `/address` creates
one.
"""

import asyncio
import json
import os
import sys
from typing import Any

import websockets

WS_URL = os.environ.get("SIMPLEX_WS_URL", "ws://127.0.0.1:5225")
CORR_ID = "hermes-address"
# The daemon answers only after it has connected to its SMP relay.
TIMEOUT = 120
# The HTTP handshake is local; only the daemon's first answer waits on the
# relay. A listener that accepts and stalls must fail an attempt in
# seconds, not hold it for TIMEOUT: 30 x (120 + 2) s hid a dead daemon
# for an hour before the unit's Restart=on-failure could retry.
CONNECT_TIMEOUT = 10
CONNECT_ATTEMPTS = 30
CONNECT_DELAY = 2


async def _command(ws: Any, cmd: str) -> dict[str, Any]:
    await ws.send(json.dumps({"corrId": CORR_ID, "cmd": cmd}))
    while True:
        event = json.loads(await asyncio.wait_for(ws.recv(), TIMEOUT))
        if event.get("corrId") == CORR_ID:
            return event.get("resp") or {}


def _link(resp: dict[str, Any]) -> str | None:
    # /address and /show_address nest the link differently.
    nested = resp.get("contactLink") or {}
    contact = resp.get("connLinkContact") or nested.get("connLinkContact")
    if not contact:
        return None
    # Older daemons and relays return only the full link.
    return contact.get("connShortLink") or contact.get("connFullLink")


async def _connect() -> Any:
    # The listening socket can lag the daemon start. A socket forward
    # (hermes-simplex-fwd on a native host) accepts even earlier and then
    # closes the stream before any HTTP status line: that surfaces as
    # EOFError / InvalidMessage, not OSError, and killed the unit on its
    # first attempt at every boot of the live medium (seen 2026-09).
    last: Exception | None = None
    for _ in range(CONNECT_ATTEMPTS):
        try:
            return await websockets.connect(WS_URL, open_timeout=CONNECT_TIMEOUT)
        except (
            TimeoutError,
            OSError,
            EOFError,
            websockets.exceptions.InvalidMessage,
        ) as err:
            last = err
            await asyncio.sleep(CONNECT_DELAY)
    msg = f"simplex-address: cannot reach {WS_URL}: {last}"
    raise SystemExit(msg)


async def main() -> None:
    ws = await _connect()
    async with ws:
        resp = await _command(ws, "/show_address")
        link = _link(resp)
        if link is None:
            resp = await _command(ws, "/address")
            link = _link(resp)
        if link is None:
            print(json.dumps(resp), file=sys.stderr)
            sys.exit("simplex-address: the daemon returned no address")
        print(link)


asyncio.run(main())
