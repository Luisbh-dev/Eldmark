#!/usr/bin/env bash
# "Zone in a container" check (TEC-20; the job of the same name in .github/workflows/export.yml).
#
# With docker compose it brings up the database, the platform and ONE zone from the image built out of the exported
# server (exports/server, tools/export.sh server), all with throwaway test secrets, and checks the whole path:
#   1. a bot with an account enters with a ticket over DTLS and plays the progress scenario (equips the bow, receives
#      50 gold and a potion); it leaves;
#   2. the same account enters again and the bot SEES what was saved (the gold, the potion) in a new session;
#   3. a third bot is connected when the container is stopped with "docker stop" (SIGTERM): the zone must announce
#      the shutdown, save and release the character, deregister, exit with code 0 and leave a report with
#      "closed": true.
#
# Usage, from the root of the repository: tools/ci/zone_container_check.sh <godot>
#   godot  Godot executable that runs the bots from the project sources (already imported)
# Environment: PYTHON (default python3), KEEP=1 to leave the containers up at the end.
# Everything it writes goes to build/zone-container/. Ports: the platform's API on 127.0.0.1:24680 and the zone's UDP
# 24600.
#
# Exit code: 0 if everything checks out, 1 if not.
set -euo pipefail

GODOT="${1:?godot}"
PYTHON="${PYTHON:-python3}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
WORK="$ROOT/build/zone-container"
SECRETS="$WORK/secrets"
rm -rf "$WORK"
mkdir -p "$SECRETS"

EMAIL="viajera@eldmark.test"
PASSWORD="ci-$(openssl rand -hex 8)"
CHARACTER="Viajera"
API="http://127.0.0.1:24680"

DEPLOY="$ROOT/platform/deploy"
compose() {
	docker compose -p eldmark-ci -f "$DEPLOY/docker-compose.yml" -f "$DEPLOY/docker-compose.ci.yml" \
		--env-file "$WORK/ci.env" --profile zonas "$@"
}

fail() {
	echo "FAILED: $*" >&2
	exit 1
}

dump_logs() {
	echo "--- containers" >&2
	compose ps -a >&2 || true
	for service in platform zone-vado-gris db; do
		echo "--- logs of $service" >&2
		compose logs --no-color --tail 120 "$service" >&2 || true
	done
	for log in "$WORK"/*.log; do
		[ -f "$log" ] || continue
		echo "--- $log" >&2
		tail -n 40 "$log" >&2 || true
	done
}
cleanup() {
	status=$?
	if [ "$status" -ne 0 ]; then
		dump_logs
	fi
	if [ "${KEEP:-0}" != "1" ]; then
		compose down -v --remove-orphans > /dev/null 2>&1 || true
	fi
	exit "$status"
}
trap cleanup EXIT

# --- Test secrets (platform.md 10.3: one file per secret) --------------------------------------------------
PG_PASSWORD="$(openssl rand -hex 16)"
ZONE_TOKEN="ci-$(openssl rand -hex 16)"
printf '%s' "$PG_PASSWORD" > "$SECRETS/postgres_password"
printf 'postgres://eldmark:%s@db:5432/eldmark?sslmode=disable' "$PG_PASSWORD" > "$SECRETS/database_url"
printf '1:%s' "$(openssl rand -base64 32)" > "$SECRETS/ticket_keys"
printf '%s' "$ZONE_TOKEN" > "$SECRETS/zone_token_vado_gris"
printf '1:vado_gris:0:%s' "$(printf '%s' "$ZONE_TOKEN" | openssl dgst -sha256 | sed 's/^.* //')" > "$SECRETS/zone_tokens"
openssl rand -base64 32 | tr -d '\n' > "$SECRETS/email_hmac_key"
printf 'smtp://test:test@localhost:587' > "$SECRETS/smtp_url"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
	-keyout "$SECRETS/vado_gris_dtls_key" -out "$SECRETS/vado_gris_dtls_cert" \
	-subj "/CN=vado-gris.ci.test" -addext "subjectAltName=DNS:vado-gris.ci.test" 2> /dev/null
# Inside the containers the files are read by unprivileged users.
chmod 0755 "$SECRETS"
chmod 0444 "$SECRETS"/*

PROTOCOL="$(sed -n 's/^const PROTOCOL_VERSION: int = \([0-9]*\).*/\1/p' scripts/shared/net/net_protocol.gd | head -n 1)"
[ -n "$PROTOCOL" ] || fail "cannot read PROTOCOL_VERSION"
cat > "$WORK/ci.env" << EOF
ELDMARK_ENV=test
ELDMARK_MAIL=log
ELDMARK_DOMAIN=api.ci.test
ELDMARK_ACME_EMAIL=ci@eldmark.test
ELDMARK_PUBLIC_HOST=127.0.0.1
ELDMARK_ZONE_HOSTS=127.0.0.1
ELDMARK_MIN_PROTOCOL=$PROTOCOL
ELDMARK_MAIL_FROM=no-reply@eldmark.test
ELDMARK_SECRETS_DIR=$SECRETS
ELDMARK_BACKUP_HOST_DIR=$WORK/backups
ELDMARK_PLATFORM_IMAGE=eldmark-platform:ci
ELDMARK_ZONE_IMAGE=eldmark-zone:ci
ELDMARK_OPS_IMAGE=eldmark-ops:ci
EOF

# --- Images and services ------------------------------------------------------------------------------------
[ -f exports/server/eldmark-server.x86_64 ] || fail "exports/server is missing: export the server first (tools/export.sh server)"
compose build platform zone-vado-gris
compose up -d db
compose run --rm platform migrate up
compose up -d platform
for _ in $(seq 1 60); do
	curl -fsS "$API/ready" > /dev/null 2>&1 && break
	sleep 1
done
curl -fsS "$API/ready" > /dev/null || fail "the platform does not become ready"

psql() {
	compose exec -T db psql -U eldmark -d eldmark -tA -c "$1"
}

# --- Account (platform.md 15: the same call the e2e tests make) -------------------------------------------------
BODY="$("$PYTHON" -I -c '
import json, sys
print(json.dumps({"email": sys.argv[1], "password": sys.argv[2], "age_confirmed": True,
    "accept": {"terms": 1, "privacy": 1, "rules": 1}, "consents": {"crash_reports": False, "analytics": False}}))
' "$EMAIL" "$PASSWORD")"
STATUS="$(curl -sS -o "$WORK/register.json" -w '%{http_code}' -X POST "$API/v1/accounts" \
	-H 'Content-Type: application/json' -H "X-Eldmark-Protocol: $PROTOCOL" --data "$BODY")"
[ "$STATUS" = "202" ] || fail "registration answered $STATUS: $(cat "$WORK/register.json")"
psql "update accounts set role = 'admin' where email = '$EMAIL'" > /dev/null
printf '%s\n' "$PASSWORD" > "$WORK/account.pw"

compose up -d zone-vado-gris
echo "Waiting for the zone to be live..."
LIVE=0
for _ in $(seq 1 120); do
	if [ "$(psql "select count(*) from zone_instances where status = 'live'")" = "1" ]; then
		LIVE=1
		break
	fi
	sleep 2
done
[ "$LIVE" = "1" ] || fail "the zone never became live"
ZONE_ID="$(compose ps -q zone-vado-gris)"

run_bot() { # name, extra options...
	local name="$1"
	shift
	"$GODOT" --headless --path "$ROOT" -- --bot --platform="$API" --login="$EMAIL" \
		--password-file="$WORK/account.pw" --character="$CHARACTER" --report="$WORK/$name.json" "$@" \
		> "$WORK/$name.log" 2>&1
}

# --- 1. First session: the progress scenario ------------------------------------------------------------------
run_bot bot1 --bot-scenario=progress --quit-after-ticks=900 || fail "the first bot failed"
CHARACTER_ID="$(psql "select character_id from characters where name = '$CHARACTER'" | head -n 1)"
[ -n "$CHARACTER_ID" ] || fail "the character was not created"
for _ in $(seq 1 30); do
	[ "$(psql "select count(*) from character_leases where character_id = $CHARACTER_ID and zone_instance_id is null and released_at is not null and last_save_version > 0")" = "1" ] && break
	sleep 1
done
[ "$(psql "select count(*) from character_leases where character_id = $CHARACTER_ID and zone_instance_id is null and released_at is not null and last_save_version > 0")" = "1" ] \
	|| fail "the first session was not saved and released"
VERSION1="$(psql "select save_version from character_progress where character_id = $CHARACTER_ID")"
echo "First session saved (save_version $VERSION1)"

# --- 2. Second session: the bot sees what was saved ----------------------------------------------------------------
run_bot bot2 --quit-after-ticks=300 || fail "the second bot failed"
for _ in $(seq 1 30); do
	[ "$(psql "select count(*) from character_leases where character_id = $CHARACTER_ID and zone_instance_id is null and released_at is not null")" = "1" ] && break
	sleep 1
done
"$PYTHON" -I - "$WORK/bot1.json" "$WORK/bot2.json" "$CHARACTER_ID" << 'PY'
import json, sys

first = json.load(open(sys.argv[1], encoding="utf8"))
second = json.load(open(sys.argv[2], encoding="utf8"))
problems = []
if first.get("scenario", {}).get("phase") != "done":
    problems.append("scenario of the first bot: %s" % first.get("scenario"))
if not first.get("platform", {}).get("created"):
    problems.append("the first bot did not create the character: %s" % first.get("platform"))
if second.get("platform", {}).get("created") or second.get("platform", {}).get("character_id") != sys.argv[3]:
    problems.append("the second bot did not get the same character back: %s" % second.get("platform"))
gold = [w for w in second.get("progress", {}).get("wallets", []) if w.get("currency") == 1]
if not gold or gold[0].get("balance") != 50:
    problems.append("the second session does not see the 50 gold: %s" % second.get("progress", {}).get("wallets"))
potions = [i for i in second.get("progress", {}).get("items", []) if i.get("def_id") == "potion_health"]
if not potions:
    problems.append("the second session does not see the health potion")
print("second session: wallets=%s potions=%d" % (second.get("progress", {}).get("wallets"), len(potions)))
if problems:
    print("FAILED: " + "; ".join(problems))
    sys.exit(1)
PY
VERSION2="$(psql "select save_version from character_progress where character_id = $CHARACTER_ID")"

# --- 3. docker stop with a bot inside -----------------------------------------------------------------------------
"$GODOT" --headless --path "$ROOT" -- --bot --platform="$API" --login="$EMAIL" \
	--password-file="$WORK/account.pw" --character="$CHARACTER" --report="$WORK/bot3.json" \
	--quit-after-ticks=100000 > "$WORK/bot3.log" 2>&1 &
BOT3=$!
for _ in $(seq 1 60); do
	[ "$(psql "select count(*) from character_leases where character_id = $CHARACTER_ID and zone_instance_id is not null")" = "1" ] && break
	sleep 1
done
[ "$(psql "select count(*) from character_leases where character_id = $CHARACTER_ID and zone_instance_id is not null")" = "1" ] \
	|| fail "the third bot did not get into the zone"
sleep 5
echo "docker stop (SIGTERM) with a bot inside"
STOP_START="$(date +%s)"
docker stop -t 45 "$ZONE_ID" > /dev/null
echo "The container stopped in $(($(date +%s) - STOP_START)) s"
kill "$BOT3" 2> /dev/null || true
wait "$BOT3" 2> /dev/null || true

EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$ZONE_ID")"
[ "$EXIT_CODE" = "0" ] || fail "the zone exited with code $EXIT_CODE (expected 0)"
compose logs --no-color --no-log-prefix zone-vado-gris > "$WORK/zone-container.log" 2>&1 || true
for expected in "[entrypoint] signal received" "Cierre del servidor: apareció el archivo de parada" \
	"Servidor cerrado" "[entrypoint] the server exited with code 0"; do
	grep -qF "$expected" "$WORK/zone-container.log" || fail "the zone log lacks \"$expected\""
done
docker cp "$ZONE_ID:/run/eldmark/report.json" "$WORK/zone-report.json"
"$PYTHON" -I - "$WORK/zone-report.json" << 'PY'
import json, sys

report = json.load(open(sys.argv[1], encoding="utf8"))
print("final report: closed=%s build=%s at_stop=%s" % (report.get("closed"), report.get("build"),
      report.get("players", {}).get("at_stop")))
if report.get("closed") is not True:
    sys.exit("the final report does not say closed: true")
if report.get("players", {}).get("at_stop", 0) < 1:
    sys.exit("the zone had no player at the stop")
PY
[ "$(psql "select count(*) from character_leases where character_id = $CHARACTER_ID and zone_instance_id is null and released_at is not null")" = "1" ] \
	|| fail "the character is not released after the stop"
VERSION3="$(psql "select save_version from character_progress where character_id = $CHARACTER_ID")"
[ "$VERSION3" -gt "$VERSION2" ] || fail "no final save at the stop (save_version $VERSION2 -> $VERSION3)"
[ "$(psql "select status from zone_instances limit 1")" = "stopped" ] \
	|| fail "the instance is not stopped: $(psql "select status from zone_instances limit 1")"
echo "CONTAINER CHECK OK (save_version $VERSION1 -> $VERSION2 -> $VERSION3)"
