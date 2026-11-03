#!/usr/bin/env python3
"""Compone las comparativas "antes / ahora" del torreón del fuerte (ART-57) y las hojas de contactos
del modelo solo, a partir de las capturas de tools/render/*.gd.

Uso, desde la raíz del repo (necesita Pillow):

    python tools/blender/compose_fort_keep_comparison.py [carpeta_build]

Por defecto la carpeta es build/torreon (la que usan las herramientas de render). Lee, de esa
carpeta, antes/ y camaras_antes/ (la torre original de 6 x 6 m), v1_despues/ y v1_camaras_despues/
(la primera versión del torreón, ya sin ellas se omite la columna) y despues/, camaras_despues/ y
modelo/ (la versión actual), y escribe en comparativas/ un PNG por vista con las columnas
(original | primera versión | actual) y las hojas del modelo solo.
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
	f = font(30)
	box = draw.textbbox((0, 0), text, font=f)
	w, h = box[2] - box[0] + 24, box[3] - box[1] + 18
	draw.rectangle([14, 14, 14 + w, 14 + h], fill=(0, 0, 0))
	draw.text((26, 18), text, fill=(255, 255, 255), font=f)
	return image


def compare(columns: list, out_path: str) -> bool:
	"""columns: lista de (ruta, etiqueta). Las que no existen se omiten; hace falta al menos la última."""
	found = [(p, t) for p, t in columns if os.path.exists(p)]
	if not found or found[-1][0] != columns[-1][0]:
		return False
	images = [Image.open(p).convert("RGB") for p, _t in found]
	cell_w = 1920 // len(images) if len(images) > 2 else 960
	cell_h = images[0].height * cell_w // images[0].width
	sheet = Image.new("RGB", (cell_w * len(images) + 6 * (len(images) - 1), cell_h), (255, 255, 255))
	for i, ((_p, text), image) in enumerate(zip(found, images)):
		sheet.paste(label(image.resize((cell_w, cell_h), Image.LANCZOS), text), (i * (cell_w + 6), 0))
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
		cols = [(os.path.join(BUILD, "camaras_antes", name + ".png"), "ORIGINAL: torre 6 x 6"),
				(os.path.join(BUILD, "v1_camaras_despues", name + ".png"), "PRIMERA VERSION"),
				(os.path.join(BUILD, "camaras_despues", name + ".png"), "AHORA")]
		done += compare(cols, os.path.join(OUT, "camara_" + name + ".png"))
	for name in PLAYER_PAIRS:
		cols = [(os.path.join(BUILD, "antes", name + ".png"), "ORIGINAL: torre 6 x 6"),
				(os.path.join(BUILD, "v1_despues", name + ".png"), "PRIMERA VERSION"),
				(os.path.join(BUILD, "despues", name + ".png"), "AHORA")]
		done += compare(cols, os.path.join(OUT, "jugador_" + name + ".png"))
	modelo = os.path.join(BUILD, "modelo")
	old = os.path.join(BUILD, "v1_modelo")
	# la primera versión frente a la actual desde el mismo ángulo
	for name in ("vuelta_1_suroeste", "detalle_base_esquina", "detalle_puerta", "detalle_cadalso", "aerea"):
		cols = [(os.path.join(old, name + ".png"), "PRIMERA VERSION"), (os.path.join(modelo, name + ".png"), "AHORA")]
		if os.path.exists(cols[0][0]) and os.path.exists(cols[1][0]):
			a = Image.open(cols[0][0]).convert("RGB").resize((800, 600), Image.LANCZOS)
			b = Image.open(cols[1][0]).convert("RGB").resize((800, 600), Image.LANCZOS)
			sheet = Image.new("RGB", (1606, 600), (255, 255, 255))
			sheet.paste(label(a, cols[0][1]), (0, 0))
			sheet.paste(label(b, cols[1][1]), (806, 0))
			sheet.save(os.path.join(OUT, "modelo_antes_ahora_" + name + ".png"))
			done += 1
	contact_sheet(["vuelta_%d_%s" % (i, n) for i, n in enumerate(["oeste", "suroeste", "sur", "sureste", "este", "noreste", "norte", "noroeste"])],
			modelo, os.path.join(OUT, "modelo_vuelta.png"), 4, (640, 480))
	contact_sheet(["detalle_puerta", "detalle_puerta_frente", "detalle_cadalso", "detalle_remate", "detalle_base_esquina",
			"detalle_ventanas", "detalle_estandarte", "detalle_pendon", "detalle_base_esquina_rasante"], modelo,
			os.path.join(OUT, "modelo_detalles.png"), 3, (640, 480))
	contact_sheet(["reino_eldrun", "reino_vardheim", "reino_solmarch", "reino_askarra"], modelo,
			os.path.join(OUT, "modelo_reinos.png"), 2, (800, 600))
	contact_sheet(["reino_eldrun_brasas", "reino_vardheim_base", "reino_solmarch_base", "reino_askarra_base"], modelo,
			os.path.join(OUT, "modelo_reinos_base.png"), 2, (800, 600))
	contact_sheet(["vuelta_1_suroeste", "lod1_suroeste", "lod2_suroeste", "colision_suroeste"], modelo,
			os.path.join(OUT, "modelo_lod_colision.png"), 2, (800, 600))
	contact_sheet(["lodfade_40m", "lodfade_50m", "lodfade_58m", "dist_10m", "dist_30m", "dist_60m"], modelo,
			os.path.join(OUT, "modelo_distancias.png"), 3, (640, 480))
	print("%d comparativas en %s" % (done, OUT))


if __name__ == "__main__":
	main()
