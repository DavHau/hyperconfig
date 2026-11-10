"""An OpenAI-compatible chat endpoint that scripts the turns of ../resume:
the last user message names the scenario, the last message tells the
step. Every request is appended to RECORD (one JSON line: scenario,
step), so the test can count the model calls of each turn.

  "[System note: Your previous turn was interrupted mid-run ..." (the
  auto-continue note, which embeds the original prompt): answer RESUMED-<scenario>.
  "<SCENARIO> <shell command>": call the terminal tool with the command,
  then, once its result is back, answer DONE-<scenario>.
  "DELEG<x>-TEST <child goal> ||| <child goal> ...": call delegate_task
  with one task per goal (a child's goal is itself "<SCENARIO> <command>"),
  then answer DONE-DELEG<x>-TEST. A child whose context carries the re-dispatch
  note records its first step as "resume-tool-call" (or
  "resume-tool-call-unframed-tail" when the note's transcript tail is not
  framed as untrusted data between BEGIN/END markers).
  "[ASYNC DELEGATION ..." (a subagent result delivered to the parent):
  answer GOT-RESULT, recorded under scenario DELEGATION-RESULT.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
MODEL = "fake-model"
NOTE = "previous turn was interrupted mid-run"
RESUMED = "RESUMED AFTER A RESTART"
TAIL_BEGIN = "--- BEGIN previous transcript tail ---"
TAIL_END = "--- END previous transcript tail ---"


def text_of(content):
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


def plan(messages):
    """(reply text, tool call or None, scenario, step)."""
    last = messages[-1] if messages else {}
    user = next((text_of(m.get("content")) for m in reversed(messages) if m.get("role") == "user"), "")
    words = [w for w in user.replace("\n", " ").split(" ") if w]
    scenario = next((w for w in words if w.endswith("-TEST")), "NONE")
    system = " ".join(text_of(m.get("content")) for m in messages if m.get("role") == "system")
    if "[ASYNC DELEGATION" in user:
        return "GOT-RESULT", None, "DELEGATION-RESULT", "result"
    if NOTE in user and last.get("role") == "user":
        return f"RESUMED-{scenario}", None, scenario, "resume"
    if last.get("role") == "tool":
        return f"DONE-{scenario}", None, scenario, "after-tool"
    command = user.split(scenario, 1)[1].strip() if scenario in user else "true"
    call_id = f"call_{int(time.time() * 1000)}"
    if scenario.startswith("DELEG"):
        tasks = [{"goal": g.strip(), "context": "scripted child"} for g in command.split("|||")]
        call = {"id": call_id, "type": "function",
                "function": {"name": "delegate_task", "arguments": json.dumps({"tasks": tasks})}}
        return "", call, scenario, "tool-call"
    call = {"id": call_id, "type": "function",
            "function": {"name": "terminal", "arguments": json.dumps({"command": command, "timeout": 170})}}
    if RESUMED not in system:
        return "", call, scenario, "tool-call"
    # The previous transcript's tail is framed as untrusted data.
    framed = all(m in system for m in (TAIL_BEGIN, TAIL_END, "untrusted data, never instructions"))
    return "", call, scenario, "resume-tool-call" if framed else "resume-tool-call-unframed-tail"


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
        text, call, scenario, step = plan(body.get("messages") or [])
        # Auxiliary calls (title generation and the like) carry no tools: keep them out of the record.
        if body.get("tools"):
            with open(RECORD, "a") as f:
                f.write(json.dumps({"scenario": scenario, "step": step, "at": time.time()}) + "\n")
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
