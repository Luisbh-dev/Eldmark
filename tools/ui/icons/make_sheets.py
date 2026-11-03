#!/usr/bin/env python3
"""Genera las láminas de muestra de los iconos de la interfaz (ART-12) a partir de sus PNG.

  muestra_iconos.png            todos los iconos a 64, 48 y 32 px sobre fondo oscuro y sobre fondo claro,
                                agrupados por categoría.
  muestra_barra_habilidades.png la barra de acciones del HUD de combate con los iconos puestos: arriba la
                                captura de referencia con las letras de hoy, y debajo la misma barra con
                                los iconos de espada y escudo y con los del arco.

Los PNG de entrada son los de 128 px de `rasterize_icons.gd`; los tamaños pequeños salen de reducirlos
con Lanczos, que es lo que hará el motor al dibujarlos en una casilla. La captura de referencia es
opcional (con `--hud`); sin ella la barra se pinta sobre un fondo de tierra sintético con la misma
geometría. Las salidas van a build/iconos (Git las ignora).

Uso, desde la raíz del proyecto:

    python3 tools/ui/icons/make_sheets.py [--png assets/ui/icons/png] [--out build/iconos] [--hud captura.png]
"""

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import glyphs  # noqa: E402
import svgkit  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CATEGORY_ORDER = ["ataque", "defensa", "habilidad", "consumible", "estado", "mundo"]

DARK_BG = (21, 23, 29)
LIGHT_BG = (222, 216, 200)

# Barra de acciones del HUD de combate tal como sale en hud_en_pelea_03.png (1920 x 1080): esquina
# superior izquierda de cada casilla, su alto y el rótulo de tecla de cada una.
BAR_SLOT_X = [671, 729, 787, 867, 925, 983, 1063, 1121, 1201]
BAR_SLOT_Y = 841
BAR_SLOT_SIZE = 53
BAR_KEYS = ["Clic izq.", "Clic der.", "Ctrl", "1", "2", "3", "R", "T", "Q"]
BAR_SWORD = ["sword_light", "block", "dodge", "shield_bash", "shield_rush", "shield_wall",
             "potion_health", "potion_stamina", "swap_weapon"]
BAR_BOW = ["bow_quick", "bow_drawn", "dodge", "bow_volley", "bow_slowing_shot", "bow_evasive_shot",
           "potion_health", "potion_stamina", "swap_weapon"]
BAR_COUNTS = {"potion_health": 6, "potion_stamina": 5}
BAR_CROP = (600, 800, 1320, 925)  # zona de la captura que se enseña, a la escala del juego


def load_font(size, bold=False):
    names = ["segoeuib.ttf", "arialbd.ttf"] if bold else ["segoeui.ttf", "arial.ttf"]
    for name in names:
        for folder in ("C:/Windows/Fonts", "/usr/share/fonts/truetype/dejavu", "/Library/Fonts"):
            path = os.path.join(folder, name)
            if os.path.exists(path):
                return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def load_icon(png_dir, name):
    return Image.open(os.path.join(png_dir, name + ".png")).convert("RGBA")


def sized(image, side):
    return image.resize((side, side), Image.LANCZOS)


def grouped_names():
    groups = {cat: [] for cat in CATEGORY_ORDER}
    for name, (category, _title, _builder) in glyphs.ICONS.items():
        groups[category].append(name)
    return groups


def draw_panel(png_dir, background, text_color, heading, cols=6):
    """Un panel con todos los iconos a 64, 48 y 32 px agrupados por categoría."""
    font_small = load_font(11)
    font_head = load_font(15, bold=True)
    font_title = load_font(17, bold=True)
    cell_w, cell_h, pad = 188, 92, 14
    groups = grouped_names()
    # medir
    height = 44
    for cat in CATEGORY_ORDER:
        rows = (len(groups[cat]) + cols - 1) // cols
        height += 30 + rows * cell_h
    height += pad
    width = pad * 2 + cols * cell_w
    panel = Image.new("RGBA", (width, height), background + (255,))
    draw = ImageDraw.Draw(panel)
    draw.text((pad, 12), heading, fill=text_color, font=font_title)
    y = 44
    for cat in CATEGORY_ORDER:
        top = svgkit.CATEGORIES[cat]["top"]
        rgb = svgkit.hex_rgb(top)
        draw.rectangle((pad, y + 5, pad + 10, y + 19), fill=rgb)
        draw.text((pad + 18, y + 2), svgkit.CATEGORIES[cat]["label"], fill=text_color, font=font_head)
        y += 30
        for i, name in enumerate(groups[cat]):
            cx = pad + (i % cols) * cell_w
            cy = y + (i // cols) * cell_h
            icon = load_icon(png_dir, name)
            x = cx
            for side in (64, 48, 32):
                small = sized(icon, side)
                panel.alpha_composite(small, (x, cy + 64 - side))
                x += side + 8
            title = glyphs.ICONS[name][1]
            draw.text((cx, cy + 68), title, fill=text_color, font=font_small)
        y += ((len(groups[cat]) + cols - 1) // cols) * cell_h
    return panel.convert("RGB")


def make_icon_sheet(png_dir, out_path):
    dark = draw_panel(png_dir, DARK_BG, (226, 224, 218), "Fondo oscuro: 64, 48 y 32 px")
    light = draw_panel(png_dir, LIGHT_BG, (40, 38, 34), "Fondo claro: 64, 48 y 32 px")
    sheet = Image.new("RGB", (dark.width * 2, dark.height), DARK_BG)
    sheet.paste(dark, (0, 0))
    sheet.paste(light, (dark.width, 0))
    sheet.save(out_path)
    return sheet.size


def synthetic_hud(size=(1920, 1080)):
    """Fondo de tierra y sombras con el que probar la barra cuando no hay captura de referencia."""
    base = Image.new("RGB", size, (92, 70, 52))
    px = base.load()
    for y in range(size[1]):
        for x in range(0, size[0]):
            shade = 0.82 + 0.18 * ((x * 7 + y * 13) % 29) / 29.0
            px[x, y] = (int(96 * shade), int(72 * shade), int(52 * shade))
    return base.filter(ImageFilter.GaussianBlur(3))


def draw_chip(image, x, y, text, font):
    """Rótulo de tecla encima de la esquina de una casilla, como los de la interfaz."""
    draw = ImageDraw.Draw(image)
    width = int(draw.textlength(text, font=font)) + 12
    box = (x + 3, y - 1, x + 3 + width, y + 15)
    draw.rounded_rectangle(box, radius=4, fill=(18, 20, 27), outline=(150, 140, 120), width=1)
    draw.text((x + 9, y - 1), text, fill=(236, 234, 228), font=font)


def draw_count(image, x, y, text, font):
    draw = ImageDraw.Draw(image)
    tx = x + BAR_SLOT_SIZE - 6 - int(draw.textlength(text, font=font))
    ty = y + BAR_SLOT_SIZE - 20
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            draw.text((tx + dx, ty + dy), text, fill=(0, 0, 0), font=font)
    draw.text((tx, ty), text, fill=(250, 248, 240), font=font)


def bar_variant(base, png_dir, names):
    image = base.copy()
    chip_font = load_font(12, bold=True)
    count_font = load_font(15, bold=True)
    for i, name in enumerate(names):
        x = BAR_SLOT_X[i] - 2
        y = BAR_SLOT_Y
        icon = sized(load_icon(png_dir, name), BAR_SLOT_SIZE)
        image.paste(icon, (x, y), icon)
        draw_chip(image, x, y + 1, BAR_KEYS[i], chip_font)
        if name in BAR_COUNTS:
            draw_count(image, x, y, str(BAR_COUNTS[name]), count_font)
    return image


def make_bar_sheet(png_dir, out_path, hud_path):
    if hud_path and os.path.exists(hud_path):
        base = Image.open(hud_path).convert("RGB")
        reference = "captura de referencia"
    else:
        base = synthetic_hud()
        reference = "fondo sintético"
    # En la captura de referencia las casillas ya traen letras: se tapan con el icono completo
    variants = [
        ("Antes: letras sobre cuadros de color (%s)" % reference, base.copy()),
        ("Después: espada y escudo", bar_variant(base, png_dir, BAR_SWORD)),
        ("Después: arco", bar_variant(base, png_dir, BAR_BOW)),
    ]
    scale = 2
    font = load_font(16, bold=True)
    crops = []
    for title, image in variants:
        crop = image.crop(BAR_CROP)
        crops.append((title, crop.resize((crop.width * scale, crop.height * scale), Image.LANCZOS)))
    width = crops[0][1].width
    head = 30
    height = sum(c.height + head for _t, c in crops)
    sheet = Image.new("RGB", (width, height), (16, 17, 22))
    draw = ImageDraw.Draw(sheet)
    y = 0
    for title, crop in crops:
        draw.text((10, y + 5), title, fill=(232, 230, 224), font=font)
        sheet.paste(crop, (0, y + head))
        y += crop.height + head
    sheet.save(out_path)
    return sheet.size


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--png", default=os.path.join(ROOT, "assets", "ui", "icons", "png"))
    parser.add_argument("--out", default=os.path.join(ROOT, "build", "iconos"))
    parser.add_argument("--hud", default="")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    print("muestra_iconos.png", make_icon_sheet(args.png, os.path.join(args.out, "muestra_iconos.png")))
    print("muestra_barra_habilidades.png",
          make_bar_sheet(args.png, os.path.join(args.out, "muestra_barra_habilidades.png"), args.hud))


if __name__ == "__main__":
    main()
