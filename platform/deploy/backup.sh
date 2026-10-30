#!/usr/bin/env bash
# Copia de la base de la plataforma (docs/plataforma.md §11.2 y §12, TEC-28): pg_dump -Fc con 7
# diarias y 4 semanales en una carpeta, y purges.txt (purge_log con su purged_at) junto a cada
# copia. El purges.txt más reciente se guarda además en <carpeta>/purges.txt, que no se rota nunca:
# restaurar es siempre pg_restore y luego «eldmark-platform admin --actor <correo> reapply-purges
# <carpeta>/purges.txt» (el más reciente, no el de la copia), antes de arrancar serve.
#
# Uso: backup.sh            (una vez al día, desde cron o «docker compose run --rm backup»)
#
# Variables:
#   ELDMARK_DATABASE_URL o ELDMARK_DATABASE_URL_FILE   la base (si no, las variables PG* de libpq)
#   ELDMARK_BACKUP_DIR      la carpeta de las copias (obligatoria)
#   ELDMARK_BACKUP_DAILY    cuántas diarias se conservan (7)
#   ELDMARK_BACKUP_WEEKLY   cuántas semanales se conservan (4)
#   ELDMARK_PG_BIN          carpeta de pg_dump y psql (si no, como pglib.sh)
#
# Sale con 0 si la copia y su purges.txt quedan escritos y comprobados, y con 1 si no (sin dejar
# archivos a medias). Subirlas fuera (S3 compatible con rclone o WAL-G) y el cron son del VPS (§12).
set -euo pipefail

ELD_SCRIPT=backup
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pglib.sh source-path=SCRIPTDIR
. "$script_dir/pglib.sh"

[ $# -eq 0 ] || eld_usage "${BASH_SOURCE[0]}"

dir="${ELDMARK_BACKUP_DIR:-}"
[ -n "$dir" ] || eld_die "falta ELDMARK_BACKUP_DIR (la carpeta de las copias)"
keep_daily="${ELDMARK_BACKUP_DAILY:-7}"
keep_weekly="${ELDMARK_BACKUP_WEEKLY:-4}"
[[ "$keep_daily" =~ ^[1-9][0-9]*$ ]] || eld_die "ELDMARK_BACKUP_DAILY tiene que ser un entero mayor que 0"
[[ "$keep_weekly" =~ ^[0-9]+$ ]] || eld_die "ELDMARK_BACKUP_WEEKLY tiene que ser un entero"

# La base: la misma variable que la plataforma (o su archivo, un secreto de Docker). La cadena no se
# escribe nunca en la salida: lleva la contraseña.
conn="${ELDMARK_DATABASE_URL:-}"
if [ -n "${ELDMARK_DATABASE_URL_FILE:-}" ]; then
	[ -z "$conn" ] || eld_die "se ha dado a la vez ELDMARK_DATABASE_URL y ELDMARK_DATABASE_URL_FILE; usa solo una"
	[ -r "$ELDMARK_DATABASE_URL_FILE" ] || eld_die "no se puede leer ELDMARK_DATABASE_URL_FILE"
	conn="$(tr -d '\r\n' < "$ELDMARK_DATABASE_URL_FILE")"
fi
dbarg=()
if [ -n "$conn" ]; then
	dbarg=(-d "$conn")
fi

eld_find_pg_bin pg_dump

umask 077
mkdir -p "$dir/daily" "$dir/weekly"
# Con milisegundos: dos copias seguidas (a mano y la del cron) no se pisan; el nombre ordena por fecha.
stamp="$(date -u +%Y%m%dT%H%M%S.%3NZ)"
name="eldmark-$stamp"
tmp_dump="$dir/daily/.$name.dump.partial"
tmp_purges="$dir/daily/.$name.purges.partial"
tmp_latest="$dir/.purges.txt.partial"
cleanup() {
	rm -f "$tmp_dump" "$tmp_purges" "$tmp_latest"
}
trap cleanup EXIT

# 1. La copia, y después purge_log: purges.txt tiene al menos todo lo que la copia da por purgado.
t0="$(eld_ms)"
"$PG_BIN/pg_dump" -Fc --no-password "${dbarg[@]}" -f "$tmp_dump" || eld_die "pg_dump ha fallado"
"$PG_BIN/pg_restore" --list "$tmp_dump" > /dev/null || eld_die "la copia no se puede leer (pg_restore --list)"
dump_ms=$(($(eld_ms) - t0))

# 2. purges.txt: kind<TAB>id<TAB>purged_at en UTC con microsegundos (el formato de texto de COPY,
#    que reapply-purges y restore_check.sh leen tal cual). Sin datos personales: solo ids y fechas.
PGTZ=UTC "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 --no-password "${dbarg[@]}" \
	-c "copy (select kind, id, purged_at from purge_log order by purged_at, kind, id) to stdout" > "$tmp_purges" ||
	eld_die "no se puede leer purge_log"
purge_lines="$(grep -c . "$tmp_purges" || true)"

mv "$tmp_dump" "$dir/daily/$name.dump"
mv "$tmp_purges" "$dir/daily/$name.purges.txt"
# El más reciente, siempre: se cambia de golpe (mv en la misma carpeta), nunca queda a medias.
cp "$dir/daily/$name.purges.txt" "$tmp_latest"
mv "$tmp_latest" "$dir/purges.txt"

# 3. Semanal: si la última semanal tiene casi una semana (o no hay), esta copia lo es también (enlace
#    duro si se puede: no ocupa el doble).
if [ "$keep_weekly" -gt 0 ] && [ -z "$(find "$dir/weekly" -maxdepth 1 -name 'eldmark-*.dump' -mmin -$((7 * 24 * 60 - 60)) -print -quit)" ]; then
	for ext in dump purges.txt; do
		ln "$dir/daily/$name.$ext" "$dir/weekly/$name.$ext" 2> /dev/null ||
			cp -p "$dir/daily/$name.$ext" "$dir/weekly/$name.$ext"
	done
	eld_log "también semanal: $dir/weekly/$name.dump"
fi

# 4. Rotación: las más recientes de cada carpeta, con su purges.txt; <carpeta>/purges.txt se queda.
rotate() {
	local sub="$1" keep="$2" old
	while IFS= read -r old; do
		[ -n "$old" ] || continue
		rm -f "$old" "${old%.dump}.purges.txt"
		eld_log "rotada: $old"
	done < <(find "$dir/$sub" -maxdepth 1 -name 'eldmark-*.dump' -printf '%f\n' | sort -r | tail -n +$((keep + 1)) |
		sed "s|^|$dir/$sub/|")
}
rotate daily "$keep_daily"
rotate weekly "$keep_weekly"

size="$(du -h "$dir/daily/$name.dump" | cut -f1)"
echo "Copia $dir/daily/$name.dump ($size, $dump_ms ms) y su purges.txt ($purge_lines purgas); también en $dir/purges.txt."
