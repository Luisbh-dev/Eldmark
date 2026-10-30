package accounts_test

import (
	"context"
	"net/url"
	"strings"
	"testing"
	"time"
)

func checkPageHeaders(t *testing.T, res *response) {
	t.Helper()
	want := map[string]string{
		"Content-Type":            "text/html; charset=utf-8",
		"Referrer-Policy":         "no-referrer",
		"Cache-Control":           "no-store",
		"Content-Security-Policy": "default-src 'none'; form-action 'self'",
		"X-Frame-Options":         "DENY",
	}
	for k, v := range want {
		if got := res.header.Get(k); got != v {
			t.Errorf("%s: %q", k, got)
		}
	}
	if strings.Contains(strings.ToLower(res.raw), "<script") || strings.Contains(res.raw, "style") {
		t.Errorf("sin JavaScript ni CSS: %s", res.raw)
	}
}

// El formulario de /verify enviado como un navegador (urlencoded, sin cabeceras de /v1) verifica;
// /verify?token=<script> no lo repite (§4.3).
func TestVerifyPage(t *testing.T) {
	h := newHarness(t)
	id := h.register("pagina@example.org")
	_, token := h.mailTo("pagina@example.org", "verify_email")
	if !strings.Contains(mustBody(t, h, "pagina@example.org", "verify_email"), "http://127.0.0.1:24680/verify?token="+token) {
		t.Fatal("el enlace apunta a ELDMARK_PUBLIC_URL/verify")
	}
	form := h.do(call{method: "GET", path: "/verify?token=" + token, noProtocol: true})
	checkPageHeaders(t, form)
	if form.status != 200 || !strings.Contains(form.raw, `<form method="post" action="/verify">`) ||
		!strings.Contains(form.raw, `name="token" value="`+token+`"`) {
		t.Fatalf("formulario: %d %s", form.status, form.raw)
	}
	var verified bool
	h.scalar(&verified, `select email_verified_at is not null from accounts where account_id = $1`, id)
	if verified {
		t.Fatal("abrir el enlace no verifica: hace falta el POST")
	}
	done := h.do(call{method: "POST", path: "/verify", form: "token=" + url.QueryEscape(token)})
	checkPageHeaders(t, done)
	if done.status != 200 || !strings.Contains(done.raw, "Correo verificado. Ya puedes cerrar esta página") {
		t.Fatalf("POST: %d %s", done.status, done.raw)
	}
	h.scalar(&verified, `select email_verified_at is not null from accounts where account_id = $1`, id)
	if !verified {
		t.Fatal("verificado")
	}
	again := h.do(call{method: "POST", path: "/verify", form: "token=" + token})
	if again.status != 400 || !strings.Contains(again.raw, "ya se ha usado") {
		t.Fatalf("usado: %d %s", again.status, again.raw)
	}
	for _, bad := range []string{"<script>alert(1)</script>", strings.Repeat("A", 42) + "<", "", strings.Repeat("A", 44)} {
		res := h.do(call{method: "GET", path: "/verify?token=" + url.QueryEscape(bad), noProtocol: true})
		checkPageHeaders(t, res)
		if res.status != 400 || !strings.Contains(res.raw, "Enlace no válido") || (bad != "" && strings.Contains(res.raw, bad)) ||
			strings.Contains(res.raw, "alert") {
			t.Fatalf("%q: %d %s", bad, res.status, res.raw)
		}
		res = h.do(call{method: "POST", path: "/verify", form: "token=" + url.QueryEscape(bad)})
		if res.status != 400 || strings.Contains(res.raw, "alert") {
			t.Fatalf("POST %q: %d %s", bad, res.status, res.raw)
		}
	}
}

// /verify confirma también un cambio de correo (change_email).
func TestVerifyPageConfirmsAnEmailChange(t *testing.T) {
	h := newHarness(t)
	h.register("antes@example.org")
	s := h.login("antes@example.org", password)
	h.do(call{method: "POST", path: "/v1/account/email", token: s.access, body: map[string]any{"new_email": "despues@example.org", "password": password}})
	body, token := h.mailTo("despues@example.org", "change_email")
	if !strings.Contains(body, "/verify?token="+token) {
		t.Fatal(body)
	}
	res := h.do(call{method: "POST", path: "/verify", form: "token=" + token})
	if res.status != 200 || !strings.Contains(res.raw, "Correo cambiado") {
		t.Fatal(res.raw)
	}
	h.accountID("despues@example.org")
}

func TestResetAndRevertPages(t *testing.T) {
	h := newHarness(t)
	h.register("formulario@example.org")
	h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "formulario@example.org"}, ip: h.nextIP()})
	body, token := h.mailTo("formulario@example.org", "reset_password")
	if !strings.Contains(body, "/reset?token="+token) {
		t.Fatal(body)
	}
	form := h.do(call{method: "GET", path: "/reset?token=" + token, noProtocol: true})
	checkPageHeaders(t, form)
	if !strings.Contains(form.raw, `type="password" name="new_password"`) || !strings.Contains(form.raw, `action="/reset"`) {
		t.Fatal(form.raw)
	}
	res := h.do(call{method: "POST", path: "/reset", form: "token=" + token + "&new_password=una+nueva+larga&new_password_repeat=otra+distinta"})
	if res.status != 400 || !strings.Contains(res.raw, "no coinciden") || !strings.Contains(res.raw, `value="`+token+`"`) {
		t.Fatalf("no coinciden: %s", res.raw)
	}
	res = h.do(call{method: "POST", path: "/reset", form: "token=" + token + "&new_password=corta&new_password_repeat=corta"})
	if res.status != 400 || !strings.Contains(res.raw, "al menos 10") {
		t.Fatalf("corta: %s", res.raw)
	}
	res = h.do(call{method: "POST", path: "/reset", form: "token=" + token + "&new_password=una+nueva+larga&new_password_repeat=una+nueva+larga"})
	if res.status != 200 || !strings.Contains(res.raw, "Contraseña cambiada") {
		t.Fatalf("cambiada: %s", res.raw)
	}
	h.login("formulario@example.org", "una nueva larga")

	// /revert: cambia el correo y lo devuelve desde la página.
	s := h.login("formulario@example.org", "una nueva larga")
	h.do(call{method: "POST", path: "/v1/account/email", token: s.access,
		body: map[string]any{"new_email": "otro@example.org", "password": "una nueva larga"}})
	_, change := h.mailTo("otro@example.org", "change_email")
	h.do(call{method: "POST", path: "/v1/account/email/confirm", body: map[string]any{"token": change}})
	body, revert := h.mailTo("formulario@example.org", "email_changed")
	if !strings.Contains(body, "/revert?token="+revert) {
		t.Fatal(body)
	}
	if res := h.do(call{method: "GET", path: "/revert?token=" + revert, noProtocol: true}); res.status != 200 ||
		!strings.Contains(res.raw, `action="/revert"`) {
		t.Fatal(res.raw)
	}
	res = h.do(call{method: "POST", path: "/revert", form: "token=" + revert})
	if res.status != 200 || !strings.Contains(res.raw, "Cuenta recuperada") {
		t.Fatal(res.raw)
	}
	h.accountID("formulario@example.org")
	// Caducado: la página lo dice.
	h.do(call{method: "POST", path: "/v1/account/password-reset", body: map[string]any{"email": "formulario@example.org"}, ip: h.nextIP()})
	_, late := h.mailTo("formulario@example.org", "reset_password")
	h.clock.Advance(2 * time.Hour)
	res = h.do(call{method: "POST", path: "/reset", form: "token=" + late + "&new_password=una+nueva+larga&new_password_repeat=una+nueva+larga"})
	if res.status != 400 || !strings.Contains(res.raw, "caducado") {
		t.Fatal(res.raw)
	}
}

func mustBody(t *testing.T, h *harness, email, template string) string {
	t.Helper()
	body, _ := h.mailTo(email, template)
	return body
}

// Cuenta sin verificar purgada a los 7 días en staging (con el reloj); en test, nunca.
func TestUnverifiedAccountsArePurged(t *testing.T) {
	h := newHarness(t, staging)
	unverified := h.register("sinverificar@example.org")
	verified := h.register("verificada@example.org")
	withCharacter := h.register("conpersonaje@example.org")
	sanctioned := h.register("sancionada@example.org")
	_, token := h.mailTo("verificada@example.org", "verify_email")
	h.do(call{method: "POST", path: "/v1/account/verify-email", body: map[string]any{"token": token}})
	h.exec(`insert into characters (world_id, account_id, name, name_key, realm) values (1, $1, 'Aneira', 'aneira', 1)`, withCharacter)
	h.exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', 'acoso', $2, $3)`,
		sanctioned, h.clock.Now(), h.clock.Now().Add(30*24*time.Hour))
	ctx := context.Background()
	h.clock.Advance(6 * 24 * time.Hour)
	if err := h.svc.PurgeDue(ctx); err != nil {
		t.Fatal(err)
	}
	statusOf := func(id int64) string {
		var s string
		h.scalar(&s, `select status from accounts where account_id = $1`, id)
		return s
	}
	if statusOf(unverified) != "active" {
		t.Fatal("a los 6 días, no")
	}
	h.clock.Advance(24*time.Hour + time.Second)
	if err := h.svc.PurgeDue(ctx); err != nil {
		t.Fatal(err)
	}
	if statusOf(unverified) != "purged" || statusOf(verified) != "active" || statusOf(withCharacter) != "active" ||
		statusOf(sanctioned) != "purged" {
		t.Fatalf("purga: %s %s %s %s", statusOf(unverified), statusOf(verified), statusOf(withCharacter), statusOf(sanctioned))
	}
	if !strings.Contains(h.logs.String(), "tiene personajes") {
		t.Fatal("la cuenta con personajes se registra y se deja")
	}
	// El correo de la sancionada queda bloqueado para registrarse hasta 90 días tras el fin.
	var until time.Time
	h.scalar(&until, `select until from sanctioned_email_hashes where hmac = $1`, hmacOf("sancionada@example.org"))
	if want := h.clock.Now().Add(-7*24*time.Hour - time.Second).Add(120 * 24 * time.Hour); !until.Equal(want) {
		t.Fatalf("hasta: %s, no %s", until, want)
	}
	h.do(call{method: "POST", path: "/v1/accounts", body: registerBody("sancionada@example.org", password), ip: h.nextIP()})
	if h.mailCount("sancionada@example.org", "register_blocked") != 1 {
		t.Fatal("registro bloqueado")
	}
	// En test (y dev) las cuentas sin verificar no se purgan.
	plain := newHarness(t)
	id := plain.register("dev@example.org")
	plain.clock.Advance(30 * 24 * time.Hour)
	if err := plain.svc.PurgeDue(ctx); err != nil {
		t.Fatal(err)
	}
	var s string
	plain.scalar(&s, `select status from accounts where account_id = $1`, id)
	if s != "active" {
		t.Fatal(s)
	}
}
