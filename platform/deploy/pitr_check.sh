#!/usr/bin/env bash
# Point-in-time recovery test (docs/platform.md §12, TEC-28), all in ephemeral PostgreSQL
# clusters: a primary with archive_command copies its WAL to a folder; pg_basebackup takes the base
# backup; more rows are written, the time is noted and almost all of them are deleted; then the base
# backup is restored with restore_command, recovery_target_time and recovery.signal, and the
# recovered cluster has to have all the rows from before the deletion (including those written after
# the base backup, which are only in the WAL). It is the same procedure as on the VPS with WAL-G
# (archive_command = wal-g wal-push, restore_command = wal-g wal-fetch); here the archive is a
# folder.
#
# Usage: pitr_check.sh       Exits 0 if it recovers what it should recover and 1 if not.
#
# Variables: ELDMARK_PG_BIN, ELDMARK_PG_USER (pglib.sh) and TMPDIR (short: the socket path).
set -euo pipefail

ELD_SCRIPT=pitr_check
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pglib.sh source-path=SCRIPTDIR
. "$script_dir/pglib.sh"

[ $# -eq 0 ] || eld_usage "${BASH_SOURCE[0]}"

eld_find_pg_bin initdb
eld_pg_runas

started="$(eld_ms)"
work="$(mktemp -d "${TMPDIR:-/tmp}/eldpitr-XXXXXX")"
primary="$work/primary"
restored="$work/restored"
archive="$work/wal"
cleanup() {
	eld_pg_stop "$restored"
	eld_pg_stop "$primary"
	rm -rf "$work"
}
trap cleanup EXIT
chmod 0700 "$work"
eld_give_to_pg "$work"
mkdir -p "$work/s1" "$work/s2"
[ -z "${PG_RUNAS:-}" ] || chown "$PG_RUNAS" "$work/s1" "$work/s2"
eld_check_socket_dir "$work/s1"
eld_as_pg_cmd mkdir -p "$archive"

# 1. The primary, with the WAL archived in a folder (on the VPS, WAL-G to S3-compatible storage).
eld_initdb "$primary"
eld_as_pg_cmd sh -c "cat >> '$primary/postgresql.auto.conf'" <<CONF
wal_level = replica
archive_mode = on
archive_command = 'test ! -f $archive/%f && cp %p $archive/%f'
CONF
# Only fsync=off: full_page_writes and synchronous_commit as on the VPS, since the WAL is what is
# being tested.
eld_pg_start "$primary" "$work/primary.log" "-k '$work/s1' -c listen_addresses= -c fsync=off"
p1="host=$work/s1 port=5432 user=$ELD_PG_SUPERUSER dbname=postgres"
eld_psql "$p1" -c "create database eldmark"
p1="host=$work/s1 port=5432 user=$ELD_PG_SUPERUSER dbname=eldmark"
eld_psql "$p1" -c "create table pitr_probe (id int primary key, note text not null)" \
	-c "insert into pitr_probe select g, 'antes de la copia base' from generate_series(1, 1000) g"

# 2. The base backup.
t0="$(eld_ms)"
eld_as_pg pg_basebackup -d "host=$work/s1 port=5432 user=$ELD_PG_SUPERUSER" -D "$work/base" -X stream -c fast
base_ms=$(($(eld_ms) - t0))

# 3. Rows that will only be in the WAL, the target time and the deletion to be undone.
eld_psql "$p1" -c "insert into pitr_probe select g, 'tras la copia base' from generate_series(1001, 1500) g"
target="$(eld_psql "$p1" -c "select clock_timestamp()")"
sleep 1
eld_psql "$p1" -c "delete from pitr_probe where id > 10"
# It closes the deletion's segment and waits for it to be archived: the recovery has to see a
# transaction after the target time to know it has arrived.
segment="$(eld_psql "$p1" -c "select pg_walfile_name(pg_switch_wal())")"
for _ in $(seq 1 300); do
	[ -f "$archive/$segment" ] && break
	sleep 0.1
done
[ -f "$archive/$segment" ] || eld_die "el WAL $segment no llega al archivo en 30 s"
left="$(eld_psql "$p1" -c "select count(*) from pitr_probe")"
[ "$left" -eq 10 ] || eld_die "el borrado ha dejado $left filas y no 10"
eld_pg_stop "$primary" fast

# 4. The recovery: the base backup, the archived WAL up to the target time, and promotion.
eld_as_pg_cmd cp -a "$work/base" "$restored"
eld_as_pg_cmd chmod 0700 "$restored"
eld_as_pg_cmd sh -c "cat >> '$restored/postgresql.auto.conf'" <<CONF
archive_mode = off
restore_command = 'cp $archive/%f %p'
recovery_target_time = '$target'
recovery_target_action = 'promote'
CONF
eld_as_pg_cmd touch "$restored/recovery.signal"
t0="$(eld_ms)"
eld_pg_start "$restored" "$work/restored.log" "-k '$work/s2' -c listen_addresses= -c fsync=off"
p2="host=$work/s2 port=5432 user=$ELD_PG_SUPERUSER dbname=eldmark"
for _ in $(seq 1 600); do
	[ "$(eld_psql "$p2" -c "select pg_is_in_recovery()")" = "f" ] && break
	sleep 0.1
done
[ "$(eld_psql "$p2" -c "select pg_is_in_recovery()")" = "f" ] ||
	{ cat "$work/restored.log" >&2; eld_die "el clúster recuperado no sale de la recuperación en 60 s"; }
recover_ms=$(($(eld_ms) - t0))

# 5. Everything from before the deletion has to be there, and nothing else.
summary="$(eld_psql "$p2" -F ' ' -c "select count(*), count(*) filter (where note = 'tras la copia base'),
	min(id), max(id) from pitr_probe")"
read -r rows after_base min_id max_id <<< "$summary"
if [ "$rows" -ne 1500 ] || [ "$after_base" -ne 500 ] || [ "$min_id" -ne 1 ] || [ "$max_id" -ne 1500 ]; then
	cat "$work/restored.log" >&2
	eld_die "el clúster recuperado tiene $rows filas ($after_base de tras la copia base, ids $min_id–$max_id); esperaba 1500, 500 y 1–1500"
fi
total_ms=$(($(eld_ms) - started))
echo "Recuperación a un instante correcta: 1500 filas de antes del borrado (500 solo en el WAL)," \
	"copia base en $base_ms ms, recuperación en $recover_ms ms, todo en $total_ms ms."
