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

// Admin usage errors: they exit with 2 without touching the database (no configuration). A command
// without --actor is not executed (§9.1), and bootstrap does not take one.
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
		{"admin", "--actor", "a@example.org", "reapply-purges"},
		{"admin", "--actor", "a@example.org", "reapply-purges", "a.txt", "b.txt"},
		{"admin", "reapply-purges", "purges.txt"},
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

// The admin command end to end against a database: bootstrap, create-account, a moderator's read
// with its audit row (with os_user), the admin commands a moderator cannot use (2), an --actor
// without an account (2) and the command's errors (1).
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
	run(exitError, "bootstrap", "otra@example.org", "--password-file", passwordFile) // there is already an admin
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

	// reports show: without --actor it is not executed; with the moderator's, it succeeds and leaves its
	// row.
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
	// What is admin-only, with the moderator: 2; with an email without an account: 2.
	run(exitUsage, "--actor", "mod@example.org", "reports", "close", id, "dismissed")
	run(exitUsage, "--actor", "mod@example.org", "set-role", "bran@example.org", "gm")
	run(exitUsage, "--actor", "nadie@example.org", "reports", "list")
	// Command errors: 1.
	run(exitError, "--actor", "jefa@example.org", "reports", "show", "424242")
	run(exitError, "--actor", "jefa@example.org", "set-role", "nadie@example.org", "gm")
	run(exitError, "--actor", "jefa@example.org", "sanction", "add", "Nadie", "warning", "--reason", "x")
	// The rest, through the real command.
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
	// reapply-purges on the same database: what is in purge_log is already purged (nothing changes, 0);
	// a malformed purges.txt or one that does not exist, 1.
	dir := t.TempDir()
	purges := filepath.Join(dir, "purges.txt")
	if err := os.WriteFile(purges, []byte("account\t"+strconv.FormatInt(bran, 10)+"\t2026-10-30 09:46:00.5+00\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out := run(exitOK, "--actor", "jefa@example.org", "reapply-purges", purges); !strings.Contains(out,
		"ya purgados o sin fila en la copia: 1") || !strings.Contains(out, "Todo lo de purges.txt está purgado") {
		t.Fatalf("reapply-purges:\n%s", out)
	}
	if err := os.WriteFile(purges, []byte("cuenta 1 ayer\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out := run(exitError, "--actor", "jefa@example.org", "reapply-purges", purges); !strings.Contains(out, "línea 1") {
		t.Fatalf("purges.txt mal formado:\n%s", out)
	}
	run(exitError, "--actor", "jefa@example.org", "reapply-purges", filepath.Join(dir, "no-existe.txt"))
	var cli, withOSUser int
	if err := pool.QueryRow(ctx, `select count(*), count(*) filter (where args->>'os_user' = 'operadora')
		from audit_log where source = 'cli'`).Scan(&cli, &withOSUser); err != nil || cli < 10 || cli != withOSUser {
		t.Fatalf("filas de la CLI: %d, con os_user: %d (%v)", cli, withOSUser, err)
	}
}

// serve runs the chat retention (chat_retention, every hour and at startup): anything older than 30
// days disappears and the rest stays.
// serve runs the lost-instances job (§5.3, §2.5): a live instance that stops heartbeating becomes
// lost and its leases are freed, without calling MarkLost by hand (with HEARTBEAT_S 1, at 3 s and
// the job every second).
func TestServeRunsTheLostInstances(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	testdb.Exec(t, pool, `
insert into accounts (email, age_confirmed_at) values ('perdida@eldmark.test', now());
insert into characters (world_id, account_id, name, name_key, realm) select 1, account_id, 'Aneira', 'aneira', 1 from accounts;
insert into zone_instances (zone_instance_id, world_id, zone_id, public_host, public_port, realms, build_id,
  protocol_version, record_format, max_players, status, last_heartbeat_at) values
  ('00000000-0000-4000-8000-000000000001', 1, 'vado_gris', '127.0.0.1', 24600, '{1,2}', 'b', 7, 1, 64, 'live', now());
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, expires_at)
  select character_id, 1, gen_random_uuid(), '00000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000001', now() + interval '5 s' from characters;`)
	env := serveEnv(pool)
	env["ELDMARK_HEARTBEAT_S"], env["ELDMARK_LEASE_TTL_S"] = "1", "5"
	startServe(t, pool, env)
	deadline := time.Now().Add(15 * time.Second)
	for {
		var status string
		var free bool
		if err := pool.QueryRow(ctx, `select zi.status, l.zone_instance_id is null from zone_instances zi, character_leases l`).
			Scan(&status, &free); err != nil {
			t.Fatal(err)
		}
		if status == "lost" && free {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("sin latido, a los 15 s: %s, libre %v", status, free)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

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

// serve runs the retentions of §11.1 (privacy_retention) at startup: a login from 31 days ago and a
// tombstone purged more than a year ago without a ledger entry disappear; yesterday's login stays.
func TestServeRunsThePrivacyRetention(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	now := time.Now()
	var account, tomb int64
	if err := pool.QueryRow(ctx, `insert into accounts (email, age_confirmed_at) values ('a@example.org', $1)
		returning account_id`, now).Scan(&account); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `insert into characters (world_id, account_id, realm, purged_at) values (1, $1, 1, $2)
		returning character_id`, account, now.Add(-366*24*time.Hour)).Scan(&tomb); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `insert into auth_events (account_id, kind, user_agent, at) values ($1, 'login', 'viejo', $2),
		($1, 'login', 'ayer', $3)`, account, now.Add(-31*24*time.Hour), now.Add(-24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	startServe(t, pool, serveEnv(pool))
	deadline := time.Now().Add(10 * time.Second)
	for {
		var events, tombs int
		if err := pool.QueryRow(ctx, `select (select count(*) from auth_events where user_agent in ('viejo', 'ayer')),
			(select count(*) from characters where character_id = $1)`, tomb).Scan(&events, &tombs); err != nil {
			t.Fatal(err)
		}
		if events == 1 && tombs == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("accesos %d, lápida %d", events, tombs)
		}
		time.Sleep(20 * time.Millisecond)
	}
	var agent string
	if err := pool.QueryRow(ctx, `select user_agent from auth_events where user_agent in ('viejo', 'ayer')`).Scan(&agent); err != nil ||
		agent != "ayer" {
		t.Fatalf("queda el de ayer: %q %v", agent, err)
	}
}
