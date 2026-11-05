"""Joins, side by side, the before and after captures of a folder of bench areas.

Usage: python tools/quality/compare_pairs.py <before_folder> <after_folder> <output_folder> [--width 1920]

Walks the PNGs of <after_folder> (with the same structure as <before_folder>) and writes, for each
pair, an image with the label "ANTES" (before) on the left and "DESPUÉS" (after) on the right. Each half is half the requested
width, with the same framing, so they can be used as they are in a comparison video.
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def label(image: Image.Image, text: str) -> None:
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("arial.ttf", max(18, image.width // 32))
    except OSError:
        font = ImageFont.load_default()
    box = draw.textbbox((12, 10), text, font=font)
    draw.rectangle((box[0] - 8, box[1] - 6, box[2] + 8, box[3] + 6), fill=(0, 0, 0, 170))
    draw.text((12, 10), text, fill=(255, 255, 255), font=font)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("antes")
    parser.add_argument("despues")
    parser.add_argument("salida")
    parser.add_argument("--width", type=int, default=1920)
    args = parser.parse_args()
    before_root = Path(args.antes)
    after_root = Path(args.despues)
    out_root = Path(args.salida)
    half = args.width // 2
    count = 0
    for after in sorted(after_root.rglob("*.png")):
        relative = after.relative_to(after_root)
        before = before_root / relative
        if not before.exists():
            continue
        a = Image.open(before).convert("RGB")
        b = Image.open(after).convert("RGB")
        height = round(half * a.height / a.width)
        a = a.resize((half, height), Image.LANCZOS)
        b = b.resize((half, height), Image.LANCZOS)
        label(a, "ANTES")
        label(b, "DESPUÉS")
        sheet = Image.new("RGB", (half * 2, height))
        sheet.paste(a, (0, 0))
        sheet.paste(b, (half, 0))
        target = out_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(target)
        count += 1
    print(f"{count} comparativas en {out_root}")


if __name__ == "__main__":
    main()
