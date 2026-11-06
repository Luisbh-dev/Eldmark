"""Joins three bench runs, side by side: BEFORE (audit) | WAVE 1 | NOW.

Usage: python tools/quality/compare_triple.py <before> <wave1> <now> <output> [--per-area 6] [--width 2400]
         [--areas animacion,mapa,interfaz,mundo,combate]

For each area it walks the PNGs that exist in the three folders (same structure and same framings) and leaves, from each
area, the first <per-area> spread along the list (it always includes the first and the last), with a label
per column. It serves to show the progress of a wave in a video.
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

TITLES = ("ANTES (auditoría)", "OLEADA 1", "AHORA (oleada 2)")


def label(image: Image.Image, text: str) -> None:
	draw = ImageDraw.Draw(image)
	try:
		font = ImageFont.truetype("arial.ttf", max(18, image.width // 22))
	except OSError:
		font = ImageFont.load_default()
	box = draw.textbbox((12, 10), text, font=font)
	draw.rectangle((box[0] - 8, box[1] - 6, box[2] + 8, box[3] + 6), fill=(0, 0, 0))
	draw.text((12, 10), text, fill=(255, 255, 255), font=font)


def spread(items: list, count: int) -> list:
	if len(items) <= count:
		return items
	step = (len(items) - 1) / (count - 1)
	return [items[round(i * step)] for i in range(count)]


def main() -> None:
	parser = argparse.ArgumentParser()
	parser.add_argument("antes")
	parser.add_argument("oleada1")
	parser.add_argument("ahora")
	parser.add_argument("salida")
	parser.add_argument("--per-area", type=int, default=6)
	parser.add_argument("--width", type=int, default=2400)
	parser.add_argument("--areas", default="animacion,mapa,interfaz,mundo,combate")
	parser.add_argument("--titles", default="", help="Three column titles separated by |; defaults to the original ones")
	args = parser.parse_args()
	titles = tuple(args.titles.split("|")) if args.titles else TITLES
	roots = [Path(args.antes), Path(args.oleada1), Path(args.ahora)]
	out_root = Path(args.salida)
	third = args.width // 3
	total = 0
	for area in args.areas.split(","):
		common = []
		for png in sorted((roots[2] / area).rglob("*.png")):
			relative = png.relative_to(roots[2])
			if "raw" in relative.parts or "strips" in relative.parts:
				continue
			if all((root / relative).exists() for root in roots[:2]):
				common.append(relative)
		for relative in spread(common, args.per_area):
			images = [Image.open(root / relative).convert("RGB") for root in roots]
			height = round(third * images[2].height / images[2].width)
			panels = []
			for image, title in zip(images, titles):
				panel = image.resize((third, height), Image.LANCZOS)
				label(panel, title)
				panels.append(panel)
			sheet = Image.new("RGB", (third * 3, height))
			for index, panel in enumerate(panels):
				sheet.paste(panel, (index * third, 0))
			target = out_root / area / ("_".join(relative.parts[1:]) if len(relative.parts) > 1 else relative.name)
			target.parent.mkdir(parents=True, exist_ok=True)
			sheet.save(target.with_suffix(".png"))
			total += 1
	print(f"{total} comparativas en {out_root}")


if __name__ == "__main__":
	main()
