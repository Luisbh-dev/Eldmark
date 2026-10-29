package accounts_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/legal"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

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

// router monta las rutas en un ServeMux (en serve es *app.App).
type router struct{ *http.ServeMux }

func (r router) HandlePublic(pattern string, h http.Handler) { r.Handle(pattern, h) }

type harness struct {
	t     *testing.T
	pool  *pgxpool.Pool
	cfg   *config.Config
	clock *clock.Fake
	svc   *accounts.Service
	api   *accounts.API
	h     http.Handler
	logs  *syncBuffer
	ip    atomic.Int32
}

type option func(*config.Config)

func staging(c *config.Config) { c.Env = config.EnvStaging }

func testConfig() *config.Config {
	u, _ := url.Parse("http://127.0.0.1:24680")
	return &config.Config{
		Env:            config.EnvTest,
		PublicURL:      u,
		TrustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")},
		Argon2:         config.Argon2{MemoryKiB: 8, Time: 1, Threads: 1},
		EmailHMACKey:   config.TestEmailHMACKey,
		Mail:           config.MailLog,
	}
}

func newHarness(t *testing.T, opts ...option) *harness {
	t.Helper()
	pool := testdb.New(t)
	cfg := testConfig()
	for _, o := range opts {
		o(cfg)
	}
	h := &harness{t: t, pool: pool, cfg: cfg, clock: clock.NewFake(time.Now().Truncate(time.Second)), logs: &syncBuffer{}}
	h.build(legal.Embedded(), cfg)
	return h
}

// build (re)monta el servicio sobre la misma base, con otros textos (nil: los del binario) o
// configuración.
func (h *harness) build(texts fs.FS, cfg *config.Config) {
	h.t.Helper()
	if texts == nil {
		texts = legal.Embedded()
	}
	set, err := legal.Load(texts)
	if err != nil {
		h.t.Fatal(err)
	}
	if _, err := set.Sync(context.Background(), h.pool, false); err != nil {
		h.t.Fatal(err)
	}
	log := logx.New(h.logs, slog.LevelDebug)
	svc, err := accounts.New(accounts.Options{Config: cfg, Pool: h.pool, Log: log, Clock: h.clock, Legal: set,
		Mail: &mail.LogSender{DB: h.pool, Log: log}, MinProtocol: 7})
	if err != nil {
		h.t.Fatal(err)
	}
	h.svc, h.api, h.cfg = svc, accounts.NewAPI(svc), cfg
	mux := router{http.NewServeMux()}
	h.api.Mount(mux)
	// Una ruta de juego como la de entrar al mundo (P2), montada como lo hará P2.
	mux.HandlePublic("POST /v1/characters/{id}/enter", httpx.RequireProtocol(7, h.api.RequireSession(false,
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))))
	h.h = httpx.Middleware(log, mux)
}

// nextIP da una IP de documentación distinta cada vez (los límites van por IP).
func (h *harness) nextIP() string { return h.nextIPAddr().String() }

func (h *harness) nextIPAddr() netip.Addr {
	n := h.ip.Add(1)
	return netip.AddrFrom4([4]byte{198, 51, byte(100 + n/250), byte(1 + n%250)})
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

func (r *response) errField(name string) string {
	if e, ok := r.body["error"].(map[string]any); ok {
		if f, ok := e["fields"].(map[string]any); ok {
			v, _ := f[name].(string)
			return v
		}
	}
	return ""
}

func (r *response) str(key string) string {
	v, _ := r.body[key].(string)
	return v
}

type call struct {
	method, path string
	body         any    // se manda como JSON
	form         string // se manda como formulario (sin cabeceras de /v1)
	token        string
	ip           string // X-Real-IP (desde 127.0.0.1, de confianza)
	remote       string // RemoteAddr; por defecto 127.0.0.1:40000
	headers      map[string]string
	noProtocol   bool
}

func (h *harness) do(c call) *response {
	h.t.Helper()
	var body io.Reader
	switch {
	case c.form != "":
		body = strings.NewReader(c.form)
	case c.body != nil:
		if raw, ok := c.body.(string); ok {
			body = strings.NewReader(raw)
		} else {
			data, err := json.Marshal(c.body)
			if err != nil {
				h.t.Fatal(err)
			}
			body = bytes.NewReader(data)
		}
	}
	r := httptest.NewRequest(c.method, c.path, body)
	r.RemoteAddr = "127.0.0.1:40000"
	if c.remote != "" {
		r.RemoteAddr = c.remote
	}
	if c.form != "" {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	} else if !c.noProtocol {
		r.Header.Set(httpx.ProtocolHeader, "7")
		r.Header.Set("Content-Type", "application/json")
	}
	if c.ip != "" {
		r.Header.Set("X-Real-IP", c.ip)
	}
	if c.token != "" {
		r.Header.Set("Authorization", "Bearer "+c.token)
	}
	for k, v := range c.headers {
		r.Header.Set(k, v)
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

func registerBody(email, pw string) map[string]any {
	return map[string]any{"email": email, "password": pw, "age_confirmed": true,
		"accept":   map[string]any{"terms": 1, "privacy": 1, "rules": 1},
		"consents": map[string]any{"crash_reports": false, "analytics": false}}
}

// register crea una cuenta desde una IP nueva y devuelve su id.
func (h *harness) register(email string) int64 {
	h.t.Helper()
	res := h.do(call{method: "POST", path: "/v1/accounts", body: registerBody(email, password), ip: h.nextIP()})
	if res.status != http.StatusAccepted || res.raw != "{}\n" {
		h.t.Fatalf("registro de %s: %d %s", email, res.status, res.raw)
	}
	return h.accountID(email)
}

func (h *harness) accountID(email string) int64 {
	h.t.Helper()
	var id int64
	if err := h.pool.QueryRow(context.Background(), `select account_id from accounts where email = $1`, email).Scan(&id); err != nil {
		h.t.Fatalf("cuenta %s: %v", email, err)
	}
	return id
}

type session struct {
	access, refresh string
	res             *response
}

func (h *harness) loginFrom(email, pw, ip string) *response {
	h.t.Helper()
	return h.do(call{method: "POST", path: "/v1/sessions", body: map[string]any{"email": email, "password": pw}, ip: ip})
}

// login inicia sesión (desde una IP nueva) y exige que vaya bien.
func (h *harness) login(email, pw string) session {
	h.t.Helper()
	res := h.loginFrom(email, pw, h.nextIP())
	if res.status != http.StatusOK {
		h.t.Fatalf("inicio de sesión de %s: %d %s", email, res.status, res.raw)
	}
	return session{access: res.str("access_token"), refresh: res.str("refresh_token"), res: res}
}

var tokenInBody = regexp.MustCompile(`token=([A-Za-z0-9_-]{43})`)

// mailTo devuelve el último correo de una plantilla a una dirección y su token (si lleva enlace).
func (h *harness) mailTo(email, template string) (body, token string) {
	h.t.Helper()
	err := h.pool.QueryRow(context.Background(), `select body from outbound_mail where to_email = $1 and template = $2
		order by id desc limit 1`, email, template).Scan(&body)
	if err != nil {
		h.t.Fatalf("no hay correo %s para %s: %v", template, email, err)
	}
	if m := tokenInBody.FindStringSubmatch(body); m != nil {
		token = m[1]
	}
	return body, token
}

func (h *harness) mailCount(email, template string) int {
	h.t.Helper()
	var n int
	if err := h.pool.QueryRow(context.Background(), `select count(*) from outbound_mail where to_email = $1 and template = $2`,
		email, template).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
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
