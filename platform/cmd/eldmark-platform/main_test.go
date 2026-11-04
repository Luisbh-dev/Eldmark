package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/app"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/services"
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
	if code != exitOK || !strings.Contains(stdout, "Aplicada 0001_accounts") || !strings.Contains(stdout, "Aplicada 0006_privacy") ||
		!strings.Contains(stdout, "Aplicada 0010_progress") {
		t.Fatalf("up: %d\n%s%s", code, stdout, stderr)
	}
	if code, stdout, _ = runWith(t, env, "migrate", "up"); code != exitOK || !strings.Contains(stdout, "No hay migraciones pendientes") {
		t.Fatalf("segundo up: %d %s", code, stdout)
	}
	code, stdout, _ = runWith(t, env, "migrate", "status")
	if code != exitOK || strings.Count(stdout, "aplicada") != 7 || !strings.Contains(stdout, "UTC") {
		t.Fatalf("status al día: %d\n%s", code, stdout)
	}
	if code, stdout, _ = runWith(t, env, "migrate", "down", "2"); code != exitOK ||
		!strings.Contains(stdout, "Deshecha 0010_progress\nDeshecha 0006_privacy") {
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

// serveEnv is the minimal serve configuration in tests.
func serveEnv(pool *pgxpool.Pool) map[string]string {
	sum := sha256.Sum256([]byte("token"))
	return map[string]string{
		"ELDMARK_ENV":          "test",
		"ELDMARK_DATABASE_URL": testdb.ConnString(pool),
		"ELDMARK_ZONE_TOKENS":  "1:vado_gris:0:" + hex.EncodeToString(sum[:]),
		"ELDMARK_TICKET_KEYS":  "1:" + base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)),
	}
}

// startServe starts serve on free ports with the services wired up and waits for startup to
// finish; it returns the public API URL. It is stopped when the test ends.
func startServe(t *testing.T, pool *pgxpool.Pool, env map[string]string) string {
	t.Helper()
	return "http://" + startServeApp(t, pool, env).PublicAddr()
}

// startServeApp is startServe and returns the process (both addresses).
func startServeApp(t *testing.T, pool *pgxpool.Pool, env map[string]string) *app.App {
	t.Helper()
	cfg, err := config.Load(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if err != nil {
		t.Fatal(err)
	}
	cfg.PublicAddr, cfg.InternalAddr = "127.0.0.1:0", "127.0.0.1:0"
	a, err := app.New(cfg, pool, logx.Discard(), migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	closeServices, err := services.Mount(a, cfg, pool, logx.Discard())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Listen(); err != nil {
		closeServices()
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Serve(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
		closeServices()
	})
	deadline := time.Now().Add(10 * time.Second)
	for !a.Started() {
		if time.Now().After(deadline) {
			t.Fatal("no arranca")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return a
}

// request makes a request to /v1 with the protocol and, if given, the token; it returns the status
// and the JSON body.
func request(t *testing.T, method, url, token, body string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	req.Header.Set("X-Eldmark-Protocol", "7")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

const registerJSON = `{"email": "serve@example.org", "password": "una contraseña larga", "age_confirmed": true,
	"accept": {"terms": 1, "privacy": 1, "rules": 1}, "consents": {"crash_reports": false, "analytics": false}}`

// serve wires up the accounts: the legal texts are published at startup and registration sends its
// email to outbound_mail (ELDMARK_MAIL=log).
func TestServeMountsTheAccounts(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	base := startServe(t, pool, serveEnv(pool))
	var docs int
	if err := pool.QueryRow(ctx, `select count(*) from legal_documents`).Scan(&docs); err != nil || docs != 3 {
		t.Fatalf("textos legales publicados al arrancar: %d %v", docs, err)
	}
	if status, _ := request(t, http.MethodPost, base+"/v1/accounts", "", registerJSON); status != 202 {
		t.Fatalf("registro: %d", status)
	}
	var link string
	if err := pool.QueryRow(ctx, `select body from outbound_mail where to_email = 'serve@example.org'`).Scan(&link); err != nil ||
		!strings.Contains(link, "http://127.0.0.1:24680/verify?token=") {
		t.Fatalf("correo de verificación: %v %q", err, link)
	}
	resp, err := http.Get(base + "/verify?token=no-vale")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 || resp.Header.Get("Content-Security-Policy") == "" {
		t.Fatalf("página /verify: %d", resp.StatusCode)
	}
}

// serve wires up the characters (P2) with the real progression store (progresion.md P7: validation
// of the exported rules and the tables of 0010_progress) and the minimum protocol from
// progression_rules.json.
func TestServeMountsTheCharacters(t *testing.T) {
	pool := testdb.New(t)
	base := startServe(t, pool, serveEnv(pool))
	if status, _ := request(t, http.MethodPost, base+"/v1/accounts", "", registerJSON); status != 202 {
		t.Fatalf("registro: %d", status)
	}
	status, body := request(t, http.MethodPost, base+"/v1/sessions", "",
		`{"email": "serve@example.org", "password": "una contraseña larga"}`)
	token, _ := body["access_token"].(string)
	if status != 200 || token == "" {
		t.Fatalf("inicio de sesión: %d %v", status, body)
	}
	// 8 B that the provisional validation allowed and the rules do not (another race at byte 0).
	status, body = request(t, http.MethodPost, base+"/v1/worlds/1/characters", token, `{"name": "Servida",
		"realm": "solmarch", "race_id": "race_solmarch", "appearance": "AQACAQADAiE=", "starter_template_id": "squire"}`)
	if errBody, _ := body["error"].(map[string]any); status != 400 || errBody["code"] != "validation" {
		t.Fatalf("apariencia que no vale: %d %v", status, body)
	}
	status, body = request(t, http.MethodPost, base+"/v1/worlds/1/characters", token, `{"name": "Servida",
		"realm": "solmarch", "race_id": "race_solmarch", "appearance": "AgAAAAAHAAA=", "starter_template_id": "squire"}`)
	if status != 201 {
		t.Fatalf("crear: %d %v", status, body)
	}
	var stored int
	if err := pool.QueryRow(context.Background(), `select count(*) from character_progress p
		join character_wallets w using (character_id) where p.race_id = 'race_solmarch'`).Scan(&stored); err != nil ||
		stored != 2 {
		t.Fatalf("el progreso no está en la base: %d %v", stored, err)
	}
	status, body = request(t, http.MethodGet, base+"/v1/worlds/1/characters", token, "")
	if status != 200 || body["realm"] != "solmarch" || body["used"] != 1.0 {
		t.Fatalf("lista: %d %v", status, body)
	}
	// The minimum protocol is that of progression_rules.json: a lower one gives 426.
	minProtocol := gamedata.MustLoad().ProtocolVersion
	req, _ := http.NewRequest(http.MethodGet, base+"/v1/status", nil)
	req.Header.Set("X-Eldmark-Protocol", strconv.Itoa(minProtocol-1))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUpgradeRequired {
		t.Fatalf("protocolo %d: %d", minProtocol-1, resp.StatusCode)
	}
	if status, body = request(t, http.MethodGet, base+"/v1/status", "", ""); status != 200 ||
		body["min_protocol"] != float64(minProtocol) {
		t.Fatalf("status: %d %v", status, body)
	}
}

// In staging and production, serve wires up the same thing: the progression store is no longer the
// fake in-memory one (until progresion.md P7, it did not start).
func TestServeMountsTheStoreWhenDeployed(t *testing.T) {
	pool := testdb.New(t)
	env := serveEnv(pool)
	cfg, err := config.Load(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range []config.Env{config.EnvStaging, config.EnvProduction} {
		cfg.Env = e
		a, err := app.New(cfg, pool, logx.Discard(), migrate.FS())
		if err != nil {
			t.Fatal(err)
		}
		closeServices, err := services.Mount(a, cfg, pool, logx.Discard())
		if err != nil {
			t.Errorf("%s: %v", e, err)
			continue
		}
		closeServices()
	}
}

// internalRequest makes a request to the internal API with the given zone token.
func internalRequest(t *testing.T, method, url, token, body string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// serve wires up the internal API (P3) on ELDMARK_INTERNAL_ADDR: a zone with its deployment's token
// registers, goes live, asks for a block of ids and heartbeats; without a token, 401 bad_token; an
// unknown route, 404.
func TestServeMountsTheInternalAPI(t *testing.T) {
	pool := testdb.New(t)
	a := startServeApp(t, pool, serveEnv(pool))
	base := "http://" + a.InternalAddr()
	status, body := internalRequest(t, http.MethodPost, base+"/internal/v1/zone-instances", "token", `{"world_id": 1,
		"zone_id": "vado_gris", "channel": 0, "public_host": "127.0.0.1", "public_port": 24600, "realms": [1, 2],
		"build_id": "b", "protocol_version": `+strconv.Itoa(gamedata.MustLoad().ProtocolVersion)+`, "record_format": 1,
		"max_players": 64, "dtls_cert_pem": null, "dtls_name": null, "replace": false}`)
	id, _ := body["zone_instance_id"].(string)
	if status != 200 || id == "" || body["env"] != "test" {
		t.Fatalf("registro: %d %v", status, body)
	}
	if status, body = internalRequest(t, http.MethodPost, base+"/internal/v1/zone-instances/"+id+"/live", "token", ""); status != 204 {
		t.Fatalf("live: %d %v", status, body)
	}
	if status, body = internalRequest(t, http.MethodPost, base+"/internal/v1/id-blocks", "token",
		`{"zone_instance_id": "`+id+`"}`); status != 200 || body["first"] != "1" {
		t.Fatalf("bloque: %d %v", status, body)
	}
	if status, body = internalRequest(t, http.MethodPost, base+"/internal/v1/zone-instances/"+id+"/heartbeat", "token",
		`{"players": 0, "characters": []}`); status != 200 {
		t.Fatalf("latido: %d %v", status, body)
	}
	if status, body = internalRequest(t, http.MethodPost, base+"/internal/v1/id-blocks", "",
		`{"zone_instance_id": "`+id+`"}`); status != 401 || body["error"].(map[string]any)["code"] != "bad_token" {
		t.Fatalf("sin token: %d %v", status, body)
	}
	if status, _ = internalRequest(t, http.MethodGet, base+"/internal/v1/nada", "token", ""); status != 404 {
		t.Fatalf("ruta desconocida: %d", status)
	}
	// The public API does not have the internal routes.
	if status, _ = internalRequest(t, http.MethodPost, "http://"+a.PublicAddr()+"/internal/v1/id-blocks", "token",
		`{"zone_instance_id": "`+id+`"}`); status != 404 {
		t.Fatalf("interna por la pública: %d", status)
	}
}
