#!/usr/bin/env bash
# Backup of the platform database (docs/platform.md §11.2 and §12, TEC-28): pg_dump -Fc with 7
# daily and 4 weekly copies in a folder, and purges.txt (purge_log with its purged_at) next to each
# copy. The most recent purges.txt is also kept in <folder>/purges.txt, which is never rotated:
# restoring is always pg_restore and then "eldmark-platform admin --actor <email> reapply-purges
# <folder>/purges.txt" (the most recent one, not the one from the copy), before starting serve.
#
# Usage: backup.sh            (once a day, from cron or "docker compose run --rm backup")
#
# Variables:
#   ELDMARK_DATABASE_URL or ELDMARK_DATABASE_URL_FILE   the database (otherwise, libpq's PG* vars)
#   ELDMARK_BACKUP_DIR      the folder for the copies (required)
#   ELDMARK_BACKUP_DAILY    how many daily copies are kept (7)
#   ELDMARK_BACKUP_WEEKLY   how many weekly copies are kept (4)
#   ELDMARK_PG_BIN          folder of pg_dump and psql (otherwise, as in pglib.sh)
#
# Exits 0 if the copy and its purges.txt are written and verified, and 1 if not (without leaving
# half-written files). Uploading them elsewhere (S3-compatible with rclone or WAL-G) and the cron
# job are the VPS's business (§12).
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

# The database: the same variable as the platform (or its file, a Docker secret). The string is
# never written to the output: it carries the password.
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
# With milliseconds: two consecutive copies (manual and the cron one) do not overwrite each other;
# the name sorts by date.
stamp="$(date -u +%Y%m%dT%H%M%S.%3NZ)"
name="eldmark-$stamp"
tmp_dump="$dir/daily/.$name.dump.partial"
tmp_purges="$dir/daily/.$name.purges.partial"
tmp_latest="$dir/.purges.txt.partial"
cleanup() {
	rm -f "$tmp_dump" "$tmp_purges" "$tmp_latest"
}
trap cleanup EXIT

# 1. The copy, and then purge_log: purges.txt has at least everything the copy considers purged.
t0="$(eld_ms)"
"$PG_BIN/pg_dump" -Fc --no-password "${dbarg[@]}" -f "$tmp_dump" || eld_die "pg_dump ha fallado"
"$PG_BIN/pg_restore" --list "$tmp_dump" > /dev/null || eld_die "la copia no se puede leer (pg_restore --list)"
dump_ms=$(($(eld_ms) - t0))

# 2. purges.txt: kind<TAB>id<TAB>purged_at in UTC with microseconds (COPY's text format, which
#    reapply-purges and restore_check.sh read as is). No personal data: only ids and dates.
PGTZ=UTC "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 --no-password "${dbarg[@]}" \
	-c "copy (select kind, id, purged_at from purge_log order by purged_at, kind, id) to stdout" > "$tmp_purges" ||
	eld_die "no se puede leer purge_log"
purge_lines="$(grep -c . "$tmp_purges" || true)"

mv "$tmp_dump" "$dir/daily/$name.dump"
mv "$tmp_purges" "$dir/daily/$name.purges.txt"
# The most recent one, always: it is swapped in at once (mv in the same folder), never left
# half-written.
cp "$dir/daily/$name.purges.txt" "$tmp_latest"
mv "$tmp_latest" "$dir/purges.txt"

# 3. Weekly: if the last weekly copy is nearly a week old (or there is none), this copy is one too
#    (hard link if possible: it does not take double the space).
if [ "$keep_weekly" -gt 0 ] && [ -z "$(find "$dir/weekly" -maxdepth 1 -name 'eldmark-*.dump' -mmin -$((7 * 24 * 60 - 60)) -print -quit)" ]; then
	for ext in dump purges.txt; do
		ln "$dir/daily/$name.$ext" "$dir/weekly/$name.$ext" 2> /dev/null ||
			cp -p "$dir/daily/$name.$ext" "$dir/weekly/$name.$ext"
	done
	eld_log "también semanal: $dir/weekly/$name.dump"
fi

# 4. Rotation: the most recent ones in each folder, with their purges.txt; <folder>/purges.txt
#    stays.
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
