package accounts_test

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"io/fs"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/config"
	"eldmark/platform/legal"
)

// El registro con un correo con cuenta, uno sancionado y uno nuevo da el mismo cuerpo, y a cada
// uno le llega su correo (§4.2).
func TestRegistrationDoesNotRevealAccounts(t *testing.T) {
	h := newHarness(t)
	h.register("existe@example.org")
	h.exec(`insert into sanctioned_email_hashes (hmac, until) values ($1, $2)`, hmacOf("sancionado@example.org"),
		h.clock.Now().Add(30*24*time.Hour))
	var before int
	h.scalar(&before, `select count(*) from accounts`)
	var raws []string
	for _, email := range []string{"existe@example.org", "sancionado@example.org", "nuevo@example.org"} {
		res := h.do(call{method: "POST", path: "/v1/accounts", body: registerBody(email, password), ip: h.nextIP()})
		if res.status != 202 {
			t.Fatalf("%s: %d %s", email, res.status, res.raw)
		}
		raws = append(raws, res.raw)
	}
	if raws[0] != raws[1] || raws[1] != raws[2] || raws[0] != "{}\n" {
		t.Fatalf("cuerpos distintos: %q", raws)
	}
	var after int
	h.scalar(&after, `select count(*) from accounts`)
	if after != before+1 {
		t.Fatalf("solo se crea la nueva: %d → %d", before, after)
	}
	if body, _ := h.mailTo("existe@example.org", "register_existing"); !strings.Contains(body, "olvidado la contraseña") {
		t.Fatal(body)
	}
	if body, _ := h.mailTo("sancionado@example.org", "register_blocked"); !strings.Contains(body, "hasta el") {
		t.Fatal(body)
	}
	if _, token := h.mailTo("nuevo@example.org", "verify_email"); token == "" {
		t.Fatal("el nuevo recibe su enlace")
	}
	// La cuenta nueva: aceptaciones de las versiones vigentes y consentimientos.
	var acceptances, consents int
	h.scalar(&acceptances, `select count(*) from legal_acceptances a join accounts using (account_id) where email = 'nuevo@example.org'`)
	h.scalar(&consents, `select count(*) from consents c join accounts using (account_id) where email = 'nuevo@example.org'`)
	if acceptances != 3 || consents != 2 {
		t.Fatalf("aceptaciones %d, consentimientos %d", acceptances, consents)
	}
}

// hmacOf es la huella de un correo con la clave de pruebas (sanctioned_email_hashes).
func hmacOf(email string) []byte {
	m := hmac.New(sha256.New, config.TestEmailHMACKey)
	m.Write([]byte(email))
	return m.Sum(nil)
}

func TestRegistrationValidation(t *testing.T) {
	h := newHarness(t)
	cases := []struct {
		mutate func(map[string]any)
		code   string
		field  string
		reason string
	}{
		{func(b map[string]any) { b["email"] = "a@example.org\r\nBcc: x@example.org" }, "validation", "email", "invalid"},
		{func(b map[string]any) { b["email"] = "a b@example.org" }, "validation", "email", "invalid"},
		{func(b map[string]any) { b["email"] = "a@@example.org" }, "validation", "email", "invalid"},
		{func(b map[string]any) { b["email"] = "a@localhost" }, "validation", "email", "invalid"},
		{func(b map[string]any) { b["email"] = "a@xn--bcher-kva.example" }, "validation", "email", "invalid"},
		{func(b map[string]any) { b["email"] = "Nombre <a@example.org>" }, "validation", "email", "invalid"},
		{func(b map[string]any) { b["email"] = "añeira@example.org" }, "validation", "email", "invalid"},
		{func(b map[string]any) { b["password"] = "corta" }, "validation", "password", "too_short"},
		{func(b map[string]any) { b["password"] = strings.Repeat("ñ", 129) }, "validation", "password", "too_long"},
		{func(b map[string]any) { b["password"] = "ANEIRA@EXAMPLE.ORG" }, "validation", "password", "same_as_email"},
		{func(b map[string]any) { b["age_confirmed"] = false }, "validation", "age_confirmed", "required"},
		{func(b map[string]any) { b["accept"] = map[string]any{"terms": 1, "privacy": 1} }, "validation", "accept.rules", "required"},
		{func(b map[string]any) { b["accept"] = map[string]any{"terms": 0, "privacy": 1, "rules": 1} }, "validation", "accept.terms", "outdated"},
		{func(b map[string]any) { delete(b, "consents") }, "validation", "consents.analytics", "required"},
		{func(b map[string]any) { b["apodo"] = "x" }, "bad_request", "", ""},
		{func(b map[string]any) { b["accept"] = map[string]any{"terms": 1.5, "privacy": 1, "rules": 1} }, "bad_request", "", ""},
	}
	for i, c := range cases {
		body := registerBody("aneira@example.org", password)
		c.mutate(body)
		res := h.do(call{method: "POST", path: "/v1/accounts", body: body, ip: h.nextIP()})
		h.expect(res, 400, c.code)
		if c.field != "" && res.errField(c.field) != c.reason {
			t.Errorf("caso %d: %s", i, res.raw)
		}
	}
	// Godot escribe los enteros como 1.0: valen.
	body := registerBody("Aneira@Example.org", password)
	body["accept"] = map[string]any{"terms": 1.0, "privacy": 1.0, "rules": 1.0}
	raw, _ := json.Marshal(body)
	raw = []byte(strings.Replace(string(raw), `"terms":1`, `"terms":1.0`, 1))
	if res := h.do(call{method: "POST", path: "/v1/accounts", body: string(raw), ip: h.nextIP()}); res.status != 202 {
		t.Fatal(res.raw)
	}
	h.accountID("aneira@example.org")
	// Un correo con CR/LF tampoco vale para recuperar la contraseña.
	h.expect(h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "a@example.org\r\nBcc: b@example.org"}}),
		400, "validation")
	h.expect(h.do(call{method: "POST", path: "/v1/accounts", body: "{roto", ip: h.nextIP()}), 400, "bad_request")
	h.expect(h.do(call{method: "POST", path: "/v1/accounts", body: `{"email": "` + strings.Repeat("a", 17000) + `"}`, ip: h.nextIP()}),
		413, "too_large")
}

// 3 registros por IP y hora; 3 correos por destinatario y hora (también los de recuperación).
func TestRegistrationAndMailLimits(t *testing.T) {
	h := newHarness(t)
	ip := h.nextIP()
	for i, email := range []string{"r1@example.org", "r2@example.org", "r3@example.org", "r4@example.org"} {
		res := h.do(call{method: "POST", path: "/v1/accounts", body: registerBody(email, password), ip: ip})
		if i < 3 && res.status != 202 {
			t.Fatalf("%d: %s", i, res.raw)
		}
		if i == 3 {
			h.expect(res, 429, "rate_limited")
		}
	}
	// r1 ya gastó un correo (verify_email): le quedan dos.
	for i := 0; i < 2; i++ {
		if res := h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "r1@example.org"},
			ip: h.nextIP()}); res.status != 202 {
			t.Fatal(res.raw)
		}
	}
	h.expect(h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "r1@example.org"},
		ip: h.nextIP()}), 429, "rate_limited")
	// Igual con un correo sin cuenta: el límite no delata nada.
	for i := 0; i < 3; i++ {
		if res := h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "nadie@example.org"},
			ip: h.nextIP()}); res.status != 202 || res.raw != "{}\n" {
			t.Fatal(res.raw)
		}
	}
	h.expect(h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "nadie@example.org"},
		ip: h.nextIP()}), 429, "rate_limited")
	if h.mailCount("nadie@example.org", "reset_password") != 0 {
		t.Fatal("sin cuenta no sale correo")
	}
}

// Enlaces caducados y usados: 400 validation con fields.token y nada cambia (§4.3).
func TestLinksExpireAndAreSingleUse(t *testing.T) {
	h := newHarness(t)
	h.register("enlace@example.org")
	_, first := h.mailTo("enlace@example.org", "verify_email")
	h.clock.Advance(25 * time.Hour)
	res := h.do(call{method: "POST", path: "/v1/account/verify-email", body: map[string]any{"token": first}})
	h.expect(res, 400, "validation")
	if res.errField("token") != "expired" {
		t.Fatal(res.raw)
	}
	s := h.login("enlace@example.org", password)
	if res := h.do(call{method: "POST", path: "/v1/account/verify-email/resend", token: s.access}); res.status != 202 {
		t.Fatal(res.raw)
	}
	_, second := h.mailTo("enlace@example.org", "verify_email")
	if second == first {
		t.Fatal("enlace nuevo")
	}
	if res := h.do(call{method: "POST", path: "/v1/account/verify-email", body: map[string]any{"token": second}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	res = h.do(call{method: "POST", path: "/v1/account/verify-email", body: map[string]any{"token": second}})
	if res.errField("token") != "used" {
		t.Fatal(res.raw)
	}
	if acc := h.do(call{method: "GET", path: "/v1/account", token: s.access}); acc.body["email_verified"] != true {
		t.Fatal(acc.raw)
	}
	res = h.do(call{method: "POST", path: "/v1/account/verify-email", body: map[string]any{"token": strings.Repeat("A", 43)}})
	if res.errField("token") != "invalid" {
		t.Fatal(res.raw)
	}
	// Ya verificada, pedir otro no manda nada.
	n := h.mailCount("enlace@example.org", "verify_email")
	h.do(call{method: "POST", path: "/v1/account/verify-email/resend", token: s.access})
	if h.mailCount("enlace@example.org", "verify_email") != n {
		t.Fatal("ya verificada")
	}
	// Recuperación: 1 h.
	h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "enlace@example.org"}, ip: h.nextIP()})
	_, reset := h.mailTo("enlace@example.org", "reset_password")
	h.clock.Advance(61 * time.Minute)
	res = h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": reset, "new_password": "contraseña nueva larga"}})
	if res.errField("token") != "expired" {
		t.Fatal(res.raw)
	}
	h.login("enlace@example.org", password) // nada cambió
}

// Pedir la recuperación hace el mismo trabajo exista o no la cuenta (§4.2): los dos caminos escriben
// y confirman una fila password_reset en auth_events (con la cuenta o sin ella), así que el tiempo
// de la respuesta no delata qué correos tienen cuenta.
func TestPasswordResetWritesEitherWay(t *testing.T) {
	h := newHarness(t)
	id := h.register("tiene@example.org")
	ip := h.nextIP()
	for _, email := range []string{"tiene@example.org", "nadie@example.org"} {
		if res := h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": email},
			ip: ip}); res.status != 202 || res.raw != "{}\n" {
			t.Fatal(res.raw)
		}
	}
	var withAccount, without int
	h.scalar(&withAccount, `select count(*) from auth_events where kind = 'password_reset' and account_id = $1 and ip = $2`, id, ip)
	h.scalar(&without, `select count(*) from auth_events where kind = 'password_reset' and account_id is null and ip = $1`, ip)
	if withAccount != 1 || without != 1 {
		t.Fatalf("filas password_reset: con cuenta %d, sin cuenta %d", withAccount, without)
	}
	if h.mailCount("nadie@example.org", "reset_password") != 0 || h.mailCount("tiene@example.org", "reset_password") != 1 {
		t.Fatal("correos")
	}
	// La respuesta no espera a la base: con la tabla de cuentas bloqueada, vuelve igual (y lo demás
	// llega al soltarla).
	ctx := context.Background()
	lock, err := h.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lock.Exec(ctx, `lock table accounts in access exclusive mode`); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- h.svc.RequestPasswordReset(ctx, "tiene@example.org", accounts.ClientMeta{IP: h.nextIPAddr()})
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("la respuesta espera a la base")
	}
	if err := lock.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	h.svc.Wait()
	if h.mailCount("tiene@example.org", "reset_password") != 2 {
		t.Fatal("el segundo enlace no llegó")
	}
}

// Recuperar la contraseña revoca todas las sesiones e invalida los enlaces.
func TestPasswordReset(t *testing.T) {
	h := newHarness(t)
	h.register("olvido@example.org")
	s := h.login("olvido@example.org", password)
	h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "Olvido@example.org"}, ip: h.nextIP()})
	_, reset := h.mailTo("olvido@example.org", "reset_password")
	res := h.do(call{method: "POST", path: "/v1/account/password-reset/confirm", body: map[string]any{"token": reset, "new_password": "corta"}})
	if res.errField("new_password") != "too_short" {
		t.Fatal(res.raw)
	}
	res = h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": reset, "new_password": "OLVIDO@example.org"}})
	if res.errField("new_password") != "same_as_email" {
		t.Fatal(res.raw)
	}
	if res := h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": reset, "new_password": "contraseña recuperada"}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: s.access}), 401, "unauthorized")
	var reason string
	h.scalar(&reason, `select revoke_reason from sessions`)
	if reason != "password_changed" {
		t.Fatal(reason)
	}
	_, verify := h.mailTo("olvido@example.org", "verify_email")
	if res := h.do(call{method: "POST", path: "/v1/account/verify-email", body: map[string]any{"token": verify}}); res.errField("token") != "used" {
		t.Fatalf("los enlaces pendientes dejan de valer: %s", res.raw)
	}
	h.expect(h.loginFrom("olvido@example.org", password, h.nextIP()), 401, "invalid_credentials")
	h.login("olvido@example.org", "contraseña recuperada")
}

// Tras cambiar la contraseña o el correo, el enlace de recuperación anterior falla y el
// revert_email sigue valiendo; revert_email devuelve el correo y obliga a recuperar (§4.3).
func TestEmailChangeAndRevert(t *testing.T) {
	h := newHarness(t)
	id := h.register("vieja@example.org")
	h.register("ocupada@example.org")
	// Cambio de contraseña: el enlace de recuperación anterior deja de valer y la sesión sigue.
	h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "vieja@example.org"}, ip: h.nextIP()})
	_, oldReset := h.mailTo("vieja@example.org", "reset_password")
	s := h.login("vieja@example.org", password)
	const newPassword = "contraseña cambiada"
	if res := h.do(call{method: "POST", path: "/v1/account/password", token: s.access,
		body: map[string]any{"current_password": password, "new_password": newPassword}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	if res := h.do(call{method: "GET", path: "/v1/account", token: s.access}); res.status != 200 {
		t.Fatal("la sesión que cambia sigue viva")
	}
	if res := h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": oldReset, "new_password": "otra más larga"}}); res.errField("token") != "used" {
		t.Fatal(res.raw)
	}

	// Cambio de correo hacia uno con cuenta: 202 y register_existing a ese, nada más.
	if res := h.do(call{method: "POST", path: "/v1/account/email", token: s.access,
		body: map[string]any{"new_email": "ocupada@example.org", "password": newPassword}}); res.status != 202 {
		t.Fatal(res.raw)
	}
	if h.mailCount("ocupada@example.org", "register_existing") != 1 || h.mailCount("ocupada@example.org", "change_email") != 0 {
		t.Fatal("al correo con cuenta, register_existing")
	}
	h.expect(h.do(call{method: "POST", path: "/v1/account/email", token: s.access,
		body: map[string]any{"new_email": "nueva@example.org", "password": "mala"}}), 401, "invalid_credentials")
	if res := h.do(call{method: "POST", path: "/v1/account/email", token: s.access,
		body: map[string]any{"new_email": "Nueva@example.org", "password": newPassword}}); res.status != 202 {
		t.Fatal(res.raw)
	}
	_, change := h.mailTo("nueva@example.org", "change_email")
	// Pide otra recuperación antes de confirmar: el cambio la invalida.
	h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "vieja@example.org"}, ip: h.nextIP()})
	_, pendingReset := h.mailTo("vieja@example.org", "reset_password")
	if res := h.do(call{method: "POST", path: "/v1/account/email/confirm", body: map[string]any{"token": change}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	var email string
	var verified bool
	h.scalar(&email, `select email from accounts where account_id = $1`, id)
	h.scalar(&verified, `select email_verified_at is not null from accounts where account_id = $1`, id)
	if email != "nueva@example.org" || !verified {
		t.Fatal(email, verified)
	}
	h.expect(h.do(call{method: "GET", path: "/v1/account", token: s.access}), 401, "unauthorized")
	if res := h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": pendingReset, "new_password": "otra más larga"}}); res.errField("token") != "used" {
		t.Fatalf("el enlace de recuperación anterior falla: %s", res.raw)
	}
	notice, revert := h.mailTo("vieja@example.org", "email_changed")
	if revert == "" || !strings.Contains(notice, "n***@example.org") || strings.Contains(notice, "nueva@example.org") {
		t.Fatalf("aviso al viejo: %s", notice)
	}

	// Quien robó la cuenta la cambia otra vez: el revert_email del dueño sigue valiendo (7 días).
	thief := h.login("nueva@example.org", newPassword)
	h.do(call{method: "POST", path: "/v1/account/email", token: thief.access,
		body: map[string]any{"new_email": "ladron@example.org", "password": newPassword}})
	_, change2 := h.mailTo("ladron@example.org", "change_email")
	if res := h.do(call{method: "POST", path: "/v1/account/email/confirm", body: map[string]any{"token": change2}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.clock.Advance(6 * 24 * time.Hour)
	if res := h.do(call{method: "POST", path: "/v1/account/email/revert", body: map[string]any{"token": revert}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.scalar(&email, `select email from accounts where account_id = $1`, id)
	var noPassword bool
	h.scalar(&noPassword, `select password_hash is null from accounts where account_id = $1`, id)
	if email != "vieja@example.org" || !noPassword {
		t.Fatal(email, noPassword)
	}
	// Sin contraseña: no entra nadie, tampoco el dueño, hasta recuperarla.
	h.expect(h.loginFrom("vieja@example.org", newPassword, h.nextIP()), 401, "invalid_credentials")
	h.expect(h.loginFrom("ladron@example.org", newPassword, h.nextIP()), 401, "invalid_credentials")
	var reasons string
	h.scalar(&reasons, `select string_agg(distinct revoke_reason, ',') from sessions`)
	if !strings.Contains(reasons, "email_changed") {
		t.Fatal(reasons)
	}
	_, reset := h.mailTo("vieja@example.org", "email_reverted")
	if res := h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": reset, "new_password": "la del dueño, nueva"}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.login("vieja@example.org", "la del dueño, nueva")
	// El enlace de revertir es de un solo uso.
	if res := h.do(call{method: "POST", path: "/v1/account/email/revert", body: map[string]any{"token": revert}}); res.errField("token") != "used" {
		t.Fatal(res.raw)
	}
	var kinds string
	h.scalar(&kinds, `select string_agg(kind, ',' order by id) from auth_events where kind like 'email%'`)
	if kinds != "email_changed,email_changed,email_reverted" {
		t.Fatal(kinds)
	}
}

// changeEmail cambia el correo de la sesión s (con su contraseña) de from a to y devuelve el enlace
// revert_email que llega a from.
func (h *harness) changeEmail(s session, from, to, pw string) string {
	h.t.Helper()
	if res := h.do(call{method: "POST", path: "/v1/account/email", token: s.access, ip: h.nextIP(),
		body: map[string]any{"new_email": to, "password": pw}}); res.status != 202 {
		h.t.Fatalf("cambio a %s: %s", to, res.raw)
	}
	_, change := h.mailTo(to, "change_email")
	if res := h.do(call{method: "POST", path: "/v1/account/email/confirm", body: map[string]any{"token": change}}); res.status != 204 {
		h.t.Fatalf("confirmar %s: %s", to, res.raw)
	}
	_, revert := h.mailTo(from, "email_changed")
	if revert == "" {
		h.t.Fatalf("sin revert_email a %s", from)
	}
	return revert
}

func (h *harness) revert(token string) *response {
	h.t.Helper()
	return h.do(call{method: "POST", path: "/v1/account/email/revert", body: map[string]any{"token": token}})
}

// Quien sabe la contraseña cambia el correo dos veces (A→B→C): al dueño le llega R1 en A y al ladrón
// R2 en B. Gastar un revert_email anula los de la cuenta emitidos después, así que el del dueño (el
// más antiguo) deja muerto el del ladrón, y el del ladrón, usado antes, no anula el del dueño (§4.3).
func TestRevertEmailChain(t *testing.T) {
	h := newHarness(t)
	// El dueño revierte primero: R2 ya no vale y la cuenta sigue siendo suya.
	id := h.register("dueno@example.org")
	s := h.login("dueno@example.org", password)
	r1 := h.changeEmail(s, "dueno@example.org", "ladron1@example.org", password)
	thief := h.login("ladron1@example.org", password)
	r2 := h.changeEmail(thief, "ladron1@example.org", "ladron2@example.org", password)
	if res := h.revert(r1); res.status != 204 {
		t.Fatal(res.raw)
	}
	_, reset := h.mailTo("dueno@example.org", "email_reverted")
	if res := h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": reset, "new_password": "la del dueño, nueva"}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.clock.Advance(3 * 24 * time.Hour)
	if res := h.revert(r2); res.errField("token") != "used" {
		t.Fatalf("el revert_email del ladrón sigue vivo: %s", res.raw)
	}
	var email string
	h.scalar(&email, `select email from accounts where account_id = $1`, id)
	if email != "dueno@example.org" {
		t.Fatal(email)
	}
	h.login("dueno@example.org", "la del dueño, nueva")
	h.expect(h.loginFrom("ladron1@example.org", password, h.nextIP()), 401, "invalid_credentials")

	// El ladrón revierte primero con R2: R1 sigue vivo, el dueño vuelve con él y el enlace de
	// recuperación que le llegó al ladrón deja de valer.
	id = h.register("duena@example.org")
	s = h.login("duena@example.org", password)
	r1 = h.changeEmail(s, "duena@example.org", "ladrona1@example.org", password)
	thief = h.login("ladrona1@example.org", password)
	r2 = h.changeEmail(thief, "ladrona1@example.org", "ladrona2@example.org", password)
	if res := h.revert(r2); res.status != 204 {
		t.Fatal(res.raw)
	}
	_, thiefReset := h.mailTo("ladrona1@example.org", "email_reverted")
	if res := h.revert(r1); res.status != 204 {
		t.Fatalf("el revert_email del dueño tiene que seguir valiendo: %s", res.raw)
	}
	h.scalar(&email, `select email from accounts where account_id = $1`, id)
	if email != "duena@example.org" {
		t.Fatal(email)
	}
	if res := h.do(call{method: "POST", path: "/v1/account/password-reset/confirm",
		body: map[string]any{"token": thiefReset, "new_password": "la de la ladrona"}}); res.errField("token") != "used" {
		t.Fatalf("la recuperación del ladrón sigue viva: %s", res.raw)
	}
	if res := h.revert(r2); res.errField("token") != "used" {
		t.Fatal(res.raw)
	}
}

// Mientras vive un revert_email, su correo queda reservado para el dueño: ni un registro, ni el
// cambio de correo de otra cuenta, ni un change_email a ese correo pedido antes lo toman (los dos
// primeros reciben lo mismo que un correo con cuenta), y el dueño puede volver a él. Al caducar el
// enlace, el correo queda libre (§4.3).
func TestOldEmailIsReservedWhileRevertLives(t *testing.T) {
	h := newHarness(t)
	// Otra cuenta pide pasarse a dueno@ cuando aún no lo tiene nadie.
	h.register("otro@example.org")
	other := h.login("otro@example.org", password)
	if res := h.do(call{method: "POST", path: "/v1/account/email", token: other.access, ip: h.nextIP(),
		body: map[string]any{"new_email": "dueno@example.org", "password": password}}); res.status != 202 {
		t.Fatal(res.raw)
	}
	_, early := h.mailTo("dueno@example.org", "change_email")

	id := h.register("dueno@example.org")
	s := h.login("dueno@example.org", password)
	r1 := h.changeEmail(s, "dueno@example.org", "ladron@example.org", password)
	res := h.do(call{method: "POST", path: "/v1/accounts", body: registerBody("dueno@example.org", "otra contraseña larga"),
		ip: h.nextIP()})
	if res.status != 202 || res.raw != "{}\n" {
		t.Fatal(res.raw)
	}
	var squatters int
	h.scalar(&squatters, `select count(*) from accounts where email = 'dueno@example.org'`)
	if squatters != 0 || h.mailCount("dueno@example.org", "register_existing") != 1 {
		t.Fatalf("el registro tomó el correo reservado: %d cuentas", squatters)
	}
	if res := h.do(call{method: "POST", path: "/v1/account/email/confirm", body: map[string]any{"token": early}}); res.errField("token") != "unavailable" {
		t.Fatalf("el change_email de antes tomó el correo reservado: %s", res.raw)
	}
	h.clock.Advance(time.Hour) // el límite de correos de dueno@ (3 por hora)
	other = h.login("otro@example.org", password)
	if res := h.do(call{method: "POST", path: "/v1/account/email", token: other.access, ip: h.nextIP(),
		body: map[string]any{"new_email": "dueno@example.org", "password": password}}); res.status != 202 {
		t.Fatal(res.raw)
	}
	if h.mailCount("dueno@example.org", "change_email") != 1 || h.mailCount("dueno@example.org", "register_existing") != 2 {
		t.Fatal("el cambio de otra cuenta tomó el correo reservado")
	}
	if res := h.revert(r1); res.status != 204 {
		t.Fatalf("el dueño vuelve a su correo: %s", res.raw)
	}
	var email string
	h.scalar(&email, `select email from accounts where account_id = $1`, id)
	if email != "dueno@example.org" {
		t.Fatal(email)
	}
	// Caducado el enlace, el correo que reservaba queda libre.
	h.changeEmail(other, "otro@example.org", "otro2@example.org", password)
	h.clock.Advance(accountsRevertTTL + time.Second)
	if res := h.do(call{method: "POST", path: "/v1/accounts", body: registerBody("otro@example.org", password),
		ip: h.nextIP()}); res.status != 202 {
		t.Fatal(res.raw)
	}
	h.accountID("otro@example.org")
}

// accountsRevertTTL es accounts.RevertTTL (7 días).
const accountsRevertTTL = 7 * 24 * time.Hour

// Borrado y cancelación en plazo (§4.3); vencido, no se cancela y la purga lo borra.
func TestDeletionAndCancellation(t *testing.T) {
	h := newHarness(t)
	id := h.register("borrar@example.org")
	s := h.login("borrar@example.org", password)
	h.expect(h.do(call{method: "POST", path: "/v1/account/deletion", token: s.access, body: map[string]any{}}), 400, "validation")
	h.expect(h.do(call{method: "POST", path: "/v1/account/deletion", token: s.access, body: map[string]any{"password": "mala"}}),
		401, "invalid_credentials")
	res := h.do(call{method: "POST", path: "/v1/account/deletion", token: s.access, body: map[string]any{"password": password}})
	purgeAt := h.clock.Now().Add(14 * 24 * time.Hour).Unix()
	if res.status != 202 || res.body["purge_at"] != float64(purgeAt) {
		t.Fatal(res.raw)
	}
	acc := h.do(call{method: "GET", path: "/v1/account", token: s.access})
	if acc.body["pending"].(map[string]any)["deletion_at"] != float64(purgeAt) {
		t.Fatal(acc.raw)
	}
	// Iniciar sesión sigue valiendo (para poder cancelarlo).
	h.clock.Advance(13 * 24 * time.Hour)
	s = h.login("borrar@example.org", password)
	if res := h.do(call{method: "DELETE", path: "/v1/account/deletion", token: s.access}); res.status != 204 {
		t.Fatal(res.raw)
	}
	var status string
	h.scalar(&status, `select status from accounts where account_id = $1`, id)
	if status != "active" {
		t.Fatal(status)
	}
	// Otra vez, y esta vez vence.
	s = h.login("borrar@example.org", password)
	h.do(call{method: "POST", path: "/v1/account/deletion", token: s.access, body: map[string]any{"password": password}})
	h.clock.Advance(14*24*time.Hour + time.Second)
	s = h.login("borrar@example.org", password)
	h.expect(h.do(call{method: "DELETE", path: "/v1/account/deletion", token: s.access}), 409, "deletion_expired")
	if err := h.svc.PurgeDue(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.scalar(&status, `select status from accounts where account_id = $1`, id)
	var gone int
	h.scalar(&gone, `select (select count(*) from sessions where account_id = $1) + (select count(*) from account_tokens where account_id = $1)
		+ (select count(*) from consents where account_id = $1) + (select count(*) from legal_acceptances where account_id = $1)
		+ (select count(*) from auth_events where account_id = $1) + (select count(*) from outbound_mail where to_email = 'borrar@example.org')
		+ (select count(*) from accounts where account_id = $1 and (email is not null or password_hash is not null))`, id)
	var logged bool
	h.scalar(&logged, `select exists (select 1 from purge_log where kind = 'account' and id = $1)`, id)
	if status != "purged" || gone != 0 || !logged {
		t.Fatalf("purgada: %s, %d filas personales, purge_log %v", status, gone, logged)
	}
	h.expect(h.loginFrom("borrar@example.org", password, h.nextIP()), 401, "invalid_credentials")
}

// Exportar sin contraseña → 400; con ella, el JSON de §11.2; una vez al día.
func TestExport(t *testing.T) {
	h := newHarness(t)
	id := h.register("exporta@example.org")
	s := h.login("exporta@example.org", password)
	h.expect(h.do(call{method: "POST", path: "/v1/account/export", token: s.access, body: map[string]any{}}), 400, "validation")
	h.expect(h.do(call{method: "POST", path: "/v1/account/export", token: s.access}), 400, "bad_request")
	h.expect(h.do(call{method: "POST", path: "/v1/account/export", token: s.access, body: map[string]any{"password": "mala"}}),
		401, "invalid_credentials")
	h.exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at, author_account_id) values ($1, 'warning', 'aviso', $2, null, $1)`,
		id, h.clock.Now())
	res := h.do(call{method: "POST", path: "/v1/account/export", token: s.access, body: map[string]any{"password": password}})
	if res.status != 200 || !strings.Contains(res.header.Get("Content-Disposition"), "eldmark-datos-") {
		t.Fatal(res.status, res.header, res.raw)
	}
	var data map[string]any
	if err := json.Unmarshal([]byte(res.raw), &data); err != nil {
		t.Fatal(err)
	}
	account := data["account"].(map[string]any)
	if account["email"] != "exporta@example.org" || len(data["legal_acceptances"].([]any)) != 3 ||
		len(data["consents"].([]any)) != 2 || len(data["sessions"].([]any)) != 1 || len(data["sanctions"].([]any)) != 1 {
		t.Fatalf("exportación: %s", res.raw)
	}
	if strings.Contains(res.raw, "argon2") || strings.Contains(res.raw, "password_hash") || strings.Contains(res.raw, "author") {
		t.Fatal("sin hash ni autor de las sanciones")
	}
	if _, ok := account["created_at"].(string); !ok {
		t.Fatal("fechas en texto")
	}
	h.expect(h.do(call{method: "POST", path: "/v1/account/export", token: s.access, body: map[string]any{"password": password}}),
		429, "rate_limited")
	h.clock.Advance(24*time.Hour + time.Second)
	s = h.login("exporta@example.org", password)
	if res := h.do(call{method: "POST", path: "/v1/account/export", token: s.access, body: map[string]any{"password": password}}); res.status != 200 {
		t.Fatal(res.raw)
	}
}

// Una versión nueva de un texto: GET /v1/account lo dice y aceptarla lo quita; consentimientos.
func TestAcceptNewVersionsAndConsents(t *testing.T) {
	h := newHarness(t)
	h.register("acepta@example.org")
	s := h.login("acepta@example.org", password)
	pending := h.do(call{method: "GET", path: "/v1/account", token: s.access}).body["pending"].(map[string]any)
	if pending["terms_required"] != false || len(pending["documents"].([]any)) != 0 {
		t.Fatal(pending)
	}
	texts := fstest.MapFS{}
	for _, kind := range legal.Kinds {
		data, err := fs.ReadFile(legal.Embedded(), kind+"-1.md")
		if err != nil {
			t.Fatal(err)
		}
		texts[kind+"-1.md"] = &fstest.MapFile{Data: data}
	}
	texts["privacy-2.md"] = &fstest.MapFile{Data: []byte("# Privacidad 2\n")}
	h.build(texts, h.cfg)
	acc := h.do(call{method: "GET", path: "/v1/account", token: s.access})
	pending = acc.body["pending"].(map[string]any)
	if pending["terms_required"] != true || pending["documents"].([]any)[0] != "privacy" {
		t.Fatal(acc.raw)
	}
	res := h.do(call{method: "POST", path: "/v1/account/accept", token: s.access, body: map[string]any{"terms": 1, "privacy": 1, "rules": 1}})
	if res.errField("privacy") != "outdated" {
		t.Fatal(res.raw)
	}
	if res := h.do(call{method: "POST", path: "/v1/account/accept", token: s.access,
		body: map[string]any{"terms": 1, "privacy": 2, "rules": 1}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	if acc := h.do(call{method: "GET", path: "/v1/account", token: s.access}); acc.body["pending"].(map[string]any)["terms_required"] != false {
		t.Fatal(acc.raw)
	}
	// El registro exige ya la versión 2.
	res = h.do(call{method: "POST", path: "/v1/accounts", body: registerBody("tarde@example.org", password), ip: h.nextIP()})
	if res.errField("accept.privacy") != "outdated" {
		t.Fatal(res.raw)
	}
	if res := h.do(call{method: "PUT", path: "/v1/account/consents", token: s.access,
		body: map[string]any{"crash_reports": true, "analytics": false}}); res.status != 204 {
		t.Fatal(res.raw)
	}
	h.expect(h.do(call{method: "PUT", path: "/v1/account/consents", token: s.access, body: map[string]any{"analytics": true}}),
		400, "validation")
	acc = h.do(call{method: "GET", path: "/v1/account", token: s.access})
	consents := acc.body["consents"].(map[string]any)
	slots := acc.body["slots"].(map[string]any)
	if consents["crash_reports"] != true || consents["analytics"] != false || slots["1"] != 6.0 {
		t.Fatal(acc.raw)
	}
	h.exec(`insert into entitlements (account_id, world_id, kind, quantity, source) values ($1, 1, 'character_slots', 2, 'grant'),
		($1, null, 'character_slots', 1, 'promo')`, h.accountID("acepta@example.org"))
	h.exec(`insert into account_realms (account_id, world_id, realm) values ($1, 1, 2)`, h.accountID("acepta@example.org"))
	acc = h.do(call{method: "GET", path: "/v1/account", token: s.access})
	if acc.body["slots"].(map[string]any)["1"] != 9.0 || acc.body["realms"].(map[string]any)["1"] != "solmarch" {
		t.Fatal(acc.raw)
	}
}
