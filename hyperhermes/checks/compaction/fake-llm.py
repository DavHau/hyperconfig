"""The fake model of ./default.nix: an Anthropic Messages endpoint
(POST .../v1/messages, as a TeamClaude gateway serves it) and an
OpenAI-compatible one (POST .../chat/completions). Both answer every request
with one fixed text (FAKE-SUMMARY ...), streamed (SSE) or not, and append the
request's path, model, whether it carried a credential and the first 60 chars
of its first message to a JSON-lines record. A model named in the file
$FAKE_FAIL_MODELS_FILE (one "<model> <status>" line each, read per request)
gets that HTTP error instead: 429 rate limit (an exhausted subscription),
529 overloaded, 500, 401.

Usage: fake-llm.py <port> <record-file>
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
SUMMARY = "FAKE-SUMMARY: the user asked for the 4711 report; it was written to /work/report.md."


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        first = body.get("messages", [{}])[0].get("content", "")
        if isinstance(first, list):
            first = " ".join(b.get("text", "") for b in first if isinstance(b, dict))
        with open(RECORD, "a") as f:
            f.write(json.dumps({
                "path": self.path,
                "model": body.get("model"),
                "auth": bool(self.headers.get("authorization") or self.headers.get("x-api-key")),
                "prompt": str(first)[:60],
            }) + "\n")
        model = body.get("model", "")
        failing = {}
        fail_file = os.environ.get("FAKE_FAIL_MODELS_FILE", "")
        if fail_file and os.path.exists(fail_file):
            for line in open(fail_file):
                parts = line.split()
                if len(parts) == 2:
                    failing[parts[0]] = int(parts[1])
        if model in failing:
            status = failing[model]
            kind = {429: "rate_limit_error", 529: "overloaded_error", 401: "authentication_error"}.get(status, "api_error")
            out = json.dumps({"type": "error", "error": {"type": kind, "message": "fake " + kind}}).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        if self.path.split("?")[0].endswith("/chat/completions"):
            self._openai(body, model)
            return
        if not self.path.split("?")[0].endswith("/v1/messages"):
            self.send_response(404)
            self.end_headers()
            return
        usage = {"input_tokens": 100, "output_tokens": 20}
        if body.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            events = [
                ("message_start", {"type": "message_start", "message": {
                    "id": "msg_fake", "type": "message", "role": "assistant", "model": model,
                    "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}}),
                ("content_block_start", {"type": "content_block_start", "index": 0,
                                         "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                         "delta": {"type": "text_delta", "text": SUMMARY}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta",
                                   "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                   "usage": {"output_tokens": 20}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            for name, data in events:
                self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()
            return
        out = json.dumps({
            "id": "msg_fake", "type": "message", "role": "assistant", "model": model,
            "content": [{"type": "text", "text": SUMMARY}],
            "stop_reason": "end_turn", "stop_sequence": None, "usage": usage,
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def _openai(self, body, model):
        usage = {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}
        if body.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            for delta, finish in (({"role": "assistant", "content": SUMMARY}, None), ({}, "stop")):
                chunk = {"id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": model,
                         "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(f"data: {json.dumps({'id': 'chatcmpl-fake', 'object': 'chat.completion.chunk', 'model': model, 'choices': [], 'usage': usage})}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        out = json.dumps({
            "id": "chatcmpl-fake", "object": "chat.completion", "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": SUMMARY},
                         "finish_reason": "stop"}],
            "usage": usage,
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
