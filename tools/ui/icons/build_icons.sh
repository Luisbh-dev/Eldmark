#!/usr/bin/env bash
# Regenera los iconos de la interfaz (ART-12): capas SVG, rasterizado con el motor, pintura y fondos.
#
#   GODOT=/ruta/a/godot tools/ui/icons/build_icons.sh [nombre_de_icono ...]
#
# 1. make_icons.py layers   dibuja las figuras y escribe sus capas SVG en build/iconos/capas.
# 2. rasterize_icons.gd     las rasteriza con el motor (ThorVG): una imagen por capa.
# 3. make_icons.py paint    compone las capas con grano, oclusión y luz de borde y escribe los PNG de
#                           assets/ui/icons (figuras, small/ y backgrounds/).
# Con nombres de icono al final solo se rehacen esos (los fondos no). Después hay que importar los
# recursos nuevos con `godot --headless --path . --import`; las láminas de muestra y la prueba en el
# motor salen de `make_sheets.py` y `engine_test.gd` (ver su cabecera).
set -euo pipefail

cd "$(dirname "$0")/../../.."

GODOT="${GODOT:-godot}"
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
	if python3 -c "" >/dev/null 2>&1; then PYTHON=python3; else PYTHON=python; fi
fi
export PYTHONDONTWRITEBYTECODE=1

"$PYTHON" tools/ui/icons/make_icons.py layers "$@"
"$GODOT" --headless --path . -s res://tools/ui/icons/rasterize_icons.gd
"$PYTHON" tools/ui/icons/make_icons.py paint "$@"
