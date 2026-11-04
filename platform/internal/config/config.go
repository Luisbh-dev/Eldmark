// Package config reads the platform's configuration from environment variables (platform.md
// §2.3). Each secret also accepts <NAME>_FILE with the path of a file (Docker secrets). A value that
// is missing or not understood prevents startup: [Load] returns an error in Spanish with all the
// problems, one per line, never repeating a secret's value.
package config

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/netip"
	"net/url"
	"os"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// Lookup reads an environment variable; os.LookupEnv works.
type Lookup func(key string) (string, bool)

// Env is the environment: dev, test, staging or production.
type Env string

// Environments.
const (
	EnvDev        Env = "dev"
	EnvTest       Env = "test"
	EnvStaging    Env = "staging"
	EnvProduction Env = "production"
)

// Deployed says whether it is staging or production, where the strict rules apply.
func (e Env) Deployed() bool { return e == EnvStaging || e == EnvProduction }

// Realm is a realm's code, that of NetProtocol.Realm (1 Vardheim, 2 Solmarch, 3 Askarra).
type Realm int16

// Realms.
const (
	RealmVardheim Realm = 1
	RealmSolmarch Realm = 2
	RealmAskarra  Realm = 3
)

var realmNames = map[Realm]string{RealmVardheim: "vardheim", RealmSolmarch: "solmarch", RealmAskarra: "askarra"}

// String returns the realm's text id ("vardheim"), the public API's.
func (r Realm) String() string {
	if name, ok := realmNames[r]; ok {
		return name
	}
	return "realm(" + strconv.Itoa(int(r)) + ")"
}

// ParseRealm reads a realm's text id.
func ParseRealm(name string) (Realm, bool) {
	for code, n := range realmNames {
		if n == name {
			return code, true
		}
	}
	return 0, false
}

// ZoneToken is an entry of ELDMARK_ZONE_TOKENS: the scope of a zone deployment and the SHA-256 of
// its token (the platform never stores the token, platform.md §6).
type ZoneToken struct {
	WorldID int16
	ZoneID  string
	Channel int16
	Hash    [sha256.Size]byte
}

// Argon2 are the argon2id parameters (ELDMARK_ARGON2).
type Argon2 struct {
	MemoryKiB uint32
	Time      uint32
	Threads   uint8
}

// Mail is the email sending mode.
type Mail string

// Mail modes.
const (
	MailLog  Mail = "log"  // to the outbound_mail table and the log (dev and test)
	MailSMTP Mail = "smtp" // over SMTP
)

// Database is what the migrate command needs.
type Database struct {
	Env         Env
	DatabaseURL string // secret
}

// Config is serve's full configuration.
type Config struct {
	Env         Env
	DatabaseURL string // secret

	PublicAddr   string
	InternalAddr string
	PublicURL    *url.URL

	ZoneTokens     []ZoneToken // secret (hashes only)
	ZoneHosts      []string
	TrustedProxies []netip.Prefix

	TicketKeys    map[uint8][]byte // secret
	TicketSignKey uint8
	EmailHMACKey  []byte // secret

	Argon2 Argon2
	// MinProtocol is the client's minimum protocol (below it, 426). 0 in dev and test without the
	// variable: then the protocol_version of progression_rules.json (internal/gamedata) applies, which
	// serve resolves with [Config.ResolveMinProtocol].
	MinProtocol int

	OpenRealms           []Realm
	EntryZones           map[Realm]string
	RequireVerifiedEmail bool

	Mail    Mail
	SMTPURL *url.URL // secret
	// MailFrom is the sender of the emails (ELDMARK_MAIL_FROM; by default
	// no-reply@<host of ELDMARK_PUBLIC_URL>).
	MailFrom string

	TLSCertFile string
	TLSKeyFile  string

	Heartbeat time.Duration
	LeaseTTL  time.Duration
	// LegalDir is the folder of the legal texts (ELDMARK_LEGAL_DIR); empty, the ones inside the binary
	// (platform/legal).
	LegalDir string
}

// LostAfterHeartbeats is how many heartbeats can be missed before an instance is considered lost
// (platform.md §5.3).
const LostAfterHeartbeats = 3

// LostEvery is how often the lost-instances job runs: min(5 s, HEARTBEAT_S) (§2.5).
func (c *Config) LostEvery() time.Duration { return min(5*time.Second, c.Heartbeat) }

// LostDetected is how long an instance can take to be considered lost since its last heartbeat: 3 x
// HEARTBEAT_S plus one round of the job. The leases' TTL has to exceed that (Load requires it):
// otherwise, one expires with the instance still alive and a late heartbeat would find it expired
// while the claim, enter and deletion already considered it free.
func (c *Config) LostDetected() time.Duration {
	return LostAfterHeartbeats*c.Heartbeat + c.LostEvery()
}

// ResolveMinProtocol returns the minimum protocol: that of ELDMARK_MIN_PROTOCOL or, if none was
// given (only in dev and test), the protocol_version of the exported rules.
func (c *Config) ResolveMinProtocol(rulesProtocol int) int {
	if c.MinProtocol > 0 {
		return c.MinProtocol
	}
	return rulesProtocol
}

// LogValue summarizes the configuration for the log, without secrets.
func (c *Config) LogValue() slog.Value {
	publicURL := ""
	if c.PublicURL != nil {
		publicURL = c.PublicURL.String()
	}
	realms := make([]string, 0, len(c.OpenRealms))
	for _, r := range c.OpenRealms {
		realms = append(realms, r.String())
	}
	return slog.GroupValue(
		slog.String("env", string(c.Env)),
		slog.String("public_addr", c.PublicAddr),
		slog.String("internal_addr", c.InternalAddr),
		slog.String("public_url", publicURL),
		slog.Int("zone_tokens", len(c.ZoneTokens)),
		slog.Int("ticket_keys", len(c.TicketKeys)),
		slog.Int("ticket_sign_key", int(c.TicketSignKey)),
		slog.Int("min_protocol", c.MinProtocol),
		slog.String("open_realms", strings.Join(realms, ",")),
		slog.String("mail", string(c.Mail)),
		slog.Bool("tls", c.TLSCertFile != ""),
		slog.Int("heartbeat_s", int(c.Heartbeat/time.Second)),
		slog.Int("lease_ttl_s", int(c.LeaseTTL/time.Second)),
	)
}

// Ticket key from the test vector of platform.md §5.1 (00 01 ... 1f): only valid in test.
var vectorTicketKey = func() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	return k
}()

// TestEmailHMACKey is the fixed test key for ELDMARK_EMAIL_HMAC_KEY in dev and test; outside them it
// is not accepted.
var TestEmailHMACKey = func() []byte {
	sum := sha256.Sum256([]byte("eldmark: clave HMAC de correos solo para pruebas"))
	return sum[:]
}()

var (
	zoneIDPattern   = regexp.MustCompile(`^[a-z0-9_]{1,64}$`)
	hostnamePattern = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)
)

// loader accumulates the problems to report them all at once.
type loader struct {
	lookup Lookup
	errs   []string
}

func (l *loader) fail(name, format string, args ...any) {
	l.errs = append(l.errs, name+": "+fmt.Sprintf(format, args...))
}

func (l *loader) err() error {
	if len(l.errs) == 0 {
		return nil
	}
	return errors.New("configuración no válida:\n- " + strings.Join(l.errs, "\n- "))
}

// get returns the value of an ordinary variable; empty or whitespace-only counts as absent.
func (l *loader) get(name string) (string, bool) {
	v, ok := l.lookup(name)
	v = strings.TrimSpace(v)
	if !ok || v == "" {
		return "", false
	}
	return v, true
}

// secret returns a secret from <name> or from the file in <name>_FILE (not both).
func (l *loader) secret(name string) (string, bool) {
	direct, hasDirect := l.get(name)
	path, hasFile := l.get(name + "_FILE")
	switch {
	case hasDirect && hasFile:
		l.fail(name, "se ha dado a la vez %s y %s_FILE; usa solo una", name, name)
		return "", false
	case hasFile:
		data, err := os.ReadFile(path)
		if err != nil {
			reason := "no se puede leer"
			switch {
			case errors.Is(err, os.ErrNotExist):
				reason = "no existe"
			case errors.Is(err, os.ErrPermission):
				reason = "no hay permiso para leerlo"
			}
			l.fail(name+"_FILE", "el archivo %q %s", path, reason)
			return "", false
		}
		v := strings.TrimSpace(string(data))
		if v == "" {
			l.fail(name+"_FILE", "el archivo %q está vacío", path)
			return "", false
		}
		return v, true
	default:
		return direct, hasDirect
	}
}

func (l *loader) env() Env {
	v, ok := l.get("ELDMARK_ENV")
	if !ok {
		return EnvDev
	}
	switch e := Env(v); e {
	case EnvDev, EnvTest, EnvStaging, EnvProduction:
		return e
	}
	l.fail("ELDMARK_ENV", "%q no es un entorno; vale dev, test, staging o production", v)
	return EnvDev
}

func (l *loader) databaseURL() string {
	const name = "ELDMARK_DATABASE_URL"
	v, ok := l.secret(name)
	if !ok {
		l.failMissingSecret(name, "la URL de PostgreSQL")
		return ""
	}
	// pgconn also reads the PG* variables; here we only check that the string is understood. The
	// message does not repeat the string, which carries the password.
	if _, err := pgconn.ParseConfig(v); err != nil {
		l.fail(name, "no se entiende como cadena de conexión de PostgreSQL")
		return ""
	}
	return v
}

// LoadDatabase reads what migrate needs: ELDMARK_ENV and ELDMARK_DATABASE_URL.
func LoadDatabase(lookup Lookup) (*Database, error) {
	l := &loader{lookup: lookup}
	d := &Database{Env: l.env()}
	d.DatabaseURL = l.databaseURL()
	if err := l.err(); err != nil {
		return nil, err
	}
	return d, nil
}

// Load reads serve's full configuration.
func Load(lookup Lookup) (*Config, error) {
	l := &loader{lookup: lookup}
	c := &Config{Env: l.env()}
	c.DatabaseURL = l.databaseURL()

	c.PublicAddr = l.addr("ELDMARK_PUBLIC_ADDR", "127.0.0.1:24680")
	c.InternalAddr = l.addr("ELDMARK_INTERNAL_ADDR", "127.0.0.1:24681")
	if c.PublicAddr != "" && c.PublicAddr == c.InternalAddr {
		l.fail("ELDMARK_INTERNAL_ADDR", "no puede ser la misma dirección que ELDMARK_PUBLIC_ADDR")
	}
	c.PublicURL = l.publicURL()

	c.ZoneTokens = l.zoneTokens()
	c.ZoneHosts = l.zoneHosts()
	c.TrustedProxies = l.trustedProxies()

	c.TicketKeys, c.TicketSignKey = l.ticketKeys(c.Env)
	c.EmailHMACKey = l.emailHMACKey(c.Env)

	c.Argon2 = l.argon2(c.Env)
	c.MinProtocol = l.minProtocol(c.Env)

	c.OpenRealms = l.openRealms()
	c.EntryZones = l.entryZones(c.OpenRealms)
	c.RequireVerifiedEmail = l.boolean("ELDMARK_REQUIRE_VERIFIED_EMAIL", c.Env.Deployed())

	c.Mail, c.SMTPURL = l.mail(c.Env)
	c.MailFrom = l.mailFrom(c.PublicURL)
	c.TLSCertFile, c.TLSKeyFile = l.tls()

	c.Heartbeat = l.seconds("ELDMARK_HEARTBEAT_S", 5)
	c.LeaseTTL = l.seconds("ELDMARK_LEASE_TTL_S", 30)
	if floor := c.LostDetected(); c.Heartbeat > 0 && c.LeaseTTL > 0 && c.LeaseTTL <= floor {
		l.fail("ELDMARK_LEASE_TTL_S", "tiene que ser mayor que %d × ELDMARK_HEARTBEAT_S + min(5 s, ELDMARK_HEARTBEAT_S) (%v): "+
			"un arrendamiento no puede caducar antes de que su instancia sin latido se dé por perdida", LostAfterHeartbeats, floor)
	}
	if v, ok := l.get("ELDMARK_LEGAL_DIR"); ok {
		if st, err := os.Stat(v); err != nil || !st.IsDir() {
			l.fail("ELDMARK_LEGAL_DIR", "%q no es una carpeta", v)
		}
		c.LegalDir = v
	}

	if err := l.err(); err != nil {
		return nil, err
	}
	return c, nil
}

func (l *loader) addr(name, def string) string {
	v, ok := l.get(name)
	if !ok {
		return def
	}
	_, port, err := net.SplitHostPort(v)
	if err != nil {
		l.fail(name, "%q no es una dirección host:puerto", v)
		return ""
	}
	if p, err := strconv.Atoi(port); err != nil || p < 0 || p > 65535 {
		l.fail(name, "el puerto de %q no vale", v)
		return ""
	}
	return v
}

func (l *loader) publicURL() *url.URL {
	v, ok := l.get("ELDMARK_PUBLIC_URL")
	if !ok {
		v = "http://127.0.0.1:24680"
	}
	u, err := url.Parse(v)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil ||
		u.RawQuery != "" || u.Fragment != "" {
		l.fail("ELDMARK_PUBLIC_URL", "%q no es una URL http o https absoluta (sin usuario, consulta ni fragmento)", v)
		return &url.URL{}
	}
	u.Path = strings.TrimRight(u.Path, "/")
	return u
}

func (l *loader) zoneTokens() []ZoneToken {
	const name = "ELDMARK_ZONE_TOKENS"
	v, ok := l.secret(name)
	if !ok {
		l.failMissingSecret(name, "una entrada <mundo>:<zona>:<canal>:<SHA-256 en hex del token> por despliegue de zona")
		return nil
	}
	before := len(l.errs)
	var tokens []ZoneToken
	scopes := map[[sha256.Size]byte]string{}
	for i, entry := range splitList(v) {
		parts := strings.Split(entry, ":")
		if len(parts) != 4 {
			l.fail(name, "la entrada %d no tiene la forma <mundo>:<zona>:<canal>:<hash>", i+1)
			continue
		}
		world, errW := strconv.Atoi(parts[0])
		channel, errC := strconv.Atoi(parts[2])
		hash, errH := hex.DecodeString(parts[3])
		switch {
		case errW != nil || world < 1 || world > 32767:
			l.fail(name, "la entrada %d: el mundo tiene que ser un entero de 1 a 32767", i+1)
			continue
		case !zoneIDPattern.MatchString(parts[1]):
			l.fail(name, "la entrada %d: la zona tiene que ser un id en minúsculas ([a-z0-9_])", i+1)
			continue
		case errC != nil || channel < 0 || channel > 255:
			l.fail(name, "la entrada %d: el canal tiene que ser un entero de 0 a 255", i+1)
			continue
		case errH != nil || len(hash) != sha256.Size:
			l.fail(name, "la entrada %d: el hash tiene que ser un SHA-256 en hexadecimal (64 caracteres)", i+1)
			continue
		}
		t := ZoneToken{WorldID: int16(world), ZoneID: parts[1], Channel: int16(channel)}
		copy(t.Hash[:], hash)
		scope := fmt.Sprintf("%d:%s:%d", world, t.ZoneID, channel)
		if prev, dup := scopes[t.Hash]; dup && prev != scope {
			l.fail(name, "la entrada %d repite el token de otro alcance (%s): cada token es de un solo despliegue", i+1, prev)
			continue
		}
		scopes[t.Hash] = scope
		tokens = append(tokens, t)
	}
	if len(tokens) == 0 && len(l.errs) == before {
		l.fail(name, "no tiene ninguna entrada")
	}
	return tokens
}

// failMissingSecret records that a secret is missing, unless secret has already said why.
func (l *loader) failMissingSecret(name, what string) {
	for _, e := range l.errs {
		if strings.HasPrefix(e, name+": ") || strings.HasPrefix(e, name+"_FILE: ") {
			return
		}
	}
	l.fail(name, "falta (%s; o su archivo en %s_FILE)", what, name)
}

func (l *loader) zoneHosts() []string {
	v, ok := l.get("ELDMARK_ZONE_HOSTS")
	if !ok {
		return []string{"127.0.0.1"}
	}
	var hosts []string
	for _, h := range splitList(v) {
		if _, err := netip.ParseAddr(h); err != nil && !hostnamePattern.MatchString(h) {
			l.fail("ELDMARK_ZONE_HOSTS", "%q no es un nombre de máquina ni una IP", h)
			continue
		}
		hosts = append(hosts, h)
	}
	if len(hosts) == 0 {
		l.fail("ELDMARK_ZONE_HOSTS", "no tiene ninguna entrada")
	}
	return hosts
}

func (l *loader) trustedProxies() []netip.Prefix {
	v, ok := l.get("ELDMARK_TRUSTED_PROXIES")
	if !ok {
		v = "127.0.0.1/32"
	}
	var prefixes []netip.Prefix
	for _, p := range splitList(v) {
		prefix, err := netip.ParsePrefix(p)
		if err != nil {
			l.fail("ELDMARK_TRUSTED_PROXIES", "%q no es un CIDR (por ejemplo 172.18.0.5/32)", p)
			continue
		}
		prefixes = append(prefixes, prefix.Masked())
	}
	return prefixes
}

func (l *loader) ticketKeys(env Env) (map[uint8][]byte, uint8) {
	const name = "ELDMARK_TICKET_KEYS"
	v, ok := l.secret(name)
	if !ok {
		l.failMissingSecret(name, "claves del billete con la forma 1:<base64 de 32 B>,2:<…>")
		return nil, 0
	}
	before := len(l.errs)
	keys := map[uint8][]byte{}
	for i, entry := range splitList(v) {
		id, b64, found := strings.Cut(entry, ":")
		n, err := strconv.Atoi(id)
		if !found || err != nil || n < 1 || n > 255 {
			l.fail(name, "la entrada %d no tiene la forma <id de 1 a 255>:<base64>", i+1)
			continue
		}
		key, err := base64.StdEncoding.DecodeString(b64)
		switch {
		case err != nil:
			l.fail(name, "la clave %d no es base64 estándar", n)
			continue
		case len(key) < 32:
			l.fail(name, "la clave %d tiene %d B; hacen falta al menos 32", n, len(key))
			continue
		case bytes.Equal(key, vectorTicketKey) && env != EnvTest:
			l.fail(name, "la clave %d es la del vector de prueba (00 01 … 1f), que solo vale con ELDMARK_ENV=test", n)
			continue
		}
		if _, dup := keys[uint8(n)]; dup {
			l.fail(name, "la clave %d está repetida", n)
			continue
		}
		keys[uint8(n)] = key
	}
	if len(keys) == 0 {
		if len(l.errs) == before {
			l.fail(name, "no tiene ninguna clave")
		}
		return nil, 0
	}
	ids := make([]int, 0, len(keys))
	for id := range keys {
		ids = append(ids, int(id))
	}
	sort.Ints(ids)
	sign := uint8(ids[len(ids)-1])
	if s, ok := l.get("ELDMARK_TICKET_SIGN_KEY"); ok {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 || n > 255 {
			l.fail("ELDMARK_TICKET_SIGN_KEY", "%q no es un id de clave (1 a 255)", s)
			return keys, 0
		}
		if _, exists := keys[uint8(n)]; !exists {
			l.fail("ELDMARK_TICKET_SIGN_KEY", "la clave %d no está en ELDMARK_TICKET_KEYS", n)
			return keys, 0
		}
		sign = uint8(n)
	}
	return keys, sign
}

func (l *loader) emailHMACKey(env Env) []byte {
	const name = "ELDMARK_EMAIL_HMAC_KEY"
	v, ok := l.secret(name)
	if !ok {
		if env.Deployed() {
			l.failMissingSecret(name, "la clave HMAC de los correos sancionados, base64 de 32 B")
			return nil
		}
		return TestEmailHMACKey
	}
	key, err := base64.StdEncoding.DecodeString(v)
	switch {
	case err != nil:
		l.fail(name, "no es base64 estándar")
		return nil
	case len(key) < 32:
		l.fail(name, "tiene %d B; hacen falta al menos 32", len(key))
		return nil
	case bytes.Equal(key, TestEmailHMACKey) && env.Deployed():
		l.fail(name, "es la clave fija de pruebas, que solo vale en dev y test")
		return nil
	}
	return key
}

func (l *loader) argon2(env Env) Argon2 {
	const name = "ELDMARK_ARGON2"
	v, ok := l.get(name)
	if !ok {
		if env == EnvTest {
			return Argon2{MemoryKiB: 8, Time: 1, Threads: 1}
		}
		return Argon2{MemoryKiB: 19456, Time: 2, Threads: 1}
	}
	values := map[string]uint64{}
	for _, part := range strings.Split(v, ",") {
		k, val, found := strings.Cut(strings.TrimSpace(part), "=")
		n, err := strconv.ParseUint(val, 10, 32)
		if !found || err != nil || (k != "m" && k != "t" && k != "p") {
			l.fail(name, "%q no tiene la forma m=<KiB>,t=<pasadas>,p=<hilos>", v)
			return Argon2{}
		}
		values[k] = n
	}
	a := Argon2{MemoryKiB: uint32(values["m"]), Time: uint32(values["t"])}
	p := values["p"]
	if len(values) != 3 || a.Time < 1 || p < 1 || p > 255 || uint64(a.MemoryKiB) < 8*p {
		l.fail(name, "%q no vale: hacen falta m, t y p, con t ≥ 1, 1 ≤ p ≤ 255 y m ≥ 8·p", v)
		return Argon2{}
	}
	a.Threads = uint8(p)
	return a
}

func (l *loader) minProtocol(env Env) int {
	const name = "ELDMARK_MIN_PROTOCOL"
	v, ok := l.get(name)
	if !ok {
		if env.Deployed() {
			l.fail(name, "es obligatoria en staging y production")
		}
		return 0
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > 65535 {
		l.fail(name, "%q no es un número de protocolo (1 a 65535)", v)
		return 0
	}
	return n
}

func (l *loader) openRealms() []Realm {
	v, ok := l.get("ELDMARK_OPEN_REALMS")
	if !ok {
		v = "vardheim,solmarch"
	}
	var realms []Realm
	for _, name := range splitList(v) {
		r, ok := ParseRealm(name)
		if !ok {
			l.fail("ELDMARK_OPEN_REALMS", "%q no es un reino (vardheim, solmarch o askarra)", name)
			continue
		}
		if !slices.Contains(realms, r) {
			realms = append(realms, r)
		}
	}
	if len(realms) == 0 {
		l.fail("ELDMARK_OPEN_REALMS", "no tiene ningún reino")
	}
	return realms
}

func (l *loader) entryZones(open []Realm) map[Realm]string {
	const name = "ELDMARK_ENTRY_ZONES"
	v, ok := l.get(name)
	if !ok {
		v = "vardheim=vado_gris,solmarch=vado_gris"
	}
	zones := map[Realm]string{}
	for _, entry := range splitList(v) {
		realmName, zone, found := strings.Cut(entry, "=")
		r, okRealm := ParseRealm(realmName)
		if !found || !okRealm || !zoneIDPattern.MatchString(zone) {
			l.fail(name, "%q no tiene la forma <reino>=<zona>", entry)
			continue
		}
		zones[r] = zone
	}
	for _, r := range open {
		if _, ok := zones[r]; !ok {
			l.fail(name, "el reino abierto %s no tiene zona de entrada", r)
		}
	}
	return zones
}

func (l *loader) boolean(name string, def bool) bool {
	v, ok := l.get(name)
	if !ok {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		l.fail(name, "%q no es true ni false", v)
		return def
	}
	return b
}

func (l *loader) mail(env Env) (Mail, *url.URL) {
	mode := MailLog
	if v, ok := l.get("ELDMARK_MAIL"); ok {
		switch Mail(v) {
		case MailLog, MailSMTP:
			mode = Mail(v)
		default:
			l.fail("ELDMARK_MAIL", "%q no vale: log o smtp", v)
			return MailLog, nil
		}
	}
	if mode == MailLog {
		if env.Deployed() {
			l.fail("ELDMARK_MAIL", "en staging y production el correo va por SMTP (ELDMARK_MAIL=smtp y ELDMARK_SMTP_URL)")
		}
		return MailLog, nil
	}
	const name = "ELDMARK_SMTP_URL"
	v, ok := l.secret(name)
	if !ok {
		l.failMissingSecret(name, "con ELDMARK_MAIL=smtp hace falta smtp://usuario:clave@host:587")
		return mode, nil
	}
	u, err := url.Parse(v)
	if err != nil || (u.Scheme != "smtp" && u.Scheme != "smtps") || u.Hostname() == "" || u.Port() == "" {
		l.fail(name, "no tiene la forma smtp://usuario:clave@host:puerto")
		return mode, nil
	}
	return mode, u
}

var mailFromPattern = regexp.MustCompile(`^[\x21-\x3f\x41-\x7e]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$`)

func (l *loader) mailFrom(public *url.URL) string {
	v, ok := l.get("ELDMARK_MAIL_FROM")
	if !ok {
		host := "localhost"
		if public != nil && public.Hostname() != "" {
			if _, err := netip.ParseAddr(public.Hostname()); err != nil {
				host = public.Hostname()
			}
		}
		return "no-reply@" + host
	}
	if !mailFromPattern.MatchString(v) {
		l.fail("ELDMARK_MAIL_FROM", "%q no es una dirección de correo (solo la dirección, sin nombre)", v)
		return ""
	}
	return v
}

func (l *loader) tls() (string, string) {
	cert, hasCert := l.get("ELDMARK_TLS_CERT_FILE")
	key, hasKey := l.get("ELDMARK_TLS_KEY_FILE")
	if hasCert != hasKey {
		l.fail("ELDMARK_TLS_CERT_FILE", "ELDMARK_TLS_CERT_FILE y ELDMARK_TLS_KEY_FILE van juntas")
		return "", ""
	}
	for _, f := range [...]struct{ name, path string }{{"ELDMARK_TLS_CERT_FILE", cert}, {"ELDMARK_TLS_KEY_FILE", key}} {
		if f.path == "" {
			continue
		}
		if _, err := os.Stat(f.path); err != nil {
			l.fail(f.name, "no se encuentra %q", f.path)
		}
	}
	return cert, key
}

func (l *loader) seconds(name string, def int) time.Duration {
	v, ok := l.get(name)
	if !ok {
		return time.Duration(def) * time.Second
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > 3600 {
		l.fail(name, "%q no es un número de segundos (1 a 3600)", v)
		return 0
	}
	return time.Duration(n) * time.Second
}

// splitList splits a list by commas, without spaces or empty entries.
func splitList(v string) []string {
	var out []string
	for _, part := range strings.Split(v, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}
