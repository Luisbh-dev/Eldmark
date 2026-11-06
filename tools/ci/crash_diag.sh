#!/usr/bin/env bash
# TEMPORARY diagnostic of the plain-UDP SIGBUS of the exported release server (TEC-12). Removed before merging.
set -u
SERVER_DIR="${1:?}"; GODOT="${2:?}"; PORT="${3:-26210}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/crash-diag"; rm -rf "$OUT"; mkdir -p "$OUT"
BIN="$SERVER_DIR/eldmark-server.x86_64"
ulimit -c unlimited
sudo sysctl -w kernel.core_pattern="$OUT/core.%p" > /dev/null
uname -a; lscpu | grep -E 'Model name|Flags' | cut -c1-300; free -m | head -2; df -h . | tail -1

CERT="$ROOT/tests/fixtures/dtls/zone_cert.pem"
run_case() { # name, prefix command, server options...
	local name="$1" prefix="$2"; shift 2
	# shellcheck disable=SC2086
	$prefix "$BIN" --headless -- --server --zone=vado_gris --port="$PORT" "$@" > "$OUT/$name.stdout" 2>&1 &
	local pid=$!
	for _ in $(seq 1 60); do grep -q escuchando "$OUT/$name.stdout" && break; sleep 1; done
	sleep 2
	local extra=""
	case "$*" in *dtls-cert*) extra="--dtls-cert=$CERT --dtls-name=zona-pruebas.eldmark.test";; esac
	"$GODOT" --headless --path "$ROOT" -- --bots=1 --connect="127.0.0.1:$PORT" --bot-seed=1 --quit-after-ticks=300 $extra > "$OUT/$name.swarm.log" 2>&1
	echo "$name: swarm exit $?"
	sleep 6
	if kill -0 "$pid" 2> /dev/null; then echo "$name: server still alive 6 s after the bot left"; : > "$OUT/stop"; fi
	wait "$pid"; echo "$name: server exit $?"
}
CERT="$ROOT/tests/fixtures/dtls/zone_cert.pem"; KEY="$ROOT/tests/fixtures/dtls/zone_key.pem"
run_case plain_perturb "env MALLOC_PERTURB_=85" --stop-file="$OUT/stop"
run_case dtls_perturb "env MALLOC_PERTURB_=85" --stop-file="$OUT/stop" --dtls-cert="$CERT" --dtls-key="$KEY"
run_case plain_checked "env MALLOC_CHECK_=3 MALLOC_PERTURB_=170" --stop-file="$OUT/stop"
run_case dtls_plain_arena "env MALLOC_ARENA_MAX=1" --stop-file="$OUT/stop" --dtls-cert="$CERT" --dtls-key="$KEY"

for core in "$OUT"/core.*; do
	[ -f "$core" ] || continue
	echo "=== $core"
	gdb -batch -ex "p \$_siginfo" -ex "info registers rip rsp" -ex "x/8i \$rip-12" -ex "bt 12" -ex "info threads" \
		-ex "thread apply all bt 5" "$BIN" "$core" 2>&1 | grep -v '^warning\|^\[New LWP\|^Reading\|^Download' | head -90
	break
done
exit 0
