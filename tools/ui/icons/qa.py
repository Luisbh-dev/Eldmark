#!/usr/bin/env python3
"""Objective measurements of the interface icons (ART-12), on the PNGs already written.

It checks what the art director's critique asked for, with numbers instead of by eye:

  - Visual weight: how much of the interior (112 x 112 of the 128 px) each shape covers. Goal: 35 to 55 %.
  - Silhouette: overlap (intersection over union) at 32 px between the icons of the same ability
    bar. Goal: 50 % or less (before, shield bash and shield wall reached 74 %).
  - Safe zones: how much of the top-left corner (key label) and of the bottom-right one
    (counter) the shape covers.
  - Backgrounds: value and saturation of each background per category (goal: value 25 to 35 %, saturation
    of 0.45 or less).
  - Small states: how much of the square the shape fills (goal: around 90 %).

Usage, from the project root:

    python3 tools/ui/icons/qa.py [--out build/iconos/metricas.txt]
"""

import argparse
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import glyphs  # noqa: E402
import svgkit  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ICONS = os.path.join(ROOT, "assets", "ui", "icons")

BAR_SWORD = ["sword_light", "block", "dodge", "shield_bash", "shield_rush", "shield_wall",
             "potion_health", "potion_stamina", "weapon_sword_shield"]
BAR_BOW = ["bow_quick", "bow_drawn", "dodge", "bow_volley", "bow_slowing_shot", "bow_evasive_shot",
           "potion_health", "potion_stamina", "weapon_bow"]
STATES = ["bleed", "regen", "stun", "slowed", "knockback", "downed", "rooted"]

COVER_LO, COVER_HI = 0.35, 0.55
IOU_MAX = 0.50
TL_ZONE = (0, 0, 36, 28)      # x0, y0, x1, y1 in units of 128 px
BR_ZONE = (92, 96, 128, 128)


def alpha_of(name, folder=""):
    return np.asarray(Image.open(os.path.join(ICONS, folder, name + ".png")).convert("RGBA"))[..., 3]


def mask128(name):
    return alpha_of(name) > 127


def small_mask(name, side=32):
    img = Image.open(os.path.join(ICONS, name + ".png")).convert("RGBA").split()[3]
    return np.asarray(img.resize((side, side), Image.BOX)) > 127


def iou(a, b):
    union = np.logical_or(a, b).sum()
    return float(np.logical_and(a, b).sum()) / union if union else 0.0


def zone_fraction(mask, zone):
    x0, y0, x1, y1 = zone
    return float(mask[y0:y1, x0:x1].mean())


def report():
    lines = []
    add = lines.append
    add("ICONOS GRANDES (128 px): cobertura del interior, caja y zonas seguras")
    add("%-22s %9s %9s %7s %7s" % ("icono", "cobertura", "caja", "esq.arr", "esq.aba"))
    bad_cover = 0
    for name in glyphs.ICONS:
        m = mask128(name)
        ys, xs = np.nonzero(m)
        cover = m.sum() / (svgkit.INTERIOR * svgkit.INTERIOR)
        box = "%dx%d" % (xs.max() - xs.min() + 1, ys.max() - ys.min() + 1)
        flag = "" if COVER_LO <= cover <= COVER_HI else "  <- fuera de 35-55 %"
        bad_cover += 1 if flag else 0
        add("%-22s %8.0f%% %9s %6.0f%% %6.0f%%%s" % (name, cover * 100, box,
                                                     zone_fraction(m, TL_ZONE) * 100,
                                                     zone_fraction(m, BR_ZONE) * 100, flag))
    add("fuera de rango: %d de %d" % (bad_cover, len(glyphs.ICONS)))
    add("")
    for title, bar in (("espada y escudo", BAR_SWORD), ("arco", BAR_BOW)):
        add("SOLAPE DE SILUETAS A 32 PX, barra de %s (meta: %d %% o menos)" % (title, IOU_MAX * 100))
        worst = []
        masks = {n: small_mask(n) for n in bar}
        for i in range(len(bar)):
            for j in range(i + 1, len(bar)):
                worst.append((iou(masks[bar[i]], masks[bar[j]]), bar[i], bar[j]))
        worst.sort(reverse=True)
        for value, a, b in worst[:6]:
            add("  %-18s %-18s %3.0f%%%s" % (a, b, value * 100, "  <- demasiado" if value > IOU_MAX else ""))
        add("  peor par: %.0f %%" % (worst[0][0] * 100))
        add("")
    names = list(glyphs.ICONS)
    masks = {n: small_mask(n) for n in names}
    allp = []
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            allp.append((iou(masks[names[i]], masks[names[j]]), names[i], names[j]))
    allp.sort(reverse=True)
    add("PARES MAS PARECIDOS DE TODO EL JUEGO (32 px)")
    for value, a, b in allp[:8]:
        add("  %-22s %-22s %3.0f%%" % (a, b, value * 100))
    add("")
    add("FONDOS POR CATEGORIA (meta: valor 25-35 %, saturación <= 0,45)")
    for cat, info in svgkit.CATEGORIES.items():
        sat, val = svgkit.hsv(info["top"])
        flag = "" if 0.25 <= val <= 0.35 and sat <= 0.45 else "  <- fuera"
        add("  %-13s arriba %s  valor %2.0f %%  saturación %.2f%s" % (cat, info["top"], val * 100, sat, flag))
    add("")
    add("ESTADOS PEQUEÑOS (meta: la figura llena alrededor del 90 % del lado)")
    for name in STATES:
        row = []
        for size in (14, 26):
            m = alpha_of("%s_%d" % (name, size), "small") > 127
            ys, xs = np.nonzero(m)
            if len(xs) == 0:
                row.append("%d px: vacío" % size)
                continue
            ext = max(xs.max() - xs.min() + 1, ys.max() - ys.min() + 1) / float(size)
            row.append("%d px: %2.0f%% del lado, %2.0f%% cubierto" % (size, ext * 100, m.mean() * 100))
        add("  %-10s %s" % (name, " | ".join(row)))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--out", default=os.path.join(ROOT, "build", "iconos", "metricas.txt"))
    args = parser.parse_args()
    text = report()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
