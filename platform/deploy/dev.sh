#!/usr/bin/env bash
# La plataforma en local para desarrollar (docs/plataforma.md §12): un PostgreSQL propio en
# build/dev_pg (initdb, como internal/testdb, pero se conserva entre arranques), las migraciones,
# claves de billete y un token por zona de desarrollo (1:vado_gris:0 y 1:test_world:0) en
# build/dev_secrets, el entorno en build/dev_platform.env, una cuenta admin (admin@eldmark.test,
# para --actor) y una de prueba (prueba@eldmark.test), y la orden de la zona con --platform.
#
# Uso (desde cualquier carpeta):
#   dev.sh [up]     lo prepara todo y arranca serve en primer plano; Ctrl-C para serve y PostgreSQL
#   dev.sh prepare  lo prepara todo y deja PostgreSQL en marcha, sin serve
#   dev.sh env      las variables para usar eldmark-platform a mano: eval "$(platform/deploy/dev.sh env)"
#   dev.sh stop     para PostgreSQL
#   dev.sh reset    lo para y borra la base, las claves y el entorno de desarrollo
#
# Variables:
#   ELDMARK_DEV_DIR        carpeta de trabajo (por defecto, build/ en la raíz del repositorio)
#   ELDMARK_DEV_PG_PORT    puerto de PostgreSQL, solo en 127.0.0.1 (24682)
#   ELDMARK_DEV_PUBLIC_ADDR · ELDMARK_DEV_INTERNAL_ADDR   las API (127.0.0.1:24680 · 127.0.0.1:24681),
#                          leídas al crear dev_platform.env (reset para cambiarlas)
#   ELDMARK_PLATFORM_BIN   un binario ya compilado (si no, go build a <carpeta>/eldmark-platform)
#   ELDMARK_PG_BIN, ELDMARK_PG_USER   como en internal/testdb (pglib.sh)
#
# Necesita bash, los binarios de PostgreSQL 16 y Go 1.24 (Linux, macOS o WSL). Nada de esto vale
# para staging ni producción: la base no tiene contraseña y las claves son de usar y tirar.
set -euo pipefail

ELD_SCRIPT=dev
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pglib.sh source-path=SCRIPTDIR
. "$script_dir/pglib.sh"

repo="$(cd "$script_dir/../.." && pwd)"
dir="${ELDMARK_DEV_DIR:-$repo/build}"
pg_dir="$dir/dev_pg"
data="$pg_dir/data"
secrets="$dir/dev_secrets"
env_file="$dir/dev_platform.env"
port="${ELDMARK_DEV_PG_PORT:-24682}"
admin_email="admin@eldmark.test"
test_email="prueba@eldmark.test"
# Contraseñas fijas de desarrollo (también en build/dev_secrets/*.password): se teclean en el título.
admin_password="eldmark-admin-dev"
test_password="eldmark-prueba-dev"
dev_zones=(vado_gris test_world)

usage() {
	eld_usage "${BASH_SOURCE[0]}"
}

# platform_bin: el binario (compilado si hace falta) en $bin.
platform_bin() {
	if [ -n "${ELDMARK_PLATFORM_BIN:-}" ]; then
		bin="$ELDMARK_PLATFORM_BIN"
		[ -x "$bin" ] || eld_die "ELDMARK_PLATFORM_BIN=$bin no es un ejecutable"
		return 0
	fi
	command -v go > /dev/null 2>&1 || eld_die "falta Go 1.24 para compilar la plataforma (o da ELDMARK_PLATFORM_BIN)"
	bin="$dir/eldmark-platform"
	eld_log "compilando la plataforma en $bin"
	(cd "$repo/platform" && GOTOOLCHAIN=local go build -o "$bin" ./cmd/eldmark-platform) ||
		eld_die "no compila la plataforma"
}

# write_env: las claves, los tokens y dev_platform.env, solo la primera vez (se conservan).
write_env() {
	[ -f "$env_file" ] && return 0
	mkdir -p "$secrets"
	chmod 0700 "$secrets"
	local zone token tokens=""
	(umask 077 && printf '1:%s\n' "$(eld_random_b64 32)" > "$secrets/ticket_keys")
	for zone in "${dev_zones[@]}"; do
		token="$(eld_random_hex 32)"
		(umask 077 && printf '%s\n' "$token" > "$secrets/zone_token_$zone")
		tokens="${tokens:+$tokens,}1:$zone:0:$(eld_sha256_hex "$token")"
	done
	(umask 077 && printf '%s\n' "$tokens" > "$secrets/zone_tokens")
	(umask 077 && printf '%s\n' "$admin_password" > "$secrets/admin.password")
	(umask 077 && printf '%s\n' "$test_password" > "$secrets/prueba.password")
	local public="${ELDMARK_DEV_PUBLIC_ADDR:-127.0.0.1:24680}" internal="${ELDMARK_DEV_INTERNAL_ADDR:-127.0.0.1:24681}"
	{
		echo "# Entorno de desarrollo de la plataforma, generado por platform/deploy/dev.sh (no vale para staging"
		echo "# ni producción). Se borra con «dev.sh reset»."
		printf 'ELDMARK_ENV=%q\n' dev
		printf 'ELDMARK_DATABASE_URL=%q\n' "postgres://$ELD_PG_SUPERUSER@127.0.0.1:$port/eldmark?sslmode=disable"
		printf 'ELDMARK_PUBLIC_ADDR=%q\n' "$public"
		printf 'ELDMARK_INTERNAL_ADDR=%q\n' "$internal"
		printf 'ELDMARK_PUBLIC_URL=%q\n' "http://$public"
		printf 'ELDMARK_ZONE_TOKENS_FILE=%q\n' "$secrets/zone_tokens"
		printf 'ELDMARK_TICKET_KEYS_FILE=%q\n' "$secrets/ticket_keys"
	} > "$env_file"
	eld_log "entorno nuevo en $env_file (claves y tokens en $secrets)"
}

load_env() {
	set -a
	# shellcheck source=/dev/null
	. "$env_file"
	set +a
}

# start_pg: crea el clúster la primera vez y lo arranca si no está en marcha.
start_pg() {
	eld_find_pg_bin initdb
	eld_pg_runas
	mkdir -p "$pg_dir"
	chmod 0700 "$pg_dir"
	eld_give_to_pg "$pg_dir"
	if [ ! -f "$data/PG_VERSION" ]; then
		eld_log "clúster nuevo en $data"
		eld_initdb "$data"
	fi
	if eld_as_pg pg_ctl -s -D "$data" status > /dev/null 2>&1; then
		return 0
	fi
	eld_pg_start "$data" "$pg_dir/postgres.log" "-k '' -c listen_addresses=127.0.0.1 -p $port"
	eld_log "PostgreSQL en 127.0.0.1:$port"
	local server="host=127.0.0.1 port=$port user=$ELD_PG_SUPERUSER sslmode=disable"
	if [ -z "$(eld_psql "$server dbname=postgres" -c "select 1 from pg_database where datname = 'eldmark'")" ]; then
		eld_psql "$server dbname=postgres" -c "create database eldmark"
	fi
}

# accounts: la cuenta admin (bootstrap, si no hay ninguna) y la de prueba, si faltan.
accounts() {
	local db="host=127.0.0.1 port=$port user=$ELD_PG_SUPERUSER dbname=eldmark sslmode=disable" actor
	actor="$(eld_psql "$db" -c "select email from accounts where email = '$admin_email' and role = 'admin' and status = 'active'")"
	if [ -z "$actor" ]; then
		actor="$(eld_psql "$db" -c "select email from accounts where role = 'admin' and status = 'active'
			and email is not null order by account_id limit 1")"
	fi
	if [ -z "$actor" ]; then
		"$bin" admin bootstrap "$admin_email" --password-file "$secrets/admin.password" > /dev/null
		actor="$admin_email"
		eld_log "cuenta admin: $admin_email"
	fi
	if [ -z "$(eld_psql "$db" -c "select 1 from accounts where email = '$test_email'")" ]; then
		"$bin" admin --actor "$actor" create-account "$test_email" --password-file "$secrets/prueba.password" > /dev/null
		eld_log "cuenta de prueba: $test_email"
	fi
	ACTOR="$actor"
}

prepare() {
	mkdir -p "$dir"
	platform_bin
	write_env
	load_env
	start_pg
	"$bin" migrate up > /dev/null || eld_die "migrate up falla"
	accounts
	local zone_url="http://${ELDMARK_INTERNAL_ADDR}" public_url="$ELDMARK_PUBLIC_URL"
	cat >&2 << EOF

Plataforma de desarrollo lista (base: 127.0.0.1:$port; entorno: $env_file).
  Cuentas: $ACTOR (admin) y $test_email; contraseñas: $admin_password y $test_password
           (también en $secrets/*.password).
  Orden admin: eval "\$(platform/deploy/dev.sh env)"; $bin admin --actor $ACTOR help

  Zona (otra terminal, en la raíz del repositorio; --platform llega con docs/plataforma.md P4):
    ELDMARK_ZONE_TOKEN_FILE=$secrets/zone_token_vado_gris ELDMARK_TICKET_KEYS_FILE=$secrets/ticket_keys \\
      godot --headless --path . -- --server --zone=vado_gris --platform=$zone_url
    (test_world: --zone=test_world y ELDMARK_ZONE_TOKEN_FILE=$secrets/zone_token_test_world)
  Cliente (P8):  godot --path . -- --title --platform=$public_url
  Bot (P8):      godot --headless --path . -- --bot --platform=$public_url --login=$test_email \\
                   --password-file=$secrets/prueba.password
EOF
}

command="${1:-up}"
[ $# -le 1 ] || usage
case "$command" in
up)
	prepare
	eld_log "serve en primer plano (Ctrl-C para parar)"
	"$bin" serve &
	serve_pid=$!
	trap 'kill -TERM "$serve_pid" 2> /dev/null || true' INT TERM
	status=0
	wait "$serve_pid" || status=$?
	# Un INT o un TERM corta el primer wait: se espera a que serve termine de verdad.
	if kill -0 "$serve_pid" 2> /dev/null; then
		status=0
		wait "$serve_pid" || status=$?
	fi
	trap - INT TERM
	eld_pg_stop "$data" fast
	eld_log "parado (los datos siguen en $pg_dir)"
	exit "$status"
	;;
prepare)
	prepare
	;;
env)
	[ -f "$env_file" ] || eld_die "aún no hay entorno: dev.sh prepare"
	load_env
	for name in ELDMARK_ENV ELDMARK_DATABASE_URL ELDMARK_PUBLIC_ADDR ELDMARK_INTERNAL_ADDR ELDMARK_PUBLIC_URL \
		ELDMARK_ZONE_TOKENS_FILE ELDMARK_TICKET_KEYS_FILE; do
		printf 'export %s=%q\n' "$name" "${!name}"
	done
	;;
stop)
	eld_find_pg_bin initdb
	eld_pg_runas
	eld_pg_stop "$data" fast
	eld_log "PostgreSQL parado"
	;;
reset)
	eld_find_pg_bin initdb
	eld_pg_runas
	eld_pg_stop "$data" fast
	rm -rf "$pg_dir" "$secrets" "$env_file"
	eld_log "borrados $pg_dir, $secrets y $env_file"
	;;
-h | --help | help)
	usage
	;;
*)
	usage
	;;
esac
