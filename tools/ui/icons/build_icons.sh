#!/usr/bin/env bash
# Regenerates the interface icons (ART-12): SVG layers, rasterisation with the engine, painting and backgrounds.
#
#   GODOT=/path/to/godot tools/ui/icons/build_icons.sh [icon_name ...]
#
# 1. make_icons.py layers   draws the shapes and writes their SVG layers to build/iconos/capas.
# 2. rasterize_icons.gd     rasterizes them with the engine (ThorVG): one image per layer.
# 3. make_icons.py paint    composes the layers with grain, occlusion and edge light and writes the PNGs to
#                           assets/ui/icons (shapes, small/ and backgrounds/).
# With icon names at the end only those are rebuilt (not the backgrounds). Afterwards the new
# resources must be imported with `godot --headless --path . --import`; the sample sheets and the in-engine
# test come from `make_sheets.py` and `engine_test.gd` (see their header).
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
