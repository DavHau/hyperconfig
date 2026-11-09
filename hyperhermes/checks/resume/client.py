"""Drive a hermes dashboard's JSON-RPC socket (/api/ws) as the web chat does.

  client.py <base-url> start <SCENARIO> <command>  -> prints the stored session id
  client.py <base-url> stop <stored session id>    -> resume + session.interrupt (a user Stop)

`start` creates a session, submits "<SCENARIO> <command>" and returns once
the turn has started (message.start); the client then disconnects, as a
closed browser tab does. Auth is the loopback session token from GET /.
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


class Rpc:
    def __init__(self, ws):
        self.ws, self.n, self.events = ws, 0, []

    async def call(self, method, params, timeout=120):
        self.n += 1
        rid = f"t{self.n}"
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        while True:
            frame = json.loads(await asyncio.wait_for(self.ws.recv(), timeout))
            if frame.get("id") == rid:
                if "error" in frame:
                    raise SystemExit(f"{method}: {frame['error']}")
                return frame["result"]
            if frame.get("method") == "event":
                self.events.append(frame["params"])

    async def wait_event(self, kind, timeout=120):
        for ev in self.events:
            if ev.get("type") == kind:
                return ev
        while True:
            frame = json.loads(await asyncio.wait_for(self.ws.recv(), timeout))
            if frame.get("method") == "event":
                self.events.append(frame["params"])
                if frame["params"].get("type") == kind:
                    return frame["params"]


async def main():
    url = BASE.replace("http", "ws", 1) + "/api/ws?token=" + token()
    async with websockets.connect(url, max_size=None) as ws:
        rpc = Rpc(ws)
        cmd = sys.argv[2]
        if cmd == "start":
            scenario, command = sys.argv[3], sys.argv[4]
            created = await rpc.call("session.create", {"source": "desktop"})
            sid = created["session_id"]
            await rpc.call("prompt.submit", {"session_id": sid, "text": f"{scenario} {command}"})
            await rpc.wait_event("message.start")
            print(created["stored_session_id"])
        elif cmd == "stop":
            resumed = await rpc.call("session.resume", {"session_id": sys.argv[3]})
            await rpc.call("session.interrupt", {"session_id": resumed["session_id"]})
            await rpc.wait_event("message.complete", timeout=60)
            print(json.dumps({"stopped": sys.argv[3]}))


asyncio.run(main())
