#!/usr/bin/env python3
"""Láminas de muestra de los iconos de la interfaz (ART-12), hechas para no favorecer al resultado.

Reglas de honestidad (la crítica del director de arte lo pidió): ningún icono se enseña ampliado sin
decirlo, las muestras a escala real van a 1:1 y sin reescalar, y los estados se prueban al tamaño al que
se usan. Las salidas van a build/iconos (Git las ignora):

  muestra_iconos.png            todos los iconos a 64, 48 y 32 px en casillas simuladas (marco de 2 px
                                de UIPalette.BORDER y el icono a sangre), sobre fondo oscuro y claro.
  muestra_contacto.png          los iconos a su tamaño nativo (128 px), en color y en grises.
  muestra_grises.png            la barra de espada y la de arco a 52 px, en color y en escala de grises.
  muestra_estados.png           los estados a 14, 18, 26, 30 y 52 px, 1:1 y sin reescalar, con el borde
                                rojo o verde de StatusIcons.
  muestra_estados_x4.png        lo mismo ampliado x4 con vecino más próximo, SOLO para revisar píxeles.
  muestra_capas.png             figura suelta, fondo de la categoría y suma: lo que se entrega.
  muestra_barra_habilidades.png la barra de acciones 1:1 sobre la captura de 1920 x 1080: la captura
                                de antes y las dos barras dibujadas por el motor (`engine_test.gd`).
  prueba_en_motor.png           el tablero rotulado del motor (copia de motor_tablero.png).

Las dos últimas salen de las imágenes que escribe `engine_test.gd` (con ventana); sin ellas esas
láminas se saltan. El resto solo necesita los PNG de assets/ui/icons.

Uso, desde la raíz del proyecto:

    python3 tools/ui/icons/make_sheets.py [--hud captura.png] [--motor build/iconos] [--out build/iconos]
"""

import argparse
import os
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import glyphs  # noqa: E402
import svgkit  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ICONS = os.path.join(ROOT, "assets", "ui", "icons")
CATEGORY_ORDER = ["ataque", "defensa", "habilidad", "consumible", "estado_malo", "estado_bueno", "mundo"]

DARK_BG = (21, 23, 29)
LIGHT_BG = (222, 216, 200)
BORDER = (77, 73, 66)             # UIPalette.BORDER
HARMFUL_BORDER = (235, 56, 46)    # StatusIcons.HARMFUL_BORDER
BENEFICIAL_BORDER = (89, 217, 102)  # StatusIcons.BENEFICIAL_BORDER
STATES = ["bleed", "regen", "stun", "slowed", "knockback", "downed", "rooted"]
BENEFICIAL = ["regen"]

BAR_SWORD = ["sword_light", "block", "dodge", "shield_bash", "shield_rush", "shield_wall",
             "potion_health", "potion_stamina", "weapon_sword_shield"]
BAR_BOW = ["bow_quick", "bow_drawn", "dodge", "bow_volley", "bow_slowing_shot", "bow_evasive_shot",
           "potion_health", "potion_stamina", "weapon_bow"]


def load_font(size, bold=False):
    names = ["segoeuib.ttf", "arialbd.ttf"] if bold else ["segoeui.ttf", "arial.ttf"]
    for name in names:
        for folder in ("C:/Windows/Fonts", "/usr/share/fonts/truetype/dejavu", "/Library/Fonts"):
            path = os.path.join(folder, name)
            if os.path.exists(path):
                return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def category_of(name):
    return glyphs.ICONS[name][0]


def figure(name):
    return Image.open(os.path.join(ICONS, name + ".png")).convert("RGBA")


def tile(category):
    return Image.open(os.path.join(ICONS, "backgrounds", category + ".png")).convert("RGBA")


def small_figure(name, size):
    return Image.open(os.path.join(ICONS, "small", "%s_%d.png" % (name, size))).convert("RGBA")


def rounded_mask(side, radius):
    mask = Image.new("L", (side * 4, side * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, side * 4 - 1, side * 4 - 1), radius=radius * 4, fill=255)
    return mask.resize((side, side), Image.LANCZOS)


def compose(name, side, border=BORDER):
    """Casilla simulada: fondo de la categoría y figura a sangre dentro de un marco de 2 px (a escala)."""
    bw = max(1, int(round(side * 2.0 / 52.0)))
    inner = side - 2 * bw
    base = Image.new("RGBA", (side, side), border + (255,))
    bg = tile(category_of(name)).resize((inner, inner), Image.LANCZOS)
    bg.alpha_composite(figure(name).resize((inner, inner), Image.LANCZOS))
    base.paste(bg, (bw, bw))
    out = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    out.paste(base, (0, 0), rounded_mask(side, max(1, int(round(side * 3.0 / 52.0)))))
    return out


def grayscale(img):
    alpha = img.split()[3]
    gray = img.convert("L").convert("RGBA")
    gray.putalpha(alpha)
    return gray


def groups():
    result = {cat: [] for cat in CATEGORY_ORDER}
    for name, (category, _title, _builder) in glyphs.ICONS.items():
        result[category].append(name)
    return result


def draw_panel(background, text_color, heading, cols=6):
    font_small = load_font(11)
    font_head = load_font(15, bold=True)
    font_title = load_font(17, bold=True)
    cell_w, cell_h, pad = 188, 92, 14
    grp = groups()
    height = 44
    for cat in CATEGORY_ORDER:
        if grp[cat]:
            height += 30 + ((len(grp[cat]) + cols - 1) // cols) * cell_h
    height += pad
    panel = Image.new("RGBA", (pad * 2 + cols * cell_w, height), background + (255,))
    draw = ImageDraw.Draw(panel)
    draw.text((pad, 12), heading, fill=text_color, font=font_title)
    y = 44
    for cat in CATEGORY_ORDER:
        names = grp[cat]
        if not names:
            continue
        draw.rectangle((pad, y + 5, pad + 10, y + 19), fill=svgkit.hex_rgb(svgkit.CATEGORIES[cat]["top"]))
        draw.text((pad + 18, y + 2), svgkit.CATEGORIES[cat]["label"], fill=text_color, font=font_head)
        y += 30
        for i, name in enumerate(names):
            cx = pad + (i % cols) * cell_w
            cy = y + (i // cols) * cell_h
            x = cx
            for side in (64, 48, 32):
                panel.alpha_composite(compose(name, side), (x, cy + 64 - side))
                x += side + 8
            draw.text((cx, cy + 68), glyphs.ICONS[name][1], fill=text_color, font=font_small)
        y += ((len(names) + cols - 1) // cols) * cell_h
    return panel.convert("RGB")


def make_icon_sheet(out_path):
    dark = draw_panel(DARK_BG, (226, 224, 218), "Casillas simuladas sobre fondo oscuro: 64, 48 y 32 px (1:1)")
    light = draw_panel(LIGHT_BG, (40, 38, 34), "Casillas simuladas sobre fondo claro: 64, 48 y 32 px (1:1)")
    sheet = Image.new("RGB", (dark.width * 2, dark.height), DARK_BG)
    sheet.paste(dark, (0, 0))
    sheet.paste(light, (dark.width, 0))
    sheet.save(out_path)
    return sheet.size


def make_contact_sheet(out_path):
    """Todos los iconos a 128 px, en color y en grises, con su nombre."""
    names = list(glyphs.ICONS)
    cols = 6
    cell = 128
    pad = 10
    rows = (len(names) + cols - 1) // cols
    font = load_font(11)
    head = 26
    width = pad + cols * (cell + pad)
    height = head + rows * (cell + 18 + pad) + pad
    sheet = Image.new("RGB", (width * 2, height), DARK_BG)
    draw = ImageDraw.Draw(sheet)
    title = load_font(15, bold=True)
    draw.text((pad, 4), "Tamaño nativo (128 px) · color", fill=(226, 224, 218), font=title)
    draw.text((width + pad, 4), "Tamaño nativo (128 px) · escala de grises", fill=(226, 224, 218), font=title)
    for i, name in enumerate(names):
        x = pad + (i % cols) * (cell + pad)
        y = head + (i // cols) * (cell + 18 + pad)
        tile_img = tile(category_of(name)).copy()
        tile_img.alpha_composite(figure(name))
        sheet.paste(tile_img.convert("RGB"), (x, y))
        sheet.paste(grayscale(tile_img).convert("RGB"), (width + x, y))
        draw.text((x, y + cell + 2), name, fill=(200, 198, 190), font=font)
        draw.text((width + x, y + cell + 2), name, fill=(200, 198, 190), font=font)
    sheet.save(out_path)
    return sheet.size


def make_gray_sheet(out_path):
    """Las dos barras a 52 px, en color y en escala de grises, 1:1."""
    font = load_font(13, bold=True)
    gap, pad, side = 6, 12, 52
    width = pad * 2 + 9 * side + 8 * gap
    rows = [("Barra de espada y escudo, color", BAR_SWORD, False),
            ("Barra de espada y escudo, escala de grises", BAR_SWORD, True),
            ("Barra de arco, color", BAR_BOW, False),
            ("Barra de arco, escala de grises", BAR_BOW, True)]
    height = pad + len(rows) * (side + 30)
    sheet = Image.new("RGB", (width, height), DARK_BG)
    draw = ImageDraw.Draw(sheet)
    y = pad
    for title, names, gray in rows:
        draw.text((pad, y), title, fill=(226, 224, 218), font=font)
        y += 22
        for i, name in enumerate(names):
            img = compose(name, side)
            if gray:
                img = grayscale(img)
            sheet.paste(img.convert("RGB"), (pad + i * (side + gap), y), img.split()[3])
        y += side + 8
    sheet.save(out_path)
    return sheet.size


def status_plate(name, plate, fig_side):
    """Placa de efecto como la dibuja StatusIcons: borde de 2 px y el icono dentro, a su tamaño nativo."""
    harmful = name not in BENEFICIAL
    border = HARMFUL_BORDER if harmful else BENEFICIAL_BORDER
    inner = plate - 4
    cat = "estado_malo" if harmful else "estado_bueno"
    base = Image.new("RGBA", (plate, plate), border + (255,))
    bg = tile(cat).resize((inner, inner), Image.LANCZOS)
    bg.alpha_composite(small_figure(name, fig_side))
    base.paste(bg, (2, 2))
    return base


def make_state_sheets(out_1x, out_4x):
    names = STATES
    font = load_font(12, bold=True)
    small = load_font(11)
    pad, gap = 12, 30
    label_w = 96
    cols = [("14 px", "figura", 14), ("26 px", "figura", 26), ("18 px", "placa", 18), ("30 px", "placa", 30),
            ("52 px", "casilla", 52)]
    col_w = [14, 26, 18, 30, 52]
    width = pad * 2 + label_w + sum(col_w) + gap * len(cols)
    row_h = 60
    height = pad + 44 + len(names) * row_h + pad
    sheet = Image.new("RGB", (width, height), DARK_BG)
    draw = ImageDraw.Draw(sheet)
    draw.text((pad, pad), "Estados a escala real, 1:1 y sin reescalar", fill=(226, 224, 218), font=font)
    x = pad + label_w
    for (label, kind, _size), w in zip(cols, col_w):
        draw.text((x, pad + 20), "%s\n%s" % (label, kind), fill=(176, 172, 162), font=small, spacing=0)
        x += w + gap
    y = pad + 44
    for name in names:
        draw.text((pad, y + 18), glyphs.ICONS[name][1], fill=(210, 208, 200), font=small)
        harmful = name not in BENEFICIAL
        cat = "estado_malo" if harmful else "estado_bueno"
        x = pad + label_w
        # 14 y 26 px: la figura suelta sobre el fondo
        for size in (14, 26):
            t = tile(cat).resize((size, size), Image.LANCZOS)
            t.alpha_composite(small_figure(name, size))
            sheet.paste(t.convert("RGB"), (x, y + (30 - size // 2) - 8))
            x += size + gap
        # placas de 18 y 30 px
        for plate, fig in ((18, 14), (30, 26)):
            img = status_plate(name, plate, fig)
            sheet.paste(img.convert("RGB"), (x, y + (30 - plate // 2) - 8))
            x += plate + gap
        # casilla de 52 px con el icono grande
        slot = compose(name, 52)
        sheet.paste(slot.convert("RGB"), (x, y - 8), slot.split()[3])
        y += row_h
    sheet.save(out_1x)
    big = sheet.resize((width * 4, height * 4), Image.NEAREST)
    canvas = Image.new("RGB", (big.width, big.height + 30), DARK_BG)
    canvas.paste(big, (0, 30))
    ImageDraw.Draw(canvas).text((10, 6), "AMPLIADO x4 con vecino más próximo, solo para revisar píxeles (no es el tamaño real)",
                                fill=(255, 190, 120), font=load_font(15, bold=True))
    canvas.save(out_4x)
    return sheet.size


def checker(side, cell=8):
    img = Image.new("RGB", (side, side), (70, 70, 74))
    draw = ImageDraw.Draw(img)
    for y in range(0, side, cell):
        for x in range(0, side, cell):
            if (x // cell + y // cell) % 2 == 0:
                draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(96, 96, 100))
    return img


def make_layers_sheet(out_path):
    """Figura suelta (sobre cuadros), fondo de la categoría y la suma, para algunos iconos."""
    names = ["block", "bow_drawn", "potion_health", "bleed", "fort"]
    side, pad = 128, 12
    font = load_font(13, bold=True)
    small = load_font(11)
    width = pad + len(names) * (side + pad)
    height = pad + 3 * (side + 26) + pad
    sheet = Image.new("RGB", (width, height), DARK_BG)
    draw = ImageDraw.Draw(sheet)
    labels = ["Figura suelta (PNG con alfa)", "Fondo de la categoría", "Casilla: fondo + figura"]
    for row, label in enumerate(labels):
        y = pad + row * (side + 26)
        draw.text((pad, y - 2), label, fill=(210, 208, 200), font=small)
        y += 14
        for i, name in enumerate(names):
            x = pad + i * (side + pad)
            if row == 0:
                base = checker(side).convert("RGBA")
                base.alpha_composite(figure(name))
            elif row == 1:
                base = tile(category_of(name))
            else:
                base = tile(category_of(name)).copy()
                base.alpha_composite(figure(name))
            sheet.paste(base.convert("RGB"), (x, y))
    draw.text((pad, height - 18), "Los estados llevan además figuras pequeñas nativas de 14 y 26 px (assets/ui/icons/small).",
              fill=(150, 148, 140), font=small)
    sheet.save(out_path)
    return sheet.size


def make_bar_sheet(out_path, hud_path, motor_dir):
    """La barra de acciones 1:1: captura de antes y las dos barras que dibuja el motor."""
    sword = os.path.join(motor_dir, "motor_barra_espada.png")
    bow = os.path.join(motor_dir, "motor_barra_arco.png")
    if not (os.path.exists(sword) and os.path.exists(bow)):
        return None
    crops = []
    if hud_path and os.path.exists(hud_path):
        crops.append(("Antes: letras sobre cuadros de color (captura hud_en_pelea_03.png, recorte 1:1)",
                      Image.open(hud_path).convert("RGB").crop((600, 800, 1320, 925))))
    crops.append(("Después: espada y escudo, dibujada por el motor con UIIconSlot (1:1, sin ampliar)",
                  Image.open(sword).convert("RGB")))
    crops.append(("Después: arco, dibujada por el motor con UIIconSlot (1:1, sin ampliar)",
                  Image.open(bow).convert("RGB")))
    font = load_font(14, bold=True)
    head = 26
    width = max(c.width for _t, c in crops)
    height = sum(c.height + head for _t, c in crops)
    sheet = Image.new("RGB", (width, height), (16, 17, 22))
    draw = ImageDraw.Draw(sheet)
    y = 0
    for title, crop in crops:
        draw.text((8, y + 4), title, fill=(232, 230, 224), font=font)
        sheet.paste(crop, (0, y + head))
        y += crop.height + head
    sheet.save(out_path)
    return sheet.size


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--out", default=os.path.join(ROOT, "build", "iconos"))
    parser.add_argument("--motor", default=os.path.join(ROOT, "build", "iconos"))
    parser.add_argument("--hud", default="")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    print("muestra_iconos.png", make_icon_sheet(os.path.join(args.out, "muestra_iconos.png")))
    print("muestra_contacto.png", make_contact_sheet(os.path.join(args.out, "muestra_contacto.png")))
    print("muestra_grises.png", make_gray_sheet(os.path.join(args.out, "muestra_grises.png")))
    print("muestra_estados.png", make_state_sheets(os.path.join(args.out, "muestra_estados.png"),
                                                    os.path.join(args.out, "muestra_estados_x4.png")))
    print("muestra_capas.png", make_layers_sheet(os.path.join(args.out, "muestra_capas.png")))
    size = make_bar_sheet(os.path.join(args.out, "muestra_barra_habilidades.png"), args.hud, args.motor)
    print("muestra_barra_habilidades.png", size if size else "sin imágenes del motor (ver engine_test.gd)")
    board = os.path.join(args.motor, "motor_tablero.png")
    if os.path.exists(board):
        shutil.copyfile(board, os.path.join(args.out, "prueba_en_motor.png"))
        print("prueba_en_motor.png copiada de motor_tablero.png")


if __name__ == "__main__":
    main()
