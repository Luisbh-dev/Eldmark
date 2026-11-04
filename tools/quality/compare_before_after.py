#!/usr/bin/env python
"""Pone lado a lado las capturas de dos pasadas del banco (antes y después) con los mismos nombres de archivo.

    python tools/quality/compare_before_after.py <carpeta_antes> <carpeta_después> --out <carpeta> [--pattern "pelea_*.png"]
        [--scale 0.5] [--label-before ANTES] [--label-after DESPUÉS] [--max N]

Cada pareja se guarda como `<nombre>.png` en la carpeta de salida con una banda de rótulos arriba. Solo se emparejan los
archivos que existen en las dos carpetas (los mismos encuadres del banco, así que la comparación es directa).
"""
import argparse
import fnmatch
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for name in ("arialbd.ttf", "arial.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def compose(before: Path, after: Path, out: Path, scale: float, label_before: str, label_after: str) -> None:
    left = Image.open(before).convert("RGB")
    right = Image.open(after).convert("RGB")
    if scale != 1.0:
        left = left.resize((int(left.width * scale), int(left.height * scale)), Image.LANCZOS)
        right = right.resize((int(right.width * scale), int(right.height * scale)), Image.LANCZOS)
    height = max(left.height, right.height)
    band = 44
    gap = 6
    sheet = Image.new("RGB", (left.width + right.width + gap, height + band), (14, 14, 18))
    sheet.paste(left, (0, band))
    sheet.paste(right, (left.width + gap, band))
    draw = ImageDraw.Draw(sheet)
    font = load_font(28)
    draw.text((14, 6), label_before, fill=(235, 190, 120), font=font)
    draw.text((left.width + gap + 14, 6), label_after, fill=(140, 215, 150), font=font)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--out", required=True)
    parser.add_argument("--pattern", default="*.png")
    parser.add_argument("--scale", type=float, default=0.5)
    parser.add_argument("--label-before", default="ANTES")
    parser.add_argument("--label-after", default="DESPUÉS")
    parser.add_argument("--max", type=int, default=0, help="como mucho N parejas (0 = todas)")
    args = parser.parse_args()
    before_dir, after_dir, out_dir = Path(args.before), Path(args.after), Path(args.out)
    names = sorted(p.name for p in before_dir.iterdir() if fnmatch.fnmatch(p.name, args.pattern))
    count = 0
    for name in names:
        if not (after_dir / name).exists():
            continue
        compose(before_dir / name, after_dir / name, out_dir / name, args.scale, args.label_before, args.label_after)
        count += 1
        if args.max and count >= args.max:
            break
    print(f"[comparar] {count} parejas en {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
