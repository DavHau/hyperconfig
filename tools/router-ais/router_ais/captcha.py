"""OCR for the F6107A login captcha.

The captcha is a 70x20 JPEG: six characters of a fixed 8x14 pixel font, blue on
near-white, on a 9px pitch starting at x=5, no distortion or noise. Every glyph
is therefore matched exactly against the bitmaps in `glyphs.py`. If a cell does
not match any known glyph (e.g. a firmware update changes the font) the whole
image falls back to tesseract; the login loop retries on misreads either way.
"""

import io
import re

import pytesseract
from PIL import Image, ImageFilter, ImageOps

from .glyphs import GLYPHS

CELL_X0, CELL_PITCH, CELL_W = 5, 9, 8
CELL_Y0, CELL_H = 4, 14
CHARS = 6
INK_THRESHOLD = 60  # blue minus red channel
MAX_HAMMING = 2  # nearest known glyph must be within this many pixels

_TEMPLATES = {ch: [c == "1" for c in bits] for ch, bits in GLYPHS.items()}


def _cells(im: Image.Image) -> list[list[bool]]:
    px = im.convert("RGB").load()
    cells = []
    for i in range(CHARS):
        x0 = CELL_X0 + i * CELL_PITCH
        cells.append(
            [
                px[x, y][2] - px[x, y][0] > INK_THRESHOLD
                for y in range(CELL_Y0, CELL_Y0 + CELL_H)
                for x in range(x0, x0 + CELL_W)
            ]
        )
    return cells


def match_glyphs(data: bytes) -> str | None:
    im = Image.open(io.BytesIO(data))
    if im.size != (70, 20):
        return None
    out = []
    for cell in _cells(im):
        best, best_d = None, MAX_HAMMING + 1
        for ch, tpl in _TEMPLATES.items():
            d = sum(a != b for a, b in zip(cell, tpl))
            if d < best_d:
                best, best_d = ch, d
        if best is None:
            return None
        out.append(best)
    return "".join(out)


_WHITELIST = "".join(sorted(GLYPHS))


def tesseract(data: bytes) -> str:
    im = Image.open(io.BytesIO(data)).convert("L")
    im = im.resize((im.width * 4, im.height * 4), Image.LANCZOS)
    im = im.filter(ImageFilter.GaussianBlur(1.0))
    im = im.point(lambda p: 255 if p > 180 else 0)
    im = ImageOps.expand(im, border=20, fill=255)
    text = pytesseract.image_to_string(im, config=f"--psm 7 --oem 1 -c tessedit_char_whitelist={_WHITELIST}")
    return re.sub(r"[^A-Za-z0-9]", "", text)


def solve(data: bytes) -> tuple[str, str]:
    """Return (code, method)."""
    code = match_glyphs(data)
    if code is not None:
        return code, "glyphs"
    return tesseract(data), "tesseract"
