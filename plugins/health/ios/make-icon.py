#!/usr/bin/env python3
"""Build the iOS icon from the Mac app's artwork.

🛑 ONE PICTURE, IN ONE PLACE: the apple glyph and the gradient come from
app/Icon/AppIcon.png, the padded Mac icon, so the two apps stay one family.
Only the words and a heart are drawn here. iOS wants a single 1024x1024
opaque PNG and masks the corners itself, so the plate's rounded corners
are not kept: the square is filled with the plate's own vertical gradient.

    ./make-icon.py     # rewrites Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
import os
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "..", "app", "Icon", "AppIcon.png")
OUT = os.path.join(HERE, "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")
CREAM = (243, 238, 226, 255)
RED = (236, 92, 104, 255)

src = Image.open(SOURCE).convert("RGBA")
# The Mac icon is the 824-wide plate padded to 1024. Scale the plate to
# overshoot the square, so the sampled gradient runs edge to edge.
plate = src.crop((100, 100, 924, 924)).resize((1086, 1086), Image.LANCZOS)
off = -31
canvas = Image.new("RGBA", (1024, 1024))
draw = ImageDraw.Draw(canvas)
for y in range(1024):
    py = min(1085, max(0, y - off))
    c = plate.getpixel((200, py))          # a column with no glyph and no text
    if c[3] < 255:                          # a rounded corner: use the centre column
        c = plate.getpixel((543, py))
    draw.line([(0, y), (1024, y)], fill=c[:3] + (255,))

# The glyph, pasted through a mask of "differs from the background", so
# the plate's slight vignette does not draw a box around it.
box = (330, 170, 700, 580)
glyph = plate.crop((box[0] - off, box[1] - off, box[2] - off, box[3] - off)).convert("RGB")
bg = canvas.crop(box).convert("RGB")
mask = (ImageChops.difference(glyph, bg).convert("L")
        .point(lambda v: 255 if v > 24 else 0)
        .filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.8)))
canvas.paste(glyph, box[:2], mask)

font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 126, index=0)


def word(text, y, fill, spacing=22):
    widths = [draw.textlength(ch, font=font) for ch in text]
    x = (1024 - sum(widths) - spacing * (len(text) - 1)) / 2
    for ch, w in zip(text, widths):
        draw.text((x, y), ch, font=font, fill=fill)
        x += w + spacing


word("APPLE", 650, CREAM)
word("HEALTH", 790, RED)

cx, cy, s = 612, 470, 70
heart = [(0.5, 0.95), (0.05, 0.45), (0.05, 0.25), (0.2, 0.08), (0.38, 0.1),
         (0.5, 0.25), (0.62, 0.1), (0.8, 0.08), (0.95, 0.25), (0.95, 0.45)]
draw.polygon([(cx - s / 2 + px * s, cy - s / 2 + py * s) for px, py in heart], fill=RED)
draw.ellipse((cx - s / 2 - 2, cy - s / 2 + 2, cx - 2, cy - s / 2 + s * 0.5), fill=RED)
draw.ellipse((cx + 2, cy - s / 2 + 2, cx + s / 2 + 2, cy - s / 2 + s * 0.5), fill=RED)
canvas.convert("RGB").save(OUT)
print("wrote", os.path.relpath(OUT, HERE))
