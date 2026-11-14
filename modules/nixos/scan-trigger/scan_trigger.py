"""scan-trigger: LAN web page that pulls flatbed scans over eSCL.

Runs as the unprivileged `scan-trigger` user (./default.nix). Each "Scan
page" pulls one JPEG from the scanner (eSCL ScanJobs, platen) into
<state>/current/. "Finish" streams the pages to scan-ocr.socket, whose
per-connection instance (./scan_ocr.py, no network) builds and OCRs the
PDF, and drops the result into the outbox (root:scan-outbox 2770), from
where ./scan_deliver.py, running as the owner, files it into the vault.
Pages survive a crash or restart in <state>/current/ until finished or
discarded.

Limits: eSCL replies are read up to 64 MiB (1 MiB for XML) within a total
deadline; at most maxPages per document; no scan below minFreeBytes on the
state/outbox file system or while the outbox holds outboxMaxBytes.

Security: the listener is LAN-only (firewall + bind address + peer check
here). State-changing requests are POSTs that must carry the page's token,
a Host header from the allowed list (DNS rebinding) and, when the browser
sends them, Sec-Fetch-Site: same-origin / a same-origin Origin. Local
processes on the host reach the LAN address via lo with a LAN source
address, so they have the same rights as a LAN client.
"""

import datetime
import hmac
import html
import http.server
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

CFG = json.load(open(sys.argv[1]))
STATE = CFG["stateDir"]
CURRENT = os.path.join(STATE, "current")
OUTBOX = CFG["outboxDir"]
WORK = os.path.join(STATE, "work")
HISTORY = os.path.join(STATE, "history.json")
PREFS = os.path.join(STATE, "prefs.json")
ESCL = CFG["esclUrl"].rstrip("/")
NETS = [ipaddress.ip_network(n) for n in CFG["allowedNetworks"]]
TOKEN = secrets.token_urlsafe(32)
NAME_RE = re.compile(r"^\d{4}-\d\d-\d\d_\d{6}(_\d+)?\.pdf$")
PAGE_RE = re.compile(r"^page-(\d{4})\.jpg$")
NS = {
    "pwg": "http://www.pwg.org/schemas/2010/12/sm",
    "scan": "http://schemas.hp.com/imaging/escl/2011/05/03",
}
# A4 in 1/300 inch.
A4_W, A4_H = 2480, 3508
ASLEEP_HINT = (
    "On the printer press Scan, then Remote Scanner (or turn on "
    "Function Settings > Common > Scan Settings > Auto Online), "
    "then try again."
)

port = CFG["port"]
ALLOWED_HOSTS = set()
for h in CFG["hostNames"] + [CFG["listenAddress"]]:
    ALLOWED_HOSTS.add(h.lower())
    ALLOWED_HOSTS.add(f"{h.lower()}:{port}")

lock = threading.Lock()
status = {"busy": None, "message": None, "error": False}


def log(*a):
    print(*a, flush=True)


class ScanError(Exception):
    pass


# ---------------------------------------------------------------- eSCL ---

_tls = ssl.create_default_context()
# The printer sits alone on an isolated IoT net with a self-signed cert.
_tls.check_hostname = False
_tls.verify_mode = ssl.CERT_NONE


XML_MAX = 1 << 20
JPEG_MAX = 64 << 20
VERSION_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){0,2}$")


def read_capped(r, cap, deadline):
    buf = bytearray()
    while True:
        if deadline is not None and time.monotonic() > deadline:
            raise ScanError("The scanner took too long to send the page.")
        chunk = r.read(1 << 16)
        if not chunk:
            return bytes(buf)
        buf += chunk
        if len(buf) > cap:
            raise ScanError(f"The scanner sent more than {cap >> 20} MiB.")


def escl(method, path, body=None, timeout=20, cap=XML_MAX, deadline=None):
    url = path if path.startswith("http") else f"{ESCL}/{path}"
    req = urllib.request.Request(url, data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "text/xml")
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_tls) as r:
            return r.status, r.headers, read_capped(r, cap, deadline)
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.headers, read_capped(e, XML_MAX, deadline)
        except (OSError, ScanError):
            return e.code, e.headers, b""
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise ScanError(
            f"Printer not reachable at {ESCL} ({reason}). Is it switched "
            "on and on the network? " + ASLEEP_HINT
        )


def capabilities():
    st, _, body = escl("GET", "ScannerCapabilities")
    if st != 200:
        raise ScanError(f"Scanner capabilities: HTTP {st}. " + ASLEEP_HINT)
    root = ET.fromstring(body)
    caps = root.find("scan:Platen/scan:PlatenInputCaps", NS)
    if caps is None:
        raise ScanError("The scanner reports no flatbed (platen).")

    def num(tag, default):
        e = caps.find(tag, NS)
        return int(e.text) if e is not None and e.text else default

    version = (root.findtext("pwg:Version", "2.0", NS) or "2.0").strip()
    return {
        # Echoed into our ScanSettings XML: digits and dots only.
        "version": version if VERSION_RE.match(version) else "2.0",
        "maxw": num("scan:MaxWidth", A4_W),
        "maxh": num("scan:MaxHeight", A4_H),
        "res": sorted(
            {int(e.text) for e in caps.iter(f"{{{NS['scan']}}}XResolution")
             if e.text and e.text.isdigit()}
        ),
        "modes": {e.text for e in caps.iter(f"{{{NS['scan']}}}ColorMode")},
        "docfmtext": caps.find(".//scan:DocumentFormatExt", NS) is not None,
    }


def scanner_state():
    st, _, body = escl("GET", "ScannerStatus")
    if st != 200:
        return None
    try:
        return ET.fromstring(body).findtext("pwg:State", None, NS)
    except ET.ParseError:
        return None


def settings_xml(caps, dpi, mode):
    w, h = min(A4_W, caps["maxw"]), min(A4_H, caps["maxh"])
    ext = (
        "<scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>"
        if caps["docfmtext"] else ""
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f'<scan:ScanSettings xmlns:scan="{NS["scan"]}" xmlns:pwg="{NS["pwg"]}">'
        f"<pwg:Version>{caps['version']}</pwg:Version>"
        "<scan:Intent>Document</scan:Intent>"
        "<pwg:ScanRegions><pwg:ScanRegion>"
        "<pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches"
        "</pwg:ContentRegionUnits>"
        f"<pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset>"
        f"<pwg:Width>{w}</pwg:Width><pwg:Height>{h}</pwg:Height>"
        "</pwg:ScanRegion></pwg:ScanRegions>"
        "<pwg:InputSource>Platen</pwg:InputSource>"
        f"<scan:ColorMode>{mode}</scan:ColorMode>"
        "<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>"
        f"{ext}"
        f"<scan:XResolution>{dpi}</scan:XResolution>"
        f"<scan:YResolution>{dpi}</scan:YResolution>"
        "</scan:ScanSettings>"
    ).encode()


def scan_jpeg(dpi, grey):
    caps = capabilities()
    if caps["res"] and dpi not in caps["res"]:
        dpi = min(caps["res"], key=lambda r: abs(r - dpi))
    mode = "Grayscale8" if grey else "RGB24"
    if caps["modes"] and mode not in caps["modes"]:
        raise ScanError(f"The scanner does not offer {mode}.")
    if scanner_state() == "Processing":
        raise ScanError("The scanner is busy with another job; try again "
                        "in a minute.")
    body = settings_xml(caps, dpi, mode)
    st, hdr = None, {}
    # A sleeping MF27x answers 503 (or refuses) until it is back online.
    for attempt in range(4):
        st, hdr, _ = escl("POST", "ScanJobs", body)
        if st == 201:
            break
        log(f"ScanJobs: HTTP {st} (attempt {attempt + 1})")
        if st in (503, 409) and attempt < 3:
            time.sleep(3)
            continue
        raise ScanError(f"The scanner refused the scan (HTTP {st}). "
                        + ASLEEP_HINT)
    loc = hdr.get("Location") or ""
    path = urllib.parse.urlsplit(loc).path
    if not path.startswith("/"):
        raise ScanError("The scanner sent no job location.")
    # Like sane-airscan: keep the configured host, take only the path.
    base = urllib.parse.urlsplit(ESCL)
    job = f"{base.scheme}://{base.netloc}{path.rstrip('/')}"
    deadline = time.monotonic() + CFG["downloadSeconds"]
    try:
        for attempt in range(40):
            if time.monotonic() > deadline:
                raise ScanError("The scanner never delivered the page.")
            st, _, data = escl("GET", f"{job}/NextDocument", timeout=180,
                               cap=JPEG_MAX, deadline=deadline)
            if st == 200:
                break
            if st == 503:
                time.sleep(1)
                continue
            raise ScanError(f"Fetching the page failed (HTTP {st}).")
        else:
            raise ScanError("The scanner never delivered the page.")
    finally:
        try:
            escl("DELETE", job, timeout=10)
        except ScanError:
            pass
    if not data.startswith(b"\xff\xd8"):
        raise ScanError("The scanner returned something that is not a JPEG.")
    return data, dpi


# --------------------------------------------------------------- state ---

def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def pages():
    return sorted(n for n in os.listdir(CURRENT) if PAGE_RE.match(n))


def prefs():
    p = read_json(PREFS, {})
    dpi = p.get("dpi", CFG["defaultResolution"])
    if dpi not in CFG["resolutions"]:
        dpi = CFG["defaultResolution"]
    return {"dpi": dpi, "grey": bool(p.get("grey", False))}


def outbox_bytes():
    total = 0
    for n in os.listdir(OUTBOX):
        try:
            total += os.lstat(os.path.join(OUTBOX, n)).st_size
        except OSError:
            pass
    return total


def check_room():
    for d in (STATE, OUTBOX):
        st = os.statvfs(d)
        free = st.f_bavail * st.f_frsize
        if free < CFG["minFreeBytes"]:
            raise ScanError(f"Disk almost full ({free >> 20} MiB free); not "
                            "scanning.")
    if outbox_bytes() >= CFG["outboxMaxBytes"]:
        raise ScanError("Too many finished scans are waiting for the vault "
                        "(is it mounted?); not scanning.")


def add_page(dpi, grey):
    if len(pages()) >= CFG["maxPages"]:
        raise ScanError(f"A document has at most {CFG['maxPages']} pages; "
                        "finish this one first.")
    check_room()
    data, used = scan_jpeg(dpi, grey)
    existing = pages()
    n = 1
    if existing:
        m = PAGE_RE.match(existing[-1])
        n = int(m.group(1)) + 1 if m else len(existing) + 1
    final = os.path.join(CURRENT, f"page-{n:04d}.jpg")
    tmp = final + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, final)
    log(f"scanned page {n} at {used} dpi ({len(data)} bytes)")
    return n


def unique_name():
    taken = set(os.listdir(OUTBOX)) | {
        h["name"] for h in read_json(HISTORY, [])
    }
    base = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    name, i = f"{base}.pdf", 2
    while name in taken:
        name, i = f"{base}_{i}.pdf", i + 1
    return name


def recv_exact(s, n, deadline):
    buf = bytearray()
    while len(buf) < n:
        if time.monotonic() > deadline:
            raise ScanError("OCR took too long.")
        try:
            chunk = s.recv(min(n - len(buf), 1 << 20))
        except ConnectionResetError:
            chunk = b""
        if not chunk:
            raise ScanError("The OCR worker stopped (see journalctl -u "
                            "'scan-ocr@*').")
        buf += chunk
    return bytes(buf)


def ocr_to(files, tmp):
    """Run img2pdf + ocrmypdf in a scan-ocr@ instance; PDF into tmp."""
    deadline = time.monotonic() + CFG["ocrTimeout"] + 120
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(CFG["ocrTimeout"] + 120)
        try:
            s.connect(CFG["ocrSocket"])
        except OSError as e:
            raise ScanError(f"OCR worker not available ({e}).")
        try:
            s.sendall(b"SCAN1\n")
            for f in files:
                with open(os.path.join(CURRENT, f), "rb") as fh:
                    data = fh.read()
                s.sendall(struct.pack(">Q", len(data)) + data)
            s.sendall(struct.pack(">Q", 0))
        except (BrokenPipeError, ConnectionResetError):
            # The worker refused early (e.g. a page too large) and closed;
            # its ER reply is still in our receive buffer.
            pass
        kind = recv_exact(s, 2, deadline)
        (n,) = struct.unpack(">Q", recv_exact(s, 8, deadline))
        if kind == b"ER":
            msg = recv_exact(s, min(n, 4096), deadline)
            raise ScanError("OCR failed: " + msg.decode("utf-8", "replace"))
        if kind != b"OK" or n > CFG["maxDocBytes"]:
            raise ScanError("The OCR worker sent a bad reply.")
        with open(tmp, "wb") as out:
            os.fchmod(out.fileno(), 0o640)
            left = n
            while left:
                chunk = recv_exact(s, min(left, 1 << 20), deadline)
                out.write(chunk)
                left -= len(chunk)
            out.flush()
            os.fsync(out.fileno())
    with open(tmp, "rb") as f:
        if f.read(5) != b"%PDF-":
            raise ScanError("The OCR worker sent no PDF.")


def finish():
    files = pages()
    if not files:
        raise ScanError("No pages scanned yet.")
    if outbox_bytes() >= CFG["outboxMaxBytes"]:
        raise ScanError("Too many finished scans are waiting for the vault "
                        "(is it mounted?); the pages are kept.")
    status["busy"] = f"Building the PDF and running OCR " \
                     f"({'+'.join(CFG['languages'])}) on {len(files)} page(s)"
    name = unique_name()
    tmp = os.path.join(OUTBOX, "." + name + ".part")
    try:
        ocr_to(files, tmp)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, os.path.join(OUTBOX, name))
    hist = read_json(HISTORY, [])
    hist.append({"name": name, "pages": len(files),
                 "time": int(time.time())})
    write_json(HISTORY, hist[-CFG["historySize"]:])
    for f in files:
        os.unlink(os.path.join(CURRENT, f))
    log(f"finished {name} ({len(files)} pages)")
    return name


def discard():
    files = pages()
    for f in files:
        os.unlink(os.path.join(CURRENT, f))
    log(f"discarded {len(files)} page(s)")
    return len(files)


def startup():
    os.makedirs(CURRENT, mode=0o700, exist_ok=True)
    # Half-written pages/outbox files of a crashed run.
    for d in (CURRENT, OUTBOX):
        for n in os.listdir(d):
            if n.endswith(".tmp") or n.endswith(".part"):
                os.unlink(os.path.join(d, n))
    shutil.rmtree(WORK, ignore_errors=True)
    left = len(pages())
    if left:
        status["message"] = (f"{left} page(s) left over from before (e.g. "
                             "a restart): finish or discard them.")
        log(f"{left} leftover page(s) in {CURRENT}")


# ---------------------------------------------------------------- jobs ---

def job(action, dpi, grey):
    msg = ""
    try:
        if action == "scan":
            status["busy"] = "Scanning a page"
            n = add_page(dpi, grey)
            msg = f"Page {n} scanned."
        elif action == "finish":
            msg = f"Saved {finish()}."
        elif action == "scanfinish":
            status["busy"] = "Scanning a page"
            add_page(dpi, grey)
            msg = f"Saved {finish()}."
        elif action == "discard":
            msg = f"Discarded {discard()} page(s)."
        status.update(message=msg, error=False)
    except ScanError as e:
        status.update(message=str(e), error=True)
    except Exception as e:  # keep serving; show it on the page
        log(f"{action} crashed: {e!r}")
        status.update(message=f"Internal error: {e!r}", error=True)
    finally:
        status["busy"] = None
        lock.release()


# ----------------------------------------------------------------- web ---

CSS = """
:root{color-scheme:dark light;--bg:#15171a;--fg:#e6e6e6;--mut:#9aa0a6;
--card:#202328;--acc:#3d8bfd;--bad:#ff6b6b;--ok:#5fd38d;--line:#33373d}
@media (prefers-color-scheme: light){:root{--bg:#f6f7f9;--fg:#1d1f23;
--mut:#5f6368;--card:#fff;--acc:#1a66d9;--bad:#c62828;--ok:#2e7d32;
--line:#d9dce1}}
body{margin:0;background:var(--bg);color:var(--fg);
font:17px/1.45 system-ui,sans-serif}
main{max-width:34rem;margin:0 auto;padding:1.2rem}
h1{font-size:1.3rem;margin:.2rem 0 1rem}
.card{background:var(--card);border:1px solid var(--line);
border-radius:12px;padding:1rem;margin:0 0 1rem}
button{font:inherit;border:0;border-radius:10px;padding:.8rem 1rem;
cursor:pointer;background:var(--line);color:var(--fg);width:100%;
margin:.3rem 0}
button.big{background:var(--acc);color:#fff;font-size:1.4rem;
padding:1.4rem}
button:disabled{opacity:.45;cursor:default}
.row{display:flex;gap:.6rem}.row>*{flex:1}
select{font:inherit;width:100%;padding:.5rem;border-radius:8px;
background:var(--bg);color:var(--fg);border:1px solid var(--line)}
.msg{padding:.7rem 1rem;border-radius:10px;margin:0 0 1rem;
border:1px solid var(--ok)}.msg.err{border-color:var(--bad);
color:var(--bad)}.mut{color:var(--mut)}ul{padding-left:1.2rem;margin:.3rem 0}
"""


def page_html():
    p = prefs()
    files = pages()
    busy = status["busy"]
    dis = " disabled" if busy else ""
    hist = list(reversed(read_json(HISTORY, [])))
    pending = set(os.listdir(OUTBOX))
    out = ['<!doctype html><html><head><meta charset="utf-8">',
           '<meta name="viewport" content="width=device-width,'
           'initial-scale=1">',
           '<meta name="color-scheme" content="dark light">']
    if busy:
        out.append('<meta http-equiv="refresh" content="2">')
    out.append(f"<title>Scan</title><style>{CSS}</style></head><body><main>")
    out.append("<h1>Scanner</h1>")
    if busy:
        out.append(f'<div class="msg">{html.escape(busy)}&hellip;</div>')
    elif status["message"]:
        cls = "msg err" if status["error"] else "msg"
        out.append(f'<div class="{cls}">{html.escape(status["message"])}'
                   "</div>")
    t = html.escape(TOKEN)
    opts_dpi = "".join(
        f'<option value="{r}"{" selected" if r == p["dpi"] else ""}>'
        f"{r} dpi</option>" for r in CFG["resolutions"])
    opts_mode = (
        f'<option value="color"{"" if p["grey"] else " selected"}>Colour'
        f'</option><option value="grey"{" selected" if p["grey"] else ""}>'
        "Grey</option>")
    n = len(files)
    out.append(
        '<form method="post" action="/action" class="card">'
        f'<input type="hidden" name="token" value="{t}">'
        f'<p class="mut">Current document: <b>{n}</b> page(s). Put the next '
        "page face down on the glass.</p>"
        f'<button class="big" name="do" value="scan"{dis}>Scan page</button>'
        f'<button name="do" value="scanfinish"{dis}>Scan + finish '
        "(single page)</button>"
        '<div class="row">'
        f'<button name="do" value="finish"{dis if n else " disabled"}>'
        "Finish document</button>"
        f'<button name="do" value="discard"{dis if n else " disabled"}>'
        "Discard</button></div>"
        f'<div class="row"><select name="dpi">{opts_dpi}</select>'
        f'<select name="mode">{opts_mode}</select></div></form>')
    out.append('<div class="card"><b>Last documents</b>')
    if hist:
        out.append("<ul>")
        for h in hist:
            name = h.get("name", "")
            tag = " <span class=mut>(waiting for the vault)</span>" \
                if name in pending else ""
            out.append(f"<li>{html.escape(name)}{tag}</li>")
        out.append("</ul>")
    else:
        out.append('<p class="mut">None yet.</p>')
    out.append(f'<p class="mut">Saved to {html.escape(CFG["outputLabel"])}'
               "</p></div></main></body></html>")
    return "".join(out).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "scan-trigger"
    sys_version = ""
    # Idle or slow clients must not pin threads forever.
    timeout = 30

    def log_message(self, format, *args):
        log(f"{self.client_address[0]} {format % args}")

    def send(self, code, body=b"", ctype="text/plain; charset=utf-8",
             extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; "
            "form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def gate(self):
        """Peer on the LAN and a known Host (no DNS rebinding)."""
        try:
            peer = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            peer = None
        if peer is None or not any(peer in n for n in NETS):
            self.send(403, b"LAN only\n")
            return False
        host = (self.headers.get("Host") or "").lower()
        if host not in ALLOWED_HOSTS:
            self.send(421, b"unknown host name\n")
            return False
        return True

    def do_GET(self):
        if not self.gate():
            return
        if self.path != "/":
            return self.send(404, b"not found\n")
        self.send(200, page_html(), "text/html; charset=utf-8")

    do_HEAD = do_GET

    def do_POST(self):
        if not self.gate():
            return
        if self.path != "/action":
            return self.send(404, b"not found\n")
        host = self.headers.get("Host", "").lower()
        site = self.headers.get("Sec-Fetch-Site")
        origin = self.headers.get("Origin")
        # Browsers send Sec-Fetch-* only to https/localhost, so on this
        # plain-http LAN page Origin is what a real form post carries
        # (Referrer-Policy same-origin keeps it the true origin). "null"
        # (sandboxed frames, data: URLs, redirects) is refused unless the
        # browser itself vouches with Sec-Fetch-Site: same-origin.
        if site is not None:
            if site != "same-origin":
                return self.send(403, b"cross-site request refused\n")
        elif origin is not None and origin.lower() != f"http://{host}":
            return self.send(403, b"cross-origin request refused\n")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 <= length <= 4096:
            return self.send(413, b"bad request size\n")
        form = urllib.parse.parse_qs(self.rfile.read(length).decode(
            "ascii", "replace"))

        def field(k):
            return (form.get(k) or [""])[0]

        if not hmac.compare_digest(field("token"), TOKEN):
            status.update(message="The page was out of date; it is "
                          "reloaded now. Click again.", error=True)
            return self.send(303, extra=[("Location", "/")])
        action = field("do")
        if action not in ("scan", "finish", "scanfinish", "discard"):
            return self.send(400, b"unknown action\n")
        try:
            dpi = int(field("dpi"))
        except ValueError:
            dpi = CFG["defaultResolution"]
        if dpi not in CFG["resolutions"]:
            dpi = CFG["defaultResolution"]
        grey = field("mode") == "grey"
        if lock.acquire(blocking=False):
            write_json(PREFS, {"dpi": dpi, "grey": grey})
            status.update(busy="Starting", message=None, error=False)
            threading.Thread(target=job, args=(action, dpi, grey),
                             daemon=True).start()
        else:
            log(f"{action}: busy, ignored")
        self.send(303, extra=[("Location", "/")])


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def server_bind(self):
        # The LAN address may come up after us (DHCP, a static alias).
        self.socket.setsockopt(socket.SOL_IP, 15, 1)  # IP_FREEBIND
        super().server_bind()


def main():
    startup()
    srv = Server((CFG["listenAddress"], port), Handler)
    log(f"listening on http://{CFG['listenAddress']}:{port}/, "
        f"scanner {ESCL}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
