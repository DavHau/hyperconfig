"""Captcha fixtures for camofox-test.nix, on one port:

  /captcha       a 3x3 image-grid captcha in Prosopo's markup (.prosopo-modalInner, which
                 CaptchaKraken detects): tiles 1, 5 and 9 hold a red circle. Verify with exactly
                 those selected hides the widget and shows "Verification Success"; anything else
                 shows "wrong: <tiles>" and clears the selection.
  /plain         a page without a captcha.
  /v1/...        a stand-in for the captcha model (OpenAI-compatible chat completions). It answers
                 the grid question with cells [1, 5, 9] and the pixel question with the centres of
                 tiles 1, 5 and 9, but only to a request that carries an image, names the expected
                 model and offers no tools; anything else gets a 400.
  /log           what the model stand-in was asked: one entry per request.
"""
import base64
import json
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "CaptchaKraken/CaptchaKraken-v1.2-GGUF"
TARGETS = [1, 5, 9]  # the diagonal: the same cells whichever way a grid is numbered
# Widget geometry (CSS px): 40 px instruction bar, 3x3 tiles of 100 px, 40 px Verify button.
WIDTH, HEADER, TILE, FOOTER = 300, 40, 100, 40
HEIGHT = HEADER + 3 * TILE + FOOTER

CAPTCHA = f"""<!doctype html><html><head><title>captcha</title><style>
body {{ margin: 0; font-family: sans-serif; }}
#w {{ position: absolute; left: 40px; top: 60px; width: {WIDTH}px; height: {HEIGHT}px; background: #fff; }}
#hdr {{ height: {HEADER}px; line-height: {HEADER}px; background: #1a73e8; color: #fff; text-align: center; }}
#g {{ display: grid; grid-template-columns: repeat(3, {TILE}px); grid-template-rows: repeat(3, {TILE}px); }}
.t {{ box-sizing: border-box; border: 2px solid #fff; }}
.t.sel {{ outline: 6px solid #1a73e8; outline-offset: -6px; }}
#v {{ display: block; width: {WIDTH}px; height: {FOOTER}px; border: 0; background: #1a73e8; color: #fff; }}
</style></head><body>
<p><span id="result">pending</span> <span id="picked"></span></p>
<div class="prosopo-modalInner" id="w">
  <div id="hdr">Select all images with a red circle</div>
  <div id="g"></div>
  <button id="v" type="button">Verify</button>
</div>
<script>
const want = {json.dumps(TARGETS)};
const sel = new Set();
const g = document.getElementById('g');
for (let i = 1; i <= 9; i++) {{
  const t = document.createElement('div');
  t.className = 't';
  t.style.background = want.includes(i)
    ? 'radial-gradient(circle, #d00 0 30px, #fde 31px)'
    : `repeating-linear-gradient(${{i * 20}}deg, #3a6 0 8px, #cfe 8px 16px)`;
  t.onclick = () => {{ sel.has(i) ? sel.delete(i) : sel.add(i); t.classList.toggle('sel'); }};
  g.appendChild(t);
}}
document.getElementById('v').onclick = () => {{
  const got = [...sel].sort((a, b) => a - b).join(',');
  document.getElementById('picked').textContent = got;
  if (got === want.join(',')) {{
    document.getElementById('w').style.display = 'none';
    document.getElementById('result').textContent = 'Verification Success';
  }} else {{
    document.getElementById('result').textContent = 'wrong: ' + got;
    sel.clear();
    document.querySelectorAll('.t').forEach((t) => t.classList.remove('sel'));
  }}
}};
</script>
</body></html>""".encode()

PLAIN = b"<!doctype html><html><head><title>plain</title></head><body><p>No captcha here.</p></body></html>"


def tile_point(n):
    """Centre of tile n on the widget's 0-1000 scale, as the pixel prompt asks."""
    r, c = divmod(n - 1, 3)
    return [round((c + 0.5) * TILE / WIDTH * 1000), round((HEADER + (r + 0.5) * TILE) / HEIGHT * 1000)]


LOG = []


def answer(req):
    """(status, content or error) for one chat request, and its log entry."""
    entry = {"model": req.get("model"), "tools": "tools" in req or "tool_choice" in req, "images": 0}
    texts = []
    for m in req.get("messages") or []:
        content = m.get("content")
        for part in content if isinstance(content, list) else []:
            if part.get("type") == "image_url":
                url = (part.get("image_url") or {}).get("url", "")
                head, _, data = url.partition(",")
                if head.startswith("data:image/") and head.endswith(";base64") and len(base64.b64decode(data)) > 1000:
                    entry["images"] += 1
            elif part.get("type") == "text":
                texts.append(part.get("text", ""))
    prompt = "\n".join(texts)
    entry["kind"] = "grid" if "Grid:" in prompt else "pixel"
    if entry["images"] < 1 or entry["tools"] or entry["model"] != MODEL:
        entry["refused"] = True
        LOG.append(entry)
        return 400, "expected an image, no tools and model " + MODEL
    LOG.append(entry)
    if entry["kind"] == "grid":
        return 200, json.dumps(TARGETS)
    return 200, json.dumps({"action": "click", "subjects": ["red circle"] * len(TARGETS),
                            "points": [tile_point(n) for n in TARGETS]})


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("captcha-site: " + fmt % args + "\n")

    def _send(self, status, body, ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/captcha":
            self._send(200, CAPTCHA, "text/html")
        elif self.path == "/plain":
            self._send(200, PLAIN, "text/html")
        elif self.path == "/log":
            self._send(200, json.dumps(LOG).encode())
        elif self.path in ("/health", "/v1/models"):
            self._send(200, json.dumps({"object": "list", "data": [{"id": MODEL}]}).encode())
        else:
            self.send_error(404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path != "/v1/chat/completions":
            return self.send_error(404)
        status, content = answer(json.loads(body))
        if status != 200:
            return self._send(status, json.dumps({"error": {"message": content}}).encode())
        self._send(200, json.dumps({"object": "chat.completion", "model": MODEL, "choices": [
            {"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": content}}]}).encode())


class DualStack(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    DualStack(("::", int(sys.argv[1])), H).serve_forever()
