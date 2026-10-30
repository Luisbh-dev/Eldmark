# shellcheck shell=bash
# Funciones comunes de los scripts de despliegue que levantan un PostgreSQL efímero (dev.sh,
# restore_check.sh y pitr_check.sh; docs/plataforma.md §2.6 y §12). Se carga con «.»: no se ejecuta.
#
# Variables (las mismas que internal/testdb):
#   ELDMARK_PG_BIN   carpeta de los binarios de PostgreSQL (si no, pg_config --bindir; si no, el
#                    mayor /usr/lib/postgresql/*/bin; si no, el PATH)
#   ELDMARK_PG_USER  usuario con el que corren initdb, pg_ctl y pg_basebackup cuando el script
#                    corre como root, que initdb no admite (por defecto postgres, con runuser)

# Usuario de la base en los clústeres efímeros (initdb -U), como en internal/testdb.
ELD_PG_SUPERUSER=eldmark
# Longitud máxima de la ruta de un socket Unix (sun_path tiene 108 B con el nulo final).
ELD_MAX_SOCKET_PATH=107

# eld_usage <script>: la cabecera de comentarios del script (su ayuda) por la salida de errores, y
# sale con 2.
eld_usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$1" >&2
	exit 2
}

# eld_log <texto>: una línea de progreso por la salida de errores, con el nombre del script.
eld_log() {
	printf '[%s] %s\n' "${ELD_SCRIPT:-eldmark}" "$*" >&2
}

# eld_die <texto>: el error, por la salida de errores, y sale con 1.
eld_die() {
	printf '[%s] Error: %s\n' "${ELD_SCRIPT:-eldmark}" "$*" >&2
	exit 1
}

# eld_ms: la hora en milisegundos (para medir).
eld_ms() {
	date +%s%3N
}

# eld_find_pg_bin <binario>: pone en PG_BIN la carpeta de los binarios de PostgreSQL que tiene ese
# binario (initdb para un clúster, pg_dump para una copia).
eld_find_pg_bin() {
	local tool="$1" dir candidate
	PG_BIN=""
	if [ -n "${ELDMARK_PG_BIN:-}" ]; then
		# La dada manda: sin el binario en ella no se busca en otro sitio.
		[ -x "$ELDMARK_PG_BIN/$tool" ] || eld_die "ELDMARK_PG_BIN=$ELDMARK_PG_BIN no tiene $tool"
		PG_BIN="$ELDMARK_PG_BIN"
		return 0
	fi
	if command -v pg_config > /dev/null 2>&1; then
		dir="$(pg_config --bindir 2> /dev/null || true)"
		if [ -n "$dir" ] && [ -x "$dir/$tool" ]; then
			PG_BIN="$dir"
			return 0
		fi
	fi
	# /usr/lib/postgresql/<versión>/bin, de la mayor a la menor.
	while IFS= read -r candidate; do
		if [ -n "$candidate" ] && [ -x "$candidate/$tool" ]; then
			PG_BIN="$candidate"
			return 0
		fi
	done < <(printf '%s\n' /usr/lib/postgresql/*/bin | sort -t/ -k5,5 -n -r)
	if candidate="$(command -v "$tool" 2> /dev/null)"; then
		PG_BIN="$(dirname "$candidate")"
		return 0
	fi
	eld_die "no se encuentra $tool de PostgreSQL (ELDMARK_PG_BIN, pg_config o /usr/lib/postgresql/*/bin)"
}

# eld_pg_runas: como root, pone en PG_RUNAS el usuario sin privilegios que corre el servidor
# (ELDMARK_PG_USER, postgres por defecto); si no, lo deja vacío.
eld_pg_runas() {
	PG_RUNAS=""
	if [ "$(id -u)" -eq 0 ]; then
		PG_RUNAS="${ELDMARK_PG_USER:-postgres}"
		id "$PG_RUNAS" > /dev/null 2>&1 ||
			eld_die "corre como root e initdb no lo admite: falta el usuario $PG_RUNAS (ELDMARK_PG_USER)"
		command -v runuser > /dev/null 2>&1 || eld_die "corre como root y falta runuser para usar $PG_RUNAS"
	fi
}

# eld_as_pg <orden> [argumentos]: ejecuta un binario de PG_BIN con el usuario del servidor.
eld_as_pg() {
	local tool="$1"
	shift
	if [ -n "${PG_RUNAS:-}" ]; then
		runuser -u "$PG_RUNAS" -- "$PG_BIN/$tool" "$@"
	else
		"$PG_BIN/$tool" "$@"
	fi
}

# eld_as_pg_cmd <orden> [argumentos]: ejecuta una orden del PATH con el usuario del servidor (para
# crear y copiar archivos dentro de sus carpetas).
eld_as_pg_cmd() {
	if [ -n "${PG_RUNAS:-}" ]; then
		runuser -u "$PG_RUNAS" -- "$@"
	else
		"$@"
	fi
}

# eld_give_to_pg <carpeta>: como root, cede la carpeta al usuario del servidor y comprueba que puede
# escribir en ella (no puede si una carpeta de encima no le deja pasar, como /root).
eld_give_to_pg() {
	local dir="$1"
	[ -n "${PG_RUNAS:-}" ] || return 0
	chown "$PG_RUNAS" "$dir"
	runuser -u "$PG_RUNAS" -- test -w "$dir" ||
		eld_die "el usuario $PG_RUNAS no puede escribir en $dir (una carpeta de encima no le deja pasar): usa otra (TMPDIR=/tmp)"
}

# eld_check_socket_dir <carpeta>: la ruta del socket tiene que caber en sun_path.
eld_check_socket_dir() {
	local path="$1/.s.PGSQL.5432"
	[ "${#path}" -le "$ELD_MAX_SOCKET_PATH" ] ||
		eld_die "la ruta del socket ($path) pasa de $ELD_MAX_SOCKET_PATH B: usa una carpeta más corta (TMPDIR=/tmp)"
}

# eld_initdb <datos>: crea un clúster vacío (superusuario eldmark, sin contraseña: solo socket local).
eld_initdb() {
	eld_as_pg initdb -D "$1" -U "$ELD_PG_SUPERUSER" --auth=trust -E UTF8 --no-locale --no-sync --no-instructions \
		> /dev/null
}

# eld_pg_start <datos> <registro> <opciones de postgres>: arranca el servidor y espera a que acepte
# conexiones. Para escuchar solo en un socket Unix (sin puertos que choquen):
# "-k '<carpeta>' -c listen_addresses=".
eld_pg_start() {
	local data="$1" log="$2" options="$3"
	eld_as_pg pg_ctl -w -s -D "$data" -l "$log" start -o "$options" > /dev/null ||
		{ cat "$log" >&2 2> /dev/null; eld_die "no arranca PostgreSQL en $data"; }
}

# Opciones de un clúster desechable: sin fsync (si la máquina cae, se tira). La usan los scripts que
# cargan este archivo.
# shellcheck disable=SC2034
ELD_PG_FAST="-c fsync=off -c synchronous_commit=off -c full_page_writes=off"

# eld_pg_stop <datos> [modo]: para el servidor si está en marcha (immediate por defecto).
eld_pg_stop() {
	local data="$1" mode="${2:-immediate}"
	if [ -f "$data/postmaster.pid" ]; then
		eld_as_pg pg_ctl -s -D "$data" -m "$mode" stop > /dev/null 2>&1 || true
	fi
}

# eld_psql <cadena de conexión> [argumentos de psql]: psql sin ~/.psqlrc, que para en el primer
# error y sin decoración.
eld_psql() {
	local conn="$1"
	shift
	"$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -At -d "$conn" "$@"
}

# eld_random_b64 <bytes>: bytes aleatorios en base64 estándar.
eld_random_b64() {
	head -c "$1" /dev/urandom | base64 | tr -d '\n'
}

# eld_random_hex <bytes>: bytes aleatorios en hexadecimal.
eld_random_hex() {
	head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# eld_sha256_hex <texto>: SHA-256 en hexadecimal del texto (sin salto de línea).
eld_sha256_hex() {
	printf '%s' "$1" | sha256sum | cut -c1-64
}
