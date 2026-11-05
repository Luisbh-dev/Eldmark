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
		t.Error("503 without Retry-After")
	}
	// Instances that are not valid: starting, lost, full or not admitting the realm.
	h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "starting")
	h.zone("vado_gris", 1, []int16{1, 2}, 0, 64, "lost")
	h.zone("vado_gris", 2, []int16{1, 2}, 64, 64, "live")
	h.zone("vado_gris", 3, []int16{2}, 0, 64, "live")
	h.zone("otra_zona", 0, []int16{1, 2}, 0, 64, "live")
	h.expect(h.enter(p, id), http.StatusServiceUnavailable, "zone_unavailable")
	if h.count(`select count(*) from enter_tickets`) != 0 {
		t.Error("a failed enter left a ticket")
	}
}

// enter issues the §5.1 ticket: signed with the ELDMARK_TICKET_SIGN_KEY key, with the world, the
// character, the zone fingerprint, the channel and the realm, and 10 s of life; and stores it in
// enter_tickets.
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
		t.Fatalf("zone: %s", res.raw)
	}
	character := res.body["character"].(map[string]any)
	if character["character_id"] != strconv.FormatInt(id, 10) || character["name"] != "Aneira" || character["realm"] != "vardheim" ||
		res.body["expires_in_s"] != 10.0 {
		t.Fatalf("character: %s", res.raw)
	}
	raw, err := base64.StdEncoding.DecodeString(res.body["ticket"].(string))
	if err != nil || len(raw) != tickets.Size {
		t.Fatalf("ticket: %v %d", err, len(raw))
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
		t.Fatalf("ticket fields: %+v", tk)
	}
	var sessionOK bool
	var expires time.Time
	h.scalar(&sessionOK, `select t.session_id = s.session_id from enter_tickets t join sessions s using (session_id)
		where t.ticket_id = $1 and t.character_id = $2 and t.world_id = 1 and t.zone_instance_id = $3
		  and t.consumed_at is null and s.revoked_at is null`, int64(tk.TicketID), id, instance)
	h.scalar(&expires, `select expires_at from enter_tickets where ticket_id = $1`, int64(tk.TicketID))
	if !sessionOK || !expires.Equal(h.clock.Now().Add(10*time.Second)) {
		t.Fatalf("enter_tickets row: %v %v", sessionOK, expires)
	}
	// Another enter gives another ticket.
	again := h.enter(p, id)
	h.expect(again, http.StatusOK, "")
	if again.body["ticket"] == res.body["ticket"] || h.count(`select count(*) from enter_tickets`) != 2 {
		t.Error("two enters, two tickets")
	}
	// With DTLS, the zone's certificate.
	h.exec(`update zone_instances set dtls_cert_pem = '-----BEGIN CERTIFICATE-----x', dtls_name = 'vado-gris.eldmark'`)
	res = h.enter(p, id)
	dtls, _ := res.body["zone"].(map[string]any)["dtls"].(map[string]any)
	if dtls["cert_pem"] != "-----BEGIN CERTIFICATE-----x" || dtls["name"] != "vado-gris.eldmark" {
		t.Errorf("dtls: %s", res.raw)
	}
}

// enter picks the last zone if it has a live instance that admits the realm (in its last channel if
// alive and with room); otherwise, the entry one; and within the zone, the channel with the fewest
// players.
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
	// Never entered: its realm's entry zone, in the channel with the fewest players.
	if zone, ch := zoneOf(); zone != "vado_gris" || ch != 1 {
		t.Fatalf("no last zone: %s %v", zone, ch)
	}
	// Its last zone, in its last channel even if it has more players.
	h.progress.SetSummary(id, persistence.Summary{RaceID: "race_vardheim", Level: 3, LastZoneID: "eldrun", LastChannel: 1})
	if zone, ch := zoneOf(); zone != "eldrun" || ch != 1 {
		t.Fatalf("last zone and channel: %s %v", zone, ch)
	}
	// The last channel full: another channel of the same zone.
	h.exec(`update zone_instances set players = max_players where zone_id = 'eldrun' and channel = 1`)
	if zone, ch := zoneOf(); zone != "eldrun" || ch != 0 {
		t.Fatalf("last channel full: %s %v", zone, ch)
	}
	// The last zone no longer admits its realm: the entry one.
	h.exec(`update zone_instances set realms = '{2,3}' where zone_id = 'eldrun'`)
	if zone, _ := zoneOf(); zone != "vado_gris" {
		t.Fatalf("the last zone does not admit the realm: %s", zone)
	}
	// The last zone without live instances: the entry one.
	h.exec(`update zone_instances set realms = '{1,2,3}', status = 'stopped' where zone_id = 'eldrun'`)
	if zone, _ := zoneOf(); zone != "vado_gris" {
		t.Fatalf("the last zone stopped: %s", zone)
	}
	// The entry zone with nothing alive: 503.
	h.exec(`update zone_instances set status = 'stopped'`)
	h.advance(time.Minute, p) // the limit of 10 enters per minute
	h.expect(h.enter(p, id), http.StatusServiceUnavailable, "zone_unavailable")
}

// The enter checks, in the order of §4.5.
func TestEnterChecks(t *testing.T) {
	h := newHarness(t, func(c *config.Config) { c.RequireVerifiedEmail = true })
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Aneira", "vardheim")
	h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")

	// Unverified email (ELDMARK_REQUIRE_VERIFIED_EMAIL).
	h.expect(h.enter(p, id), http.StatusForbidden, "email_unverified")
	h.exec(`update accounts set email_verified_at = $2 where account_id = $1`, p.id, h.clock.Now())
	h.expect(h.enter(p, id), http.StatusOK, "")

	// A new text to accept: terms_required with the documents (before the email).
	h.exec(`update accounts set email_verified_at = null where account_id = $1`, p.id)
	h.exec(`delete from legal_acceptances where account_id = $1 and kind = 'rules'`, p.id)
	res := h.enter(p, id)
	h.expect(res, http.StatusForbidden, "terms_required")
	if docs, _ := res.errValue("documents").([]any); len(docs) != 1 || docs[0] != "rules" {
		t.Errorf("documents: %s", res.raw)
	}
	h.exec(`insert into legal_acceptances (account_id, kind, version) values ($1, 'rules', 1)`, p.id)
	h.exec(`update accounts set email_verified_at = $2 where account_id = $1`, p.id, h.clock.Now())

	// Pending deletion: 403 (logging in does work, to cancel it).
	h.expect(h.do(call{method: "POST", path: "/v1/account/deletion", token: p.token, body: map[string]any{"password": password}}),
		http.StatusAccepted, "")
	res = h.enter(p, id)
	h.expect(res, http.StatusForbidden, "account_pending_deletion")
	if res.errValue("deletion_at") != float64(h.clock.Now().Add(14*day).Unix()) {
		t.Errorf("deletion_at: %s", res.raw)
	}
	h.expect(h.do(call{method: "DELETE", path: "/v1/account/deletion", token: p.token}), http.StatusNoContent, "")

	// World maintenance: 503 except for admin.
	h.exec(`update worlds set status = 'maintenance' where world_id = 1`)
	h.expect(h.enter(p, id), http.StatusServiceUnavailable, "maintenance")
	h.exec(`update accounts set role = 'admin' where account_id = $1`, p.id)
	h.expect(h.enter(p, id), http.StatusOK, "")
	h.exec(`update accounts set role = 'player' where account_id = $1`, p.id)
	h.exec(`update worlds set status = 'open' where world_id = 1`)

	// A deleted character: 404.
	other := h.mustCreate(p, "Brenna", "vardheim")
	h.expect(h.remove(p, other, "Brenna"), http.StatusOK, "")
	h.expect(h.enter(p, other), http.StatusNotFound, "not_found")

	// The limit of 10 per minute per account, with the bucket full again.
	h.advance(time.Minute, p)
	for range 10 {
		h.expect(h.enter(p, id), http.StatusOK, "")
	}
	h.expect(h.enter(p, id), http.StatusTooManyRequests, "rate_limited")
}

// A single character in the world per account: with another of the account leased, character_busy.
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
	// Released (zone_instance_id to null) or expired, it no longer counts.
	h.exec(`update character_leases set zone_instance_id = null where character_id = $1`, first)
	h.expect(h.enter(p, second), http.StatusOK, "")
	h.lease(first, zone, h.clock.Now().Add(30*time.Second))
	h.expect(h.enter(p, second), http.StatusConflict, "character_busy")
	h.advance(31*time.Second, p)
	h.expect(h.enter(p, second), http.StatusOK, "")
	// Another account's lease does not interfere.
	q := h.newPlayer("otra@example.org")
	other := h.mustCreate(q, "Corvo", "vardheim")
	h.lease(other, zone, h.clock.Now().Add(30*time.Second))
	h.expect(h.enter(p, first), http.StatusOK, "")
}
