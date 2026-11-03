#!/usr/bin/env python3
"""Genera los SVG de los iconos de la interfaz (ART-12) en assets/ui/icons/<nombre>.svg.

Cada icono es un lienzo de 128 x 128 con fondo con bisel por categoría y una figura de silueta
clara, dibujada con las piezas de `glyphs.py` y el kit de `svgkit.py`. Es contenido propio de
Eldmark, hecho por código: no hay nada de terceros.

Uso, desde la raíz del proyecto (sin argumentos escribe en assets/ui/icons):

    python3 tools/ui/icons/make_icons.py [directorio_de_salida] [nombre ...]

Después hay que rasterizarlos con `tools/ui/icons/rasterize_icons.gd` y generar las láminas con
`make_sheets.py`; `build_icons.sh` encadena los tres pasos.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import glyphs  # noqa: E402
import svgkit  # noqa: E402

DEFAULT_OUT = os.path.join(HERE, "..", "..", "..", "assets", "ui", "icons")


def main(argv):
    out_dir = os.path.abspath(argv[1]) if len(argv) > 1 else os.path.abspath(DEFAULT_OUT)
    only = set(argv[2:])
    os.makedirs(out_dir, exist_ok=True)
    count = 0
    for name, (category, title, builder) in glyphs.ICONS.items():
        if only and name not in only:
            continue
        svg = svgkit.icon_svg(name, category, builder(), "%s (%s)" % (title, category))
        with open(os.path.join(out_dir, name + ".svg"), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(svg)
        count += 1
    print("%d iconos escritos en %s" % (count, out_dir))


if __name__ == "__main__":
    main(sys.argv)
