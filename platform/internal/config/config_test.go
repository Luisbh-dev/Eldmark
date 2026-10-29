package config

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Clave de billete de 32 B que no es la del vector.
var goodKey = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xA5}, 32))

const dbURL = "postgres://eldmark:muy-secreta@127.0.0.1:5432/eldmark?sslmode=disable"

func zoneEntry(scope, token string) string {
	sum := sha256.Sum256([]byte(token))
	return scope + ":" + hex.EncodeToString(sum[:])
}

// minimal es lo mínimo con lo que serve arranca en dev.
func minimal() map[string]string {
	return map[string]string{
		"ELDMARK_DATABASE_URL": dbURL,
		"ELDMARK_ZONE_TOKENS":  zoneEntry("1:vado_gris:0", "token-de-la-zona"),
		"ELDMARK_TICKET_KEYS":  "1:" + goodKey,
	}
}

func lookupOf(env map[string]string) Lookup {
	return func(key string) (string, bool) {
		v, ok := env[key]
		return v, ok
	}
}

func mustLoad(t *testing.T, env map[string]string) *Config {
	t.Helper()
	c, err := Load(lookupOf(env))
	if err != nil {
		t.Fatalf("la configuración tenía que valer: %v", err)
	}
	return c
}

func mustFail(t *testing.T, env map[string]string, wantInError ...string) string {
	t.Helper()
	_, err := Load(lookupOf(env))
	if err == nil {
		t.Fatalf("la configuración no tenía que arrancar: %v", env)
	}
	msg := err.Error()
	for _, want := range wantInError {
		if !strings.Contains(msg, want) {
			t.Errorf("el error no dice %q:\n%s", want, msg)
		}
	}
	// Ningún error repite un secreto.
	for _, secret := range []string{"muy-secreta", goodKey, "token-de-la-zona"} {
		if strings.Contains(msg, secret) {
			t.Errorf("el error repite un secreto:\n%s", msg)
		}
	}
	return msg
}

func TestDefaultsInDev(t *testing.T) {
	c := mustLoad(t, minimal())
	if c.Env != EnvDev || c.PublicAddr != "127.0.0.1:24680" || c.InternalAddr != "127.0.0.1:24681" {
		t.Errorf("entorno y direcciones por defecto: %v %s %s", c.Env, c.PublicAddr, c.InternalAddr)
	}
	if c.PublicURL.String() != "http://127.0.0.1:24680" {
		t.Errorf("URL pública por defecto: %s", c.PublicURL)
	}
	if len(c.ZoneHosts) != 1 || c.ZoneHosts[0] != "127.0.0.1" {
		t.Errorf("hosts de zona por defecto: %v", c.ZoneHosts)
	}
	if len(c.TrustedProxies) != 1 || c.TrustedProxies[0].String() != "127.0.0.1/32" {
		t.Errorf("proxies de confianza por defecto: %v", c.TrustedProxies)
	}
	if c.TicketSignKey != 1 || len(c.TicketKeys[1]) != 32 {
		t.Errorf("clave del billete: %d", c.TicketSignKey)
	}
	if !bytes.Equal(c.EmailHMACKey, TestEmailHMACKey) {
		t.Error("en dev, la clave HMAC de pruebas")
	}
	if c.Argon2 != (Argon2{MemoryKiB: 19456, Time: 2, Threads: 1}) {
		t.Errorf("argon2 por defecto: %+v", c.Argon2)
	}
	if c.MinProtocol != 0 || c.ResolveMinProtocol(7) != 7 {
		t.Errorf("sin ELDMARK_MIN_PROTOCOL en dev manda el de las reglas: %d", c.MinProtocol)
	}
	if len(c.OpenRealms) != 2 || c.OpenRealms[0] != RealmVardheim || c.OpenRealms[1] != RealmSolmarch {
		t.Errorf("reinos abiertos: %v", c.OpenRealms)
	}
	if c.EntryZones[RealmVardheim] != "vado_gris" || c.EntryZones[RealmSolmarch] != "vado_gris" {
		t.Errorf("zonas de entrada: %v", c.EntryZones)
	}
	if c.RequireVerifiedEmail || c.Mail != MailLog || c.SMTPURL != nil {
		t.Errorf("correo en dev: verificado %v, modo %s", c.RequireVerifiedEmail, c.Mail)
	}
	if c.Heartbeat != 5*time.Second || c.LeaseTTL != 30*time.Second || c.LegalDir != "" || c.MailFrom != "no-reply@localhost" {
		t.Errorf("latido, TTL, textos legales y remitente: %s %s %q %q", c.Heartbeat, c.LeaseTTL, c.LegalDir, c.MailFrom)
	}
	z := c.ZoneTokens[0]
	if z.WorldID != 1 || z.ZoneID != "vado_gris" || z.Channel != 0 || z.Hash != sha256.Sum256([]byte("token-de-la-zona")) {
		t.Errorf("token de zona: %+v", z)
	}
}

func TestMissingVariablesDoNotStart(t *testing.T) {
	for _, name := range []string{"ELDMARK_DATABASE_URL", "ELDMARK_ZONE_TOKENS", "ELDMARK_TICKET_KEYS"} {
		env := minimal()
		delete(env, name)
		mustFail(t, env, name, "falta")
		// Vacía cuenta como ausente.
		env[name] = "  "
		mustFail(t, env, name, "falta")
	}
	// Con todo vacío, los tres problemas a la vez.
	msg := mustFail(t, map[string]string{})
	if strings.Count(msg, "\n- ") != 3 {
		t.Errorf("se dicen todos los problemas a la vez:\n%s", msg)
	}
}

func TestTicketKeys(t *testing.T) {
	env := minimal()
	env["ELDMARK_TICKET_KEYS"] = "1:" + base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 31))
	mustFail(t, env, "ELDMARK_TICKET_KEYS", "31 B")

	vector := make([]byte, 32)
	for i := range vector {
		vector[i] = byte(i)
	}
	env["ELDMARK_TICKET_KEYS"] = "1:" + base64.StdEncoding.EncodeToString(vector)
	for _, e := range []string{"dev", "staging", "production"} {
		env["ELDMARK_ENV"] = e
		mustFail(t, env, "vector de prueba")
	}
	env["ELDMARK_ENV"] = "test"
	if c := mustLoad(t, env); !bytes.Equal(c.TicketKeys[1], vector) {
		t.Error("en test vale la clave del vector")
	}

	env = minimal()
	other := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 48))
	env["ELDMARK_TICKET_KEYS"] = "1:" + goodKey + ", 2:" + other
	if c := mustLoad(t, env); c.TicketSignKey != 2 || len(c.TicketKeys) != 2 {
		t.Errorf("por defecto se firma con la mayor: %d", c.TicketSignKey)
	}
	env["ELDMARK_TICKET_SIGN_KEY"] = "1"
	if c := mustLoad(t, env); c.TicketSignKey != 1 {
		t.Errorf("ELDMARK_TICKET_SIGN_KEY elige la clave: %d", c.TicketSignKey)
	}
	env["ELDMARK_TICKET_SIGN_KEY"] = "3"
	mustFail(t, env, "ELDMARK_TICKET_SIGN_KEY")
	delete(env, "ELDMARK_TICKET_SIGN_KEY")
	for _, bad := range []string{"0:" + goodKey, "256:" + goodKey, "x:" + goodKey, goodKey, "1:no-es-base64!", "1:" + goodKey + ",1:" + other} {
		env["ELDMARK_TICKET_KEYS"] = bad
		mustFail(t, env, "ELDMARK_TICKET_KEYS")
	}
}

func TestDeployedEnvironmentsAreStrict(t *testing.T) {
	deployed := func(e string) map[string]string {
		env := minimal()
		env["ELDMARK_ENV"] = e
		env["ELDMARK_MIN_PROTOCOL"] = "7"
		env["ELDMARK_MAIL"] = "smtp"
		env["ELDMARK_SMTP_URL"] = "smtp://cartero:clave@smtp.example.org:587"
		env["ELDMARK_EMAIL_HMAC_KEY"] = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
		return env
	}
	for _, e := range []string{"staging", "production"} {
		c := mustLoad(t, deployed(e))
		if !c.RequireVerifiedEmail || c.MinProtocol != 7 || c.Mail != MailSMTP || c.SMTPURL.Hostname() != "smtp.example.org" {
			t.Errorf("%s: %+v", e, c)
		}
		if c.Argon2.MemoryKiB != 19456 {
			t.Errorf("%s: argon2 de producción", e)
		}

		env := deployed(e)
		delete(env, "ELDMARK_MIN_PROTOCOL")
		mustFail(t, env, "ELDMARK_MIN_PROTOCOL", "obligatoria")

		env = deployed(e)
		delete(env, "ELDMARK_MAIL")
		mustFail(t, env, "ELDMARK_MAIL", "SMTP")

		env = deployed(e)
		delete(env, "ELDMARK_SMTP_URL")
		mustFail(t, env, "ELDMARK_SMTP_URL")

		env = deployed(e)
		delete(env, "ELDMARK_EMAIL_HMAC_KEY")
		mustFail(t, env, "ELDMARK_EMAIL_HMAC_KEY")

		env = deployed(e)
		env["ELDMARK_EMAIL_HMAC_KEY"] = base64.StdEncoding.EncodeToString(TestEmailHMACKey)
		mustFail(t, env, "clave fija de pruebas")
	}
}

func TestTestEnvironmentDefaults(t *testing.T) {
	env := minimal()
	env["ELDMARK_ENV"] = "test"
	c := mustLoad(t, env)
	if c.Argon2 != (Argon2{MemoryKiB: 8, Time: 1, Threads: 1}) || c.RequireVerifiedEmail {
		t.Errorf("en test, argon2 barato y sin exigir el correo: %+v", c)
	}
	env["ELDMARK_ENV"] = "pruebas"
	mustFail(t, env, "ELDMARK_ENV")
}

func TestSecretsFromFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	env := map[string]string{
		"ELDMARK_DATABASE_URL_FILE": write("db", dbURL+"\n"),
		"ELDMARK_ZONE_TOKENS_FILE":  write("zones", zoneEntry("1:vado_gris:0", "a")+",\n"+zoneEntry("1:vado_gris:0", "b")+"\n"),
		"ELDMARK_TICKET_KEYS_FILE":  write("keys", "1:"+goodKey+"\n"),
	}
	c := mustLoad(t, env)
	if c.DatabaseURL != dbURL || len(c.ZoneTokens) != 2 || len(c.TicketKeys) != 1 {
		t.Errorf("leídos de archivos: %d tokens, %d claves", len(c.ZoneTokens), len(c.TicketKeys))
	}
	env["ELDMARK_DATABASE_URL"] = dbURL
	mustFail(t, env, "a la vez")
	delete(env, "ELDMARK_DATABASE_URL")
	env["ELDMARK_DATABASE_URL_FILE"] = filepath.Join(dir, "no-existe")
	mustFail(t, env, "ELDMARK_DATABASE_URL_FILE", "no existe")
	env["ELDMARK_DATABASE_URL_FILE"] = write("vacio", "\n")
	mustFail(t, env, "está vacío")

	d, err := LoadDatabase(lookupOf(map[string]string{"ELDMARK_DATABASE_URL_FILE": write("db2", dbURL)}))
	if err != nil || d.DatabaseURL != dbURL || d.Env != EnvDev {
		t.Errorf("LoadDatabase: %v %v", d, err)
	}
	if _, err := LoadDatabase(lookupOf(map[string]string{})); err == nil {
		t.Error("migrate tampoco arranca sin base de datos")
	}
}

func TestMalformedValues(t *testing.T) {
	cases := map[string]string{
		"ELDMARK_DATABASE_URL":           "postgres://eldmark:muy-secreta@host:puerto/x",
		"ELDMARK_PUBLIC_ADDR":            "sin-puerto",
		"ELDMARK_INTERNAL_ADDR":          "127.0.0.1:99999",
		"ELDMARK_PUBLIC_URL":             "ftp://eldmark.example",
		"ELDMARK_ZONE_HOSTS":             "203.0.113.5, mal host",
		"ELDMARK_TRUSTED_PROXIES":        "172.18.0.5",
		"ELDMARK_ARGON2":                 "m=4,t=1,p=1",
		"ELDMARK_MIN_PROTOCOL":           "siete",
		"ELDMARK_OPEN_REALMS":            "vardheim,eldrun",
		"ELDMARK_ENTRY_ZONES":            "vardheim=Vado Gris",
		"ELDMARK_REQUIRE_VERIFIED_EMAIL": "quizá",
		"ELDMARK_MAIL":                   "palomas",
		"ELDMARK_TLS_CERT_FILE":          "/no/existe.pem",
		"ELDMARK_HEARTBEAT_S":            "0",
		"ELDMARK_LEASE_TTL_S":            "5",
		"ELDMARK_EMAIL_HMAC_KEY":         base64.StdEncoding.EncodeToString([]byte("corta")),
	}
	for name, value := range cases {
		env := minimal()
		env[name] = value
		mustFail(t, env, name)
	}
	// Mismo puerto para las dos API.
	env := minimal()
	env["ELDMARK_INTERNAL_ADDR"] = "127.0.0.1:24680"
	mustFail(t, env, "misma dirección")
	// Un reino abierto sin zona de entrada.
	env = minimal()
	env["ELDMARK_OPEN_REALMS"] = "vardheim,solmarch,askarra"
	mustFail(t, env, "askarra no tiene zona de entrada")
	env["ELDMARK_ENTRY_ZONES"] = "vardheim=vado_gris,solmarch=vado_gris,askarra=test_world"
	if c := mustLoad(t, env); c.EntryZones[RealmAskarra] != "test_world" {
		t.Errorf("zona de entrada de Askarra: %v", c.EntryZones)
	}
}

func TestZoneTokens(t *testing.T) {
	env := minimal()
	env["ELDMARK_ZONE_TOKENS"] = zoneEntry("1:vado_gris:0", "a") + "," + zoneEntry("1:test_world:3", "b")
	c := mustLoad(t, env)
	if len(c.ZoneTokens) != 2 || c.ZoneTokens[1].ZoneID != "test_world" || c.ZoneTokens[1].Channel != 3 {
		t.Errorf("dos alcances: %+v", c.ZoneTokens)
	}
	for _, bad := range []string{
		"1:vado_gris:0",                   // sin hash
		zoneEntry("0:vado_gris:0", "a"),   // mundo 0
		zoneEntry("1:Vado:0", "a"),        // zona con mayúsculas
		zoneEntry("1:vado_gris:256", "a"), // canal fuera de u8
		"1:vado_gris:0:abcd",              // hash corto
		zoneEntry("1:vado_gris:0", "a") + "," + zoneEntry("1:test_world:0", "a"), // un token, dos alcances
	} {
		env["ELDMARK_ZONE_TOKENS"] = bad
		mustFail(t, env, "ELDMARK_ZONE_TOKENS")
	}
}

func TestLogValueHasNoSecrets(t *testing.T) {
	c := mustLoad(t, minimal())
	var buf bytes.Buffer
	slog.New(slog.NewJSONHandler(&buf, nil)).Info("configuración", "config", c)
	out := buf.String()
	for _, secret := range []string{"muy-secreta", goodKey, hex.EncodeToString(c.ZoneTokens[0].Hash[:])} {
		if strings.Contains(out, secret) {
			t.Errorf("el registro de la configuración lleva un secreto: %s", out)
		}
	}
	if !strings.Contains(out, `"env":"dev"`) {
		t.Errorf("el registro resume la configuración: %s", out)
	}
}

func TestRealmNames(t *testing.T) {
	for _, r := range []Realm{RealmVardheim, RealmSolmarch, RealmAskarra} {
		back, ok := ParseRealm(r.String())
		if !ok || back != r {
			t.Errorf("ida y vuelta de %d", r)
		}
	}
	if _, ok := ParseRealm("Vardheim"); ok {
		t.Error("los ids de texto van en minúsculas")
	}
}

func TestMailFromAndLegalDir(t *testing.T) {
	env := minimal()
	env["ELDMARK_PUBLIC_URL"] = "https://eldmark.example"
	if c := mustLoad(t, env); c.MailFrom != "no-reply@eldmark.example" {
		t.Errorf("remitente por defecto: %q", c.MailFrom)
	}
	env["ELDMARK_MAIL_FROM"] = "cuentas@eldmark.example"
	if c := mustLoad(t, env); c.MailFrom != "cuentas@eldmark.example" {
		t.Errorf("remitente: %q", c.MailFrom)
	}
	for _, bad := range []string{"Eldmark <a@b.example>", "a@b.example\r\nBcc: c@d.example", "sin-arroba"} {
		env["ELDMARK_MAIL_FROM"] = bad
		mustFail(t, env, "ELDMARK_MAIL_FROM")
	}
	env = minimal()
	env["ELDMARK_LEGAL_DIR"] = t.TempDir()
	if c := mustLoad(t, env); c.LegalDir != env["ELDMARK_LEGAL_DIR"] {
		t.Errorf("carpeta legal: %q", c.LegalDir)
	}
	env["ELDMARK_LEGAL_DIR"] = filepath.Join(t.TempDir(), "no-existe")
	mustFail(t, env, "ELDMARK_LEGAL_DIR")
}
