#!/usr/bin/env bash
# Regenera por completo los iconos de la interfaz (ART-12): SVG, PNG de 128 px y láminas de muestra.
#
#   GODOT=/ruta/a/godot tools/ui/icons/build_icons.sh [--hud captura.png]
#
# 1. make_icons.py     escribe assets/ui/icons/*.svg (todo por código, determinista).
# 2. rasterize_icons.gd los rasteriza con el motor a assets/ui/icons/png/*.png (128 px).
# 3. make_sheets.py    deja las láminas de muestra en build/iconos/ (Git las ignora).
# Después hay que importar los recursos nuevos con `godot --headless --path . --import`.
set -euo pipefail

cd "$(dirname "$0")/../../.."

GODOT="${GODOT:-godot}"
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
	if command -v python3 >/dev/null 2>&1; then PYTHON=python3; else PYTHON=python; fi
fi

"$PYTHON" tools/ui/icons/make_icons.py
"$GODOT" --headless --path . -s res://tools/ui/icons/rasterize_icons.gd
"$PYTHON" tools/ui/icons/make_sheets.py "$@"
