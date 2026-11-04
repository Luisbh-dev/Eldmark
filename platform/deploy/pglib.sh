# shellcheck shell=bash
# Common functions of the deployment scripts that bring up an ephemeral PostgreSQL (dev.sh,
# restore_check.sh and pitr_check.sh; docs/platform.md §2.6 and §12). It is loaded with ".": it is
# not executed.
#
# Variables (the same as internal/testdb):
#   ELDMARK_PG_BIN   folder of the PostgreSQL binaries (otherwise, pg_config --bindir; otherwise,
#                    the highest /usr/lib/postgresql/*/bin; otherwise, the PATH)
#   ELDMARK_PG_USER  user that initdb, pg_ctl and pg_basebackup run as when the script runs as
#                    root, which initdb does not allow (postgres by default, with runuser)

# Database user in the ephemeral clusters (initdb -U), as in internal/testdb.
ELD_PG_SUPERUSER=eldmark
# Maximum length of a Unix socket path (sun_path is 108 B including the trailing null).
ELD_MAX_SOCKET_PATH=107

# eld_usage <script>: the script's comment header (its help) to standard error, and exits with 2.
eld_usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$1" >&2
	exit 2
}

# eld_log <text>: a progress line to standard error, with the script's name.
eld_log() {
	printf '[%s] %s\n' "${ELD_SCRIPT:-eldmark}" "$*" >&2
}

# eld_die <text>: the error, to standard error, and exits with 1.
eld_die() {
	printf '[%s] Error: %s\n' "${ELD_SCRIPT:-eldmark}" "$*" >&2
	exit 1
}

# eld_ms: the time in milliseconds (for measuring).
eld_ms() {
	date +%s%3N
}

# eld_find_pg_bin <binary>: sets PG_BIN to the folder of PostgreSQL binaries that has that binary
# (initdb for a cluster, pg_dump for a backup).
eld_find_pg_bin() {
	local tool="$1" dir candidate
	PG_BIN=""
	if [ -n "${ELDMARK_PG_BIN:-}" ]; then
		# The given one rules: without the binary in it, nowhere else is searched.
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
	# /usr/lib/postgresql/<version>/bin, from highest to lowest.
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

# eld_pg_runas: as root, sets PG_RUNAS to the unprivileged user that runs the server
# (ELDMARK_PG_USER, postgres by default); otherwise leaves it empty.
eld_pg_runas() {
	PG_RUNAS=""
	if [ "$(id -u)" -eq 0 ]; then
		PG_RUNAS="${ELDMARK_PG_USER:-postgres}"
		id "$PG_RUNAS" > /dev/null 2>&1 ||
			eld_die "corre como root e initdb no lo admite: falta el usuario $PG_RUNAS (ELDMARK_PG_USER)"
		command -v runuser > /dev/null 2>&1 || eld_die "corre como root y falta runuser para usar $PG_RUNAS"
	fi
}

# eld_as_pg <command> [arguments]: runs a binary from PG_BIN as the server's user.
eld_as_pg() {
	local tool="$1"
	shift
	if [ -n "${PG_RUNAS:-}" ]; then
		runuser -u "$PG_RUNAS" -- "$PG_BIN/$tool" "$@"
	else
		"$PG_BIN/$tool" "$@"
	fi
}

# eld_as_pg_cmd <command> [arguments]: runs a command from the PATH as the server's user (to create
# and copy files inside its folders).
eld_as_pg_cmd() {
	if [ -n "${PG_RUNAS:-}" ]; then
		runuser -u "$PG_RUNAS" -- "$@"
	else
		"$@"
	fi
}

# eld_give_to_pg <folder>: as root, hands the folder over to the server's user and checks that it
# can write to it (it cannot if a folder above does not let it through, like /root).
eld_give_to_pg() {
	local dir="$1"
	[ -n "${PG_RUNAS:-}" ] || return 0
	chown "$PG_RUNAS" "$dir"
	runuser -u "$PG_RUNAS" -- test -w "$dir" ||
		eld_die "el usuario $PG_RUNAS no puede escribir en $dir (una carpeta de encima no le deja pasar): usa otra (TMPDIR=/tmp)"
}

# eld_check_socket_dir <folder>: the socket path has to fit in sun_path.
eld_check_socket_dir() {
	local path="$1/.s.PGSQL.5432"
	[ "${#path}" -le "$ELD_MAX_SOCKET_PATH" ] ||
		eld_die "la ruta del socket ($path) pasa de $ELD_MAX_SOCKET_PATH B: usa una carpeta más corta (TMPDIR=/tmp)"
}

# eld_initdb <data>: creates an empty cluster (eldmark superuser, no password: local socket only).
eld_initdb() {
	eld_as_pg initdb -D "$1" -U "$ELD_PG_SUPERUSER" --auth=trust -E UTF8 --no-locale --no-sync --no-instructions \
		> /dev/null
}

# eld_pg_start <data> <log> <postgres options>: starts the server and waits for it to accept
# connections. To listen only on a Unix socket (no ports to clash):
# "-k '<folder>' -c listen_addresses=".
eld_pg_start() {
	local data="$1" log="$2" options="$3"
	eld_as_pg pg_ctl -w -s -D "$data" -l "$log" start -o "$options" > /dev/null ||
		{ cat "$log" >&2 2> /dev/null; eld_die "no arranca PostgreSQL en $data"; }
}

# Options for a disposable cluster: no fsync (if the machine goes down, it is thrown away). Used by
# the scripts that load this file.
# shellcheck disable=SC2034
ELD_PG_FAST="-c fsync=off -c synchronous_commit=off -c full_page_writes=off"

# eld_pg_stop <data> [mode]: stops the server if it is running (immediate by default).
eld_pg_stop() {
	local data="$1" mode="${2:-immediate}"
	if [ -f "$data/postmaster.pid" ]; then
		eld_as_pg pg_ctl -s -D "$data" -m "$mode" stop > /dev/null 2>&1 || true
	fi
}

# eld_psql <connection string> [psql arguments]: psql without ~/.psqlrc, stopping at the first
# error and without decoration.
eld_psql() {
	local conn="$1"
	shift
	"$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -At -d "$conn" "$@"
}

# eld_random_b64 <bytes>: random bytes in standard base64.
eld_random_b64() {
	head -c "$1" /dev/urandom | base64 | tr -d '\n'
}

# eld_random_hex <bytes>: random bytes in hexadecimal.
eld_random_hex() {
	head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# eld_sha256_hex <text>: SHA-256 in hexadecimal of the text (without a trailing newline).
eld_sha256_hex() {
	printf '%s' "$1" | sha256sum | cut -c1-64
}
