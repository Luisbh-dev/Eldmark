package accounts_test

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"eldmark/platform/internal/passwords"
)

// Contraseña buena, mala y correo inexistente: los dos fallos dan el mismo código y el mismo cuerpo
// (plataforma.md §15 P1).
func TestLoginDoesNotRevealAccounts(t *testing.T) {
	h := newHarness(t)
	h.register("aneira@example.org")
	ok := h.loginFrom("Aneira@Example.org ", password, h.nextIP())
	if ok.status != 200 || ok.str("scope") != "game" || ok.body["restriction"] != nil ||
		len(ok.str("access_token")) != 43 || len(ok.str("refresh_token")) != 43 {
		t.Fatalf("contraseña buena (correo normalizado): %d %s", ok.status, ok.raw)
	}
	if ok.body["access_expires_in"] != 900.0 || ok.body["refresh_expires_in"] != 43200.0 {
		t.Fatalf("plazos: %v %v", ok.body["access_expires_in"], ok.body["refresh_expires_in"])
	}
	account := ok.body["account"].(map[string]any)
	if account["email"] != "aneira@example.org" || account["role"] != "player" || account["email_verified"] != false ||
		account["account_id"] != fmt.Sprint(h.accountID("aneira@example.org")) {
		t.Fatalf("cuenta: %v", account)
	}
	bad := h.loginFrom("aneira@example.org", "otra contraseña", h.nextIP())
	unknown := h.loginFrom("nadie@example.org", "otra contraseña", h.nextIP())
	h.expect(bad, 401, "invalid_credentials")
	if bad.raw != unknown.raw || bad.status != unknown.status {
		t.Fatalf("mala y desconocido, distinto:\n%s\n%s", bad.raw, unknown.raw)
	}
	var kinds string
	h.scalar(&kinds, `select string_agg(kind, ',' order by id) from auth_events where kind like 'login%'`)
	if kinds != "login_ok,login_fail,login_fail" {
		t.Fatalf("auth_events: %s", kinds)
	}
	// Ni contraseñas ni tokens en el registro.
	for _, secret := range []string{password, "otra contraseña", ok.str("access_token"), ok.str("refresh_token")} {
		if strings.Contains(h.logs.String(), secret) {
			t.Fatalf("el registro lleva un secreto: %q", secret)
		}
	}
}

// 5 fallos desde la IP B → 429 en B; el dueño entra desde A (tras el freno de 30 s de la cuenta);
// al 5.º fallo, un correo login_failures.
func TestFailuresLockTheGroupNotTheOwner(t *testing.T) {
	h := newHarness(t)
	h.register("dueno@example.org")
	ipA, ipB := h.nextIP(), h.nextIP()
	for i := 1; i <= 5; i++ {
		h.expect(h.loginFrom("dueno@example.org", "contraseña mala", ipB), 401, "invalid_credentials")
	}
	if h.mailCount("dueno@example.org", "login_failures") != 1 {
		t.Fatal("al 5.º fallo, un aviso al dueño")
	}
	res := h.loginFrom("dueno@example.org", password, ipB)
	h.expect(res, 429, "rate_limited")
	if res.header.Get("Retry-After") == "" || res.body["error"].(map[string]any)["retry_after_s"].(float64) < 1 {
		t.Fatalf("429 con espera: %s", res.raw)
	}
	// La cuenta, desde cualquier IP: un intento cada 30 s.
	h.expect(h.loginFrom("dueno@example.org", password, ipA), 429, "rate_limited")
	h.clock.Advance(31 * time.Second)
	h.expect(h.loginFrom("dueno@example.org", password, ipB), 429, "rate_limited") // B, 15 min
	if res := h.loginFrom("dueno@example.org", password, ipA); res.status != 200 {
		t.Fatalf("el dueño entra desde A: %d %s", res.status, res.raw)
	}
	// Acertar reinicia las dos: B ya puede.
	if res := h.loginFrom("dueno@example.org", password, ipB); res.status != 200 {
		t.Fatalf("tras acertar, B: %d %s", res.status, res.raw)
	}
	if h.mailCount("dueno@example.org", "login_failures") != 1 {
		t.Fatal("un solo aviso")
	}
}

// 10 fallos seguidos desde un grupo: 1 h sin intentos desde él.
func TestTenFailuresLockForAnHour(t *testing.T) {
	h := newHarness(t)
	h.register("diez@example.org")
	ip := h.nextIP()
	for i := 1; i <= 10; i++ {
		res := h.loginFrom("diez@example.org", "contraseña mala", ip)
		if i <= 5 {
			h.expect(res, 401, "invalid_credentials")
		} else {
			h.expect(res, 429, "rate_limited")
			h.clock.Advance(16 * time.Minute) // pasa el bloqueo de 15 min y vuelve a fallar
			h.expect(h.loginFrom("diez@example.org", "contraseña mala", ip), 401, "invalid_credentials")
		}
	}
	h.clock.Advance(16 * time.Minute)
	res := h.loginFrom("diez@example.org", password, ip)
	h.expect(res, 429, "rate_limited")
	if wait := res.body["error"].(map[string]any)["retry_after_s"].(float64); wait < 2000 {
		t.Fatalf("tras 10 fallos, cerca de una hora: %v", wait)
	}
}

// 5 fallos con el correo inexistente A desde X; después el inexistente B y el existente C desde X
// reciben lo mismo (invalid_credentials, no 429): cada correo tiene su contador.
func TestUnknownEmailsHaveTheirOwnCounters(t *testing.T) {
	h := newHarness(t)
	h.register("c@example.org")
	x := h.nextIP()
	for i := 0; i < 5; i++ {
		h.expect(h.loginFrom("a@example.org", "contraseña mala", x), 401, "invalid_credentials")
	}
	h.expect(h.loginFrom("a@example.org", "contraseña mala", x), 429, "rate_limited")
	b := h.loginFrom("b@example.org", "contraseña mala", x)
	c := h.loginFrom("c@example.org", "contraseña mala", x)
	h.expect(b, 401, "invalid_credentials")
	if b.raw != c.raw {
		t.Fatalf("B y C, distinto:\n%s\n%s", b.raw, c.raw)
	}
}

// burst lanza n inicios de sesión a la vez con la contraseña mala (cada uno desde ip()) y cuenta
// las respuestas por estado.
func (h *harness) burst(email string, n int, ip func() string) map[int]int {
	h.t.Helper()
	codes := make([]int, n)
	var wg sync.WaitGroup
	for i := range n {
		addr := ip()
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes[i] = h.loginFrom(email, "contraseña mala", addr).status
		}()
	}
	wg.Wait()
	got := map[int]int{}
	for _, c := range codes {
		got[c]++
	}
	return got
}

// Intentos a la vez no se saltan el freno (§4.2): comprobar el freno, mirar la contraseña y anotar el
// fallo van en una sola sección por cuenta. Tras 5 fallos y los 30 s, 30 intentos simultáneos desde
// 30 IP miran la contraseña una sola vez; con una cuenta nueva, 10 a la vez desde un grupo, cinco.
func TestConcurrentAttemptsRespectTheThrottle(t *testing.T) {
	h := newHarness(t)
	h.register("rafaga@example.org")
	for i := 0; i < 5; i++ {
		h.expect(h.loginFrom("rafaga@example.org", "contraseña mala", h.nextIP()), 401, "invalid_credentials")
	}
	h.clock.Advance(31 * time.Second)
	if got := h.burst("rafaga@example.org", 30, h.nextIP); got[401] != 1 || got[429] != 29 {
		t.Fatalf("freno de la cuenta con 30 a la vez: %v", got)
	}
	h.register("grupo@example.org")
	ip := h.nextIP()
	if got := h.burst("grupo@example.org", 10, func() string { return ip }); got[401] != 5 || got[429] != 5 {
		t.Fatalf("bloqueo del grupo con 10 a la vez: %v", got)
	}
	// Un correo sin cuenta tiene el mismo freno.
	if got := h.burst("nadie@example.org", 10, func() string { return h.nextIP() }); got[401] != 5 || got[429] != 5 {
		t.Fatalf("correo sin cuenta: %v", got)
	}
}

// Los fallos por /v1/account/password cuentan igual que los del inicio de sesión (el sexto → 429).
func TestSessionRoutesSharePasswordCounters(t *testing.T) {
	h := newHarness(t)
	h.register("cambia@example.org")
	s := h.login("cambia@example.org", password)
	ip := h.nextIP()
	body := map[string]any{"current_password": "contraseña mala", "new_password": "otra contraseña nueva"}
	for i := 0; i < 5; i++ {
		h.expect(h.do(call{method: "POST", path: "/v1/account/password", body: body, token: s.access, ip: ip}), 401,
			"invalid_credentials")
	}
	h.expect(h.do(call{method: "POST", path: "/v1/account/password", body: body, token: s.access, ip: ip}), 429, "rate_limited")
	h.expect(h.loginFrom("cambia@example.org", password, ip), 429, "rate_limited")
	var n int
	h.scalar(&n, `select count(*) from auth_events where kind = 'password_fail'`)
	if n != 5 {
		t.Fatalf("password_fail: %d", n)
	}
}

// 11 inicios de sesión desde una IP en un minuto → 429 (10/min, ráfaga 10).
func TestLoginRateLimitPerIP(t *testing.T) {
	h := newHarness(t)
	ip := h.nextIP()
	for i := 0; i < 10; i++ {
		h.expect(h.loginFrom(fmt.Sprintf("n%d@example.org", i), "contraseña mala", ip), 401, "invalid_credentials")
	}
	h.expect(h.loginFrom("n10@example.org", "contraseña mala", ip), 429, "rate_limited")
	h.clock.Advance(6 * time.Second)
	h.expect(h.loginFrom("n11@example.org", "contraseña mala", ip), 401, "invalid_credentials")
}

// X-Forwarded-For y un X-Real-IP desde un origen no fiable no cambian la IP del límite.
func TestSpoofedHeadersDoNotChangeTheIP(t *testing.T) {
	h := newHarness(t)
	for i := 0; i < 10; i++ {
		res := h.do(call{method: "POST", path: "/v1/sessions", remote: "203.0.113.50:1234",
			body:    map[string]any{"email": fmt.Sprintf("x%d@example.org", i), "password": "mala"},
			headers: map[string]string{"X-Real-IP": fmt.Sprintf("192.0.2.%d", i+1), "X-Forwarded-For": fmt.Sprintf("192.0.2.%d", 100+i)}})
		h.expect(res, 401, "invalid_credentials")
	}
	res := h.do(call{method: "POST", path: "/v1/sessions", remote: "203.0.113.50:1234",
		body:    map[string]any{"email": "y@example.org", "password": "mala"},
		headers: map[string]string{"X-Real-IP": "192.0.2.200", "X-Forwarded-For": "192.0.2.201"}})
	h.expect(res, 429, "rate_limited")
	// Desde el proxy de confianza, X-Real-IP sí manda: otra IP, otro cubo.
	h.expect(h.do(call{method: "POST", path: "/v1/sessions", ip: "203.0.113.50",
		body: map[string]any{"email": "z@example.org", "password": "mala"}}), 429, "rate_limited")
	h.expect(h.do(call{method: "POST", path: "/v1/sessions", ip: "192.0.2.200",
		body: map[string]any{"email": "z@example.org", "password": "mala"}}), 401, "invalid_credentials")
}

// Acceso caducado → 401 y refresco; el acceso viejo deja de valer.
func TestExpiredAccessAndRefresh(t *testing.T) {
	h := newHarness(t)
	h.register("refresco@example.org")
	s := h.login("refresco@example.org", password)
	if res := h.do(call{method: "GET", path: "/v1/account", token: s.access}); res.status != 200 {
		t.Fatalf("con acceso: %d", res.status)
	}
	h.clock.Advance(16 * time.Minute)
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: s.access}), 401, "unauthorized")
	res := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": s.refresh}})
	if res.status != 200 || res.str("scope") != "game" || res.str("access_token") == s.access {
		t.Fatalf("refresco: %d %s", res.status, res.raw)
	}
	if res := h.do(call{method: "GET", path: "/v1/account", token: res.str("access_token")}); res.status != 200 {
		t.Fatalf("acceso nuevo: %d", res.status)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: s.access}), 401, "unauthorized")
	h.expect(h.do(call{method: "GET", path: "/v1/account"}), 401, "unauthorized")
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: "x"}), 401, "unauthorized")
}

// Reutilizar el refresco anterior revoca la sesión (refresh_reuse).
func TestRefreshReuseRevokesTheSession(t *testing.T) {
	h := newHarness(t)
	h.register("robo@example.org")
	s := h.login("robo@example.org", password)
	r1 := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": s.refresh}})
	if r1.status != 200 {
		t.Fatal(r1.raw)
	}
	h.expect(h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": s.refresh}}),
		401, "unauthorized")
	var reason string
	h.scalar(&reason, `select revoke_reason from sessions`)
	if reason != "refresh_reuse" {
		t.Fatalf("revocada por reutilización: %q", reason)
	}
	h.expect(h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": r1.str("refresh_token")}}),
		401, "unauthorized")
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: r1.str("access_token")}), 401, "unauthorized")
	var n int
	h.scalar(&n, `select count(*) from auth_events where kind = 'refresh_reuse'`)
	if n != 1 {
		t.Fatalf("auth_events refresh_reuse: %d", n)
	}
}

// Un refresco de hace dos rotaciones da 401 sin revocar.
func TestRefreshFromTwoRotationsAgo(t *testing.T) {
	h := newHarness(t)
	h.register("dos@example.org")
	s := h.login("dos@example.org", password)
	r1 := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": s.refresh}})
	r2 := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": r1.str("refresh_token")}})
	if r1.status != 200 || r2.status != 200 {
		t.Fatal(r1.raw, r2.raw)
	}
	h.expect(h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": s.refresh}}),
		401, "unauthorized")
	r3 := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": r2.str("refresh_token")}})
	if r3.status != 200 {
		t.Fatalf("la sesión sigue viva: %d %s", r3.status, r3.raw)
	}
	var revoked bool
	h.scalar(&revoked, `select revoked_at is not null from sessions`)
	if revoked {
		t.Fatal("no se revoca")
	}
}

// Las 12 h no se alargan al rotar.
func TestRotationDoesNotExtendTheSession(t *testing.T) {
	h := newHarness(t)
	h.register("doce@example.org")
	s := h.login("doce@example.org", password)
	refresh := s.refresh
	var last *response
	for elapsed := 14 * time.Minute; elapsed < 12*time.Hour; elapsed += 14 * time.Minute {
		h.clock.Advance(14 * time.Minute)
		last = h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": refresh}})
		if last.status != 200 {
			t.Fatalf("a las %s: %d %s", elapsed, last.status, last.raw)
		}
		refresh = last.str("refresh_token")
		remaining := (12*time.Hour - elapsed).Seconds()
		if got := last.body["refresh_expires_in"].(float64); got != remaining {
			t.Fatalf("a las %s quedan %v s, no %v", elapsed, got, remaining)
		}
		if got := last.body["access_expires_in"].(float64); got > remaining || got > 900 {
			t.Fatalf("el acceso no pasa del fin de la sesión: %v", got)
		}
	}
	h.clock.Advance(14 * time.Minute)
	h.expect(h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": refresh}}),
		401, "unauthorized")
}

// Una segunda sesión revoca la primera (replaced).
func TestSecondLoginRevokesTheFirst(t *testing.T) {
	h := newHarness(t)
	h.register("una@example.org")
	first := h.login("una@example.org", password)
	second := h.login("una@example.org", password)
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: first.access}), 401, "unauthorized")
	if res := h.do(call{method: "GET", path: "/v1/account", token: second.access}); res.status != 200 {
		t.Fatal(res.raw)
	}
	var reason string
	h.scalar(&reason, `select revoke_reason from sessions where revoked_at is not null`)
	if reason != "replaced" {
		t.Fatal(reason)
	}
	// Cerrar sesión: 204 y el acceso deja de valer.
	if res := h.do(call{method: "DELETE", path: "/v1/sessions/current", token: second.access}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: second.access}), 401, "unauthorized")
}

// Suspendida con contraseña mala → invalid_credentials; con buena → sesión privacy con el motivo.
// Con la de una expulsada valen la cuenta, la exportación, la supresión, el refresco y cerrar
// sesión; las demás (también enter) dan 403 account_banned.
func TestPrivacySessionForSanctionedAccounts(t *testing.T) {
	h := newHarness(t)
	suspended := h.register("suspendida@example.org")
	banned := h.register("expulsada@example.org")
	now := h.clock.Now()
	until := now.Add(72 * time.Hour)
	h.exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', 'spam', $2, $3)`,
		suspended, now.Add(-time.Hour), until)
	h.exec(`insert into sanctions (account_id, kind, reason, starts_at) values ($1, 'ban', 'trampas', $2)`, banned, now.Add(-time.Hour))

	h.expect(h.loginFrom("suspendida@example.org", "contraseña mala", h.nextIP()), 401, "invalid_credentials")
	s := h.login("suspendida@example.org", password)
	restriction, _ := s.res.body["restriction"].(map[string]any)
	if s.res.str("scope") != "privacy" || restriction["code"] != "account_suspended" || restriction["reason"] != "spam" ||
		restriction["until"] != float64(until.Unix()) {
		t.Fatalf("suspendida: %s", s.res.raw)
	}
	var scope string
	h.scalar(&scope, `select scope from sessions where account_id = $1`, suspended)
	if scope != "privacy" {
		t.Fatal(scope)
	}

	b := h.login("expulsada@example.org", password)
	if b.res.str("scope") != "privacy" || b.res.body["restriction"].(map[string]any)["code"] != "account_banned" {
		t.Fatalf("expulsada: %s", b.res.raw)
	}
	for _, c := range []call{
		{method: "POST", path: "/v1/characters/42/enter"},
		{method: "PUT", path: "/v1/account/consents", body: map[string]any{"crash_reports": true, "analytics": true}},
		{method: "POST", path: "/v1/account/verify-email/resend"},
		{method: "POST", path: "/v1/account/accept", body: map[string]any{"terms": 1, "privacy": 1, "rules": 1}},
		{method: "POST", path: "/v1/account/email", body: map[string]any{"new_email": "x@example.org", "password": password}},
	} {
		c.token = b.access
		res := h.do(c)
		h.expect(res, 403, "account_banned")
		e := res.body["error"].(map[string]any)
		if e["reason"] != "trampas" || e["until"] != nil || !strings.Contains(e["message"].(string), "expulsada") {
			t.Fatalf("%s %s: %s", c.method, c.path, res.raw)
		}
	}
	if res := h.do(call{method: "GET", path: "/v1/account", token: b.access}); res.status != 200 ||
		res.body["restriction"].(map[string]any)["code"] != "account_banned" {
		t.Fatalf("la cuenta, con la sesión de privacidad: %s", res.raw)
	}
	r := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": b.refresh}})
	if r.status != 200 || r.str("scope") != "privacy" {
		t.Fatalf("el refresco conserva el ámbito: %s", r.raw)
	}
	access := r.str("access_token")
	if res := h.do(call{method: "POST", path: "/v1/account/export", token: access, body: map[string]any{"password": password}}); res.status != 200 {
		t.Fatalf("exportar con la sesión de privacidad: %d %s", res.status, res.raw)
	}
	if res := h.do(call{method: "POST", path: "/v1/account/deletion", token: access, body: map[string]any{"password": password}}); res.status != 202 {
		t.Fatalf("supresión: %d %s", res.status, res.raw)
	}
	if res := h.do(call{method: "DELETE", path: "/v1/sessions/current", token: access}); res.status != 204 {
		t.Fatalf("cerrar sesión: %d %s", res.status, res.raw)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: access}), 401, "unauthorized")

	// Una sesión de juego de una cuenta que se suspende después: 403 en las rutas de juego.
	h.register("luego@example.org")
	g := h.login("luego@example.org", password)
	h.exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', 'acoso', $2, $3)`,
		h.accountID("luego@example.org"), now, until)
	res := h.do(call{method: "POST", path: "/v1/characters/1/enter", token: g.access})
	h.expect(res, 403, "account_suspended")
	if !strings.Contains(res.body["error"].(map[string]any)["message"].(string), "suspendida hasta el") {
		t.Fatal(res.raw)
	}
	// Si la sanción termina, la sesión de privacidad ya no sirve: hay que volver a entrar.
	h.exec(`update sanctions set revoked_at = $2 where account_id = $1`, suspended, now)
	h.expect(h.do(call{method: "POST", path: "/v1/characters/1/enter", token: s.access}), 401, "unauthorized")
	if g2 := h.login("suspendida@example.org", password); g2.res.str("scope") != "game" {
		t.Fatalf("sin sanción, sesión de juego: %s", g2.res.raw)
	}
}

// needsRehash: con otros parámetros, el inicio de sesión reescribe la cadena.
func TestLoginRehashes(t *testing.T) {
	h := newHarness(t)
	id := h.register("rehash@example.org")
	cfg := testConfig()
	cfg.Argon2.MemoryKiB = 16
	h.build(nil, cfg)
	h.login("rehash@example.org", password)
	var phc string
	h.scalar(&phc, `select password_hash from accounts where account_id = $1`, id)
	p, err := passwords.ParamsOf(phc)
	if err != nil || p.MemoryKiB != 16 {
		t.Fatalf("reescrita con m=16: %s %v", phc, err)
	}
	h.login("rehash@example.org", password)
}

// Sin X-Eldmark-Protocol o por debajo del mínimo, 426 (§4.1); /v1/status con la carga de cada mundo.
func TestStatusAndProtocol(t *testing.T) {
	h := newHarness(t)
	res := h.do(call{method: "GET", path: "/v1/status", noProtocol: true})
	h.expect(res, 426, "client_outdated")
	if res.body["error"].(map[string]any)["min_protocol"] != 7.0 {
		t.Fatal(res.raw)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/status", headers: map[string]string{"X-Eldmark-Protocol": "6"}}), 426, "client_outdated")
	h.exec(`insert into zone_instances (zone_instance_id, world_id, zone_id, public_host, public_port, realms, build_id,
		protocol_version, record_format, max_players, players, status) values
		(gen_random_uuid(), 1, 'vado_gris', '127.0.0.1', 24600, '{1,2}', 'b', 7, 1, 100, 60, 'live')`)
	res = h.do(call{method: "GET", path: "/v1/status"})
	worlds := res.body["worlds"].([]any)
	w := worlds[0].(map[string]any)
	if res.status != 200 || res.str("status") != "ok" || res.body["min_protocol"] != 7.0 || len(worlds) != 1 ||
		w["name"] != "Eld" || w["load"] != "medium" || w["world_id"] != 1.0 {
		t.Fatalf("estado: %s", res.raw)
	}
	h.exec(`update worlds set status = 'maintenance'`)
	if res := h.do(call{method: "GET", path: "/v1/status"}); res.str("status") != "maintenance" {
		t.Fatal(res.raw)
	}
}

func TestLegalEndpoints(t *testing.T) {
	h := newHarness(t)
	res := h.do(call{method: "GET", path: "/v1/legal"})
	terms := res.body["terms"].(map[string]any)
	if res.status != 200 || terms["version"] != 1.0 || len(terms["sha256"].(string)) != 64 || res.body["rules"] == nil {
		t.Fatal(res.raw)
	}
	text := h.do(call{method: "GET", path: "/v1/legal/privacy"})
	if text.status != 200 || !strings.HasPrefix(text.header.Get("Content-Type"), "text/markdown") ||
		!strings.Contains(text.raw, "Borrador pendiente de revisión legal") {
		t.Fatalf("texto: %d %s", text.status, text.header)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/legal/otro"}), 404, "not_found")
}

// Con el reloj parado, el freno de la cuenta sigue en pie sin intentos: CheckPassword directo.
func TestCheckPasswordDirect(t *testing.T) {
	h := newHarness(t)
	id := h.register("directa@example.org")
	ctx := context.Background()
	ip := h.nextIPAddr()
	ok, err := h.svc.CheckPassword(ctx, id, "directa@example.org", password, ip)
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	ok, err = h.svc.CheckPassword(ctx, 0, "nadie@example.org", password, ip)
	if err != nil || ok {
		t.Fatal("sin cuenta nunca vale", ok, err)
	}
	h.exec(`update accounts set password_hash = 'roto' where account_id = $1`, id)
	if ok, err := h.svc.CheckPassword(ctx, id, "directa@example.org", password, ip); ok || err != nil {
		t.Fatal("una cadena rota cuenta como fallo", ok, err)
	}
	if !strings.Contains(h.logs.String(), "hash de contraseña no válido") {
		t.Fatal("y se registra")
	}
}
