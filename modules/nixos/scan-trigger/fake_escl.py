"""Fake eSCL scanner for the scan-trigger VM test (and local checks).

Serves ScannerCapabilities/ScannerStatus/ScanJobs/NextDocument like a
flatbed MF27x; the page is a JPEG rendered with German, English and Thai
text. `asleep` file in the cwd: answer 503 to ScanJobs (printer offline).
Logs every request to requests.log in the cwd.
"""

import http.server
import io
import os
import re
import sys
import time

from PIL import Image, ImageDraw, ImageFont

LATIN_FONT, THAI_FONT = sys.argv[2], sys.argv[3]
PORT = int(sys.argv[1])
counter = [0]
dpi = [300]

CAPS = b"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
<pwg:Version>2.63</pwg:Version><pwg:MakeAndModel>MF270 Series</pwg:MakeAndModel>
<scan:Platen><scan:PlatenInputCaps>
<scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>2550</scan:MaxWidth>
<scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>3508</scan:MaxHeight>
<scan:SettingProfiles><scan:SettingProfile>
<scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode></scan:ColorModes>
<scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat></scan:DocumentFormats>
<scan:SupportedResolutions><scan:DiscreteResolutions>
<scan:DiscreteResolution><scan:XResolution>150</scan:XResolution><scan:YResolution>150</scan:YResolution></scan:DiscreteResolution>
<scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
<scan:DiscreteResolution><scan:XResolution>600</scan:XResolution><scan:YResolution>600</scan:YResolution></scan:DiscreteResolution>
</scan:DiscreteResolutions></scan:SupportedResolutions>
</scan:SettingProfile></scan:SettingProfiles>
</scan:PlatenInputCaps></scan:Platen>
</scan:ScannerCapabilities>"""

STATUS = b"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
<pwg:Version>2.63</pwg:Version><pwg:State>Idle</pwg:State></scan:ScannerStatus>"""


def page(n, dpi):
    # A4 at the requested resolution, but at most 150 dpi of detail for
    # the default 300 (fast in a VM); 600 renders the full 4960x7016
    # colour page (memory check of the OCR worker) with a colour photo-ish
    # gradient so the JPEG isn't trivially small.
    dpi = 600 if dpi >= 600 else 150
    k = dpi / 150
    img = Image.new("RGB", (round(1240 * k), round(1754 * k)), "white")
    d = ImageDraw.Draw(img)
    if dpi >= 600:
        for y in range(round(800 * k), round(1600 * k), 4):
            c = (y * 7 % 256, y * 3 % 256, 255 - y % 256)
            d.line([(round(100 * k), y), (round(1140 * k), y)], fill=c,
                   width=4)
    latin = ImageFont.truetype(LATIN_FONT, round(56 * k))
    thai = ImageFont.truetype(THAI_FONT, round(72 * k))
    d.text((100 * k, 150 * k), f"Rechnung Nummer {n}", fill="black",
           font=latin)
    d.text((100 * k, 300 * k), f"Invoice page {n} Hyperconfig",
           fill="black", font=latin)
    d.text((100 * k, 470 * k), "สวัสดีครับ", fill="black", font=thai)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90, dpi=(dpi, dpi))
    return buf.getvalue()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        with open("requests.log", "a") as f:
            f.write(f"{self.command} {self.path}\n")

    def reply(self, code, body=b"", ctype="text/xml", extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/eSCL/ScannerCapabilities":
            return self.reply(200, CAPS)
        if self.path == "/eSCL/ScannerStatus":
            return self.reply(200, STATUS)
        if self.path.startswith("/eSCL/ScanJobs/") and \
                self.path.endswith("/NextDocument"):
            # A real flatbed takes a while; also keeps parallel clicks
            # overlapping in the test.
            time.sleep(1)
            if os.path.exists("huge"):
                # A misbehaving device: endless body, no Content-Length.
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.end_headers()
                try:
                    self.wfile.write(b"\xff\xd8")
                    junk = b"\0" * (1 << 20)
                    for _ in range(100):
                        self.wfile.write(junk)
                except OSError:
                    pass
                self.close_connection = True
                return
            return self.reply(200, page(counter[0], dpi[0]), "image/jpeg")
        self.reply(404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        with open("last-settings.xml", "wb") as f:
            f.write(body)
        m = re.search(rb"<scan:XResolution>(\d+)<", body)
        dpi[0] = int(m.group(1)) if m else 300
        if self.path != "/eSCL/ScanJobs":
            return self.reply(404)
        if os.path.exists("asleep"):
            return self.reply(503)
        counter[0] += 1
        self.reply(201, extra=[
            ("Location", f"http://wrong-host/eSCL/ScanJobs/job{counter[0]}")
        ])

    def do_DELETE(self):
        self.reply(200)


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
