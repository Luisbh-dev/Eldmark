package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"eldmark/platform/internal/app"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func runWith(t *testing.T, env map[string]string, args ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	lookup := config.Lookup(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	code := run(context.Background(), args, lookup, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{{}, {"frobnicar"}, {"migrate"}, {"migrate", "down"}, {"migrate", "down", "0"},
		{"migrate", "down", "x"}, {"migrate", "sideways"}, {"serve", "extra"}} {
		code, _, stderr := runWith(t, nil, args...)
		if code != exitUsage || !strings.Contains(stderr, "eldmark-platform") && !strings.Contains(stderr, "migrate down") {
			t.Errorf("%v: código %d, %q", args, code, stderr)
		}
	}
	if code, stdout, _ := runWith(t, nil, "help"); code != exitOK || !strings.Contains(stdout, "migrate status") {
		t.Errorf("help: %d %q", code, stdout)
	}
}

func TestConfigErrorsStopTheCommands(t *testing.T) {
	code, _, stderr := runWith(t, map[string]string{}, "serve")
	if code != exitError || !strings.Contains(stderr, "ELDMARK_DATABASE_URL") || !strings.Contains(stderr, "no arranca") {
		t.Fatalf("serve sin configuración: %d %q", code, stderr)
	}
	code, _, stderr = runWith(t, map[string]string{}, "migrate", "up")
	if code != exitError || !strings.Contains(stderr, "ELDMARK_DATABASE_URL") {
		t.Fatalf("migrate sin base: %d %q", code, stderr)
	}
}

func TestMigrateCommands(t *testing.T) {
	pool := testdb.NewEmpty(t)
	env := map[string]string{"ELDMARK_ENV": "test", "ELDMARK_DATABASE_URL": testdb.ConnString(pool)}

	code, stdout, _ := runWith(t, env, "migrate", "status")
	if code != exitError || !strings.Contains(stdout, "0001_accounts") || !strings.Contains(stdout, "pendiente") {
		t.Fatalf("status de una base vacía (pendientes → código 1): %d\n%s", code, stdout)
	}
	code, stdout, stderr := runWith(t, env, "migrate", "up")
	if code != exitOK || !strings.Contains(stdout, "Aplicada 0001_accounts") || !strings.Contains(stdout, "Aplicada 0006_privacy") {
		t.Fatalf("up: %d\n%s%s", code, stdout, stderr)
	}
	if code, stdout, _ = runWith(t, env, "migrate", "up"); code != exitOK || !strings.Contains(stdout, "No hay migraciones pendientes") {
		t.Fatalf("segundo up: %d %s", code, stdout)
	}
	code, stdout, _ = runWith(t, env, "migrate", "status")
	if code != exitOK || strings.Count(stdout, "aplicada") != 6 || !strings.Contains(stdout, "UTC") {
		t.Fatalf("status al día: %d\n%s", code, stdout)
	}
	if code, stdout, _ = runWith(t, env, "migrate", "down", "2"); code != exitOK ||
		!strings.Contains(stdout, "Deshecha 0006_privacy\nDeshecha 0005_social") {
		t.Fatalf("down 2: %d %s", code, stdout)
	}
	for _, e := range []string{"staging", "production"} {
		env["ELDMARK_ENV"] = e
		code, _, stderr = runWith(t, env, "migrate", "down", "1")
		if code != exitError || !strings.Contains(stderr, "solo se usa en desarrollo y CI") {
			t.Fatalf("down en %s: %d %q", e, code, stderr)
		}
	}
	env["ELDMARK_ENV"] = "dev"
	if code, _, stderr = runWith(t, env, "migrate", "down", "9"); code != exitError || !strings.Contains(stderr, "Error") {
		t.Fatalf("down de más: %d %q", code, stderr)
	}
}

// serve monta las cuentas: los textos legales se publican al arrancar y el registro manda su
// correo a outbound_mail (ELDMARK_MAIL=log).
func TestServeMountsTheAccounts(t *testing.T) {
	pool := testdb.New(t)
	sum := sha256.Sum256([]byte("token"))
	env := map[string]string{
		"ELDMARK_ENV":          "test",
		"ELDMARK_DATABASE_URL": testdb.ConnString(pool),
		"ELDMARK_ZONE_TOKENS":  "1:vado_gris:0:" + hex.EncodeToString(sum[:]),
		"ELDMARK_TICKET_KEYS":  "1:" + base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)),
	}
	cfg, err := config.Load(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if err != nil {
		t.Fatal(err)
	}
	cfg.PublicAddr, cfg.InternalAddr = "127.0.0.1:0", "127.0.0.1:0"
	a, err := app.New(cfg, pool, logx.Discard(), migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	closeServices, err := mountServices(a, cfg, pool, logx.Discard())
	if err != nil {
		t.Fatal(err)
	}
	defer closeServices()
	if err := a.Listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Serve(ctx) }()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	}()
	base := "http://" + a.PublicAddr()
	deadline := time.Now().Add(10 * time.Second)
	for !a.Started() {
		if time.Now().After(deadline) {
			t.Fatal("no arranca")
		}
		time.Sleep(20 * time.Millisecond)
	}
	var docs int
	if err := pool.QueryRow(ctx, `select count(*) from legal_documents`).Scan(&docs); err != nil || docs != 3 {
		t.Fatalf("textos legales publicados al arrancar: %d %v", docs, err)
	}
	body := `{"email": "serve@example.org", "password": "una contraseña larga", "age_confirmed": true,
		"accept": {"terms": 1, "privacy": 1, "rules": 1}, "consents": {"crash_reports": false, "analytics": false}}`
	req, _ := http.NewRequest(http.MethodPost, base+"/v1/accounts", strings.NewReader(body))
	req.Header.Set("X-Eldmark-Protocol", "7")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 202 {
		t.Fatalf("registro: %d", resp.StatusCode)
	}
	var link string
	if err := pool.QueryRow(ctx, `select body from outbound_mail where to_email = 'serve@example.org'`).Scan(&link); err != nil ||
		!strings.Contains(link, "http://127.0.0.1:24680/verify?token=") {
		t.Fatalf("correo de verificación: %v %q", err, link)
	}
	resp, err = http.Get(base + "/verify?token=no-vale")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 || resp.Header.Get("Content-Security-Policy") == "" {
		t.Fatalf("página /verify: %d", resp.StatusCode)
	}
}
