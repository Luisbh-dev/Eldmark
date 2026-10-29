#!/usr/bin/env bash
# Exporta Eldmark con los presets de export_presets.cfg (TEC-12).
#
# Destinos:
#   client  "Cliente Windows"  -> exports/windows/Eldmark.exe (y su .pck)
#   server  "Servidor Linux"   -> exports/server/eldmark-server.x86_64 (y su .pck), servidor dedicado
#                                 con los modelos, materiales, audio y animaciones recortados, más
#                                 run-server.sh, que lo lanza con --headless
#   all     los dos (por defecto)
#
# Uso, desde cualquier carpeta:
#   tools/export.sh [client|server|all] [--debug] [--pack-only] [--zip] [--dry-run]
#
#   --debug      exporta con las plantillas de depuración en lugar de las de lanzamiento
#   --pack-only  solo el .pck de cada preset (godot --export-pack): NO necesita las plantillas de
#                exportación y sirve para comprobar los filtros y el recorte de recursos
#   --zip        comprime cada carpeta exportada (exports/Eldmark-windows.zip, exports/Eldmark-server.zip)
#   --dry-run    muestra lo que haría sin exportar nada
#
# Requisitos (ver README, «Exportación»):
#   - Godot 4.7.2 (variable GODOT o `godot` en el PATH) y, salvo con --pack-only, las plantillas de
#     exportación de la misma versión (Editor > Administrar plantillas de exportación > Descargar e
#     instalar).
#   - Los objetos de Git LFS descargados (git lfs pull): el terreno y las texturas van por LFS.
#
# Códigos de salida: 0 bien, 1 fallo o uso incorrecto, 2 falta Godot, sus plantillas o los objetos LFS.
set -euo pipefail

# Nombres de los presets (los de export_presets.cfg; test_export_config.gd comprueba que coinciden).
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

# Versión de Godot ("4.7.2.stable.official.xxxx" -> "4.7.2.stable") y carpeta de sus plantillas.
GODOT_VERSION="$("$GODOT" --version | head -n 1)"
TEMPLATE_VERSION="$(echo "$GODOT_VERSION" | cut -d. -f1-4)"
case "$(uname -s)" in
	Linux) DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/godot" ;;
	Darwin) DATA_HOME="$HOME/Library/Application Support/Godot" ;;
	*) DATA_HOME="${APPDATA:-$HOME/AppData/Roaming}/Godot" ;;
esac
TEMPLATES_DIR="$DATA_HOME/export_templates/$TEMPLATE_VERSION"

# Un comando que no hace nada con --dry-run.
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

# Comprime una carpeta exportada (en exports/<nombre>.zip).
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

# Identificador de la compilación (git describe), que se guarda junto a lo exportado.
BUILD_ID="$(git describe --tags --always --dirty 2> /dev/null || echo desconocido)"
echo "Godot $GODOT_VERSION · compilación $BUILD_ID · destino: $TARGET ($MODE)"

# Importa los recursos (deja al día la caché .godot/ que usa la exportación).
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
		# El servidor dedicado se ejecuta siempre sin ventana: el lanzador pone --headless y pasa el
		# resto de las opciones (--zone, --port, --max-players...) detrás de --server.
		cat > exports/server/run-server.sh << 'EOF'
#!/usr/bin/env bash
# Lanza el servidor dedicado de Eldmark: ./run-server.sh --zone=vado_gris --port=24600
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
