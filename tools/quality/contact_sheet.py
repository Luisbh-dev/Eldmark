#!/usr/bin/env python
"""Contact sheet: joins the PNGs of a folder into a single image with their names, to review them at a glance.

Usage: python contact_sheet.py <folder> <output.png> [columns=4] [cell_width=480] [from-to]
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    folder, out = argv[1], argv[2]
    cols = int(argv[3]) if len(argv) > 3 else 4
    tw = int(argv[4]) if len(argv) > 4 else 480
    files = sorted(f for f in os.listdir(folder) if f.lower().endswith(".png"))
    if len(argv) > 5:
        a, b = [int(x) for x in argv[5].split("-")]
        files = files[a:b]
    try:
        font = ImageFont.truetype("arial.ttf", 14)
    except OSError:
        font = ImageFont.load_default()
    ims = []
    for f in files:
        im = Image.open(os.path.join(folder, f)).convert("RGB")
        th = int(im.height * tw / im.width)
        ims.append((f, im.resize((tw, th))))
    if not ims:
        print("no hay imágenes en", folder)
        return 1
    th = max(i.height for _, i in ims)
    rows = (len(ims) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * tw, rows * (th + 18)), (20, 20, 20))
    dr = ImageDraw.Draw(sheet)
    for i, (f, im) in enumerate(ims):
        x, y = (i % cols) * tw, (i // cols) * (th + 18)
        sheet.paste(im, (x, y + 18))
        dr.text((x + 3, y + 1), f[:-4], fill=(255, 255, 255), font=font)
    sheet.save(out)
    print(out, sheet.size)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
