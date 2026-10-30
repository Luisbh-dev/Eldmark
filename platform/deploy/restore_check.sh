#!/usr/bin/env bash
# Restauración de prueba de una copia (docs/plataforma.md §11.2 y §12, TEC-28): la restaura en un
# clúster de PostgreSQL efímero, aplica las migraciones que le falten, vuelve a aplicar las purgas
# con el purges.txt más reciente (eldmark-platform admin reapply-purges) y hace las consultas de
# integridad. No toca la base de verdad ni deja nada: el clúster se borra al salir.
#
# Uso:
#   restore_check.sh <copia.dump> <purges.txt>
#   restore_check.sh --dir <carpeta de backup.sh>   la copia más reciente (daily/ o weekly/) y el
#                                                   purges.txt más reciente de esa carpeta
#
# Sale con 0 si todo cuadra, 1 si algo falla (para alertar, TEC-31) y 2 si el uso no vale.
#
# Variables:
#   ELDMARK_PLATFORM_BIN    el binario eldmark-platform (por defecto, el del PATH)
#   ELDMARK_RESTORE_ACTOR   correo de una cuenta admin de la copia para el --actor de reapply-purges
#                           (por defecto, la primera admin activa que no está en purges.txt; si la
#                           copia no tiene ninguna, se crea una de usar y tirar con bootstrap)
#   ELDMARK_PG_BIN, ELDMARK_PG_USER   como en internal/testdb (pglib.sh)
#   TMPDIR                  dónde va el clúster (corto: la ruta del socket no puede pasar de 107 B)
set -euo pipefail

ELD_SCRIPT=restore_check
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pglib.sh source-path=SCRIPTDIR
. "$script_dir/pglib.sh"

usage() {
	eld_usage "${BASH_SOURCE[0]}"
}

dump=""
purges=""
case "${1:-}" in
--dir)
	[ $# -eq 2 ] || usage
	backup_dir="$2"
	[ -d "$backup_dir" ] || eld_die "$backup_dir no es una carpeta"
	dump="$(find "$backup_dir/daily" "$backup_dir/weekly" -maxdepth 1 -name 'eldmark-*.dump' -printf '%T@ %p\n' 2> /dev/null |
		sort -n -r | head -n 1 | cut -d' ' -f2- || true)"
	[ -n "$dump" ] || eld_die "no hay ninguna copia (*.dump) en $backup_dir/daily ni en $backup_dir/weekly"
	purges="$backup_dir/purges.txt"
	;;
-h | --help | help)
	usage
	;;
*)
	[ $# -eq 2 ] || usage
	dump="$1"
	purges="$2"
	;;
esac
[ -r "$dump" ] || eld_die "no se puede leer la copia $dump"
[ -r "$purges" ] || eld_die "no se puede leer $purges (el purges.txt más reciente que dejó backup.sh)"

bin="${ELDMARK_PLATFORM_BIN:-}"
if [ -z "$bin" ]; then
	bin="$(command -v eldmark-platform 2> /dev/null)" ||
		eld_die "no se encuentra eldmark-platform: ponlo en el PATH o en ELDMARK_PLATFORM_BIN"
fi
[ -x "$bin" ] || eld_die "ELDMARK_PLATFORM_BIN=$bin no es un ejecutable"

eld_find_pg_bin initdb
eld_pg_runas

started="$(eld_ms)"
work="$(mktemp -d "${TMPDIR:-/tmp}/eldrc-XXXXXX")"
data="$work/data"
cleanup() {
	eld_pg_stop "$data"
	rm -rf "$work"
}
trap cleanup EXIT
chmod 0700 "$work"
eld_give_to_pg "$work"
eld_check_socket_dir "$work"

eld_log "copia: $dump ($(du -h "$dump" | cut -f1)); purges: $purges ($(grep -c . "$purges" || true) líneas)"
eld_initdb "$data"
eld_pg_start "$data" "$work/postgres.log" "-k '$work' -c listen_addresses= $ELD_PG_FAST"
conn="host=$work port=5432 user=$ELD_PG_SUPERUSER dbname=eldmark sslmode=disable"
eld_psql "host=$work port=5432 user=$ELD_PG_SUPERUSER dbname=postgres" -c "create database eldmark"

# 1. pg_restore de la copia entera (sin dueños ni permisos: el clúster es de otro usuario).
t0="$(eld_ms)"
"$PG_BIN/pg_restore" --no-owner --no-privileges --exit-on-error -d "$conn" "$dump" ||
	eld_die "pg_restore no ha podido restaurar la copia"
restore_ms=$(($(eld_ms) - t0))
counts="$(eld_psql "$conn" -F ' ' -c "select (select count(*) from accounts), (select count(*) from characters)")"
eld_log "restaurada en $restore_ms ms: ${counts% *} cuentas y ${counts#* } personajes"

# 2. purges.txt en un esquema aparte del clúster de prueba, y los correos que la copia aún tiene de
#    las cuentas purgadas después de tomarla (antes de reapply-purges, que los borra): con ellos se
#    mira que la auditoría no guarde ninguno (§11.2).
eld_psql "$conn" -c "create schema restore_check" \
	-c "create table restore_check.purges (kind text not null, id bigint not null, purged_at timestamptz not null)"
eld_psql "$conn" -c "copy restore_check.purges (kind, id, purged_at) from stdin" < "$purges" ||
	eld_die "$purges no tiene el formato de backup.sh (kind<TAB>id<TAB>purged_at)"
eld_psql "$conn" -c "create table restore_check.purged_emails as
	select a.account_id, lower(a.email) as email from accounts a
	join restore_check.purges p on p.kind = 'account' and p.id = a.account_id
	where a.email is not null"
purge_counts="$(eld_psql "$conn" -F ' ' -c "select count(*) filter (where kind = 'account'),
	count(*) filter (where kind = 'character'), (select count(*) from restore_check.purged_emails)
	from restore_check.purges")"
read -r purge_accounts purge_characters purge_emails <<< "$purge_counts"
eld_log "purges.txt: $purge_accounts cuentas y $purge_characters personajes; la copia aún tiene el correo de $purge_emails"

# 3. La orden de la plataforma, con una configuración de usar y tirar: solo ve la base de prueba.
platform() {
	env -i PATH="$PATH" HOME="${HOME:-/tmp}" USER="${USER:-restore_check}" TMPDIR="${TMPDIR:-/tmp}" \
		ELDMARK_ENV=dev \
		ELDMARK_DATABASE_URL="$conn" \
		ELDMARK_ZONE_TOKENS="1:restore_check:0:$(eld_random_hex 32)" \
		ELDMARK_TICKET_KEYS="1:$(eld_random_b64 32)" \
		ELDMARK_EMAIL_HMAC_KEY="$(eld_random_b64 32)" \
		"$bin" "$@"
}

# 4. Las migraciones que falten (una copia de antes de un despliegue; expandir y contraer, §2.4).
if ! platform migrate status > "$work/status.txt" 2>&1; then
	eld_log "a la copia le faltan migraciones del binario: migrate up"
	platform migrate up >&2 || eld_die "migrate up falla sobre la copia"
fi

# 5. reapply-purges con una cuenta admin de la copia (o una de usar y tirar si no tiene ninguna).
actor="${ELDMARK_RESTORE_ACTOR:-}"
if [ -z "$actor" ]; then
	actor="$(eld_psql "$conn" -c "select email from accounts a
		where a.role = 'admin' and a.status = 'active' and a.email is not null
		and not exists (select 1 from restore_check.purges p where p.kind = 'account' and p.id = a.account_id)
		and not exists (select 1 from sanctions s where s.account_id = a.account_id and s.revoked_at is null
			and s.kind in ('suspension', 'ban') and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now()))
		order by a.account_id limit 1")"
fi
if [ -z "$actor" ]; then
	admins="$(eld_psql "$conn" -c "select count(*) from accounts where role = 'admin' and status <> 'purged'")"
	[ "$admins" -eq 0 ] ||
		eld_die "la copia no tiene ninguna cuenta admin que pueda hacer de --actor: da una con ELDMARK_RESTORE_ACTOR"
	actor="restore-check@eldmark.invalid"
	eld_random_b64 24 > "$work/actor.password"
	platform admin bootstrap "$actor" --password-file "$work/actor.password" > /dev/null ||
		eld_die "no se puede crear la cuenta admin de usar y tirar"
	eld_log "la copia no tiene cuentas admin: se usa una de usar y tirar"
fi
t0="$(eld_ms)"
platform admin --actor "$actor" reapply-purges "$purges" >&2 || eld_die "reapply-purges falla sobre la copia"
reapply_ms=$(($(eld_ms) - t0))

# 6. El esquema, al día con el binario.
platform migrate status > "$work/status.txt" 2>&1 ||
	{ cat "$work/status.txt" >&2; eld_die "migrate status: la base restaurada no está al día con el binario"; }

# 7. Integridad: cada consulta tiene que dar 0.
checks="$(eld_psql "$conn" -F '|' <<'SQL'
-- Todo por conjuntos (una pasada por tabla): con miles de purgas y tablas grandes, un exists por
-- fila sobre columnas sin índice (chat_messages.sender_account_id) tarda minutos.
with purged_accounts as (
	select id from purge_log where kind = 'account'
	union
	select id from restore_check.purges where kind = 'account'
), purged_characters as (
	select id from purge_log where kind = 'character'
	union
	select id from restore_check.purges where kind = 'character'
	union
	select c.character_id from characters c join purged_accounts a on a.id = c.account_id
), dirty_accounts as (
	select a.account_id as id from accounts a join purged_accounts p on p.id = a.account_id
		where a.status <> 'purged' or a.purged_at is null or a.email is not null or a.password_hash is not null
	union select s.account_id from sessions s join purged_accounts p on p.id = s.account_id
	union select t.account_id from account_tokens t join purged_accounts p on p.id = t.account_id
	union select e.account_id from auth_events e join purged_accounts p on p.id = e.account_id
	union select c.account_id from consents c join purged_accounts p on p.id = c.account_id
	union select l.account_id from legal_acceptances l join purged_accounts p on p.id = l.account_id
	union select e.account_id from entitlements e join purged_accounts p on p.id = e.account_id
	union select r.account_id from account_realms r join purged_accounts p on p.id = r.account_id
	union select i.account_id from ignores i join purged_accounts p on p.id = i.account_id
	union select i.ignored_account_id from ignores i join purged_accounts p on p.id = i.ignored_account_id
	union select m.sender_account_id from chat_messages m join purged_accounts p on p.id = m.sender_account_id
	union select s.account_id from sanctions s join purged_accounts p on p.id = s.account_id where s.reason <> ''
), dirty_characters as (
	select c.character_id as id from characters c join purged_characters p on p.id = c.character_id
		where c.purged_at is null or c.name is not null or c.name_key is not null
	union select s.character_id from character_pvp_stats s join purged_characters p on p.id = s.character_id
	union select l.character_id from character_leases l join purged_characters p on p.id = l.character_id
	union select t.character_id from enter_tickets t join purged_characters p on p.id = t.character_id
	union select n.character_id from character_names n join purged_characters p on p.id = n.character_id
)
select 'personajes sin cuenta', count(*) from characters c
	where not exists (select 1 from accounts a where a.account_id = c.account_id)
union all
select 'arrendamientos de instancias inexistentes', count(*) from character_leases l
	where not exists (select 1 from zone_instances z where z.zone_instance_id = l.claimed_by)
	or (l.zone_instance_id is not null
		and not exists (select 1 from zone_instances z where z.zone_instance_id = l.zone_instance_id))
union all
select 'arrendamientos que siguen de la copia', count(*) from character_leases
union all
select 'billetes que siguen de la copia', count(*) from enter_tickets
union all
select 'purgas de purges.txt sin fila en purge_log', count(*) from restore_check.purges p
	where not exists (select 1 from purge_log l where l.kind = p.kind and l.id = p.id)
	and (exists (select 1 from accounts a where p.kind = 'account' and a.account_id = p.id)
		or exists (select 1 from characters c where p.kind = 'character' and c.character_id = p.id))
union all
select 'purged_at distinto del de purges.txt', count(*) from restore_check.purges p
	left join accounts a on p.kind = 'account' and a.account_id = p.id
	left join characters c on p.kind = 'character' and c.character_id = p.id
	where (a.account_id is not null and a.purged_at is distinct from p.purged_at)
	or (c.character_id is not null and c.purged_at is distinct from p.purged_at)
union all
select 'cuentas purgadas con datos personales', count(*) from dirty_accounts
union all
select 'personajes purgados con datos personales', count(*) from dirty_characters
union all
select 'correos de cuentas purgadas en outbound_mail', count(*) from outbound_mail o
	join restore_check.purged_emails e on lower(o.to_email) = e.email
union all
-- Una fila sin «@» no puede tener un correo: así solo se busca en las que sí (ninguna, si todo va bien).
select 'filas de audit_log con el correo de una cuenta purgada', count(*) from audit_log l
	where strpos(l.args::text, '@') > 0
	and exists (select 1 from restore_check.purged_emails e where strpos(lower(l.args::text), e.email) > 0)
SQL
)"
failed=0
while IFS='|' read -r name count; do
	if [ "$count" -ne 0 ]; then
		eld_log "MAL: $name: $count"
		failed=1
	else
		eld_log "bien: $name: 0"
	fi
done <<< "$checks"
[ "$failed" -eq 0 ] || eld_die "la copia restaurada no pasa las comprobaciones de integridad"

total_ms=$(($(eld_ms) - started))
echo "Restauración de prueba correcta: $(basename "$dump"), restaurada en $restore_ms ms, reapply-purges en $reapply_ms ms" \
	"($purge_accounts cuentas y $purge_characters personajes), todo en $total_ms ms."
