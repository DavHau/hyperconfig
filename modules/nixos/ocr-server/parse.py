"""Firecrawl-Parse-compatible OCR endpoint in front of a local llama-server.

POST /v2/parse takes the multipart request that anydoc's `ocr="hosted"`
sends (an `options` JSON part and a `file` part) and answers
`{"success": true, "data": {"markdown": ...}}`. Each page of a PDF (or
each frame of an image) is rendered to a JPEG of at most 1800 px on its
long side, which Typhoon OCR was trained on, and transcribed by the model
with its one supported prompt. Pages run concurrently, one per server
slot.

`options.pages` ("2-4,7", 1-based) limits the pages; anydoc never sends
it, the `ocr` CLI does. Pages that do not finish within the budget are
marked in the Markdown instead of failing the whole document: anydoc
gives up after 300 s.

Nothing leaves this host: the only connection made is to the model at
OCR_LLAMA_URL (the unit allows loopback only).
"""

import base64
import concurrent.futures
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LLAMA_URL = os.environ["OCR_LLAMA_URL"].rstrip("/") + "/v1/chat/completions"
HOST = os.environ.get("OCR_HOST", "127.0.0.1")
PORT = int(os.environ["OCR_PORT"])
SLOTS = int(os.environ.get("OCR_SLOTS", "2"))
BUDGET = float(os.environ.get("OCR_BUDGET_SECONDS", "270"))
MAX_BYTES = int(os.environ.get("OCR_MAX_BYTES", str(100 * 1024 * 1024)))
MAX_PAGES = int(os.environ.get("OCR_MAX_PAGES", "300"))
DIM = 1800

# Typhoon OCR 1.5's v1.5 prompt (typhoon_ocr/ocr_utils.py), figure
# descriptions in English. The model card: "intended to be used with a
# specific prompt only; it will not work with any other prompts".
PROMPT = """Extract all text from the image.

Instructions:
- Only return the clean Markdown.
- Do not include any explanation or extra text.
- You must include all information on the page.

Formatting Rules:
- Tables: Render tables using <table>...</table> in clean HTML format.
- Equations: Render equations using LaTeX syntax with inline ($...$) and block ($$...$$).
- Images/Charts/Diagrams: Wrap any clearly defined visual areas (e.g. charts, diagrams, pictures) in:

<figure>
Describe the image's main elements (people, objects, text), note any contextual clues (place, event, culture), mention visible text and its meaning, provide deeper analysis when relevant (especially for financial charts, graphs, or documents), comment on style or architecture if relevant, then give a concise overall summary. Describe in English.
</figure>

- Page Numbers: Wrap page numbers in <page_number>...</page_number> (e.g., <page_number>14</page_number>).
- Checkboxes: Use ☐ for unchecked and ☑ for checked boxes."""


class BadRequest(Exception):
    pass


def multipart(content_type, body):
    m = re.search(r'boundary="?([^";]+)"?', content_type or "")
    if not m or not content_type.startswith("multipart/form-data"):
        raise BadRequest("expected multipart/form-data with a boundary")
    delimiter = b"--" + m.group(1).encode()
    parts = {}
    for chunk in body.split(delimiter)[1:]:
        if chunk.startswith(b"--"):
            break
        head, sep, data = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue
        name = re.search(rb'name="([^"]*)"', head)
        if name:
            parts[name.group(1).decode()] = data[:-2] if data.endswith(b"\r\n") else data
    return parts


def page_set(spec, count):
    if spec is None:
        return list(range(1, count + 1))
    pages = set()
    for item in str(spec).split(","):
        lo, _, hi = item.strip().partition("-")
        try:
            lo, hi = int(lo), int(hi or lo)
        except ValueError:
            raise BadRequest(f"bad page range {item!r}")
        pages.update(p for p in range(lo, hi + 1) if 1 <= p <= count)
    if not pages:
        raise BadRequest(f"no page of {spec!r} exists (document has {count})")
    return sorted(pages)


def run(argv, timeout=120):
    r = subprocess.run(argv, capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise BadRequest(f"{argv[0]} failed: {r.stderr.decode(errors='replace').strip()[-300:]}")
    return r.stdout.decode(errors="replace")


def pdf_pages(path):
    m = re.search(r"^Pages:\s+(\d+)", run(["pdfinfo", path]), re.M)
    if not m:
        raise BadRequest("pdfinfo found no page count")
    return int(m.group(1))


def render_pdf_page(path, page, outdir):
    out = os.path.join(outdir, f"p{page}")
    run(["pdftoppm", "-f", str(page), "-l", str(page), "-scale-to", str(DIM),
         "-jpeg", "-jpegopt", "quality=90", "-singlefile", path, out])
    return out + ".jpg"


def image_frames(path, outdir):
    """Every frame of an image (multi-page TIFF too), upright and at most DIM px."""
    run(["magick", path, "-auto-orient", "-resize", f"{DIM}x{DIM}>", "-background", "white",
         "-alpha", "remove", "-quality", "90", os.path.join(outdir, "f%04d.jpg")])
    return sorted(glob.glob(os.path.join(outdir, "f*.jpg")))


def transcribe(jpeg, deadline):
    with open(jpeg, "rb") as f:
        url = "data:image/jpeg;base64," + base64.b64encode(f.read()).decode()
    body = json.dumps({
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": url}},
            {"type": "text", "text": PROMPT}]}],
        # typhoon-ocr's own client settings (app.py).
        "temperature": 0.1,
        "top_p": 0.6,
        "repeat_penalty": 1.1,
        "max_tokens": 8192,
    }).encode()
    req = urllib.request.Request(LLAMA_URL, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=max(1.0, deadline - time.monotonic())) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()


def convert(data, options):
    deadline = time.monotonic() + BUDGET
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "input")
        with open(src, "wb") as f:
            f.write(data)
        if data.startswith(b"%PDF"):
            total = pdf_pages(src)
            pages = page_set(options.get("pages"), total)
            render = lambda p: render_pdf_page(src, p, tmp)
        else:
            frames = image_frames(src, tmp)
            if not frames:
                raise BadRequest("neither a PDF nor an image ImageMagick can read")
            total = len(frames)
            pages = page_set(options.get("pages"), total)
            render = lambda p: frames[p - 1]
        if len(pages) > MAX_PAGES:
            raise BadRequest(f"{len(pages)} pages requested; at most {MAX_PAGES} per request")

        def one(page):
            if time.monotonic() >= deadline:
                return None
            try:
                return transcribe(render(page), deadline)
            except (TimeoutError, urllib.error.URLError) as e:
                if time.monotonic() >= deadline:
                    return None
                raise RuntimeError(f"page {page}: {e}") from e

        with concurrent.futures.ThreadPoolExecutor(SLOTS) as pool:
            texts = list(pool.map(one, pages))

    out = []
    for page, text in zip(pages, texts):
        if total > 1:
            out.append(f"<!-- page {page} of {total} -->")
        if text is None:
            out.append(f"[page {page}: not OCRed within the {int(BUDGET)} s budget; "
                       f"OCR it separately: `ocr --pages {page} <file>`]")
        else:
            out.append(text)
    return "\n\n".join(out) + "\n", {"numPages": total, "pages": pages,
                                      "unfinished": [p for p, t in zip(pages, texts) if t is None]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
        else:
            self.reply(404, {"success": False, "error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v2/parse":
            self.reply(404, {"success": False, "error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BYTES:
                self.close_connection = True
                self.reply(413, {"success": False, "error": f"body must be 1..{MAX_BYTES} bytes"})
                return
            parts = multipart(self.headers.get("Content-Type"), self.rfile.read(length))
            if not parts.get("file"):
                raise BadRequest("no file part")
            options = json.loads(parts.get("options") or b"{}")
            if not isinstance(options, dict):
                raise BadRequest("options must be a JSON object")
            t0 = time.monotonic()
            markdown, meta = convert(parts["file"], options)
            meta["seconds"] = round(time.monotonic() - t0, 1)
            print(f"parsed {len(parts['file'])} bytes: {meta}", file=sys.stderr, flush=True)
            self.reply(200, {"success": True, "data": {"markdown": markdown, "metadata": meta}})
        except (BadRequest, ValueError) as e:
            self.reply(400, {"success": False, "error": str(e)})
        except Exception as e:  # noqa: BLE001
            print(f"error: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
            self.reply(500, {"success": False, "error": f"{type(e).__name__}: {e}"})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
