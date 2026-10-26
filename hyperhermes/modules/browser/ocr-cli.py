"""ocr FILE [--pages 2-4,7] [-o OUT.md]: Markdown of a scanned PDF or a
document image, from the deployment's own OCR endpoint (OCR_URL).
Nothing goes to a third party."""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid


def main():
    ap = argparse.ArgumentParser(
        prog="ocr",
        description="OCR a scanned PDF or an image (PNG, JPEG, TIFF, WebP, HEIC...) to Markdown "
        "on the fleet's own GPU (Typhoon OCR: English and Thai).")
    ap.add_argument("file")
    ap.add_argument("--pages", help="1-based pages or frames, e.g. 3 or 2-4,7 (default: all)")
    ap.add_argument("-o", "--output", help="write the Markdown here instead of stdout")
    args = ap.parse_args()

    with open(args.file, "rb") as f:
        data = f.read()
    options = {"pages": args.pages} if args.pages else {}
    boundary = uuid.uuid4().hex
    name = os.path.basename(args.file).replace('"', "_")
    body = b"".join([
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="options"\r\n\r\n',
        json.dumps(options).encode(),
        f"\r\n--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'.encode(),
        b"Content-Type: application/octet-stream\r\n\r\n",
        data,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    req = urllib.request.Request(
        os.environ["OCR_URL"].rstrip("/") + "/v2/parse", body,
        {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=330) as r:
            reply = json.load(r)
    except urllib.error.HTTPError as e:
        try:
            reply = json.load(e)
        except ValueError:
            reply = {"error": f"HTTP {e.code}"}
    except OSError as e:
        sys.exit(f"ocr: endpoint unreachable ({e}); the model may be starting, retry once")
    if not reply.get("success"):
        sys.exit(f"ocr: {reply.get('error', 'failed')}")
    data = reply["data"]
    if args.output:
        with open(args.output, "w") as f:
            f.write(data["markdown"])
    else:
        sys.stdout.write(data["markdown"])
    meta = data.get("metadata") or {}
    if meta.get("unfinished"):
        pages = ",".join(map(str, meta["unfinished"]))
        print(f"ocr: pages {pages} ran out of time; rerun with --pages {pages}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
