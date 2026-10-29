package app_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/app"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func testConfig() *config.Config {
	return &config.Config{
		Env:          config.EnvTest,
		PublicAddr:   "127.0.0.1:0",
		InternalAddr: "127.0.0.1:0",
		Heartbeat:    5 * time.Second,
		LeaseTTL:     30 * time.Second,
	}
}

// syncBuffer es un registro que se puede leer mientras se escribe.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func newApp(t *testing.T, pool *pgxpool.Pool, migrations fs.FS) (*app.App, *syncBuffer) {
	t.Helper()
	logs := &syncBuffer{}
	a, err := app.New(testConfig(), pool, logx.New(logs, slog.LevelDebug), migrations)
	if err != nil {
		t.Fatal(err)
	}
	a.SchemaPoll = 50 * time.Millisecond
	return a, logs
}

// serve arranca la plataforma en puertos libres y la para al terminar la prueba.
func serve(t *testing.T, a *app.App) {
	t.Helper()
	if err := a.Listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Serve(ctx) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("Serve terminó con error: %v", err)
			}
		case <-time.After(15 * time.Second):
			t.Error("Serve no terminó al cancelar")
		}
	})
}

func get(t *testing.T, addr, path string) (int, map[string]any, http.Header) {
	t.Helper()
	resp, err := http.Get("http://" + addr + path)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	var body map[string]any
	if err := json.Unmarshal(data, &body); err != nil {
		t.Fatalf("GET %s: cuerpo JSON: %v (%s)", path, err, data)
	}
	return resp.StatusCode, body, resp.Header
}

func waitReady(t *testing.T, addr string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		status, body, _ := get(t, addr, "/ready")
		if status == 200 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("/ready no llega a 200: %d %v", status, body)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// Con la base parada, /health sigue en 200 y /ready da 503 con el motivo (plataforma.md §15 P0).
func TestReadyWithTheDatabaseDown(t *testing.T) {
	pool, err := db.Open(context.Background(), "host="+filepath.Join(t.TempDir(), "parada")+" user=eldmark dbname=eldmark")
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	a, _ := newApp(t, pool, migrate.FS())
	for _, h := range []http.Handler{a.PublicHandler(), a.InternalHandler()} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
		if rec.Code != 200 {
			t.Fatalf("/health sin base: %d", rec.Code)
		}
		rec = httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ready", nil))
		if rec.Code != 503 || !strings.Contains(rec.Body.String(), "La base de datos no responde") {
			t.Fatalf("/ready sin base: %d %s", rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "parada") || strings.Contains(rec.Body.String(), "eldmark") {
			t.Fatalf("/ready no da detalles de la base: %s", rec.Body.String())
		}
	}
}

// serve no migra: con migraciones pendientes no arranca, /ready dice por qué y, en cuanto se
// aplican, arranca sin reiniciar.
func TestServeWaitsForTheMigrations(t *testing.T) {
	pool := testdb.NewEmpty(t)
	a, logs := newApp(t, pool, migrate.FS())
	serve(t, a)
	status, body, header := get(t, a.PublicAddr(), "/ready")
	if status != 503 || !strings.Contains(body["reason"].(string), "migrate up") || header.Get("Retry-After") == "" {
		t.Fatalf("/ready con la base sin migrar: %d %v", status, body)
	}
	if status, _, _ := get(t, a.PublicAddr(), "/health"); status != 200 {
		t.Fatalf("/health: %d", status)
	}
	if a.Started() {
		t.Fatal("no arranca sin el esquema")
	}
	// Mientras el motivo no cambia, se registra una sola vez aunque se mire cada 50 ms.
	time.Sleep(300 * time.Millisecond)
	if n := strings.Count(logs.String(), "no puede arrancar todavía"); n != 1 {
		t.Errorf("el mismo motivo se registra una vez, no %d: %s", n, logs.String())
	}
	r, err := migrate.New(pool, migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Up(context.Background()); err != nil {
		t.Fatal(err)
	}
	waitReady(t, a.PublicAddr())
	waitReady(t, a.InternalAddr())
	if !a.Started() || !strings.Contains(logs.String(), "plataforma lista") ||
		!strings.Contains(logs.String(), "no puede arrancar todavía") {
		t.Fatalf("el arranque se registra: %s", logs.String())
	}
	status, body, _ = get(t, a.PublicAddr(), "/no/existe")
	if status != 404 || body["error"].(map[string]any)["code"] != "not_found" {
		t.Fatalf("ruta desconocida: %d %v", status, body)
	}
}

// Una base con una migración posterior a las del binario vale: serve arranca (expandir y
// contraer, plataforma.md §2.4).
func TestServeStartsWithALaterMigration(t *testing.T) {
	pool := testdb.New(t)
	newer := fstest.MapFS{}
	entries, _ := fs.ReadDir(migrate.FS(), ".")
	for _, e := range entries {
		data, _ := fs.ReadFile(migrate.FS(), e.Name())
		newer[e.Name()] = &fstest.MapFile{Data: data}
	}
	newer["9999_futura.up.sql"] = &fstest.MapFile{Data: []byte("alter table accounts add column apodo text;")}
	newer["9999_futura.down.sql"] = &fstest.MapFile{Data: []byte("alter table accounts drop column apodo;")}
	r, err := migrate.New(pool, newer)
	if err != nil {
		t.Fatal(err)
	}
	if applied, err := r.Up(context.Background()); err != nil || len(applied) != 1 {
		t.Fatalf("la posterior: %v %v", applied, err)
	}
	a, _ := newApp(t, pool, migrate.FS())
	serve(t, a)
	waitReady(t, a.PublicAddr())
}

// La gracia de arranque (§2.5): latido de las instancias vivas a ahora y arrendamientos vivos con
// al menos el TTL; lo demás no se toca.
func TestStartupGrace(t *testing.T) {
	pool := testdb.New(t)
	testdb.Exec(t, pool, `
insert into accounts (email, age_confirmed_at) values ('gracia@eldmark.test', now());
insert into sessions (account_id, access_hash, access_expires_at, refresh_hash, refresh_expires_at)
  select account_id, '\x01', now(), '\x02', now() + interval '12 h' from accounts;
insert into characters (world_id, account_id, name, name_key, realm)
  select 1, account_id, n, lower(n), 1 from accounts, (values ('Aneira'), ('Brand')) as v(n);
insert into zone_instances (zone_instance_id, world_id, zone_id, public_host, public_port, realms, build_id,
  protocol_version, record_format, max_players, status, last_heartbeat_at) values
  ('00000000-0000-4000-8000-000000000001', 1, 'vado_gris', '127.0.0.1', 24600, '{1,2}', 'b', 7, 1, 64, 'live', now() - interval '1 hour'),
  ('00000000-0000-4000-8000-000000000002', 1, 'test_world', '127.0.0.1', 24601, '{1,2}', 'b', 7, 1, 64, 'stopped', now() - interval '1 hour');
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, expires_at)
  select character_id, 1, gen_random_uuid(),
    case when name = 'Aneira' then '00000000-0000-4000-8000-000000000001'::uuid end,
    '00000000-0000-4000-8000-000000000001', now() - interval '1 minute'
  from characters;`)
	a, _ := newApp(t, pool, migrate.FS())
	serve(t, a)
	waitReady(t, a.PublicAddr())
	ctx := context.Background()
	var liveFresh, stoppedOld bool
	if err := pool.QueryRow(ctx, `select
		(select last_heartbeat_at > now() - interval '10 s' from zone_instances where status = 'live'),
		(select last_heartbeat_at < now() - interval '50 min' from zone_instances where status = 'stopped')`).
		Scan(&liveFresh, &stoppedOld); err != nil {
		t.Fatal(err)
	}
	if !liveFresh || !stoppedOld {
		t.Fatalf("latidos: la viva renovada %v, la parada igual %v", liveFresh, stoppedOld)
	}
	var heldLong, freeOld bool
	if err := pool.QueryRow(ctx, `select
		(select expires_at > now() + interval '25 s' from character_leases l join characters c using (character_id) where c.name = 'Aneira'),
		(select expires_at < now() from character_leases l join characters c using (character_id) where c.name = 'Brand')`).
		Scan(&heldLong, &freeOld); err != nil {
		t.Fatal(err)
	}
	if !heldLong || !freeOld {
		t.Fatalf("arrendamientos: el vivo alargado %v, el libre igual %v", heldLong, freeOld)
	}
}

func TestListenFailsOnABusyPort(t *testing.T) {
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	cfg := testConfig()
	cfg.InternalAddr = busy.Addr().String()
	pool, err := db.Open(context.Background(), "host=/nadie user=eldmark")
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	a, err := app.New(cfg, pool, logx.Discard(), migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Listen(); err == nil || !strings.Contains(err.Error(), "ELDMARK_INTERNAL_ADDR") {
		t.Fatalf("puerto ocupado: %v", err)
	}
}
