"""Drive a dashboard's chat socket (/api/ws) as the web chat does, for ../agent-notify.

  client.py <base-url> <text> [profile]         -> creates a desktop session (in profile), submits
                                                  <text>, returns at message.start, prints the stored id
"""

import asyncio
import json
import re
import sys
import urllib.request

import websockets

BASE = sys.argv[1].rstrip("/")


def token() -> str:
    html = urllib.request.urlopen(BASE + "/", timeout=30).read().decode()
    return re.search(r'__HERMES_SESSION_TOKEN__\s*=\s*"([^"]+)"', html).group(1)


async def main():
    url = BASE.replace("http", "ws", 1) + "/api/ws?token=" + token()
    async with websockets.connect(url, max_size=None) as ws:
        n = 0

        async def call(method, params):
            nonlocal n
            n += 1
            rid = f"t{n}"
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
            while True:
                frame = json.loads(await asyncio.wait_for(ws.recv(), 120))
                if frame.get("id") == rid:
                    if "error" in frame:
                        raise SystemExit(f"{method}: {frame['error']}")
                    return frame["result"]

        text, profile = sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else None)
        created = await call("session.create", {"source": "desktop", **({"profile": profile} if profile else {})})
        await call("prompt.submit", {"session_id": created["session_id"], "text": text})
        while True:
            frame = json.loads(await asyncio.wait_for(ws.recv(), 120))
            if frame.get("method") == "event" and frame["params"].get("type") == "message.start":
                break
        print(created["stored_session_id"])


asyncio.run(main())
