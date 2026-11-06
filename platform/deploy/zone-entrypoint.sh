#!/usr/bin/env bash
# Entrypoint of the zone image (TEC-20). Usage: zone-entrypoint.sh <server options>   (they go after "--")
#                                              zone-entrypoint.sh --healthcheck
#
# Runs the exported server as a child and turns SIGTERM and SIGINT (docker stop) into the creation of the
# server's --stop-file: the zone then announces the shutdown, saves every character, deregisters from the platform
# and writes a final report with "closed": true. The exit code is the server's.
set -u

RUN_DIR="${ELDMARK_RUN_DIR:-/run/eldmark}"
STOP_FILE="$RUN_DIR/stop"
REPORT="$RUN_DIR/report.json"
SERVER="${ELDMARK_SERVER_BIN:-/opt/eldmark/eldmark-server.x86_64}"
# The report is rewritten every 10 s; older than this means the zone is stuck.
MAX_REPORT_AGE_S="${ELDMARK_MAX_REPORT_AGE_S:-45}"

if [ "${1:-}" = "--healthcheck" ]; then
	[ -f "$REPORT" ] || exit 1
	now="$(date +%s)"
	modified="$(stat -c %Y "$REPORT")"
	[ $((now - modified)) -lt "$MAX_REPORT_AGE_S" ] || exit 1
	# After the shutdown the report says closed: the container is going away, not unhealthy.
	exit 0
fi

mkdir -p "$RUN_DIR"
rm -f "$STOP_FILE" "$REPORT"

# shellcheck disable=SC2329 # invoked by the trap below
request_stop() {
	echo "[entrypoint] signal received: asking the zone for an orderly shutdown"
	: > "$STOP_FILE"
}
trap request_stop TERM INT

"$SERVER" --headless -- "$@" --stop-file="$STOP_FILE" --report="$REPORT" &
pid=$!

# wait returns early (128 + signal) when the trap runs: wait again until the server is really gone.
wait "$pid"
code=$?
while kill -0 "$pid" 2> /dev/null; do
	wait "$pid"
	code=$?
done
echo "[entrypoint] the server exited with code $code"
exit "$code"
