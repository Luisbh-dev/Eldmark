// Package platformtest assembles the entire platform inside a test's process (for tests only):
// the ephemeral testdb database, the fake clock, in-memory progress
// (persistence.MemoryProgressStore; with [NewWithProgress], the real store from progression.md P7),
// the public API (accounts and characters), the internal one (zones, claim and save, war and
// social), the admin command and the retention jobs, with helpers to act as client and as zone.
//
// It is used by the zones, persistence, war and social tests: the internal API only makes sense
// with real accounts, characters and tickets in front of it.
package platformtest

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/characters"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/privacy"
	"eldmark/platform/internal/social"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/internal/tickets"
	"eldmark/platform/internal/war"
	"eldmark/platform/internal/zones"
	"eldmark/platform/legal"
)

// SyncBuffer is a log that can be read while it is being written.
type SyncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *SyncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *SyncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// TicketKey is the ticket key from the platform vector in platform.md §5.1 (only valid in
// tests).
var TicketKey = func() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	return k
}()

// Scopes are the zone deployments with a token in the tests: world 2 exists to check that the
// instance sets the world.
var Scopes = []zones.Scope{
	{WorldID: 1, ZoneID: "vado_gris", Channel: 0},
	{WorldID: 1, ZoneID: "vado_gris", Channel: 1},
	{WorldID: 1, ZoneID: "test_world", Channel: 0},
	{WorldID: 2, ZoneID: "vado_gris", Channel: 0},
}

// Token is the zone token of a scope in the tests.
func Token(s zones.Scope) string { return fmt.Sprintf("tok-%d-%s-%d", s.WorldID, s.ZoneID, s.Channel) }

// Config is the tests' configuration: env test, 5 s heartbeat and 30 s TTL (the clock is fake:
// it is advanced instead of waiting).
func Config() *config.Config {
	u, _ := url.Parse("http://127.0.0.1:24680")
	cfg := &config.Config{
		Env:            config.EnvTest,
		PublicURL:      u,
		ZoneHosts:      []string{"127.0.0.1", "203.0.113.5"},
		TrustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")},
		Argon2:         config.Argon2{MemoryKiB: 8, Time: 1, Threads: 1},
		EmailHMACKey:   config.TestEmailHMACKey,
		Mail:           config.MailLog,
		OpenRealms:     []config.Realm{config.RealmVardheim, config.RealmSolmarch},
		EntryZones:     map[config.Realm]string{config.RealmVardheim: "vado_gris", config.RealmSolmarch: "vado_gris"},
		TicketKeys:     map[uint8][]byte{1: TicketKey},
		TicketSignKey:  1,
		Heartbeat:      5 * time.Second,
		LeaseTTL:       30 * time.Second,
	}
	for _, s := range Scopes {
		cfg.ZoneTokens = append(cfg.ZoneTokens, config.ZoneToken{WorldID: s.WorldID, ZoneID: s.ZoneID, Channel: s.Channel,
			Hash: sha256.Sum256([]byte(Token(s)))})
	}
	return cfg
}

// Protocol is the tests' protocol (the minimum of the services).
const Protocol = 7

// Platform is the platform inside the test's process.
type Platform struct {
	T        testing.TB
	Pool     *pgxpool.Pool
	Cfg      *config.Config
	Clock    *clock.Fake
	Progress *persistence.MemoryProgressStore // the fake one; nil with [NewWithProgress]
	// ProgressStore is the store the platform uses: Progress or the one from [NewWithProgress].
	ProgressStore persistence.ProgressStore
	Accounts      *accounts.Service
	Characters    *characters.Service
	Zones         *zones.Service
	Store         *persistence.Store
	War           *war.Service
	Social        *social.Service
	Admin         *admin.Service   // the admin command (P7a), with os_user "prueba"
	Privacy       *privacy.Service // the retention jobs from §11.1 (P9a), with the fake clock
	Public        http.Handler
	Internal      http.Handler
	Logs          *SyncBuffer

	ip atomic.Int32
}

type publicRouter struct{ *http.ServeMux }

func (r publicRouter) HandlePublic(pattern string, h http.Handler) { r.Handle(pattern, h) }

type internalRouter struct{ *http.ServeMux }

func (r internalRouter) HandleInternal(pattern string, h http.Handler) { r.Handle(pattern, h) }

// New assembles the platform on a fresh database. opts change the configuration before assembly.
func New(t testing.TB, opts ...func(*config.Config)) *Platform {
	t.Helper()
	return Attach(t, testdb.New(t), opts...)
}

// NewWithProgress assembles the platform on a fresh database with the given progress store and
// creation validation (the real ones, internal/progress) instead of the fake and the provisional
// ones. newStore receives the platform's fake clock.
func NewWithProgress(t testing.TB, newStore func(now func() time.Time) persistence.ProgressStore,
	validator persistence.CreateValidator, opts ...func(*config.Config)) *Platform {
	t.Helper()
	return attach(t, testdb.New(t), newStore, validator, opts...)
}

// Attach assembles the platform on a database that already has the schema (one restored with
// pg_restore, for example), with a new in-memory clock and progress.
func Attach(t testing.TB, pool *pgxpool.Pool, opts ...func(*config.Config)) *Platform {
	t.Helper()
	return attach(t, pool, nil, nil, opts...)
}

func attach(t testing.TB, pool *pgxpool.Pool, newStore func(now func() time.Time) persistence.ProgressStore,
	validator persistence.CreateValidator, opts ...func(*config.Config)) *Platform {
	t.Helper()
	cfg := Config()
	for _, o := range opts {
		o(cfg)
	}
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `insert into worlds (world_id, name) values (2, 'Segundo') on conflict do nothing`); err != nil {
		t.Fatal(err)
	}
	p := &Platform{T: t, Pool: pool, Cfg: cfg, Clock: clock.NewFake(time.Now().Truncate(time.Second)),
		Logs: &SyncBuffer{}}
	if newStore == nil {
		p.Progress = persistence.NewMemoryProgressStore()
		p.ProgressStore = p.Progress
	} else {
		p.ProgressStore = newStore(p.Clock.Now)
	}
	set, err := legal.Load(legal.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := set.Sync(ctx, pool, false); err != nil {
		t.Fatal(err)
	}
	log := logx.New(p.Logs, slog.LevelDebug)
	purger := characters.NewPurger(pool, p.ProgressStore, p.Clock, log)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	p.Accounts, err = accounts.New(accounts.Options{Config: cfg, Pool: pool, Log: log, Clock: p.Clock, Legal: set,
		Mail: &mail.LogSender{DB: pool, Log: log}, Characters: purger, Progress: p.ProgressStore, MinProtocol: Protocol})
	must(err)
	p.Characters, err = characters.New(characters.Options{Config: cfg, Pool: pool, Log: log, Clock: p.Clock,
		Accounts: p.Accounts, Progress: p.ProgressStore, Validator: validator, Purger: purger, MinProtocol: Protocol})
	must(err)
	p.Zones, err = zones.New(zones.Options{Config: cfg, Pool: pool, Log: log, Clock: p.Clock, MinProtocol: Protocol})
	must(err)
	p.Store, err = persistence.NewStore(persistence.StoreOptions{Pool: pool, Progress: p.ProgressStore, Clock: p.Clock,
		LeaseTTL: cfg.LeaseTTL, Log: log})
	must(err)
	p.War, err = war.New(war.Options{Pool: pool, Guard: p.Zones.Guard(), Clock: p.Clock, Log: log})
	must(err)
	p.Social, err = social.New(social.Options{Pool: pool, Guard: p.Zones.Guard(), Clock: p.Clock, Log: log})
	must(err)
	p.Admin, err = admin.New(admin.Options{Pool: pool, Accounts: p.Accounts, Characters: purger, Legal: set, Clock: p.Clock, Log: log,
		OSUser: "prueba", PurgePoll: 10 * time.Millisecond})
	must(err)
	p.Privacy, err = privacy.New(privacy.Options{Pool: pool, Progress: p.ProgressStore, Clock: p.Clock, Log: log})
	must(err)

	public := publicRouter{http.NewServeMux()}
	auth := accounts.NewAPI(p.Accounts)
	auth.Mount(public)
	characters.NewAPI(p.Characters).Mount(public, auth)
	p.Public = httpx.Middleware(log, public)

	internal := internalRouter{http.NewServeMux()}
	internal.Handle("/", httpx.NotFound())
	zones.NewAPI(p.Zones).Mount(internal)
	persistence.NewAPI(p.Store, p.Zones.Guard()).Mount(internal)
	p.War.Mount(internal)
	p.Social.Mount(internal)
	p.Internal = httpx.Middleware(log.With("api", "internal"), internal)
	return p
}

// Response is an HTTP response with its JSON body already read.
type Response struct {
	Status int
	Header http.Header
	Raw    string
	Body   map[string]any
}

// Code is the response's error.code, or "".
func (r *Response) Code() string {
	if e, ok := r.Body["error"].(map[string]any); ok {
		code, _ := e["code"].(string)
		return code
	}
	return ""
}

// ErrValue is a field of the error object.
func (r *Response) ErrValue(name string) any {
	if e, ok := r.Body["error"].(map[string]any); ok {
		return e[name]
	}
	return nil
}

// Field is error.fields[name].
func (r *Response) Field(name string) string {
	if f, ok := r.ErrValue("fields").(map[string]any); ok {
		v, _ := f[name].(string)
		return v
	}
	return ""
}

// String is a text field of the body.
func (r *Response) String(name string) string {
	v, _ := r.Body[name].(string)
	return v
}

func do(t testing.TB, h http.Handler, method, path string, body any, header map[string]string) *Response {
	t.Helper()
	var reader io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		reader = strings.NewReader(b)
	case []byte:
		reader = bytes.NewReader(b)
	default:
		data, err := json.Marshal(b)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(data)
	}
	r := httptest.NewRequest(method, path, reader)
	r.RemoteAddr = "127.0.0.1:40000"
	r.Header.Set("Content-Type", "application/json")
	for k, v := range header {
		r.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	res := &Response{Status: rec.Code, Header: rec.Header(), Raw: rec.Body.String()}
	if strings.HasPrefix(rec.Header().Get("Content-Type"), "application/json") && rec.Body.Len() > 0 {
		dec := json.NewDecoder(bytes.NewReader(rec.Body.Bytes()))
		dec.UseNumber()
		if err := dec.Decode(&res.Body); err != nil {
			t.Fatalf("%s %s: JSON: %v (%s)", method, path, err, rec.Body.String())
		}
	}
	return res
}

// Expect fails if the response does not have that status and that error code ("" for no error).
func Expect(t testing.TB, res *Response, status int, code string) {
	t.Helper()
	if res.Status != status || res.Code() != code {
		t.Fatalf("se esperaba %d %q y llega %d %q: %s", status, code, res.Status, res.Code(), res.Raw)
	}
}

// Client (public API).

// Password is the password of the test accounts.
const Password = "una contraseña larga"

// Player is an account with a game session: the access token and the refresh token of the
// latest one.
type Player struct {
	ID      int64
	Email   string
	Token   string
	Refresh string
}

func (p *Platform) nextIP() string {
	n := p.ip.Add(1)
	return netip.AddrFrom4([4]byte{198, 51, byte(100 + n/250), byte(1 + n%250)}).String()
}

// PublicDo makes a request to the public API with the protocol and, if given, the token.
func (p *Platform) PublicDo(method, path, token string, body any) *Response {
	p.T.Helper()
	h := map[string]string{httpx.ProtocolHeader: strconv.Itoa(Protocol), "X-Real-IP": p.nextIP()}
	if token != "" {
		h["Authorization"] = "Bearer " + token
	}
	return do(p.T, p.Public, method, path, body, h)
}

// NewPlayer registers an account and logs in.
func (p *Platform) NewPlayer(email string) *Player {
	p.T.Helper()
	res := p.PublicDo("POST", "/v1/accounts", "", map[string]any{"email": email, "password": Password,
		"age_confirmed": true, "accept": map[string]any{"terms": 1, "privacy": 1, "rules": 1},
		"consents": map[string]any{"crash_reports": false, "analytics": false}})
	if res.Status != http.StatusAccepted {
		p.T.Fatalf("registro de %s: %d %s", email, res.Status, res.Raw)
	}
	pl := &Player{Email: email}
	p.Scalar(&pl.ID, `select account_id from accounts where email = $1`, email)
	p.Login(pl)
	return pl
}

// Login opens a new session (and revokes the account's previous ones, replaced).
func (p *Platform) Login(pl *Player) {
	p.T.Helper()
	res := p.PublicDo("POST", "/v1/sessions", "", map[string]any{"email": pl.Email, "password": Password})
	if res.Status != http.StatusOK {
		p.T.Fatalf("inicio de sesión de %s: %d %s", pl.Email, res.Status, res.Raw)
	}
	pl.Token, pl.Refresh = res.String("access_token"), res.String("refresh_token")
}

// RefreshSession refreshes the player's session (rotates both tokens in the same row, §4.2).
func (p *Platform) RefreshSession(pl *Player) *Response {
	p.T.Helper()
	res := p.PublicDo("POST", "/v1/sessions/refresh", "", map[string]any{"refresh_token": pl.Refresh})
	if res.Status == http.StatusOK {
		pl.Token, pl.Refresh = res.String("access_token"), res.String("refresh_token")
	}
	return res
}

// Appearance is 8 B of appearance in base64 (the provisional validation does not look at them).
var Appearance = base64.StdEncoding.EncodeToString([]byte{1, 0, 2, 1, 0, 3, 2, 0x21})

// ValidAppearances are 8 B that are valid under the real rules in each open realm (the ones in
// tests/fixtures/progression/appearance_cases.json): the ones [Platform.NewCharacter] uses with
// [NewWithProgress].
var ValidAppearances = map[string]string{"vardheim": "AQAAAQEDAgE=", "solmarch": "AgAAAAAHAAA="}

// NewCharacter creates a character in world 1 and returns its id.
func (p *Platform) NewCharacter(pl *Player, name, realm string) int64 {
	p.T.Helper()
	appearance := Appearance
	if p.Progress == nil {
		appearance = ValidAppearances[realm]
	}
	res := p.PublicDo("POST", "/v1/worlds/1/characters", pl.Token, map[string]any{"name": name, "realm": realm,
		"race_id": "race_" + realm, "appearance": appearance, "starter_template_id": "squire"})
	if res.Status != http.StatusCreated {
		p.T.Fatalf("crear %s: %d %s", name, res.Status, res.Raw)
	}
	c, _ := res.Body["character"].(map[string]any)
	id, err := strconv.ParseInt(fmt.Sprint(c["character_id"]), 10, 64)
	if err != nil {
		p.T.Fatalf("character_id: %v", c)
	}
	return id
}

// NewCharacterIn creates a character by hand in another world (the phase 5 public API creates
// in world 1), with its progress in the platform's store.
func (p *Platform) NewCharacterIn(pl *Player, worldID int16, name string, realm int16) int64 {
	p.T.Helper()
	var id int64
	key := strings.ToLower(name)
	p.Scalar(&id, `insert into characters (world_id, account_id, name, name_key, realm) values ($1, $2, $3, $4, $5)
		returning character_id`, worldID, pl.ID, name, key, realm)
	p.Exec(`insert into character_names (world_id, name_key, character_id, status) values ($1, $2, $3, 'active')`,
		worldID, key, id)
	p.Exec(`insert into character_pvp_stats (character_id, world_id) values ($1, $2)`, id, worldID)
	appearance, err := base64.StdEncoding.DecodeString(ValidAppearances["vardheim"])
	if err != nil {
		p.T.Fatal(err)
	}
	params := persistence.CreateParams{RaceID: "race_vardheim", Appearance: [8]byte(appearance),
		StarterTemplateID: "squire"}
	if err := db.InTx(context.Background(), p.Pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		return p.ProgressStore.Create(context.Background(), tx, worldID, id, params)
	}); err != nil {
		p.T.Fatal(err)
	}
	return id
}

// Enter requests entry to the world with the character.
func (p *Platform) Enter(pl *Player, characterID int64) *Response {
	p.T.Helper()
	return p.PublicDo("POST", "/v1/characters/"+strconv.FormatInt(characterID, 10)+"/enter", pl.Token, nil)
}

// MustEnter enters and returns the ticket's ticket_id and the chosen instance.
func (p *Platform) MustEnter(pl *Player, characterID int64) (int64, string) {
	p.T.Helper()
	res := p.Enter(pl, characterID)
	if res.Status != http.StatusOK {
		p.T.Fatalf("enter: %d %s", res.Status, res.Raw)
	}
	raw, err := base64.StdEncoding.DecodeString(res.String("ticket"))
	if err != nil {
		p.T.Fatal(err)
	}
	t, err := tickets.Parse(raw, p.Cfg.TicketKeys)
	if err != nil {
		p.T.Fatal(err)
	}
	var instance string
	p.Scalar(&instance, `select zone_instance_id::text from enter_tickets where ticket_id = $1`, int64(t.TicketID))
	return int64(t.TicketID), instance
}

// Database.

// Exec runs a statement or fails.
func (p *Platform) Exec(sql string, args ...any) {
	p.T.Helper()
	if _, err := p.Pool.Exec(context.Background(), sql, args...); err != nil {
		p.T.Fatalf("%v\n%s", err, sql)
	}
}

// Scalar reads a one-column row into dst or fails.
func (p *Platform) Scalar(dst any, sql string, args ...any) {
	p.T.Helper()
	if err := p.Pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		p.T.Fatalf("%v\n%s", err, sql)
	}
}

// Count is a count(*) (or any integer).
func (p *Platform) Count(sql string, args ...any) int {
	p.T.Helper()
	var n int
	p.Scalar(&n, sql, args...)
	return n
}
