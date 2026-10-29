package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"eldmark/platform/internal/testdb"
)

// Errores de uso de admin: salen con 2 sin tocar la base (sin configuración). Una orden sin
// --actor no se ejecuta (§9.1), y bootstrap no lo lleva.
func TestAdminUsage(t *testing.T) {
	for _, args := range [][]string{
		{"admin"}, {"admin", "frobnicar"}, {"admin", "--actor", "a@example.org"},
		{"admin", "reports", "show", "1"},
		{"admin", "--actor", "a@example.org", "reports", "show"},
		{"admin", "--actor", "a@example.org", "reports", "show", "uno"},
		{"admin", "--actor", "a@example.org", "set-role", "b@example.org"},
		{"admin", "--actor", "a@example.org", "audit"},
		{"admin", "--actor", "a@example.org", "audit", "--since", "ayer"},
		{"admin", "--actor", "a@example.org", "chat", "--character", "Bran", "--from", "2026-11-01"},
		{"admin", "--actor", "a@example.org", "sanction", "add", "Bran", "mute", "--duration", "7x", "--reason", "x"},
		{"admin", "--actor", "a@example.org", "sanction", "add", "Bran", "warning"},
		{"admin", "--actor", "a@example.org", "create-account", "b@example.org"},
		{"admin", "--actor", "a@example.org", "bootstrap", "b@example.org", "--password-file", "x"},
		{"admin", "--actor", "a@example.org", "names", "rename", "Bran"},
	} {
		code, _, stderr := runWith(t, map[string]string{}, args...)
		if code != exitUsage {
			t.Errorf("%v: código %d, %q", args, code, stderr)
		}
	}
	code, _, stderr := runWith(t, map[string]string{}, "admin", "reports", "show", "1")
	if !strings.Contains(stderr, "--actor") || code != exitUsage {
		t.Fatalf("sin --actor: %d %q", code, stderr)
	}
	if code, stdout, _ := runWith(t, nil, "admin", "help"); code != exitOK || !strings.Contains(stdout, "set-role") {
		t.Fatalf("admin help: %d %q", code, stdout)
	}
}

// La orden admin de punta a punta contra una base: bootstrap, create-account, una lectura de un
// moderador con su fila en la auditoría (con os_user), las órdenes de admin que un moderador no
// puede usar (2), un --actor sin cuenta (2) y los errores de la orden (1).
func TestAdminCommands(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	env := serveEnv(pool)
	env["USER"], env["SUDO_USER"] = "operadora", ""
	passwordFile := filepath.Join(t.TempDir(), "clave")
	if err := os.WriteFile(passwordFile, []byte("una contraseña larga\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	run := func(want int, args ...string) string {
		t.Helper()
		code, stdout, stderr := runWith(t, env, append([]string{"admin"}, args...)...)
		if code != want {
			t.Fatalf("%v: código %d (se esperaba %d)\n%s%s", args, code, want, stdout, stderr)
		}
		return stdout + stderr
	}
	run(exitOK, "bootstrap", "jefa@example.org", "--password-file", passwordFile)
	run(exitError, "bootstrap", "otra@example.org", "--password-file", passwordFile) // ya hay admin
	run(exitOK, "--actor", "jefa@example.org", "create-account", "mod@example.org", "--password-file", passwordFile,
		"--role", "moderator")
	run(exitOK, "--actor", "jefa@example.org", "create-account", "bran@example.org", "--password-file", passwordFile)
	var bran int64
	if err := pool.QueryRow(ctx, `select account_id from accounts where email = 'bran@example.org'`).Scan(&bran); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `insert into characters (world_id, account_id, name, name_key, realm)
		values (1, $1, 'Bran', 'bran', 1)`, bran); err != nil {
		t.Fatal(err)
	}
	var report int64
	if err := pool.QueryRow(ctx, `insert into reports (world_id, target_account_id, target_name, category, comment, context)
		values (1, $1, 'Bran', 'language', 'insultos', '{"zone": "vado_gris"}') returning report_id`, bran).Scan(&report); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `insert into report_evidence (report_id, seq, sender_name, channel, text, sent_at)
		values ($1, 0, 'Bran', 2, 'palabrota', now())`, report); err != nil {
		t.Fatal(err)
	}
	id := strconv.FormatInt(report, 10)

	// reports show: sin --actor no se ejecuta; con el del moderador, sale y queda su fila.
	run(exitUsage, "reports", "show", id)
	out := run(exitOK, "--actor", "mod@example.org", "reports", "show", id)
	if !strings.Contains(out, "Reporte "+id) || !strings.Contains(out, "palabrota") {
		t.Fatalf("reports show:\n%s", out)
	}
	var args []byte
	var actor *int64
	if err := pool.QueryRow(ctx, `select args, actor_account_id from audit_log where command = 'reports show'`).
		Scan(&args, &actor); err != nil {
		t.Fatal(err)
	}
	var parsed map[string]any
	_ = json.Unmarshal(args, &parsed)
	if parsed["os_user"] != "operadora" || parsed["report_id"] != id || actor == nil {
		t.Fatalf("fila reports show: %s", args)
	}
	if out := run(exitOK, "--actor", "mod@example.org", "reports", "list", "--status", "all"); !strings.Contains(out, "Reportes: 1.") {
		t.Fatalf("reports list:\n%s", out)
	}
	// Lo que es de admin, con el moderador: 2; con un correo sin cuenta: 2.
	run(exitUsage, "--actor", "mod@example.org", "reports", "close", id, "dismissed")
	run(exitUsage, "--actor", "mod@example.org", "set-role", "bran@example.org", "gm")
	run(exitUsage, "--actor", "nadie@example.org", "reports", "list")
	// Errores de la orden: 1.
	run(exitError, "--actor", "jefa@example.org", "reports", "show", "424242")
	run(exitError, "--actor", "jefa@example.org", "set-role", "nadie@example.org", "gm")
	run(exitError, "--actor", "jefa@example.org", "sanction", "add", "Nadie", "warning", "--reason", "x")
	// Lo demás, por la orden de verdad.
	if out := run(exitOK, "--actor", "jefa@example.org", "set-role", "bran@example.org", "gm"); !strings.Contains(out, "player → gm") {
		t.Fatalf("set-role:\n%s", out)
	}
	if out := run(exitOK, "--actor", "jefa@example.org", "sanction", "add", "bran", "mute", "--duration", "1d",
		"--reason", "lenguaje", "--report", id); !strings.Contains(out, "hasta el") {
		t.Fatalf("sanción:\n%s", out)
	}
	if out := run(exitOK, "--actor", "mod@example.org", "sanction", "list", "Bran"); !strings.Contains(out, "vigente") {
		t.Fatalf("sanction list:\n%s", out)
	}
	run(exitOK, "--actor", "jefa@example.org", "reports", "close", id, "actioned", "--resolution", "silencio de 24 h")
	run(exitOK, "--actor", "jefa@example.org", "names", "block", "Malnombre", "--reason", "ofensivo")
	if out := run(exitOK, "--actor", "mod@example.org", "chat", "--character", "Bran", "--from", "2026-01-01",
		"--to", time.Now().Add(24*time.Hour).UTC().Format("2006-01-02")); !strings.Contains(out, "Mensajes: 0.") {
		t.Fatalf("chat:\n%s", out)
	}
	out = run(exitOK, "--actor", "mod@example.org", "audit", "--since", "2026-01-01", "--target", "Bran")
	for _, want := range []string{"set-role", "sanction", "reports close", "chat", "Bran (#"} {
		if !strings.Contains(out, want) {
			t.Errorf("audit sin %q:\n%s", want, out)
		}
	}
	run(exitOK, "--actor", "jefa@example.org", "purge-now", "bran@example.org", "--wait", "0s")
	var status string
	if err := pool.QueryRow(ctx, `select status from accounts where account_id = $1`, bran).Scan(&status); err != nil ||
		status != "purged" {
		t.Fatalf("purge-now: %q %v", status, err)
	}
	var cli, withOSUser int
	if err := pool.QueryRow(ctx, `select count(*), count(*) filter (where args->>'os_user' = 'operadora')
		from audit_log where source = 'cli'`).Scan(&cli, &withOSUser); err != nil || cli < 10 || cli != withOSUser {
		t.Fatalf("filas de la CLI: %d, con os_user: %d (%v)", cli, withOSUser, err)
	}
}

// serve corre la retención del chat (chat_retention, cada hora y al arrancar): lo de más de 30 días
// desaparece y lo demás se queda.
func TestServeRunsTheChatRetention(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	for i, age := range []time.Duration{40 * 24 * time.Hour, 29 * 24 * time.Hour} {
		if _, err := pool.Exec(ctx, `insert into chat_messages (world_id, zone_id, zone_channel, channel,
			sender_character_id, sender_account_id, text, sent_at, message_key)
			values (1, 'vado_gris', 0, 2, 1, 1, 'hola', $1, $2)`, time.Now().Add(-age), "k"+strconv.Itoa(i)); err != nil {
			t.Fatal(err)
		}
	}
	startServe(t, pool, serveEnv(pool))
	deadline := time.Now().Add(10 * time.Second)
	for {
		var n int
		if err := pool.QueryRow(ctx, `select count(*) from chat_messages`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("mensajes: %d", n)
		}
		time.Sleep(20 * time.Millisecond)
	}
	var key string
	if err := pool.QueryRow(ctx, `select message_key from chat_messages`).Scan(&key); err != nil || key != "k1" {
		t.Fatalf("queda el de hace 29 días: %q %v", key, err)
	}
}
