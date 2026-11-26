"""An OpenAI-compatible chat endpoint scripting the turns of ../agent-notify.

  "<SCENARIO>-TEST <shell command>": call the terminal tool with the command, then answer
  DONE-<SCENARIO>-TEST once its result is back (step "tool-call", then "after-tool").
  A request whose last user message is a message from another agent ("[MESSAGE FROM ANOTHER AGENT"):
  answer ACK-NOTICE, step "notice" (an idle turn started by it) or, when it follows a tool result
  (a steer into a running turn), answer DONE-<scenario> with step "steered".

Every tool-bearing request is appended to RECORD as one JSON line: scenario, step, the user rows'
texts (roles user only) and whether the system prompt carries the note on messages from agents.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
MODEL = "fake-model"
NOTICE = "[MESSAGE FROM ANOTHER AGENT"


def text_of(content):
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


def plan(messages):
    last = messages[-1] if messages else {}
    users = [text_of(m.get("content")) for m in messages if m.get("role") == "user"]
    first_task = next((u for u in users if "-TEST" in u and NOTICE not in u), "")
    words = [w for w in first_task.replace("\n", " ").split(" ") if w]
    scenario = next((w for w in reversed(words) if w.endswith("-TEST")), "NONE")
    if last.get("role") == "user" and NOTICE in text_of(last.get("content")):
        before = messages[-2] if len(messages) > 1 else {}
        if before.get("role") == "tool":
            return f"DONE-{scenario}", None, scenario, "steered"
        return "ACK-NOTICE", None, scenario, "notice"
    if last.get("role") == "tool":
        return f"DONE-{scenario}", None, scenario, "after-tool"
    user = users[-1] if users else ""
    command = user.split(scenario, 1)[1].strip() if scenario in user else "true"
    call = {"id": f"call_{int(time.time() * 1000)}", "type": "function",
            "function": {"name": "terminal", "arguments": json.dumps({"command": command, "timeout": 170})}}
    return "", call, scenario, "tool-call"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": MODEL, "object": "model"}]})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if not self.path.endswith("/chat/completions"):
            return self._json(404, {"error": {"message": "not found"}})
        messages = body.get("messages") or []
        text, call, scenario, step = plan(messages)
        if body.get("tools"):
            system = " ".join(text_of(m.get("content")) for m in messages if m.get("role") == "system")
            with open(RECORD, "a") as f:
                f.write(json.dumps({
                    "scenario": scenario, "step": step, "at": time.time(),
                    "users": [text_of(m.get("content")) for m in messages if m.get("role") == "user"],
                    "note": "## Messages from other agents" in system}) + "\n")
        elif call is not None:
            text, call = "title", None
        created = int(time.time())
        finish = "tool_calls" if call else "stop"
        usage = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        if not body.get("stream"):
            message = {"role": "assistant", "content": text or None}
            if call:
                message["tool_calls"] = [call]
            return self._json(200, {
                "id": "chatcmpl-1", "object": "chat.completion", "created": created, "model": MODEL,
                "choices": [{"index": 0, "finish_reason": finish, "message": message}], "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def chunk(delta, finish_reason=None, with_usage=False):
            obj = {"id": "chatcmpl-1", "object": "chat.completion.chunk", "created": created, "model": MODEL,
                   "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}]}
            if with_usage:
                obj["usage"] = usage
            self.wfile.write(f"data: {json.dumps(obj)}\n\n".encode())

        if call:
            chunk({"role": "assistant", "tool_calls": [{"index": 0, **call}]})
        else:
            chunk({"role": "assistant", "content": text})
        chunk({}, finish, with_usage=True)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
