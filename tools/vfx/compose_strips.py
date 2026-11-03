#!/usr/bin/env python3
"""Une los fotogramas que graba la vista previa (scenes/tests/vfx_preview.tscn) en hojas de 4 x 3.

La vista previa guarda, por efecto, `<carpeta>/<efecto>/frame_NN.png` (recortes alrededor del efecto) y un
`meta.json` con el tiempo de cada fotograma. Este script los pega en `<carpeta>/strip_<efecto>.png`, de
1920 x 1080, con el tiempo escrito en cada casilla. Uso, desde la raíz del proyecto:

    python tools/vfx/compose_strips.py [carpeta] [efecto ...]

Por defecto recorre build/vfx/strips y compone todos los efectos que encuentra. Con --realms compone
además `realms_<efecto>.png`: el mismo fotograma de cada reino (carpetas `<efecto>_r1` a `<efecto>_r4`)
una al lado de otra. Con --summary compone `resumen.png`, un fotograma representativo de cada efecto.
"""

import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "..", "..", "build", "vfx", "strips")
COLUMNS = 4
ROWS = 3
# Casilla según el recorte guardado: 4:3 con la cámara de demostración, 16:9 con la del juego.
CELL_DEMO = (480, 360)
CELL_GAME = (640, 360)
BACKGROUND = (18, 18, 22)


def cell_for(frame_size):
	"""Tamaño de casilla de una hoja según la proporción de sus fotogramas."""
	return CELL_GAME if abs(frame_size[0] / frame_size[1] - 16 / 9) < 0.05 else CELL_DEMO


def load_font(size):
	try:
		return ImageFont.load_default(size=size)
	except TypeError:
		return ImageFont.load_default()


def label(draw, xy, text, font):
	x, y = xy
	box = draw.textbbox((x, y), text, font=font)
	draw.rectangle((box[0] - 6, box[1] - 3, box[2] + 6, box[3] + 3), fill=(0, 0, 0))
	draw.text((x, y), text, fill=(235, 235, 235), font=font)


def compose(folder, name):
	source = os.path.join(folder, name)
	with open(os.path.join(source, "meta.json"), encoding="utf-8") as handle:
		meta = json.load(handle)
	times = meta["times"]
	font = load_font(20)
	first = Image.open(os.path.join(source, "frame_00.png"))
	columns, rows, cell = COLUMNS, ROWS, cell_for(first.size)
	if meta.get("strip") == "showcase":
		# Pantallas completas (16:9): 2 x 2 de 960 x 540.
		columns, rows, cell = 2, 2, (960, 540)
	sheet = Image.new("RGB", (columns * cell[0], rows * cell[1]), BACKGROUND)
	draw = ImageDraw.Draw(sheet)
	for index in range(min(len(times), columns * rows)):
		path = os.path.join(source, "frame_%02d.png" % index)
		if not os.path.exists(path):
			continue
		frame = Image.open(path).convert("RGB").resize(cell, Image.LANCZOS)
		x = (index % columns) * cell[0]
		y = (index // columns) * cell[1]
		sheet.paste(frame, (x, y))
		label(draw, (x + 10, y + 8), "t = %.3f s" % times[index], font)
		draw.rectangle((x, y, x + cell[0] - 1, y + cell[1] - 1), outline=(40, 40, 48))
	label(draw, (10, rows * cell[1] - 34), name, load_font(22))
	out = os.path.join(folder, "strip_%s.png" % name)
	sheet.save(out)
	print(out)
	return out


def compose_realms(folder, name, picks):
	"""Una fila con el mismo fotograma de cada reino (carpetas name_r1 a name_r4)."""
	font = load_font(22)
	probe = os.path.join(folder, "%s_r1" % name, "frame_%02d.png" % picks[0])
	cell = cell_for(Image.open(probe).size) if os.path.exists(probe) else CELL_DEMO
	sheet = Image.new("RGB", (cell[0] * 4, cell[1] * len(picks)), BACKGROUND)
	draw = ImageDraw.Draw(sheet)
	names = {1: "Vardheim", 2: "Solmarch", 3: "Askarra", 4: "Eldrun"}
	for row, pick in enumerate(picks):
		for column, realm in enumerate((1, 2, 3, 4)):
			path = os.path.join(folder, "%s_r%d" % (name, realm), "frame_%02d.png" % pick)
			if not os.path.exists(path):
				continue
			frame = Image.open(path).convert("RGB").resize(cell, Image.LANCZOS)
			sheet.paste(frame, (column * cell[0], row * cell[1]))
			if row == 0:
				label(draw, (column * cell[0] + 10, 8), names[realm], font)
	out = os.path.join(folder, "realms_%s.png" % name)
	sheet.save(out)
	print(out)


# Hoja de resumen: un fotograma representativo de cada efecto, [carpeta, fotograma, rótulo].
SUMMARY = (
	("metal_side", 4, "Chispa de metal (de perfil)"),
	("flesh", 4, "Impacto en carne"),
	("cloth", 4, "Impacto en tela"),
	("block", 4, "Bloqueo en escudo de madera"),
	("parry", 3, "Parada perfecta"),
	("dust", 4, "Polvo de aterrizaje"),
	("dodge", 4, "Polvo de esquiva"),
	("trail_r1", 8, "Estela - Vardheim"),
	("trail_r4", 8, "Estela - Eldrun"),
	("aura_r2", 4, "Aura de carga - Solmarch"),
	("aura_r2", 5, "Aura: carga completa"),
	("melee", 3, "Refriega: diez efectos a la vez"),
)


def compose_summary(folder):
	columns, rows = 4, 3
	font = load_font(20)
	cell = CELL_DEMO
	for name, pick, title in SUMMARY:
		path = os.path.join(folder, name, "frame_%02d.png" % pick)
		if os.path.exists(path):
			cell = cell_for(Image.open(path).size)
			break
	sheet = Image.new("RGB", (columns * cell[0], rows * cell[1]), BACKGROUND)
	draw = ImageDraw.Draw(sheet)
	for index, (name, pick, title) in enumerate(SUMMARY):
		path = os.path.join(folder, name, "frame_%02d.png" % pick)
		if not os.path.exists(path):
			continue
		frame = Image.open(path).convert("RGB")
		# Un fotograma de otra proporción se recorta al centro para llenar la casilla.
		target = cell[0] / cell[1]
		if abs(frame.size[0] / frame.size[1] - target) > 0.05:
			if frame.size[0] / frame.size[1] > target:
				width = int(frame.size[1] * target)
				left = (frame.size[0] - width) // 2
				frame = frame.crop((left, 0, left + width, frame.size[1]))
			else:
				height = int(frame.size[0] / target)
				top = (frame.size[1] - height) // 2
				frame = frame.crop((0, top, frame.size[0], top + height))
		frame = frame.resize(cell, Image.LANCZOS)
		x = (index % columns) * cell[0]
		y = (index // columns) * cell[1]
		sheet.paste(frame, (x, y))
		label(draw, (x + 10, y + cell[1] - 36), title, font)
		draw.rectangle((x, y, x + cell[0] - 1, y + cell[1] - 1), outline=(40, 40, 48))
	out = os.path.join(folder, "resumen.png")
	sheet.save(out)
	print(out)


def main():
	args = [a for a in sys.argv[1:] if not a.startswith("--")]
	folder = args[0] if args else DEFAULT_DIR
	only = args[1:]
	for entry in sorted(os.listdir(folder)):
		if only and entry not in only:
			continue
		if os.path.exists(os.path.join(folder, entry, "meta.json")):
			compose(folder, entry)
	if "--summary" in sys.argv:
		compose_summary(folder)
	if "--realms" in sys.argv:
		for name, picks in (("trail", (6, 8, 10)), ("aura", (4, 5, 9))):
			compose_realms(folder, name, picks=picks)


if __name__ == "__main__":
	main()
