#!/usr/bin/env bash
# Exports Eldmark with the presets in export_presets.cfg (TEC-12).
#
# Targets:
#   client  "Cliente Windows"  -> exports/windows/Eldmark.exe (and its .pck)
#   server  "Servidor Linux"   -> exports/server/eldmark-server.x86_64 (and its .pck), dedicated server
#                                 with models, materials, audio and animations stripped, plus
#                                 run-server.sh, which launches it with --headless
#   all     both (default)
#
# Usage, from any folder:
#   tools/export.sh [client|server|all] [--debug] [--pack-only] [--zip] [--dry-run]
#
#   --debug      export with the debug templates instead of the release ones
#   --pack-only  only the .pck of each preset (godot --export-pack): does NOT need the export
#                templates and is useful for checking the filters and the resource stripping
#   --zip        compress each exported folder (exports/Eldmark-windows.zip, exports/Eldmark-server.zip)
#   --dry-run    show what it would do without exporting anything
#
# Requirements (see docs/getting-started.md, section Export):
#   - Godot 4.7.2 (GODOT variable or `godot` on the PATH) and, except with --pack-only, the export
#     templates of the same version (Editor > Manage Export Templates > Download and
#     Install).
#   - The Git LFS objects downloaded (git lfs pull): the terrain and the textures go through LFS.
#
# Exit codes: 0 success, 1 failure or incorrect usage, 2 Godot, its templates or the LFS objects are missing.
set -euo pipefail

# Preset names (those in export_presets.cfg; test_export_config.gd checks that they match).
CLIENT_PRESET="Cliente Windows"
SERVER_PRESET="Servidor Linux"
CLIENT_OUT="exports/windows/Eldmark.exe"
SERVER_OUT="exports/server/eldmark-server.x86_64"

TARGET="all"
MODE="release"
PACK_ONLY=0
ZIP=0
DRY_RUN=0

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
	case "$arg" in
		client | server | all) TARGET="$arg" ;;
		--debug) MODE="debug" ;;
		--pack-only) PACK_ONLY=1 ;;
		--zip) ZIP=1 ;;
		--dry-run) DRY_RUN=1 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Opción desconocida: $arg" >&2; usage >&2; exit 1 ;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GODOT="${GODOT:-godot}"

if ! command -v "$GODOT" > /dev/null 2>&1; then
	echo "No se encuentra Godot ('$GODOT'). Instala Godot 4.7.2 o indica su ruta con la variable GODOT." >&2
	exit 2
fi

# Godot version ("4.7.2.stable.official.xxxx" -> "4.7.2.stable") and its templates folder.
GODOT_VERSION="$("$GODOT" --version | head -n 1)"
TEMPLATE_VERSION="$(echo "$GODOT_VERSION" | cut -d. -f1-4)"
case "$(uname -s)" in
	Linux) DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/godot" ;;
	Darwin) DATA_HOME="$HOME/Library/Application Support/Godot" ;;
	*) DATA_HOME="${APPDATA:-$HOME/AppData/Roaming}/Godot" ;;
esac
TEMPLATES_DIR="$DATA_HOME/export_templates/$TEMPLATE_VERSION"

# A command that does nothing with --dry-run.
run() {
	printf '+'
	printf ' %q' "$@"
	printf '\n'
	if [ "$DRY_RUN" -eq 0 ]; then
		"$@"
	fi
}

check_templates() {
	local pattern="$1" platform="$2"
	if ! compgen -G "$TEMPLATES_DIR/$pattern" > /dev/null; then
		cat >&2 << EOF
Faltan las plantillas de exportación de $platform para Godot $TEMPLATE_VERSION.
Instálalas desde el editor (Editor > Administrar plantillas de exportación > Descargar e instalar,
o Instalar desde archivo con el .tpz de la versión $TEMPLATE_VERSION). Se esperan en:
  $TEMPLATES_DIR
Para comprobar solo los filtros de los presets, sin plantillas: tools/export.sh --pack-only
EOF
		exit 2
	fi
}

check_lfs() {
	local sample="scenes/world/zones/vado_gris/terrain/terrain3d_00_00.res"
	if [ -f "$sample" ] && head -c 64 "$sample" | grep -q "version https://git-lfs"; then
		echo "Los objetos de Git LFS no están descargados (el terreno es un puntero). Ejecuta: git lfs pull" >&2
		exit 2
	fi
}

# Compresses an exported folder (into exports/<name>.zip).
zip_dir() {
	local dir="$1" name="$2"
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "+ (cd $dir && zip -qr ../$name .)"
		return
	fi
	rm -f "exports/$name"
	(cd "$dir" && zip -qr "../$name" .)
}

check_lfs
if [ "$PACK_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
	if [ "$TARGET" = "client" ] || [ "$TARGET" = "all" ]; then
		check_templates "windows_${MODE}_x86_64*" "Windows"
	fi
	if [ "$TARGET" = "server" ] || [ "$TARGET" = "all" ]; then
		check_templates "linux_${MODE}*" "Linux"
	fi
fi

# Build identifier (git describe), stored next to the exported files.
BUILD_ID="$(git describe --tags --always --dirty 2> /dev/null || echo desconocido)"
echo "Godot $GODOT_VERSION · compilación $BUILD_ID · destino: $TARGET ($MODE)"

# Imports the resources (brings the .godot/ cache that the export uses up to date).
run "$GODOT" --headless --path "$ROOT" --import

export_preset() {
	local preset="$1" out="$2"
	run mkdir -p "$(dirname "$out")"
	if [ "$PACK_ONLY" -eq 1 ]; then
		run "$GODOT" --headless --path "$ROOT" --export-pack "$preset" "${out%.*}.pck"
	else
		run "$GODOT" --headless --path "$ROOT" "--export-$MODE" "$preset" "$out"
	fi
	if [ "$DRY_RUN" -eq 0 ]; then
		echo "$BUILD_ID" > "$(dirname "$out")/BUILD_ID"
	fi
}

if [ "$TARGET" = "client" ] || [ "$TARGET" = "all" ]; then
	export_preset "$CLIENT_PRESET" "$CLIENT_OUT"
	if [ "$ZIP" -eq 1 ]; then
		zip_dir exports/windows Eldmark-windows.zip
	fi
fi

if [ "$TARGET" = "server" ] || [ "$TARGET" = "all" ]; then
	export_preset "$SERVER_PRESET" "$SERVER_OUT"
	if [ "$DRY_RUN" -eq 0 ]; then
		# The dedicated server always runs without a window: the launcher adds --headless and passes the
		# remaining options (--zone, --port, --max-players...) after --server.
		cat > exports/server/run-server.sh << 'EOF'
#!/usr/bin/env bash
# Launches the Eldmark dedicated server: ./run-server.sh --zone=vado_gris --port=24600
cd "$(dirname "${BASH_SOURCE[0]}")"
exec ./eldmark-server.x86_64 --headless -- --server "$@"
EOF
		chmod +x exports/server/run-server.sh
	fi
	if [ "$ZIP" -eq 1 ]; then
		zip_dir exports/server Eldmark-server.zip
	fi
fi

echo "Listo. Lo exportado está en $ROOT/exports/"
