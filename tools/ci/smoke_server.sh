#!/usr/bin/env bash
# Smoke test of the EXPORTED dedicated server (TEC-12): it loads Vado Gris, simulates 300+ ticks and a SwarmBot
# connects and plays. The bot is the one from the project sources (a Godot editor binary), the server is the
# exported one.
#
# Usage: tools/ci/smoke_server.sh <server_dir> <godot> [port]
#   server_dir  folder of the exported server (eldmark-server.x86_64, run-server.sh, BUILD_ID)
#   godot       Godot executable that runs the bot from the project sources
#   port        UDP port (default 26200)
# Environment: SERVER_CMD replaces the command that starts the server up to and including the "--" that precedes the
# game options (to try the script against the sources). The default is the exported binary with --log-file: its standard
# output is block-buffered when redirected, so the log file (flushed) is what says that the zone is listening.
#
# The connection is over DTLS with the certificate of the tests, as in production (the platform only hands out zones with DTLS).
# With PLAIN=1 it is over plain UDP instead (the local and test servers): the client waits for the server to cut the
# connection, because a disconnect started by the client crashes the exported release server (docs/operations.md
# section 9; tools/ci/engine_canary.sh watches for that).
#
# Exit code: 0 if everything checks out, 1 if not.
set -euo pipefail

SERVER_DIR="${1:?server_dir}"
GODOT="${2:?godot}"
PORT="${3:-26200}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/smoke"
DTLS_CERT="$ROOT/tests/fixtures/dtls/zone_cert.pem"
DTLS_KEY="$ROOT/tests/fixtures/dtls/zone_key.pem"
DTLS_NAME="zona-pruebas.eldmark.test"
rm -rf "$OUT"
mkdir -p "$OUT"
SERVER_CMD="${SERVER_CMD:-$SERVER_DIR/eldmark-server.x86_64 --headless --log-file $OUT/server.log --}"

SERVER_DTLS=(--dtls-cert="$DTLS_CERT" --dtls-key="$DTLS_KEY")
BOT_DTLS=(--dtls-cert="$DTLS_CERT" --dtls-name="$DTLS_NAME")
if [ "${PLAIN:-0}" = "1" ]; then
	SERVER_DTLS=()
	BOT_DTLS=()
fi

# shellcheck disable=SC2086
$SERVER_CMD --server --zone=vado_gris --port="$PORT" --quit-after-ticks=1500 --report="$OUT/server.json" \
	"${SERVER_DTLS[@]}" \
	> "$OUT/server.stdout" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2> /dev/null || true' EXIT

# The server needs a moment to load the zone: wait for the UDP port to be announced in its log.
for _ in $(seq 1 60); do
	if grep -q "escuchando en el puerto" "$OUT/server.log" 2> /dev/null; then
		break
	fi
	if ! kill -0 "$SERVER_PID" 2> /dev/null; then
		echo "The server exited before it was ready:" >&2
		tail -n 40 "$OUT/server.log" >&2
		exit 1
	fi
	sleep 1
done
sleep 2

"$GODOT" --headless --path "$ROOT" -- --bots=1 --connect="127.0.0.1:$PORT" --bot-seed=1 \
	--quit-after-ticks=300 --report="$OUT/swarm.json" \
	"${BOT_DTLS[@]}" > "$OUT/swarm.log" 2>&1 || {
	echo "The SwarmBot failed:" >&2
	tail -n 40 "$OUT/swarm.log" >&2
	exit 1
}

# The server stops by itself at --quit-after-ticks; wait for it.
for _ in $(seq 1 120); do
	kill -0 "$SERVER_PID" 2> /dev/null || break
	sleep 1
done
wait "$SERVER_PID" || {
	echo "The server did not end well:" >&2
	tail -n 40 "$OUT/server.log" >&2
	exit 1
}
trap - EXIT

"${PYTHON:-python3}" -I - "$OUT/server.json" "$OUT/swarm.json" "$SERVER_DIR" << 'PY'
import json, os, sys

server = json.load(open(sys.argv[1], encoding="utf8"))
swarm = json.load(open(sys.argv[2], encoding="utf8"))
build_file = os.path.join(sys.argv[3], "BUILD_ID")
problems = []
if server.get("zone") != "vado_gris":
    problems.append("zone is %r" % server.get("zone"))
if server.get("ticks", 0) < 300:
    problems.append("only %s ticks" % server.get("ticks"))
if server.get("players", {}).get("joined_total", 0) < 1:
    problems.append("no player joined")
if swarm.get("bots", {}).get("played", 0) < 1:
    problems.append("the SwarmBot did not play: %s" % swarm.get("bots"))
if os.path.exists(build_file):
    expected = open(build_file, encoding="utf8").read().strip()
    if server.get("build") != expected:
        problems.append("the report build %r is not BUILD_ID %r" % (server.get("build"), expected))
print("server: zone=%s ticks=%s joined=%s build=%s" % (server.get("zone"), server.get("ticks"),
      server.get("players", {}).get("joined_total"), server.get("build")))
print("swarm: %s" % swarm.get("bots"))
if problems:
    print("SMOKE FAILED: " + "; ".join(problems))
    sys.exit(1)
print("SMOKE OK")
PY
