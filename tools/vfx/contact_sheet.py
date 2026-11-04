#!/usr/bin/env python3
"""Contact sheet of the effect textures (visual review, does not go into the game).

    python tools/vfx/contact_sheet.py [output_folder]

Paints each texture the way its shader reads it: light masks in gray, shape masks on a dark
background, and those that carry data in the channels (puffs, blood jets, wood planks) already interpreted,
with a test color. By default it writes build/vfx/tex_sheet.png.
"""

import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TEX_DIR = os.path.join(HERE, "..", "..", "scenes", "vfx", "textures")
LIGHT_MASKS = ("soft_dot", "flare_star", "spark_streak", "rays")
CELL = 230
BACKGROUND = (52, 58, 70)


def over_background(rgba_array):
	"""Composes a float array (h, w, 4) over the sheet background."""
	background = np.zeros(rgba_array.shape[:2] + (3,)) + np.array(BACKGROUND) / 255.0
	alpha = rgba_array[..., 3:4]
	rgb = rgba_array[..., :3] * alpha + background * (1.0 - alpha)
	return Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8), "RGB")


def preview(name, image):
	data = np.asarray(image, dtype=np.float32) / 255.0
	if name in LIGHT_MASKS:
		red = image.split()[0]
		return Image.merge("RGB", (red, red, red))
	if name == "noise":
		return image.convert("RGB")
	if name == "puffs":
		# Approximate interpretation: relief lit from the top left, edge eroded at 25 %.
		height = data[..., 0]
		detail = data[..., 1]
		body = height * (0.7 + 0.6 * (detail - 0.5) * 1.0 + 0.0)
		alpha = np.clip((body - 0.25) / 0.14, 0.0, 1.0)
		gy, gx = np.gradient(height)
		light = np.clip(0.55 + (-gx - gy) * 10.0, 0.25, 1.0)
		color = np.stack([light * 0.85, light * 0.8, light * 0.7, alpha], axis=-1)
		return over_background(color)
	if name == "splat_jets":
		shade = data[..., 0]
		spec = data[..., 1]
		alpha = data[..., 3]
		base = np.stack([shade * 0.55, shade * 0.05, shade * 0.06], axis=-1)
		rgb = np.clip(base + spec[..., None] * np.array([0.7, 0.55, 0.5]), 0, 1)
		return over_background(np.concatenate([rgb, alpha[..., None]], axis=-1))
	if name == "planks":
		shade = data[..., 0]
		fresh = data[..., 1]
		alpha = data[..., 3]
		dark = np.array([0.42, 0.27, 0.15])
		pale = np.array([0.82, 0.64, 0.4])
		base = dark[None, None, :] * (1 - fresh[..., None]) + pale[None, None, :] * fresh[..., None]
		rgb = base * shade[..., None]
		return over_background(np.concatenate([rgb, alpha[..., None]], axis=-1))
	background = Image.new("RGBA", image.size, BACKGROUND + (255,))
	return Image.alpha_composite(background, image).convert("RGB")


def main():
	out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "build", "vfx")
	os.makedirs(out_dir, exist_ok=True)
	names = sorted(f[:-4] for f in os.listdir(TEX_DIR) if f.endswith(".png"))
	columns = 4
	rows = (len(names) + columns - 1) // columns
	sheet = Image.new("RGB", (columns * (CELL + 10) + 10, rows * (CELL + 10) + 10), (22, 22, 26))
	for index, name in enumerate(names):
		image = Image.open(os.path.join(TEX_DIR, name + ".png")).convert("RGBA")
		tile = preview(name, image)
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
