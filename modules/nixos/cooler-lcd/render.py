"""Render the cooler LCD frames at build time.

Usage: render.py LOGO_PNG LOUSE_PNG TEXT_FONT EMOJI_FONT OUT_DIR

OUT_DIR/logo: the arms alternate two blues, so the logo only repeats every
120 degrees (shape alone: 60): 60 frames 2 degrees apart make a seamless
loop, back to back, frame 0 upright.

OUT_DIR/message-heart, OUT_DIR/message-louse: "I <icon>" over "Joy", at
the largest font size that fits, composed landscape 320x240 as the panel
sits, then turned 90 degrees clockwise onto the portrait raster (checked
upright on som). The icon is a red heart emoji or a head louse drawing,
scaled to the cap height of the text. Noto Color Emoji is a bitmap font
that only renders at size 109.

Each frame is one 512-byte header report followed by 240x320
little-endian RGB565, the format of trlcd_libusb.
"""

import struct
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFont

logo_png, louse_png, text_font, emoji_font, out_dir = sys.argv[1:]

HEADER = bytearray(512)
HEADER[0:4] = bytes([0xDA, 0xDB, 0xDC, 0xDD])
HEADER[4] = 2  # version
HEADER[6] = 1  # command: picture
HEADER[8:12] = struct.pack("<HH", 240, 320)
HEADER[12] = 2  # RGB565
HEADER[22:26] = struct.pack("<I", 240 * 320 * 2)
HEADER[29] = 8


def encode(canvas):
    # The panel shows the raster 5 px too high (landscape) and wraps the
    # overflow to the bottom (measured on som); roll it back. Landscape
    # down is raster left: the raster is landscape turned clockwise.
    rgb = ImageChops.offset(canvas, -5, 0).tobytes()
    return bytes(HEADER) + b"".join(
        struct.pack("<H", (r >> 3) << 11 | (g >> 2) << 5 | b >> 3)
        for r, g, b in zip(rgb[0::3], rgb[1::3], rgb[2::3])
    )


def render_logo():
    logo = Image.open(logo_png).convert("RGBA")
    # Juicier blues than the stock logo: more saturated and a bit brighter.
    # Enhancing the RGB bands only keeps the alpha edges intact.
    rgb = ImageEnhance.Color(logo.convert("RGB")).enhance(1.4)
    rgb = ImageEnhance.Brightness(rgb).enhance(1.15)
    logo = Image.merge("RGBA", (*rgb.split(), logo.getchannel("A")))
    with open(f"{out_dir}/logo", "wb") as out:
        for step in range(60):
            # Negative: Pillow turns counter-clockwise, spin clockwise.
            turned = logo.rotate(-2 * step, Image.BICUBIC)
            # The tips sit on a circle as wide as the SVG canvas, so 240
            # (the short side) is the largest that never clips.
            turned = turned.resize((240, 240), Image.LANCZOS)
            canvas = Image.new("RGB", (240, 320))
            canvas.paste(turned, (0, 40), turned)
            out.write(encode(canvas))


def render_message(name, icon):
    W, H, MARGIN = 320, 240, 6

    def layout(size):
        font = ImageFont.truetype(text_font, size)
        i_box, joy_box = font.getbbox("I"), font.getbbox("Joy")
        cap = i_box[3] - i_box[1]
        icon_w = round(cap * icon.width / icon.height)
        gap, line_gap = size // 6, size // 8
        line1 = i_box[2] - i_box[0] + gap + icon_w
        line2 = joy_box[2] - joy_box[0]
        height = cap + line_gap + joy_box[3] - joy_box[1]
        fits = (max(line1, line2) <= W - 2 * MARGIN
                and height <= H - 2 * MARGIN)
        return (fits, font, i_box, joy_box, cap, icon_w, gap, line_gap,
                line1, line2, height)

    size = 20
    while layout(size + 1)[0]:
        size += 1
    (_, font, i_box, joy_box, cap, icon_w, gap, line_gap,
     line1, line2, height) = layout(size)

    canvas = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(canvas)
    top = (H - height) // 2
    x = (W - line1) // 2
    draw.text((x - i_box[0], top - i_box[1]), "I", font=font, fill="white")
    scaled = icon.resize((icon_w, cap), Image.LANCZOS)
    canvas.paste(scaled, (x + i_box[2] - i_box[0] + gap, top), scaled)
    draw.text(
        ((W - line2) // 2 - joy_box[0], top + cap + line_gap - joy_box[1]),
        "Joy",
        font=font,
        fill="white",
    )
    with open(f"{out_dir}/message-{name}", "wb") as out:
        out.write(encode(canvas.rotate(-90, expand=True)))


def heart():
    image = Image.new("RGBA", (160, 160))
    ImageDraw.Draw(image).text(
        (0, 0),
        "\u2764\ufe0f",
        font=ImageFont.truetype(emoji_font, 109),
        embedded_color=True,
    )
    return image.crop(image.getbbox())


def louse():
    image = Image.open(louse_png).convert("RGBA")
    return image.crop(image.getchannel("A").getbbox())


render_logo()
render_message("heart", heart())
render_message("louse", louse())
