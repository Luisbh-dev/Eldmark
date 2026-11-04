"""Une, lado a lado, las capturas de antes y de después de una carpeta de áreas del banco.

Uso: python tools/quality/compare_pairs.py <carpeta_antes> <carpeta_despues> <carpeta_salida> [--width 1920]

Recorre los PNG de <carpeta_despues> (con la misma estructura que <carpeta_antes>) y escribe, por cada
pareja, una imagen con ANTES a la izquierda y DESPUÉS a la derecha. Cada mitad mide la mitad del ancho
pedido, con el mismo encuadre, para poder usarlas tal cual en un vídeo comparativo.
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
