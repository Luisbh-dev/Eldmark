// Package platformtest monta la plataforma entera en el proceso de una prueba (solo para pruebas):
// la base efímera de testdb, el reloj falso, el progreso en memoria
// (persistence.MemoryProgressStore), la API pública (cuentas y personajes), la interna (zonas,
// reclamación y guardado, guerra y lo social) y la orden admin, con ayudas para hacer de cliente y
// de zona.
//
// Lo usan las pruebas de zones, persistence, war y social: la API interna solo se entiende con
// cuentas, personajes y billetes de verdad delante.
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

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/characters"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/social"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/internal/tickets"
	"eldmark/platform/internal/war"
	"eldmark/platform/internal/zones"
	"eldmark/platform/legal"
)

// SyncBuffer es un registro que se puede leer mientras se escribe.
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

// TicketKey es la clave del billete del vector de plataforma.md §5.1 (solo vale en test).
var TicketKey = func() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	return k
}()

// Scopes son los despliegues de zona con token en las pruebas: el mundo 2 existe para comprobar que
// la instancia pone el mundo.
var Scopes = []zones.Scope{
	{WorldID: 1, ZoneID: "vado_gris", Channel: 0},
	{WorldID: 1, ZoneID: "vado_gris", Channel: 1},
	{WorldID: 1, ZoneID: "test_world", Channel: 0},
	{WorldID: 2, ZoneID: "vado_gris", Channel: 0},
}

// Token es el token de zona de un alcance en las pruebas.
func Token(s zones.Scope) string { return fmt.Sprintf("tok-%d-%s-%d", s.WorldID, s.ZoneID, s.Channel) }

// Config es la configuración de las pruebas: env test, latido de 5 s y TTL de 30 s (el reloj es
// falso: se adelanta en lugar de esperar).
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

// Protocol es el protocolo de las pruebas (el mínimo de los servicios).
const Protocol = 7

// Platform es la plataforma en el proceso de la prueba.
type Platform struct {
	T          testing.TB
	Pool       *pgxpool.Pool
	Cfg        *config.Config
	Clock      *clock.Fake
	Progress   *persistence.MemoryProgressStore
	Accounts   *accounts.Service
	Characters *characters.Service
	Zones      *zones.Service
	Store      *persistence.Store
	War        *war.Service
	Social     *social.Service
	Admin      *admin.Service // la orden admin (P7a), con os_user «prueba»
	Public     http.Handler
	Internal   http.Handler
	Logs       *SyncBuffer

	ip atomic.Int32
}

type publicRouter struct{ *http.ServeMux }

func (r publicRouter) HandlePublic(pattern string, h http.Handler) { r.Handle(pattern, h) }

type internalRouter struct{ *http.ServeMux }

func (r internalRouter) HandleInternal(pattern string, h http.Handler) { r.Handle(pattern, h) }

// New monta la plataforma sobre una base nueva. opts cambian la configuración antes de montar.
func New(t testing.TB, opts ...func(*config.Config)) *Platform {
	t.Helper()
	return Attach(t, testdb.New(t), opts...)
}

// Attach monta la plataforma sobre una base que ya tiene el esquema (una restaurada con
// pg_restore, por ejemplo), con un reloj y un progreso en memoria nuevos.
func Attach(t testing.TB, pool *pgxpool.Pool, opts ...func(*config.Config)) *Platform {
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
		Progress: persistence.NewMemoryProgressStore(), Logs: &SyncBuffer{}}
	set, err := legal.Load(legal.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := set.Sync(ctx, pool, false); err != nil {
		t.Fatal(err)
	}
	log := logx.New(p.Logs, slog.LevelDebug)
	purger := characters.NewPurger(pool, p.Progress, p.Clock, log)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	p.Accounts, err = accounts.New(accounts.Options{Config: cfg, Pool: pool, Log: log, Clock: p.Clock, Legal: set,
		Mail: &mail.LogSender{DB: pool, Log: log}, Characters: purger, MinProtocol: Protocol})
	must(err)
	p.Characters, err = characters.New(characters.Options{Config: cfg, Pool: pool, Log: log, Clock: p.Clock,
		Accounts: p.Accounts, Progress: p.Progress, Purger: purger, MinProtocol: Protocol})
	must(err)
	p.Zones, err = zones.New(zones.Options{Config: cfg, Pool: pool, Log: log, Clock: p.Clock, MinProtocol: Protocol})
	must(err)
	p.Store, err = persistence.NewStore(persistence.StoreOptions{Pool: pool, Progress: p.Progress, Clock: p.Clock,
		LeaseTTL: cfg.LeaseTTL, Log: log})
	must(err)
	p.War, err = war.New(war.Options{Pool: pool, Guard: p.Zones.Guard(), Clock: p.Clock, Log: log})
	must(err)
	p.Social, err = social.New(social.Options{Pool: pool, Guard: p.Zones.Guard(), Clock: p.Clock, Log: log})
	must(err)
	p.Admin, err = admin.New(admin.Options{Pool: pool, Accounts: p.Accounts, Characters: purger, Legal: set, Clock: p.Clock, Log: log,
		OSUser: "prueba", PurgePoll: 10 * time.Millisecond})
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

// Response es una respuesta HTTP con su cuerpo JSON ya leído.
type Response struct {
	Status int
	Header http.Header
	Raw    string
	Body   map[string]any
}

// Code es el error.code de la respuesta, o "".
func (r *Response) Code() string {
	if e, ok := r.Body["error"].(map[string]any); ok {
		code, _ := e["code"].(string)
		return code
	}
	return ""
}

// ErrValue es un campo del objeto error.
func (r *Response) ErrValue(name string) any {
	if e, ok := r.Body["error"].(map[string]any); ok {
		return e[name]
	}
	return nil
}

// Field es error.fields[name].
func (r *Response) Field(name string) string {
	if f, ok := r.ErrValue("fields").(map[string]any); ok {
		v, _ := f[name].(string)
		return v
	}
	return ""
}

// String es un campo de texto del cuerpo.
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

// Expect falla si la respuesta no tiene ese estado y ese código de error ("" sin error).
func Expect(t testing.TB, res *Response, status int, code string) {
	t.Helper()
	if res.Status != status || res.Code() != code {
		t.Fatalf("se esperaba %d %q y llega %d %q: %s", status, code, res.Status, res.Code(), res.Raw)
	}
}

// Cliente (API pública).

// Password es la contraseña de las cuentas de prueba.
const Password = "una contraseña larga"

// Player es una cuenta con una sesión de juego: el token de acceso y el de refresco de la última.
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

// PublicDo hace una petición a la API pública con el protocolo y, si se da, el token.
func (p *Platform) PublicDo(method, path, token string, body any) *Response {
	p.T.Helper()
	h := map[string]string{httpx.ProtocolHeader: strconv.Itoa(Protocol), "X-Real-IP": p.nextIP()}
	if token != "" {
		h["Authorization"] = "Bearer " + token
	}
	return do(p.T, p.Public, method, path, body, h)
}

// NewPlayer registra una cuenta e inicia sesión.
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

// Login abre una sesión nueva (y revoca las anteriores de la cuenta, replaced).
func (p *Platform) Login(pl *Player) {
	p.T.Helper()
	res := p.PublicDo("POST", "/v1/sessions", "", map[string]any{"email": pl.Email, "password": Password})
	if res.Status != http.StatusOK {
		p.T.Fatalf("inicio de sesión de %s: %d %s", pl.Email, res.Status, res.Raw)
	}
	pl.Token, pl.Refresh = res.String("access_token"), res.String("refresh_token")
}

// RefreshSession refresca la sesión del jugador (rota los dos tokens en la misma fila, §4.2).
func (p *Platform) RefreshSession(pl *Player) *Response {
	p.T.Helper()
	res := p.PublicDo("POST", "/v1/sessions/refresh", "", map[string]any{"refresh_token": pl.Refresh})
	if res.Status == http.StatusOK {
		pl.Token, pl.Refresh = res.String("access_token"), res.String("refresh_token")
	}
	return res
}

// Appearance son 8 B de apariencia en base64.
var Appearance = base64.StdEncoding.EncodeToString([]byte{1, 0, 2, 1, 0, 3, 2, 0x21})

// NewCharacter crea un personaje en el mundo 1 y devuelve su id.
func (p *Platform) NewCharacter(pl *Player, name, realm string) int64 {
	p.T.Helper()
	res := p.PublicDo("POST", "/v1/worlds/1/characters", pl.Token, map[string]any{"name": name, "realm": realm,
		"race_id": "race_" + realm, "appearance": Appearance, "starter_template_id": "squire"})
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

// NewCharacterIn crea a mano un personaje en otro mundo (la API pública de la fase 5 crea en el 1),
// con su progreso en el falso.
func (p *Platform) NewCharacterIn(pl *Player, worldID int16, name string, realm int16) int64 {
	p.T.Helper()
	var id int64
	key := strings.ToLower(name)
	p.Scalar(&id, `insert into characters (world_id, account_id, name, name_key, realm) values ($1, $2, $3, $4, $5)
		returning character_id`, worldID, pl.ID, name, key, realm)
	p.Exec(`insert into character_names (world_id, name_key, character_id, status) values ($1, $2, $3, 'active')`,
		worldID, key, id)
	p.Exec(`insert into character_pvp_stats (character_id, world_id) values ($1, $2)`, id, worldID)
	if err := p.Progress.Create(context.Background(), nil, worldID, id, persistence.CreateParams{RaceID: "race_vardheim",
		StarterTemplateID: "squire"}); err != nil {
		p.T.Fatal(err)
	}
	return id
}

// Enter pide entrar al mundo con el personaje.
func (p *Platform) Enter(pl *Player, characterID int64) *Response {
	p.T.Helper()
	return p.PublicDo("POST", "/v1/characters/"+strconv.FormatInt(characterID, 10)+"/enter", pl.Token, nil)
}

// MustEnter entra y devuelve el ticket_id del billete y la instancia elegida.
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

// Base de datos.

// Exec ejecuta una sentencia o falla.
func (p *Platform) Exec(sql string, args ...any) {
	p.T.Helper()
	if _, err := p.Pool.Exec(context.Background(), sql, args...); err != nil {
		p.T.Fatalf("%v\n%s", err, sql)
	}
}

// Scalar lee una fila de una columna en dst o falla.
func (p *Platform) Scalar(dst any, sql string, args ...any) {
	p.T.Helper()
	if err := p.Pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		p.T.Fatalf("%v\n%s", err, sql)
	}
}

// Count es un count(*) (o cualquier entero).
func (p *Platform) Count(sql string, args ...any) int {
	p.T.Helper()
	var n int
	p.Scalar(&n, sql, args...)
	return n
}
