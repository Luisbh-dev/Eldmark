package characters_test

import (
	"encoding/base64"
	"net/http"
	"strconv"
	"testing"
	"time"

	"eldmark/platform/internal/config"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/tickets"
)

func TestEnterWithoutLiveZone(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Aneira", "vardheim")
	res := h.enter(p, id)
	h.expect(res, http.StatusServiceUnavailable, "zone_unavailable")
	if res.header.Get("Retry-After") == "" {
		t.Error("503 sin Retry-After")
	}
	// Instancias que no valen: arrancando, perdida, llena o que no admite el reino.
	h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "starting")
	h.zone("vado_gris", 1, []int16{1, 2}, 0, 64, "lost")
	h.zone("vado_gris", 2, []int16{1, 2}, 64, 64, "live")
	h.zone("vado_gris", 3, []int16{2}, 0, 64, "live")
	h.zone("otra_zona", 0, []int16{1, 2}, 0, 64, "live")
	h.expect(h.enter(p, id), http.StatusServiceUnavailable, "zone_unavailable")
	if h.count(`select count(*) from enter_tickets`) != 0 {
		t.Error("un enter fallido dejó un billete")
	}
}

// enter emite el billete de §5.1: firmado con la clave de ELDMARK_TICKET_SIGN_KEY, con el mundo, el
// personaje, la huella de la zona, el canal y el reino, y 10 s de vida; y lo guarda en enter_tickets.
func TestEnterIssuesTheTicket(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Aneira", "vardheim")
	instance := h.zone("vado_gris", 0, []int16{1, 2}, 3, 64, "live")
	res := h.enter(p, id)
	h.expect(res, http.StatusOK, "")
	zone := res.body["zone"].(map[string]any)
	if zone["zone_id"] != "vado_gris" || zone["channel"] != 0.0 || zone["host"] != "203.0.113.5" || zone["port"] != 24600.0 ||
		zone["dtls"] != nil {
		t.Fatalf("zona: %s", res.raw)
	}
	character := res.body["character"].(map[string]any)
	if character["character_id"] != strconv.FormatInt(id, 10) || character["name"] != "Aneira" || character["realm"] != "vardheim" ||
		res.body["expires_in_s"] != 10.0 {
		t.Fatalf("personaje: %s", res.raw)
	}
	raw, err := base64.StdEncoding.DecodeString(res.body["ticket"].(string))
	if err != nil || len(raw) != tickets.Size {
		t.Fatalf("billete: %v %d", err, len(raw))
	}
	tk, err := tickets.Parse(raw, map[uint8][]byte{1: ticketKey})
	if err != nil {
		t.Fatal(err)
	}
	now := uint32(h.clock.Now().Unix())
	if tk.Version != 1 || tk.KeyID != 1 || tk.WorldID != 1 || tk.CharacterID != uint64(id) ||
		tk.ZoneKey != tickets.ZoneKey("vado_gris") || tk.Channel != 0 || tk.Realm != 1 || tk.Arrival != 0 ||
		tk.Flags != tickets.FlagFromMenu || tk.IssuedAt != now || tk.ExpiresAt != now+10 || tk.TicketID == 0 ||
		tk.TicketID>>63 != 0 {
		t.Fatalf("campos del billete: %+v", tk)
	}
	var sessionOK bool
	var expires time.Time
	h.scalar(&sessionOK, `select t.session_id = s.session_id from enter_tickets t join sessions s using (session_id)
		where t.ticket_id = $1 and t.character_id = $2 and t.world_id = 1 and t.zone_instance_id = $3
		  and t.consumed_at is null and s.revoked_at is null`, int64(tk.TicketID), id, instance)
	h.scalar(&expires, `select expires_at from enter_tickets where ticket_id = $1`, int64(tk.TicketID))
	if !sessionOK || !expires.Equal(h.clock.Now().Add(10*time.Second)) {
		t.Fatalf("fila de enter_tickets: %v %v", sessionOK, expires)
	}
	// Otro enter da otro billete.
	again := h.enter(p, id)
	h.expect(again, http.StatusOK, "")
	if again.body["ticket"] == res.body["ticket"] || h.count(`select count(*) from enter_tickets`) != 2 {
		t.Error("dos enter, dos billetes")
	}
	// Con DTLS, el certificado de la zona.
	h.exec(`update zone_instances set dtls_cert_pem = '-----BEGIN CERTIFICATE-----x', dtls_name = 'vado-gris.eldmark'`)
	res = h.enter(p, id)
	dtls, _ := res.body["zone"].(map[string]any)["dtls"].(map[string]any)
	if dtls["cert_pem"] != "-----BEGIN CERTIFICATE-----x" || dtls["name"] != "vado-gris.eldmark" {
		t.Errorf("dtls: %s", res.raw)
	}
}

// enter elige la última zona si tiene una instancia viva que admite el reino (en su último canal
// si está vivo y con sitio); si no, la de entrada; y dentro de la zona, el canal con menos
// jugadores.
func TestEnterChoosesTheZone(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Aneira", "vardheim")
	h.zone("vado_gris", 0, []int16{1, 2}, 10, 64, "live")
	h.zone("vado_gris", 1, []int16{1, 2}, 3, 64, "live")
	h.zone("eldrun", 0, []int16{1, 2, 3}, 1, 64, "live")
	h.zone("eldrun", 1, []int16{1, 2, 3}, 5, 64, "live")
	zoneOf := func() (string, float64) {
		t.Helper()
		res := h.enter(p, id)
		if res.status != http.StatusOK {
			t.Fatalf("enter: %d %s", res.status, res.raw)
		}
		z := res.body["zone"].(map[string]any)
		return z["zone_id"].(string), z["channel"].(float64)
	}
	// Nunca ha entrado: la zona de entrada de su reino, en el canal con menos jugadores.
	if zone, ch := zoneOf(); zone != "vado_gris" || ch != 1 {
		t.Fatalf("sin última zona: %s %v", zone, ch)
	}
	// Su última zona, en su último canal aunque tenga más jugadores.
	h.progress.SetSummary(id, persistence.Summary{RaceID: "race_vardheim", Level: 3, LastZoneID: "eldrun", LastChannel: 1})
	if zone, ch := zoneOf(); zone != "eldrun" || ch != 1 {
		t.Fatalf("última zona y canal: %s %v", zone, ch)
	}
	// El último canal lleno: otro canal de la misma zona.
	h.exec(`update zone_instances set players = max_players where zone_id = 'eldrun' and channel = 1`)
	if zone, ch := zoneOf(); zone != "eldrun" || ch != 0 {
		t.Fatalf("último canal lleno: %s %v", zone, ch)
	}
	// La última zona ya no admite su reino: la de entrada.
	h.exec(`update zone_instances set realms = '{2,3}' where zone_id = 'eldrun'`)
	if zone, _ := zoneOf(); zone != "vado_gris" {
		t.Fatalf("la última zona no admite el reino: %s", zone)
	}
	// La última zona sin instancias vivas: la de entrada.
	h.exec(`update zone_instances set realms = '{1,2,3}', status = 'stopped' where zone_id = 'eldrun'`)
	if zone, _ := zoneOf(); zone != "vado_gris" {
		t.Fatalf("la última zona parada: %s", zone)
	}
	// La zona de entrada sin nada vivo: 503.
	h.exec(`update zone_instances set status = 'stopped'`)
	h.advance(time.Minute, p) // el límite de 10 enter por minuto
	h.expect(h.enter(p, id), http.StatusServiceUnavailable, "zone_unavailable")
}

// Las comprobaciones de enter, en el orden de §4.5.
func TestEnterChecks(t *testing.T) {
	h := newHarness(t, func(c *config.Config) { c.RequireVerifiedEmail = true })
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Aneira", "vardheim")
	h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")

	// Correo sin verificar (ELDMARK_REQUIRE_VERIFIED_EMAIL).
	h.expect(h.enter(p, id), http.StatusForbidden, "email_unverified")
	h.exec(`update accounts set email_verified_at = $2 where account_id = $1`, p.id, h.clock.Now())
	h.expect(h.enter(p, id), http.StatusOK, "")

	// Un texto nuevo por aceptar: terms_required con los documentos (antes que el correo).
	h.exec(`update accounts set email_verified_at = null where account_id = $1`, p.id)
	h.exec(`delete from legal_acceptances where account_id = $1 and kind = 'rules'`, p.id)
	res := h.enter(p, id)
	h.expect(res, http.StatusForbidden, "terms_required")
	if docs, _ := res.errValue("documents").([]any); len(docs) != 1 || docs[0] != "rules" {
		t.Errorf("documents: %s", res.raw)
	}
	h.exec(`insert into legal_acceptances (account_id, kind, version) values ($1, 'rules', 1)`, p.id)
	h.exec(`update accounts set email_verified_at = $2 where account_id = $1`, p.id, h.clock.Now())

	// Borrado pendiente: 403 (iniciar sesión sí funciona, para cancelarlo).
	h.expect(h.do(call{method: "POST", path: "/v1/account/deletion", token: p.token, body: map[string]any{"password": password}}),
		http.StatusAccepted, "")
	res = h.enter(p, id)
	h.expect(res, http.StatusForbidden, "account_pending_deletion")
	if res.errValue("deletion_at") != float64(h.clock.Now().Add(14*day).Unix()) {
		t.Errorf("deletion_at: %s", res.raw)
	}
	h.expect(h.do(call{method: "DELETE", path: "/v1/account/deletion", token: p.token}), http.StatusNoContent, "")

	// Mantenimiento del mundo: 503 salvo para admin.
	h.exec(`update worlds set status = 'maintenance' where world_id = 1`)
	h.expect(h.enter(p, id), http.StatusServiceUnavailable, "maintenance")
	h.exec(`update accounts set role = 'admin' where account_id = $1`, p.id)
	h.expect(h.enter(p, id), http.StatusOK, "")
	h.exec(`update accounts set role = 'player' where account_id = $1`, p.id)
	h.exec(`update worlds set status = 'open' where world_id = 1`)

	// Un personaje borrado: 404.
	other := h.mustCreate(p, "Brenna", "vardheim")
	h.expect(h.remove(p, other, "Brenna"), http.StatusOK, "")
	h.expect(h.enter(p, other), http.StatusNotFound, "not_found")

	// El límite de 10 por minuto y cuenta, con el cubo lleno otra vez.
	h.advance(time.Minute, p)
	for range 10 {
		h.expect(h.enter(p, id), http.StatusOK, "")
	}
	h.expect(h.enter(p, id), http.StatusTooManyRequests, "rate_limited")
}

// Un solo personaje en el mundo por cuenta: con otro de la cuenta arrendado, character_busy.
func TestOneCharacterInTheWorldPerAccount(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	first := h.mustCreate(p, "Aneira", "vardheim")
	second := h.mustCreate(p, "Brenna", "vardheim")
	zone := h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")
	h.lease(first, zone, h.clock.Now().Add(30*time.Second))
	for _, id := range []int64{first, second} {
		res := h.enter(p, id)
		h.expect(res, http.StatusConflict, "character_busy")
		if res.errValue("retry_after_s") != 3.0 {
			t.Errorf("retry_after_s: %s", res.raw)
		}
	}
	// Liberado (zone_instance_id a null) o caducado, ya no cuenta.
	h.exec(`update character_leases set zone_instance_id = null where character_id = $1`, first)
	h.expect(h.enter(p, second), http.StatusOK, "")
	h.lease(first, zone, h.clock.Now().Add(30*time.Second))
	h.expect(h.enter(p, second), http.StatusConflict, "character_busy")
	h.advance(31*time.Second, p)
	h.expect(h.enter(p, second), http.StatusOK, "")
	// El arrendamiento de otra cuenta no molesta.
	q := h.newPlayer("otra@example.org")
	other := h.mustCreate(q, "Corvo", "vardheim")
	h.lease(other, zone, h.clock.Now().Add(30*time.Second))
	h.expect(h.enter(p, first), http.StatusOK, "")
}
