#!/usr/bin/env bash
# Diagnostic (TEC-12): how the EXPORTED server ends in several ways, to tell a crash at exit from a crash while running.
# Usage: tools/ci/server_exit_diag.sh <server_dir> <godot> [port]
# It only prints; it always exits 0.
set -u

SERVER_DIR="${1:?server_dir}"
GODOT="${2:?godot}"
PORT="${3:-26210}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/exit-diag"
rm -rf "$OUT"
mkdir -p "$OUT"
BIN="$SERVER_DIR/eldmark-server.x86_64"

run() { # name, extra engine options, server options...
	local name="$1" engine="$2"
	shift 2
	# shellcheck disable=SC2086
	"$BIN" --headless $engine -- --server --zone=vado_gris --port="$PORT" "$@" > "$OUT/$name.stdout" 2>&1
	echo "$name: exit code $?"
}

run quit300 "" --quit-after-ticks=300
run quit300_logfile "--log-file $OUT/quit300_logfile.log" --quit-after-ticks=300
run quit1500_report "" --quit-after-ticks=1500 --report="$OUT/report.json"
run quit300_nonpcs "" --quit-after-ticks=300 --no-npcs --no-dummies

# The graceful path: the stop file.
touch_stop() { sleep 20; : > "$OUT/stop"; }
touch_stop &
"$BIN" --headless -- --server --zone=vado_gris --port="$PORT" --stop-file="$OUT/stop" --report="$OUT/stopfile.json" \
	> "$OUT/stopfile.stdout" 2>&1
echo "stopfile: exit code $?"
tail -n 3 "$OUT/quit300.stdout" | cut -c1-200

# With a SwarmBot connected (the case that crashed in the smoke test).
with_bot() { # name, server options...
	local name="$1"
	shift
	"$BIN" --headless -- --server --zone=vado_gris --port="$PORT" --quit-after-ticks=1500 "$@" > "$OUT/$name.stdout" 2>&1 &
	local pid=$!
	sleep 12
	"$GODOT" --headless --path "$ROOT" -- --bots=1 --connect="127.0.0.1:$PORT" --bot-seed=1 --quit-after-ticks=300 		> "$OUT/$name.swarm.log" 2>&1
	echo "$name: swarm exit code $?"
	wait "$pid"
	echo "$name: server exit code $?"
}
with_bot bot_default
with_bot bot_nonpcs --no-npcs --no-dummies
with_bot bot_report --report="$OUT/bot_report.json"
exit 0
