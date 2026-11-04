#!/usr/bin/env python
"""Crops of interface elements from the full captures of the interfaz area.

They are the same pixel regions (at 1920 x 1080) used for the quality audit, so that a before
and an after can be compared on the same framing even if the HUD moves: if an element moves, the crop shows it out of
place and that is exactly what is wanted.

Usage: python crops.py <output>   (reads <output>/interfaz/*.png and writes <output>/interfaz/recorte_*.png)
"""
import os
import sys

from PIL import Image

# (output file, source capture, (x, y, width, height), zoom)
CROPS = [
    ("recorte_barra_de_habilidades_y_vida.png", "hud_en_pelea_05.png", (640, 830, 640, 180), 2),
    ("recorte_numeros_de_dano.png", "hud_en_pelea_02.png", (700, 380, 360, 120), 3),
    ("recorte_placas_de_nombre.png", "hud_en_pelea_02.png", (0, 430, 420, 130), 3),
    ("recorte_barra_de_jefe.png", "barra_de_jefe_01.png", (640, 180, 640, 110), 2),
    ("recorte_panel_captura_fuerte.png", "captura_fuerte_01.png", (940, 40, 460, 120), 3),
    ("recorte_registro_de_bajas.png", "hud_en_pelea_02.png", (1480, 10, 440, 90), 2),
    ("recorte_barra_de_ayuda_inferior.png", "hud_en_pelea_02.png", (160, 1030, 1620, 40), 1),
]


def make_crops(base):
    """Writes the crops whose source captures exist. Returns the names written."""
    folder = os.path.join(base, "interfaz")
    written = []
    for out_name, src_name, (x, y, w, h), scale in CROPS:
        src = os.path.join(folder, src_name)
        if not os.path.exists(src):
            continue
        im = Image.open(src).convert("RGB")
        if im.width != 1920 or im.height != 1080:
            sx, sy = im.width / 1920.0, im.height / 1080.0
            box = (int(x * sx), int(y * sy), int((x + w) * sx), int((y + h) * sy))
        else:
            box = (x, y, x + w, y + h)
        part = im.crop(box)
        if scale != 1:
            part = part.resize((part.width * scale, part.height * scale), Image.LANCZOS)
        part.save(os.path.join(folder, out_name))
        written.append(out_name)
    return written


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    print("\n".join(make_crops(sys.argv[1])))
