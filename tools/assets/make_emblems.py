#!/usr/bin/env python3
"""Genera los emblemas provisionales de los cuatro bandos (UI-02) en assets/emblems/<id>.svg.

Son formas geométricas sencillas, de 128 x 128, hechas para Eldmark (no son de terceros) y
provisionales: el arte final llegará con ART-03 y los sustituirá con los mismos nombres de archivo.

    lobo (Vardheim)        triángulos que forman la cabeza de un lobo
    sol partido (Solmarch) disco y rayos partidos por una grieta vertical
    yunque (Askarra)       trapecios y un triángulo sobre una grieta en llamas
    corona rota (Huecos)   corona de cinco puntas partida en dos por una grieta en zigzag

Los colores principales son los de bando de RealmCatalog (scripts/shared/war/realm_catalog.gd);
test_ui_theme.gd comprueba que cada SVG los contiene. Uso, desde la raíz del proyecto:

    python3 tools/assets/make_emblems.py
"""

import math
import os

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "emblems")

# Colores de bando (RealmCatalog): azul hielo, oro, carmesí y gris hueso.
VARDHEIM = "#7EC8E8"
SOLMARCH = "#E9C341"
ASKARRA = "#C3242F"
HUECOS = "#BDB6A6"
BRONCE = "#CD7F32"


def shade(hex_color, factor):
    """Oscurece (factor < 1) o aclara (factor > 1) un color #RRGGBB."""
    channels = [int(hex_color[i:i + 2], 16) for i in (1, 3, 5)]
    if factor <= 1.0:
        mixed = [round(c * factor) for c in channels]
    else:
        mixed = [round(c + (255 - c) * (factor - 1.0)) for c in channels]
    return "#%02X%02X%02X" % tuple(max(0, min(255, c)) for c in mixed)


def poly(points, fill, extra=""):
    text = " ".join("%g,%g" % (x, y) for x, y in points)
    return '<polygon points="%s" fill="%s"%s/>' % (text, fill, extra)


def svg(body, title):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">\n'
        "<title>%s (emblema provisional)</title>\n%s\n</svg>\n" % (title, "\n".join(body))
    )


def mirror(points):
    return [(128 - x, y) for x, y in points]


def wolf():
    base = VARDHEIM
    dark = shade(base, 0.62)
    deep = "#10242E"
    body = []
    # Orejas.
    for ear in ([(28, 50), (30, 8), (58, 38)],):
        body.append(poly(ear, dark))
        body.append(poly(mirror(ear), dark))
    inner = [(33, 40), (32, 20), (49, 37)]
    body.append(poly(inner, base))
    body.append(poly(mirror(inner), base))
    # Cabeza: siete triángulos que se tocan en el centro de la frente.
    facets = [
        ([(22, 66), (36, 38), (64, 70)], base),
        ([(36, 38), (92, 38), (64, 70)], shade(base, 1.18)),
        ([(22, 66), (64, 70), (44, 100)], dark),
        ([(44, 100), (84, 100), (64, 70)], base),
        ([(44, 100), (84, 100), (64, 118)], dark),
    ]
    for points, fill in facets:
        body.append(poly(points, fill))
    for points, fill in (facets[0], facets[2]):
        body.append(poly(mirror(points), fill))
    # Ojos y nariz.
    eye = [(40, 56), (58, 60), (44, 67)]
    body.append(poly(eye, deep))
    body.append(poly(mirror(eye), deep))
    body.append(poly([(57, 102), (71, 102), (64, 111)], deep))
    return svg(body, "Lobo de Vardheim")


def split_sun():
    base = SOLMARCH
    dark = shade(base, 0.7)
    cx, cy = 64.0, 64.0
    left, right = [], []
    # Rayos: doce triángulos, largos y cortos alternos, ninguno sobre el eje vertical.
    for i in range(12):
        angle = math.radians(15 + 30 * i)
        reach = 58.0 if i % 2 == 0 else 47.0
        half = math.radians(7.5)
        tip = (cx + reach * math.sin(angle), cy - reach * math.cos(angle))
        b1 = (cx + 31 * math.sin(angle - half), cy - 31 * math.cos(angle - half))
        b2 = (cx + 31 * math.sin(angle + half), cy - 31 * math.cos(angle + half))
        ray = poly([tip, b1, b2], base if i % 2 == 0 else dark)
        (right if math.sin(angle) > 0 else left).append(ray)
    # Disco: dos mitades.
    left.append('<path d="M64 38 A26 26 0 0 0 64 90 Z" fill="%s"/>' % base)
    right.append('<path d="M64 38 A26 26 0 0 1 64 90 Z" fill="%s"/>' % base)
    body = [
        '<g transform="translate(-3.5 0)">', *left, "</g>",
        '<g transform="translate(3.5 0)">', *right, "</g>",
    ]
    return svg(body, "Sol partido de Solmarch")


def anvil():
    base = ASKARRA
    dark = shade(base, 0.62)
    light = shade(base, 1.25)
    body = [
        poly([(34, 34), (112, 34), (112, 52), (34, 52)], base),           # cara superior
        poly([(34, 36), (8, 44), (34, 52)], light),                       # cuerno
        poly([(46, 52), (100, 52), (90, 78), (56, 78)], dark),            # cintura
        poly([(38, 78), (108, 78), (118, 96), (28, 96)], base),           # base
        '<polyline points="12,112 30,104 44,114 62,102 78,116 94,104 116,112" fill="none" '
        'stroke="%s" stroke-width="5" stroke-linejoin="miter" stroke-linecap="butt"/>' % BRONCE,
        poly([(28, 118), (36, 104), (44, 118)], BRONCE),                  # llamas
        poly([(70, 120), (80, 104), (90, 120)], BRONCE),
    ]
    return svg(body, "Yunque de Askarra")


def broken_crown():
    base = HUECOS
    dark = shade(base, 0.6)
    crack = [(65, 36), (60, 56), (69, 72), (59, 88), (66, 104)]
    left_piece = [(22, 104), (22, 50), (42, 74), (64, 34)] + crack
    right_piece = [crack[0], (86, 74), (106, 50), (106, 104)] + list(reversed(crack[1:]))
    body = [
        '<g transform="translate(-3 2)">',
        poly(left_piece, base),
        '<line x1="22" y1="91" x2="60" y2="91" stroke="%s" stroke-width="4"/>' % dark,
        "</g>",
        '<g transform="translate(3 -2)">',
        poly(right_piece, shade(base, 0.9)),
        '<line x1="66" y1="91" x2="106" y2="91" stroke="%s" stroke-width="4"/>' % dark,
        "</g>",
    ]
    return svg(body, "Corona rota de los Huecos")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    emblems = {
        "vardheim": wolf(),
        "solmarch": split_sun(),
        "askarra": anvil(),
        "huecos": broken_crown(),
    }
    for name, text in emblems.items():
        path = os.path.join(OUT_DIR, name + ".svg")
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        print("Escrito", os.path.normpath(path))


if __name__ == "__main__":
    main()
