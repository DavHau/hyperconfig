"""scan-ocr: build one searchable PDF from scanned JPEGs, offline.

One instance per connection of scan-ocr.socket (./default.nix): stdin and
stdout are the connection. The JPEGs come from the printer, so this side
parses untrusted data (img2pdf, Tesseract, Leptonica, pikepdf) and runs
apart from the web service: its own dynamic user, no network at all
(PrivateNetwork, AF_UNIX only), no write access outside its private /tmp,
no W+X memory, a memory cap and a runtime cap.

Request:  b"SCAN1\\n", then per page an 8-byte big-endian length and the
          JPEG, then a zero length.
Reply:    b"OK" or b"ER", an 8-byte length, then the PDF or a UTF-8
          error message.
"""

import json
import os
import struct
import subprocess
import sys
import tempfile
import time

CFG = json.load(open(sys.argv[1]))
MAX_PAGES = CFG["maxPages"]
MAX_PAGE = CFG["maxPageBytes"]
MAGIC = b"SCAN1\n"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


class Fail(Exception):
    pass


def read_exact(f, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = f.read(min(n - len(buf), 1 << 20))
        if not chunk:
            raise Fail("connection closed early")
        buf += chunk
    return bytes(buf)


def reply(out, kind, payload_len, write_payload):
    out.write(kind + struct.pack(">Q", payload_len))
    write_payload()
    out.flush()


def run(cmd, timeout):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Fail(f"{os.path.basename(cmd[0])} took longer than "
                   f"{timeout} s")
    if p.returncode != 0:
        tail = (p.stderr or p.stdout).strip().splitlines()[-5:]
        log(f"{cmd[0]} failed ({p.returncode}): " + " | ".join(tail))
        raise Fail(f"{os.path.basename(cmd[0])} failed: "
                   + " / ".join(tail)[-300:])


def memory_peak():
    try:
        rel = open("/proc/self/cgroup").read().strip().split("::", 1)[1]
        return int(open(f"/sys/fs/cgroup{rel}/memory.peak").read())
    except (OSError, IndexError, ValueError):
        return None


def work(inp, tmp):
    if read_exact(inp, len(MAGIC)) != MAGIC:
        raise Fail("bad request")
    files = []
    while True:
        (n,) = struct.unpack(">Q", read_exact(inp, 8))
        if n == 0:
            break
        if len(files) >= MAX_PAGES:
            raise Fail(f"more than {MAX_PAGES} pages")
        if n > MAX_PAGE:
            raise Fail("page too large")
        data = read_exact(inp, n)
        if not data.startswith(b"\xff\xd8"):
            raise Fail("a page is not a JPEG")
        path = os.path.join(tmp, f"page-{len(files) + 1:04d}.jpg")
        with open(path, "wb") as f:
            f.write(data)
        files.append(path)
        del data
    if not files:
        raise Fail("no pages")
    raw, ocr = os.path.join(tmp, "raw.pdf"), os.path.join(tmp, "ocr.pdf")
    # The scan region is A4, so A4 pages give the true size whatever DPI
    # the device writes into the JPEG.
    run([CFG["img2pdf"], "--pagesize", "A4", "--fit", "into", "-o", raw]
        + files, CFG["img2pdfTimeout"])
    run([CFG["ocrmypdf"], "--jobs", str(CFG["ocrJobs"]),
         "-l", "+".join(CFG["languages"]),
         "--output-type", CFG["outputType"]] + CFG["ocrArgs"] + [raw, ocr],
        CFG["ocrTimeout"])
    return ocr, len(files)


def main():
    inp, out = sys.stdin.buffer, sys.stdout.buffer
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory() as tmp:
        try:
            ocr, n = work(inp, tmp)
        except Fail as e:
            msg = str(e).encode()
            reply(out, b"ER", len(msg), lambda: out.write(msg))
            log(f"error: {e}")
            return
        size = os.path.getsize(ocr)

        def send():
            with open(ocr, "rb") as f:
                while chunk := f.read(1 << 20):
                    out.write(chunk)

        reply(out, b"OK", size, send)
        log(f"ocr {n} page(s), {size} bytes, {time.monotonic() - t0:.0f} s, "
            f"memory.peak={memory_peak()}")


if __name__ == "__main__":
    main()
