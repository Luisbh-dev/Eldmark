package app_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
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
	"sync/atomic"
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

// syncBuffer is a log that can be read while it is being written.
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

// serve starts the platform on free ports and stops it when the test ends.
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
				t.Errorf("Serve ended with an error: %v", err)
			}
		case <-time.After(15 * time.Second):
			t.Error("Serve did not end on cancel")
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
		t.Fatalf("GET %s: JSON body: %v (%s)", path, err, data)
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
			t.Fatalf("/ready does not reach 200: %d %v", status, body)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// With the database stopped, /health stays at 200 and /ready gives 503 with the reason
// (platform.md §15 P0).
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
			t.Fatalf("/health without a database: %d", rec.Code)
		}
		rec = httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ready", nil))
		if rec.Code != 503 || !strings.Contains(rec.Body.String(), "La base de datos no responde") {
			t.Fatalf("/ready without a database: %d %s", rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "parada") || strings.Contains(rec.Body.String(), "eldmark") {
			t.Fatalf("/ready gives no database details: %s", rec.Body.String())
		}
	}
}

// serve does not migrate: with pending migrations it does not start, /ready says why and, as soon
// as they are applied, it starts without restarting.
func TestServeWaitsForTheMigrations(t *testing.T) {
	pool := testdb.NewEmpty(t)
	a, logs := newApp(t, pool, migrate.FS())
	serve(t, a)
	status, body, header := get(t, a.PublicAddr(), "/ready")
	if status != 503 || !strings.Contains(body["reason"].(string), "migrate up") || header.Get("Retry-After") == "" {
		t.Fatalf("/ready with an unmigrated database: %d %v", status, body)
	}
	if status, _, _ := get(t, a.PublicAddr(), "/health"); status != 200 {
		t.Fatalf("/health: %d", status)
	}
	if a.Started() {
		t.Fatal("does not start without the schema")
	}
	// As long as the reason does not change, it is logged only once even if checked every 50 ms.
	time.Sleep(300 * time.Millisecond)
	if n := strings.Count(logs.String(), "no puede arrancar todavía"); n != 1 {
		t.Errorf("the same reason is logged once, not %d times: %s", n, logs.String())
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
		t.Fatalf("the startup is logged: %s", logs.String())
	}
	status, body, _ = get(t, a.PublicAddr(), "/no/existe")
	if status != 404 || body["error"].(map[string]any)["code"] != "not_found" {
		t.Fatalf("unknown route: %d %v", status, body)
	}
}

// A database with a migration later than the binary's is fine: serve starts (expand and contract,
// platform.md §2.4).
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
		t.Fatalf("the later one: %v %v", applied, err)
	}
	a, _ := newApp(t, pool, migrate.FS())
	serve(t, a)
	waitReady(t, a.PublicAddr())
}

// The startup grace period (§2.5): heartbeat of the live instances set to now and live leases with
// at least the TTL; the rest is not touched. A lease that had already expired before its instance's
// last heartbeat (the zone stopped renewing it: the character left) does not come back to life.
func TestStartupGrace(t *testing.T) {
	pool := testdb.New(t)
	testdb.Exec(t, pool, `
insert into accounts (email, age_confirmed_at) values ('gracia@eldmark.test', now());
insert into sessions (account_id, access_hash, access_expires_at, refresh_hash, refresh_expires_at)
  select account_id, '\x01', now(), '\x02', now() + interval '12 h' from accounts;
insert into characters (world_id, account_id, name, name_key, realm)
  select 1, account_id, n, lower(n), 1 from accounts, (values ('Aneira'), ('Brand'), ('Cora')) as v(n);
insert into zone_instances (zone_instance_id, world_id, zone_id, public_host, public_port, realms, build_id,
  protocol_version, record_format, max_players, status, last_heartbeat_at) values
  ('00000000-0000-4000-8000-000000000001', 1, 'vado_gris', '127.0.0.1', 24600, '{1,2}', 'b', 7, 1, 64, 'live', now() - interval '1 hour'),
  ('00000000-0000-4000-8000-000000000002', 1, 'test_world', '127.0.0.1', 24601, '{1,2}', 'b', 7, 1, 64, 'stopped', now() - interval '1 hour');
insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, expires_at)
  select character_id, 1, gen_random_uuid(),
    case when name in ('Aneira', 'Cora') then '00000000-0000-4000-8000-000000000001'::uuid end,
    '00000000-0000-4000-8000-000000000001',
    case when name = 'Cora' then now() - interval '2 hours' else now() - interval '1 minute' end
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
		t.Fatalf("heartbeats: the live one renewed %v, the stopped one unchanged %v", liveFresh, stoppedOld)
	}
	var heldLong, freeOld, expiredBefore bool
	if err := pool.QueryRow(ctx, `select
		(select expires_at > now() + interval '25 s' from character_leases l join characters c using (character_id) where c.name = 'Aneira'),
		(select expires_at < now() from character_leases l join characters c using (character_id) where c.name = 'Brand'),
		(select expires_at < now() - interval '1 hour' from character_leases l join characters c using (character_id) where c.name = 'Cora')`).
		Scan(&heldLong, &freeOld, &expiredBefore); err != nil {
		t.Fatal(err)
	}
	if !heldLong || !freeOld || !expiredBefore {
		t.Fatalf("leases: the live one extended %v, the free one unchanged %v, the one expired before the last heartbeat unchanged %v",
			heldLong, freeOld, expiredBefore)
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
		t.Fatalf("port in use: %v", err)
	}
}

// The packages' routes answer 503 until startup finishes; the startup hooks run with the schema up
// to date and the periodic jobs, when it finishes and then every round.
func TestBootHooksJobsAndGate(t *testing.T) {
	pool := testdb.NewEmpty(t)
	a, logs := newApp(t, pool, migrate.FS())
	a.HandlePublic("GET /v1/prueba", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) }))
	var hookCalls, jobCalls atomic.Int32
	a.OnBoot(func(ctx context.Context) error {
		if hookCalls.Add(1) == 1 {
			return errors.New("el primer intento falla")
		}
		return nil
	})
	jobRan := make(chan struct{}, 10)
	a.AddJob("prueba", 30*time.Millisecond, func(ctx context.Context) error {
		jobCalls.Add(1)
		jobRan <- struct{}{}
		return nil
	})
	serve(t, a)
	status, body, header := get(t, a.PublicAddr(), "/v1/prueba")
	if status != 503 || body["error"].(map[string]any)["code"] != "unavailable" || header.Get("Retry-After") == "" {
		t.Fatalf("before startup: %d %v", status, body)
	}
	if hookCalls.Load() != 0 {
		t.Fatal("the hooks wait for the schema")
	}
	r, _ := migrate.New(pool, migrate.FS())
	if _, err := r.Up(context.Background()); err != nil {
		t.Fatal(err)
	}
	waitReady(t, a.PublicAddr())
	resp, err := http.Get("http://" + a.PublicAddr() + "/v1/prueba")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 204 || hookCalls.Load() != 2 {
		t.Fatalf("after startup: %d, hooks %d", resp.StatusCode, hookCalls.Load())
	}
	for i := 0; i < 2; i++ {
		select {
		case <-jobRan:
		case <-time.After(5 * time.Second):
			t.Fatalf("the work runs at startup and on every round (%d)", jobCalls.Load())
		}
	}
	if !strings.Contains(logs.String(), "el primer intento falla") {
		t.Fatal("the hook failure is logged")
	}
}

// A periodic job does not run in two processes at once: if another holds the lock, it is skipped.
func TestJobsTakeTheAdvisoryLock(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `select pg_advisory_lock($1)`, app.JobLockKey("bloqueado")); err != nil {
		t.Fatal(err)
	}
	a, _ := newApp(t, pool, migrate.FS())
	var ran atomic.Int32
	a.AddJob("bloqueado", 20*time.Millisecond, func(context.Context) error { ran.Add(1); return nil })
	serve(t, a)
	waitReady(t, a.PublicAddr())
	time.Sleep(150 * time.Millisecond)
	if ran.Load() != 0 {
		t.Fatal("with the lock held by another process, it does not run")
	}
	if _, err := conn.Exec(ctx, `select pg_advisory_unlock($1)`, app.JobLockKey("bloqueado")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for ran.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("with the lock released, it runs")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
