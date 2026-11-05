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

// Good password, bad password and nonexistent email: the two failures give the same code and the
// same body (platform.md §15 P1).
func TestLoginDoesNotRevealAccounts(t *testing.T) {
	h := newHarness(t)
	h.register("aneira@example.org")
	ok := h.loginFrom("Aneira@Example.org ", password, h.nextIP())
	if ok.status != 200 || ok.str("scope") != "game" || ok.body["restriction"] != nil ||
		len(ok.str("access_token")) != 43 || len(ok.str("refresh_token")) != 43 {
		t.Fatalf("good password (normalized email): %d %s", ok.status, ok.raw)
	}
	if ok.body["access_expires_in"] != 900.0 || ok.body["refresh_expires_in"] != 43200.0 {
		t.Fatalf("lifetimes: %v %v", ok.body["access_expires_in"], ok.body["refresh_expires_in"])
	}
	account := ok.body["account"].(map[string]any)
	if account["email"] != "aneira@example.org" || account["role"] != "player" || account["email_verified"] != false ||
		account["account_id"] != fmt.Sprint(h.accountID("aneira@example.org")) {
		t.Fatalf("account: %v", account)
	}
	bad := h.loginFrom("aneira@example.org", "otra contraseña", h.nextIP())
	unknown := h.loginFrom("nadie@example.org", "otra contraseña", h.nextIP())
	h.expect(bad, 401, "invalid_credentials")
	if bad.raw != unknown.raw || bad.status != unknown.status {
		t.Fatalf("wrong and unknown, different:\n%s\n%s", bad.raw, unknown.raw)
	}
	var kinds string
	h.scalar(&kinds, `select string_agg(kind, ',' order by id) from auth_events where kind like 'login%'`)
	if kinds != "login_ok,login_fail,login_fail" {
		t.Fatalf("auth_events: %s", kinds)
	}
	// No passwords or tokens in the log.
	for _, secret := range []string{password, "otra contraseña", ok.str("access_token"), ok.str("refresh_token")} {
		if strings.Contains(h.logs.String(), secret) {
			t.Fatalf("the log carries a secret: %q", secret)
		}
	}
}

// 5 failures from IP B -> 429 on B; the owner gets in from A (after the account's 30 s brake); on
// the 5th failure, a login_failures email.
func TestFailuresLockTheGroupNotTheOwner(t *testing.T) {
	h := newHarness(t)
	h.register("dueno@example.org")
	ipA, ipB := h.nextIP(), h.nextIP()
	for i := 1; i <= 5; i++ {
		h.expect(h.loginFrom("dueno@example.org", "contraseña mala", ipB), 401, "invalid_credentials")
	}
	if h.mailCount("dueno@example.org", "login_failures") != 1 {
		t.Fatal("on the 5th failure, a notice to the owner")
	}
	res := h.loginFrom("dueno@example.org", password, ipB)
	h.expect(res, 429, "rate_limited")
	if res.header.Get("Retry-After") == "" || res.body["error"].(map[string]any)["retry_after_s"].(float64) < 1 {
		t.Fatalf("429 with a wait: %s", res.raw)
	}
	// The account, from any IP: one attempt every 30 s.
	h.expect(h.loginFrom("dueno@example.org", password, ipA), 429, "rate_limited")
	h.clock.Advance(31 * time.Second)
	h.expect(h.loginFrom("dueno@example.org", password, ipB), 429, "rate_limited") // B, 15 min
	if res := h.loginFrom("dueno@example.org", password, ipA); res.status != 200 {
		t.Fatalf("the owner logs in from A: %d %s", res.status, res.raw)
	}
	// A success resets both: B can already try.
	if res := h.loginFrom("dueno@example.org", password, ipB); res.status != 200 {
		t.Fatalf("after succeeding, B: %d %s", res.status, res.raw)
	}
	if h.mailCount("dueno@example.org", "login_failures") != 1 {
		t.Fatal("a single notice")
	}
}

// 10 consecutive failures from a group: 1 h without attempts from it.
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
			h.clock.Advance(16 * time.Minute) // the 15 min block passes and it fails again
			h.expect(h.loginFrom("diez@example.org", "contraseña mala", ip), 401, "invalid_credentials")
		}
	}
	h.clock.Advance(16 * time.Minute)
	res := h.loginFrom("diez@example.org", password, ip)
	h.expect(res, 429, "rate_limited")
	if wait := res.body["error"].(map[string]any)["retry_after_s"].(float64); wait < 2000 {
		t.Fatalf("after 10 failures, about an hour: %v", wait)
	}
}

// 5 failures with nonexistent email A from X; afterwards nonexistent B and existing C from X get the
// same (invalid_credentials, not 429): each email has its own counter.
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
		t.Fatalf("B and C, different:\n%s\n%s", b.raw, c.raw)
	}
}

// burst launches n logins at once with the bad password (each from ip()) and counts the responses by
// status.
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

// Simultaneous attempts do not skip the brake (§4.2): checking the brake, looking at the password
// and recording the failure all go in a single section per account. After 5 failures and the 30 s,
// 30 simultaneous attempts from 30 IPs look at the password only once; with a new account, 10 at
// once from one group, five.
func TestConcurrentAttemptsRespectTheThrottle(t *testing.T) {
	h := newHarness(t)
	h.register("rafaga@example.org")
	for i := 0; i < 5; i++ {
		h.expect(h.loginFrom("rafaga@example.org", "contraseña mala", h.nextIP()), 401, "invalid_credentials")
	}
	h.clock.Advance(31 * time.Second)
	if got := h.burst("rafaga@example.org", 30, h.nextIP); got[401] != 1 || got[429] != 29 {
		t.Fatalf("account brake with 30 at once: %v", got)
	}
	h.register("grupo@example.org")
	ip := h.nextIP()
	if got := h.burst("grupo@example.org", 10, func() string { return ip }); got[401] != 5 || got[429] != 5 {
		t.Fatalf("group lockout with 10 at once: %v", got)
	}
	// An email without an account has the same brake.
	if got := h.burst("nadie@example.org", 10, func() string { return h.nextIP() }); got[401] != 5 || got[429] != 5 {
		t.Fatalf("email without an account: %v", got)
	}
}

// Failures through /v1/account/password count the same as those of login (the sixth -> 429).
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

// 11 logins from one IP in a minute -> 429 (10/min, burst 10).
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

// X-Forwarded-For and an X-Real-IP from an untrusted origin do not change the limit's IP.
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
	// From the trusted proxy, X-Real-IP does rule: another IP, another bucket.
	h.expect(h.do(call{method: "POST", path: "/v1/sessions", ip: "203.0.113.50",
		body: map[string]any{"email": "z@example.org", "password": "mala"}}), 429, "rate_limited")
	h.expect(h.do(call{method: "POST", path: "/v1/sessions", ip: "192.0.2.200",
		body: map[string]any{"email": "z@example.org", "password": "mala"}}), 401, "invalid_credentials")
}

// Expired access -> 401 and refresh; the old access stops being valid.
func TestExpiredAccessAndRefresh(t *testing.T) {
	h := newHarness(t)
	h.register("refresco@example.org")
	s := h.login("refresco@example.org", password)
	if res := h.do(call{method: "GET", path: "/v1/account", token: s.access}); res.status != 200 {
		t.Fatalf("with access: %d", res.status)
	}
	h.clock.Advance(16 * time.Minute)
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: s.access}), 401, "unauthorized")
	res := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": s.refresh}})
	if res.status != 200 || res.str("scope") != "game" || res.str("access_token") == s.access {
		t.Fatalf("refresh: %d %s", res.status, res.raw)
	}
	if res := h.do(call{method: "GET", path: "/v1/account", token: res.str("access_token")}); res.status != 200 {
		t.Fatalf("new access: %d", res.status)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: s.access}), 401, "unauthorized")
	h.expect(h.do(call{method: "GET", path: "/v1/account"}), 401, "unauthorized")
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: "x"}), 401, "unauthorized")
}

// Reusing the previous refresh revokes the session (refresh_reuse).
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
		t.Fatalf("revoked for reuse: %q", reason)
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

// A refresh from two rotations ago gives 401 without revoking.
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
		t.Fatalf("the session is still alive: %d %s", r3.status, r3.raw)
	}
	var revoked bool
	h.scalar(&revoked, `select revoked_at is not null from sessions`)
	if revoked {
		t.Fatal("it is not revoked")
	}
}

// The 12 h are not extended on rotation.
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
			t.Fatalf("at %s: %d %s", elapsed, last.status, last.raw)
		}
		refresh = last.str("refresh_token")
		remaining := (12*time.Hour - elapsed).Seconds()
		if got := last.body["refresh_expires_in"].(float64); got != remaining {
			t.Fatalf("at %s there are %v s left, not %v", elapsed, got, remaining)
		}
		if got := last.body["access_expires_in"].(float64); got > remaining || got > 900 {
			t.Fatalf("the access does not outlast the end of the session: %v", got)
		}
	}
	h.clock.Advance(14 * time.Minute)
	h.expect(h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": refresh}}),
		401, "unauthorized")
}

// A second session revokes the first (replaced).
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
	// Logging out: 204 and the access stops being valid.
	if res := h.do(call{method: "DELETE", path: "/v1/sessions/current", token: second.access}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: second.access}), 401, "unauthorized")
}

// Suspended with a bad password -> invalid_credentials; with a good one -> privacy session with the
// reason. With a banned account's, the account, the export, the deletion, the refresh and logout
// are valid; the others (including enter) give 403 account_banned.
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
		t.Fatalf("suspended: %s", s.res.raw)
	}
	var scope string
	h.scalar(&scope, `select scope from sessions where account_id = $1`, suspended)
	if scope != "privacy" {
		t.Fatal(scope)
	}

	b := h.login("expulsada@example.org", password)
	if b.res.str("scope") != "privacy" || b.res.body["restriction"].(map[string]any)["code"] != "account_banned" {
		t.Fatalf("banned: %s", b.res.raw)
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
		t.Fatalf("the account, with the privacy session: %s", res.raw)
	}
	r := h.do(call{method: "POST", path: "/v1/sessions/refresh", body: map[string]any{"refresh_token": b.refresh}})
	if r.status != 200 || r.str("scope") != "privacy" {
		t.Fatalf("the refresh keeps the scope: %s", r.raw)
	}
	access := r.str("access_token")
	if res := h.do(call{method: "POST", path: "/v1/account/export", token: access, body: map[string]any{"password": password}}); res.status != 200 {
		t.Fatalf("export with the privacy session: %d %s", res.status, res.raw)
	}
	if res := h.do(call{method: "POST", path: "/v1/account/deletion", token: access, body: map[string]any{"password": password}}); res.status != 202 {
		t.Fatalf("deletion: %d %s", res.status, res.raw)
	}
	if res := h.do(call{method: "DELETE", path: "/v1/sessions/current", token: access}); res.status != 204 {
		t.Fatalf("log out: %d %s", res.status, res.raw)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: access}), 401, "unauthorized")

	// A gameplay session of an account that is suspended afterwards: 403 on the gameplay routes.
	h.register("luego@example.org")
	g := h.login("luego@example.org", password)
	h.exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', 'acoso', $2, $3)`,
		h.accountID("luego@example.org"), now, until)
	res := h.do(call{method: "POST", path: "/v1/characters/1/enter", token: g.access})
	h.expect(res, 403, "account_suspended")
	if !strings.Contains(res.body["error"].(map[string]any)["message"].(string), "suspendida hasta el") {
		t.Fatal(res.raw)
	}
	// If the sanction ends, the privacy session is no longer valid: you have to log in again.
	h.exec(`update sanctions set revoked_at = $2 where account_id = $1`, suspended, now)
	h.expect(h.do(call{method: "POST", path: "/v1/characters/1/enter", token: s.access}), 401, "unauthorized")
	if g2 := h.login("suspendida@example.org", password); g2.res.str("scope") != "game" {
		t.Fatalf("no sanction, game session: %s", g2.res.raw)
	}
}

// needsRehash: with other parameters, login rewrites the string.
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
		t.Fatalf("rewritten with m=16: %s %v", phc, err)
	}
	h.login("rehash@example.org", password)
}

// Without X-Eldmark-Protocol or below the minimum, 426 (§4.1); /v1/status with each world's load.
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
		t.Fatalf("state: %s", res.raw)
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
		t.Fatalf("text: %d %s", text.status, text.header)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/legal/otro"}), 404, "not_found")
}

// With the clock stopped, the account's brake stays in place without attempts: CheckPassword
// directly.
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
		t.Fatal("without an account it is never valid", ok, err)
	}
	h.exec(`update accounts set password_hash = 'roto' where account_id = $1`, id)
	if ok, err := h.svc.CheckPassword(ctx, id, "directa@example.org", password, ip); ok || err != nil {
		t.Fatal("a broken chain counts as a failure", ok, err)
	}
	if !strings.Contains(h.logs.String(), "hash de contraseña no válido") {
		t.Fatal("and it is logged")
	}
}
