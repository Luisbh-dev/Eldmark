#!/usr/bin/env bash
# Regenerates the fort keep from scratch (ART-57): textures, model, import, texture import
# settings and realm materials. From the repo root, with Git Bash:
#
#     bash tools/blender/regenerate_fort_keep.sh
#
# Optional variables: BLENDER (by default the one in C:/Users/MrPortainer/Tools) and GODOT (Godot's console
# executable; by default the winget one). It is deterministic: two passes give the same files
# (except the .import files and the .ctex files in Godot's cache).
set -euo pipefail

BLENDER="${BLENDER:-C:/Users/MrPortainer/Tools/blender-5.2.3-windows-x64/blender.exe}"
GODOT="${GODOT:-$LOCALAPPDATA/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "1/6 texturas propias (numpy y Pillow)"
python tools/blender/make_fort_keep_textures.py
echo "2/6 modelo (Blender sin interfaz)"
"$BLENDER" --background --factory-startup --python tools/blender/build_fort_keep.py
echo "3/6 importar (crea los .import de las texturas nuevas)"
"$GODOT" --headless --path . --import
echo "4/6 ajustes de importación de las texturas (VRAM, mipmaps, mapa de normales)"
"$GODOT" --headless --path . -s res://tools/assets/apply_texture_import_presets.gd
echo "5/6 importar otra vez con los ajustes"
"$GODOT" --headless --path . --import
echo "6/6 materiales de reino"
"$GODOT" --headless --path . -s res://tools/materials/build_fort_keep_materials.gd
echo "Hecho. Capturas: tools/render/render_fort_keep_model.gd y render_fort_keep_views.gd (necesitan ventana)."
