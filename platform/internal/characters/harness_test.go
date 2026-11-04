package characters_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/characters"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/legal"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

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

// router mounts the routes on a ServeMux (in serve it is *app.App).
type router struct{ *http.ServeMux }

func (r router) HandlePublic(pattern string, h http.Handler) { r.Handle(pattern, h) }

// The ticket key from the platform.md §5.1 vector (only valid in test).
var ticketKey = func() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	return k
}()

type harness struct {
	t        *testing.T
	pool     *pgxpool.Pool
	cfg      *config.Config
	clock    *clock.Fake
	accounts *accounts.Service
	svc      *characters.Service
	progress *persistence.MemoryProgressStore
	h        http.Handler
	logs     *syncBuffer
	ip       atomic.Int32
}

type option func(*config.Config)

func testConfig() *config.Config {
	u, _ := url.Parse("http://127.0.0.1:24680")
	return &config.Config{
		Env:            config.EnvTest,
		PublicURL:      u,
		TrustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")},
		Argon2:         config.Argon2{MemoryKiB: 8, Time: 1, Threads: 1},
		EmailHMACKey:   config.TestEmailHMACKey,
		Mail:           config.MailLog,
		OpenRealms:     []config.Realm{config.RealmVardheim, config.RealmSolmarch},
		EntryZones:     map[config.Realm]string{config.RealmVardheim: "vado_gris", config.RealmSolmarch: "vado_gris"},
		TicketKeys:     map[uint8][]byte{1: ticketKey},
		TicketSignKey:  1,
		Heartbeat:      5 * time.Second,
		LeaseTTL:       30 * time.Second,
	}
}

func newHarness(t *testing.T, opts ...option) *harness {
	t.Helper()
	pool := testdb.New(t)
	cfg := testConfig()
	for _, o := range opts {
		o(cfg)
	}
	h := &harness{t: t, pool: pool, cfg: cfg, clock: clock.NewFake(time.Now().Truncate(time.Second)), logs: &syncBuffer{},
		progress: persistence.NewMemoryProgressStore()}
	set, err := legal.Load(legal.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := set.Sync(context.Background(), pool, false); err != nil {
		t.Fatal(err)
	}
	log := logx.New(h.logs, slog.LevelDebug)
	purger := characters.NewPurger(pool, h.progress, h.clock, log)
	h.accounts, err = accounts.New(accounts.Options{Config: cfg, Pool: pool, Log: log, Clock: h.clock, Legal: set,
		Mail: &mail.LogSender{DB: pool, Log: log}, Characters: purger, MinProtocol: 7})
	if err != nil {
		t.Fatal(err)
	}
	h.svc, err = characters.New(characters.Options{Config: cfg, Pool: pool, Log: log, Clock: h.clock,
		Accounts: h.accounts, Progress: h.progress, Purger: purger, MinProtocol: 7})
	if err != nil {
		t.Fatal(err)
	}
	mux := router{http.NewServeMux()}
	auth := accounts.NewAPI(h.accounts)
	auth.Mount(mux)
	characters.NewAPI(h.svc).Mount(mux, auth)
	h.h = httpx.Middleware(log, mux)
	return h
}

func (h *harness) nextIP() string {
	n := h.ip.Add(1)
	return netip.AddrFrom4([4]byte{198, 51, byte(100 + n/250), byte(1 + n%250)}).String()
}

type response struct {
	status int
	header http.Header
	raw    string
	body   map[string]any
}

func (r *response) errCode() string {
	if e, ok := r.body["error"].(map[string]any); ok {
		code, _ := e["code"].(string)
		return code
	}
	return ""
}

func (r *response) errValue(name string) any {
	if e, ok := r.body["error"].(map[string]any); ok {
		return e[name]
	}
	return nil
}

func (r *response) errField(name string) string {
	if f, ok := r.errValue("fields").(map[string]any); ok {
		v, _ := f[name].(string)
		return v
	}
	return ""
}

// character returns the response's character object (create, restore, rename).
func (r *response) character() map[string]any {
	c, _ := r.body["character"].(map[string]any)
	return c
}

type call struct {
	method, path string
	body         any // sent as JSON; a string, as is
	token        string
	ip           string
}

func (h *harness) do(c call) *response {
	h.t.Helper()
	var body io.Reader
	switch b := c.body.(type) {
	case nil:
	case string:
		body = strings.NewReader(b)
	default:
		data, err := json.Marshal(b)
		if err != nil {
			h.t.Fatal(err)
		}
		body = bytes.NewReader(data)
	}
	r := httptest.NewRequest(c.method, c.path, body)
	r.RemoteAddr = "127.0.0.1:40000"
	r.Header.Set(httpx.ProtocolHeader, "7")
	r.Header.Set("Content-Type", "application/json")
	if c.ip != "" {
		r.Header.Set("X-Real-IP", c.ip)
	}
	if c.token != "" {
		r.Header.Set("Authorization", "Bearer "+c.token)
	}
	rec := httptest.NewRecorder()
	h.h.ServeHTTP(rec, r)
	res := &response{status: rec.Code, header: rec.Header(), raw: rec.Body.String()}
	if strings.HasPrefix(rec.Header().Get("Content-Type"), "application/json") && rec.Body.Len() > 0 {
		if err := json.Unmarshal(rec.Body.Bytes(), &res.body); err != nil {
			h.t.Fatalf("%s %s: JSON: %v (%s)", c.method, c.path, err, rec.Body.String())
		}
	}
	return res
}

func (h *harness) expect(res *response, status int, code string) {
	h.t.Helper()
	if res.status != status || res.errCode() != code {
		h.t.Fatalf("se esperaba %d %q y llega %d %q: %s", status, code, res.status, res.errCode(), res.raw)
	}
}

const password = "una contraseña larga"

// player is an account with a gameplay session.
type player struct {
	id    int64
	email string
	token string
}

// newPlayer registers an account (from a new IP) and logs in.
func (h *harness) newPlayer(email string) *player {
	h.t.Helper()
	res := h.do(call{method: "POST", path: "/v1/accounts", ip: h.nextIP(), body: map[string]any{"email": email,
		"password": password, "age_confirmed": true, "accept": map[string]any{"terms": 1, "privacy": 1, "rules": 1},
		"consents": map[string]any{"crash_reports": false, "analytics": false}}})
	if res.status != http.StatusAccepted {
		h.t.Fatalf("registro de %s: %d %s", email, res.status, res.raw)
	}
	p := &player{email: email}
	h.scalar(&p.id, `select account_id from accounts where email = $1`, email)
	h.login(p)
	return p
}

// login opens a new session for the player (and revokes the previous one).
func (h *harness) login(p *player) {
	h.t.Helper()
	res := h.do(call{method: "POST", path: "/v1/sessions", ip: h.nextIP(),
		body: map[string]any{"email": p.email, "password": password}})
	if res.status != http.StatusOK {
		h.t.Fatalf("inicio de sesión de %s: %d %s", p.email, res.status, res.raw)
	}
	p.token, _ = res.body["access_token"].(string)
}

// advance moves the clock forward and opens new sessions for the players (access lasts 15 min).
func (h *harness) advance(d time.Duration, players ...*player) {
	h.t.Helper()
	h.clock.Advance(d)
	for _, p := range players {
		h.login(p)
	}
}

// setClock sets the clock and opens new sessions for the players.
func (h *harness) setClock(at time.Time, players ...*player) {
	h.t.Helper()
	h.clock.Set(at)
	for _, p := range players {
		h.login(p)
	}
}

// appearance is any 8 B of appearance, in base64 (the provisional validation does not look at them).
var appearance = base64.StdEncoding.EncodeToString([]byte{1, 0, 2, 1, 0, 3, 2, 0x21})

func createBody(name, realm string) map[string]any {
	return map[string]any{"name": name, "realm": realm, "race_id": "race_" + realm, "appearance": appearance,
		"starter_template_id": "squire"}
}

func (h *harness) create(p *player, name, realm string) *response {
	h.t.Helper()
	return h.do(call{method: "POST", path: "/v1/worlds/1/characters", token: p.token, body: createBody(name, realm)})
}

// mustCreate creates a character and returns its id.
func (h *harness) mustCreate(p *player, name, realm string) int64 {
	h.t.Helper()
	res := h.create(p, name, realm)
	if res.status != http.StatusCreated {
		h.t.Fatalf("crear %s: %d %s", name, res.status, res.raw)
	}
	return idOf(h.t, res.character())
}

func idOf(t *testing.T, c map[string]any) int64 {
	t.Helper()
	s, ok := c["character_id"].(string)
	id, err := strconv.ParseInt(s, 10, 64)
	if !ok || err != nil {
		t.Fatalf("character_id no es una cadena decimal: %v", c)
	}
	return id
}

func path(format string, id int64) string {
	return strings.Replace(format, "{id}", strconv.FormatInt(id, 10), 1)
}

func (h *harness) remove(p *player, id int64, confirm string) *response {
	h.t.Helper()
	return h.do(call{method: "DELETE", path: path("/v1/characters/{id}", id), token: p.token,
		body: map[string]any{"confirm_name": confirm}})
}

func (h *harness) restore(p *player, id int64) *response {
	h.t.Helper()
	return h.do(call{method: "POST", path: path("/v1/characters/{id}/restore", id), token: p.token})
}

func (h *harness) enter(p *player, id int64) *response {
	h.t.Helper()
	return h.do(call{method: "POST", path: path("/v1/characters/{id}/enter", id), token: p.token})
}

func (h *harness) list(p *player) *response {
	h.t.Helper()
	res := h.do(call{method: "GET", path: "/v1/worlds/1/characters", token: p.token})
	if res.status != http.StatusOK {
		h.t.Fatalf("lista: %d %s", res.status, res.raw)
	}
	return res
}

func (h *harness) nameCheck(p *player, name string) *response {
	h.t.Helper()
	return h.do(call{method: "GET", path: "/v1/worlds/1/name-check?name=" + url.QueryEscape(name), token: p.token})
}

// zone registers a zone instance (as the internal API, P3, would) and returns its id.
func (h *harness) zone(zoneID string, channel int, realms []int16, players, maxPlayers int, status string) string {
	h.t.Helper()
	var id string
	h.scalar(&id, `insert into zone_instances (zone_instance_id, world_id, zone_id, channel, public_host, public_port,
		realms, build_id, protocol_version, record_format, max_players, players, status)
		values (gen_random_uuid(), 1, $1, $2, '203.0.113.5', $3, $4, 'build-1', 7, 1, $5, $6, $7)
		returning zone_instance_id::text`, zoneID, channel, 24600+channel, realms, maxPlayers, players, status)
	return id
}

// lease gives the character a lease on the instance that expires at expires.
func (h *harness) lease(characterID int64, instance string, expires time.Time) {
	h.t.Helper()
	h.exec(`insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, expires_at)
		values ($1, 1, gen_random_uuid(), $2, $2, $3)
		on conflict (character_id) do update set zone_instance_id = excluded.zone_instance_id, expires_at = excluded.expires_at`,
		characterID, instance, expires)
}

func (h *harness) exec(sql string, args ...any) {
	h.t.Helper()
	if _, err := h.pool.Exec(context.Background(), sql, args...); err != nil {
		h.t.Fatalf("%v\n%s", err, sql)
	}
}

func (h *harness) scalar(dst any, sql string, args ...any) {
	h.t.Helper()
	if err := h.pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		h.t.Fatalf("%v\n%s", err, sql)
	}
}

func (h *harness) count(sql string, args ...any) int {
	h.t.Helper()
	var n int
	h.scalar(&n, sql, args...)
	return n
}

const day = 24 * time.Hour
