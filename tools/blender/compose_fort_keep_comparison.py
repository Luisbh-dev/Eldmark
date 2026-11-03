#!/usr/bin/env python3
"""Compone las comparativas "antes / después" del torreón del fuerte (ART-57) y las hojas de
contactos del modelo solo, a partir de las capturas de tools/render/*.gd.

Uso, desde la raíz del repo (necesita Pillow):

    python tools/blender/compose_fort_keep_comparison.py [carpeta_build]

Por defecto la carpeta es build/torreon (la que usan las herramientas de render). Lee
camaras_antes/, camaras_despues/, antes/, despues/ y modelo/, y escribe en comparativas/ un PNG
por pareja (izquierda, torreón actual; derecha, torreón nuevo) y las hojas del modelo.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BUILD = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, "build", "torreon")
OUT = os.path.join(BUILD, "comparativas")

CAMERA_PAIRS = ["fuerte_de_cerca", "puerta_del_fuerte", "vista_aerea", "vista_desde_puerta_vardheim",
		"vista_desde_puerta_solmarch", "puente_norte", "vado", "campamento_solmarch"]
PLAYER_PAIRS = ["01_campamento_spawn", "09_puente_entrada", "10_puente_centro", "11_puente_desde_la_orilla",
		"13_ladera_del_fuerte", "14_fuerte_esquina_exterior", "15_fuerte_puerta_lejos", "16_fuerte_puerta_cerca",
		"17_fuerte_patio", "18_fuerte_torre", "19_fuerte_circulo_de_captura", "20_fuerte_patio_hacia_la_puerta",
		"22_fuerte_rampa_norte", "24_vado_centro", "25_vado_desde_el_oeste", "31_capilla"]


def font(size: int) -> ImageFont.ImageFont:
	for name in ("arialbd.ttf", "arial.ttf", "DejaVuSans-Bold.ttf"):
		try:
			return ImageFont.truetype(name, size)
		except OSError:
			continue
	return ImageFont.load_default()


def label(image: Image.Image, text: str) -> Image.Image:
	draw = ImageDraw.Draw(image)
	f = font(34)
	box = draw.textbbox((0, 0), text, font=f)
	w, h = box[2] - box[0] + 24, box[3] - box[1] + 18
	draw.rectangle([14, 14, 14 + w, 14 + h], fill=(0, 0, 0))
	draw.text((26, 18), text, fill=(255, 255, 255), font=f)
	return image


def pair(before_path: str, after_path: str, out_path: str) -> bool:
	if not (os.path.exists(before_path) and os.path.exists(after_path)):
		return False
	a = Image.open(before_path).convert("RGB")
	b = Image.open(after_path).convert("RGB")
	half = (a.width // 2, a.height // 2)
	a = label(a.resize(half, Image.LANCZOS), "ANTES: torre actual")
	b = label(b.resize(half, Image.LANCZOS), "DESPUES: torreon nuevo")
	sheet = Image.new("RGB", (half[0] * 2 + 6, half[1]), (255, 255, 255))
	sheet.paste(a, (0, 0))
	sheet.paste(b, (half[0] + 6, 0))
	sheet.save(out_path)
	return True


def contact_sheet(names: list, folder: str, out_path: str, columns: int, cell: tuple) -> None:
	rows = (len(names) + columns - 1) // columns
	sheet = Image.new("RGB", (columns * cell[0], rows * cell[1]), (20, 20, 20))
	for i, name in enumerate(names):
		path = os.path.join(folder, name + ".png")
		if not os.path.exists(path):
			continue
		image = Image.open(path).convert("RGB").resize(cell, Image.LANCZOS)
		sheet.paste(image, ((i % columns) * cell[0], (i // columns) * cell[1]))
	sheet.save(out_path)


def main() -> None:
	os.makedirs(OUT, exist_ok=True)
	done = 0
	for name in CAMERA_PAIRS:
		if pair(os.path.join(BUILD, "camaras_antes", name + ".png"), os.path.join(BUILD, "camaras_despues", name + ".png"),
				os.path.join(OUT, "camara_" + name + ".png")):
			done += 1
	for name in PLAYER_PAIRS:
		if pair(os.path.join(BUILD, "antes", name + ".png"), os.path.join(BUILD, "despues", name + ".png"),
				os.path.join(OUT, "jugador_" + name + ".png")):
			done += 1
	modelo = os.path.join(BUILD, "modelo")
	contact_sheet(["vuelta_%d_%s" % (i, n) for i, n in enumerate(["oeste", "suroeste", "sur", "sureste", "este", "noreste", "norte", "noroeste"])],
			modelo, os.path.join(OUT, "modelo_vuelta.png"), 4, (640, 480))
	contact_sheet(["detalle_puerta", "detalle_puerta_frente", "detalle_cadalso", "detalle_remate", "detalle_base_esquina",
			"detalle_ventanas"], modelo, os.path.join(OUT, "modelo_detalles.png"), 3, (640, 480))
	contact_sheet(["reino_vardheim", "vuelta_1_suroeste", "reino_solmarch"], modelo, os.path.join(OUT, "modelo_reinos.png"), 3, (640, 480))
	contact_sheet(["vuelta_1_suroeste", "lod1_suroeste", "colision_suroeste", "aerea"], modelo,
			os.path.join(OUT, "modelo_lod_colision.png"), 2, (800, 600))
	print("%d comparativas en %s" % (done, OUT))


if __name__ == "__main__":
	main()
