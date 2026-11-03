#!/usr/bin/env python3
"""Hoja de contactos de las texturas de efectos (revisión visual, no entra en el juego).

    python tools/vfx/contact_sheet.py [carpeta_de_salida]

Pinta las máscaras de luz en gris y las de forma sobre un fondo oscuro. Por defecto escribe
build/vfx/tex_sheet.png.
"""

import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TEX_DIR = os.path.join(HERE, "..", "..", "scenes", "vfx", "textures")
LIGHT_MASKS = ("soft_dot", "flare_star", "spark_streak", "wisp", "rays")
CELL = 230


def main():
	out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "build", "vfx")
	os.makedirs(out_dir, exist_ok=True)
	names = sorted(f[:-4] for f in os.listdir(TEX_DIR) if f.endswith(".png"))
	columns = 6
	rows = (len(names) + columns - 1) // columns
	sheet = Image.new("RGB", (columns * (CELL + 10) + 10, rows * (CELL + 10) + 10), (22, 22, 26))
	for index, name in enumerate(names):
		image = Image.open(os.path.join(TEX_DIR, name + ".png")).convert("RGBA")
		background = Image.new("RGBA", image.size, (52, 58, 70, 255))
		if name in LIGHT_MASKS:
			red = image.split()[0]
			tile = Image.merge("RGB", (red, red, red))
		elif name == "noise":
			tile = image.convert("RGB")
		else:
			tile = Image.alpha_composite(background, image).convert("RGB")
		scale = CELL / max(tile.size)
		tile = tile.resize((max(1, int(tile.size[0] * scale)), max(1, int(tile.size[1] * scale))),
				Image.LANCZOS)
		x = 10 + (index % columns) * (CELL + 10) + (CELL - tile.size[0]) // 2
		y = 10 + (index // columns) * (CELL + 10) + (CELL - tile.size[1]) // 2
		sheet.paste(tile, (x, y))
	path = os.path.join(out_dir, "tex_sheet.png")
	sheet.save(path)
	print(path)


if __name__ == "__main__":
	main()
