#!/usr/bin/env bash
# Diagnostic (TEC-12): how the EXPORTED server ends in several ways, to tell a crash at exit from a crash while running.
# Usage: tools/ci/server_exit_diag.sh <server_dir> [port]
# It only prints; it always exits 0.
set -u

SERVER_DIR="${1:?server_dir}"
PORT="${2:-26210}"
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
exit 0
