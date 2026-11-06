#!/usr/bin/env bash
# Canary of an ENGINE crash (TEC-12; docs/operations.md section 9, docs/networking.md section 3).
#
# The exported RELEASE Linux server of Godot 4.7.2 dies with SIGBUS (exit code 135) when it handles a DISCONNECT that a
# client over plain UDP started; over DTLS, or when the server starts the disconnect, it does not. NetTransport avoids
# it (the client waits for the server to cut), so the game never triggers it. This script brings the old behavior back
# (ELDMARK_CLIENT_STARTS_DISCONNECT=1) and reports what the server does:
#   - it dies with 135: the bug is still there (a warning; the workaround stays);
#   - it ends well: the engine no longer has it (a notice: the workaround and this canary can be removed).
# It never fails: what it reports is information. Exit code 2 only if the server could not even start.
#
# Usage: tools/ci/engine_canary.sh <server_dir> <godot> [port]    (the server of the artifact and the Godot that runs the bot)
set -u

SERVER_DIR="${1:?server_dir}"
GODOT="${2:?godot}"
PORT="${3:-26211}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/canary"
rm -rf "$OUT"
mkdir -p "$OUT"

"$SERVER_DIR/eldmark-server.x86_64" --headless --log-file "$OUT/server.log" -- --server --zone=vado_gris --port="$PORT" \
	--stop-file="$OUT/stop" > "$OUT/server.stdout" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2> /dev/null || true' EXIT
for _ in $(seq 1 60); do
	grep -q "escuchando en el puerto" "$OUT/server.log" 2> /dev/null && break
	kill -0 "$SERVER_PID" 2> /dev/null || { echo "The server exited before it was ready"; exit 2; }
	sleep 1
done
sleep 2

ELDMARK_CLIENT_STARTS_DISCONNECT=1 "$GODOT" --headless --path "$ROOT" -- --bots=1 --connect="127.0.0.1:$PORT" --bot-seed=1 \
	--quit-after-ticks=300 > "$OUT/bot.log" 2>&1
sleep 5
if kill -0 "$SERVER_PID" 2> /dev/null; then
	: > "$OUT/stop"
fi
wait "$SERVER_PID"
code=$?
trap - EXIT
if [ "$code" -eq 135 ]; then
	echo "::warning title=Engine crash still present::the release server died with SIGBUS (135) on a DISCONNECT started by a plain-UDP client; NetTransport avoids it"
	echo "canary: the engine bug is still there (server exit code 135)"
elif [ "$code" -eq 0 ]; then
	echo "::notice title=Engine crash gone::the release server survived a client-started plain-UDP disconnect: ELDMARK_CLIENT_STARTS_DISCONNECT and this canary can be retired"
	echo "canary: the engine no longer crashes (server exit code 0)"
else
	echo "canary: the server ended with an unexpected code $code"
fi
exit 0
