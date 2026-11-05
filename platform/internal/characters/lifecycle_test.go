package characters_test

import (
	"net/http"
	"testing"
	"time"

	"eldmark/platform/internal/persistence"
)

// Delete, restore and the reserved name: a character with more than 24 h of life reserves its name
// 7 days and 30 more.
func TestDeleteRestoreAndReservedName(t *testing.T) {
	h := newHarness(t)
	a := h.newPlayer("a@example.org")
	b := h.newPlayer("b@example.org")
	id := h.mustCreate(a, "Brenna", "vardheim")
	h.advance(2*day, a, b)

	res := h.remove(a, id, "Brena")
	h.expect(res, http.StatusBadRequest, "validation")
	if res.errField("confirm_name") != "mismatch" {
		t.Fatalf("wrong confirmation: %s", res.raw)
	}
	h.expect(h.do(call{method: "DELETE", path: path("/v1/characters/{id}", id), token: a.token, body: map[string]any{}}),
		http.StatusBadRequest, "validation")
	// The confirmation is valid with the same NameRules key.
	res = h.remove(a, id, "BRÉNNA")
	h.expect(res, http.StatusOK, "")
	restoreUntil := h.clock.Now().Add(7 * day)
	if res.body["restore_until"] != float64(restoreUntil.Unix()) {
		t.Fatalf("restore_until: %s", res.raw)
	}
	var reserved time.Time
	h.scalar(&reserved, `select reserved_until from character_names where name_key = 'brenna' and status = 'reserved'
		and character_id = $1`, id)
	if !reserved.Equal(restoreUntil.Add(30 * day)) {
		t.Fatalf("reserved until %v", reserved)
	}
	c := h.list(a).body["characters"].([]any)[0].(map[string]any)
	if c["deleted_at"] != float64(h.clock.Now().Unix()) || c["restore_until"] != float64(restoreUntil.Unix()) {
		t.Errorf("the list shows the deletion with its deadline: %v", c)
	}
	h.expect(h.remove(a, id, "Brenna"), http.StatusNotFound, "not_found") // already deleted
	h.expect(h.enter(a, id), http.StatusNotFound, "not_found")
	if h.count(`select count(*) from auth_events where account_id = $1 and kind = 'character_delete'`, a.id) != 1 {
		t.Error("the character_delete entry is missing")
	}

	// Meanwhile nobody can use the name.
	h.expect(h.create(b, "Brenna", "solmarch"), http.StatusConflict, "name_taken")
	if res := h.nameCheck(b, "brenna"); res.body["code"] != "name_invalid" {
		t.Errorf("lowercase name-check: %s", res.raw)
	}
	if res := h.nameCheck(b, "Brenna"); res.body["code"] != "name_taken" {
		t.Errorf("name-check: %s", res.raw)
	}

	// Restoring within the window: it comes back with its name.
	h.advance(6*day, a, b)
	res = h.restore(a, id)
	h.expect(res, http.StatusOK, "")
	if c := res.character(); c["deleted_at"] != nil || c["restore_until"] != nil || c["name"] != "Brenna" {
		t.Fatalf("restored: %s", res.raw)
	}
	if h.count(`select count(*) from character_names where name_key = 'brenna' and status = 'active'
		and reserved_until is null and character_id = $1`, id) != 1 {
		t.Error("the name is active again")
	}
	h.expect(h.restore(a, id), http.StatusOK, "") // restoring a living one returns it as is

	// Delete again and let the window pass: it can no longer be restored, and the name stays reserved
	// 30 days.
	h.expect(h.remove(a, id, "Brenna"), http.StatusOK, "")
	h.advance(7*day+time.Second, a, b)
	h.expect(h.restore(a, id), http.StatusNotFound, "not_found")
	h.expect(h.create(b, "Brenna", "solmarch"), http.StatusConflict, "name_taken")
	h.advance(30*day, a, b)
	h.expect(h.create(b, "Brenna", "solmarch"), http.StatusCreated, "")
	h.expect(h.restore(a, id), http.StatusNotFound, "not_found")
}

// Creating and deleting right away (less than 24 h of life and less than 1 h played) frees the name
// at restore_until, without the 30 extra days (PL-SEG12).
func TestTrialCharacterFreesTheNameAtRestoreUntil(t *testing.T) {
	h := newHarness(t)
	a := h.newPlayer("a@example.org")
	b := h.newPlayer("b@example.org")
	id := h.mustCreate(a, "Probeta", "vardheim")
	h.expect(h.remove(a, id, "Probeta"), http.StatusOK, "")
	h.advance(7*day-time.Second, a, b)
	h.expect(h.create(b, "Probeta", "solmarch"), http.StatusConflict, "name_taken")
	h.advance(time.Second, a, b)
	res := h.create(b, "Probeta", "solmarch")
	h.expect(res, http.StatusCreated, "")
	// The old one can no longer be restored (and its name belongs to another).
	h.expect(h.restore(a, id), http.StatusNotFound, "not_found")

	// With 1 h played it is not a test character even if it has less than 24 h: 30 extra days.
	other := h.mustCreate(a, "Jugado", "vardheim")
	h.progress.SetSummary(other, persistence.Summary{RaceID: "race_vardheim", Level: 2, PlayedSeconds: 3600})
	h.expect(h.remove(a, other, "Jugado"), http.StatusOK, "")
	var reserved time.Time
	h.scalar(&reserved, `select reserved_until from character_names where name_key = 'jugado'`)
	if !reserved.Equal(h.clock.Now().Add(37 * day)) {
		t.Errorf("with 1 h played, reserved until %v", reserved)
	}
}

// With the character in the world (live lease) it cannot be deleted; and 5 deletions per day at
// most.
func TestDeleteBusyAndDailyLimit(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	var ids []int64
	for i, name := range []string{"Uno", "Dos", "Tres", "Cuatro", "Cinco", "Seis"} {
		if i == 5 {
			h.advance(day, p)
		}
		ids = append(ids, h.mustCreate(p, name, "vardheim"))
	}
	zone := h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")
	h.lease(ids[0], zone, h.clock.Now().Add(20*time.Second))
	res := h.remove(p, ids[0], "Uno")
	h.expect(res, http.StatusConflict, "character_busy")
	if res.errValue("retry_after_s") != 3.0 {
		t.Errorf("retry_after_s: %s", res.raw)
	}
	// An expired or released lease does not count.
	h.advance(21*time.Second, p)
	for i, name := range []string{"Uno", "Dos", "Tres", "Cuatro", "Cinco"} {
		h.expect(h.remove(p, ids[i], name), http.StatusOK, "")
	}
	res = h.remove(p, ids[5], "Seis")
	h.expect(res, http.StatusTooManyRequests, "rate_limited")
	if h.count(`select count(*) from characters where deleted_at is null`) != 1 {
		t.Error("the sixth deletion should not have gone through")
	}
	h.advance(day, p)
	h.expect(h.remove(p, ids[5], "Seis"), http.StatusOK, "")
}

func TestOtherAccountsCharacters(t *testing.T) {
	h := newHarness(t)
	a := h.newPlayer("a@example.org")
	b := h.newPlayer("b@example.org")
	id := h.mustCreate(a, "Aneira", "vardheim")
	h.exec(`update characters set must_rename = true where character_id = $1`, id)
	h.expect(h.remove(b, id, "Aneira"), http.StatusNotFound, "not_found")
	h.expect(h.restore(b, id), http.StatusNotFound, "not_found")
	h.expect(h.enter(b, id), http.StatusNotFound, "not_found")
	h.expect(h.do(call{method: "POST", path: path("/v1/characters/{id}/rename", id), token: b.token,
		body: map[string]any{"name": "Otro"}}), http.StatusNotFound, "not_found")
	if h.count(`select count(*) from characters where character_id = $1 and deleted_at is null and name = 'Aneira'`, id) != 1 {
		t.Error("another account changed the character")
	}
}

// The forced rename: enter gives rename_required, the new name passes the rules and the old one
// stays reserved 30 days.
func TestForcedRename(t *testing.T) {
	h := newHarness(t)
	a := h.newPlayer("a@example.org")
	b := h.newPlayer("b@example.org")
	id := h.mustCreate(a, "Groserio", "vardheim")
	h.mustCreate(b, "Ocupado", "solmarch")
	rename := func(name string) *response {
		return h.do(call{method: "POST", path: path("/v1/characters/{id}/rename", id), token: a.token,
			body: map[string]any{"name": name}})
	}
	h.expect(rename("Nuevo"), http.StatusConflict, "rename_not_required")

	h.exec(`update characters set must_rename = true where character_id = $1`, id)
	h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")
	h.expect(h.enter(a, id), http.StatusConflict, "rename_required")
	if c := h.list(a).body["characters"].([]any)[0].(map[string]any); c["must_rename"] != true {
		t.Errorf("the list says must_rename: %v", c)
	}
	res := rename("nuevo")
	h.expect(res, http.StatusUnprocessableEntity, "name_invalid")
	h.expect(rename("GROSERIO"), http.StatusConflict, "name_taken") // the same name with other capitalization
	h.expect(rename("Ocupado"), http.StatusConflict, "name_taken")
	h.expect(h.do(call{method: "POST", path: path("/v1/characters/{id}/rename", id), token: a.token, body: map[string]any{}}),
		http.StatusBadRequest, "validation")
	res = rename("Educado")
	h.expect(res, http.StatusOK, "")
	if c := res.character(); c["name"] != "Educado" || c["must_rename"] != false {
		t.Fatalf("renamed: %s", res.raw)
	}
	h.expect(rename("Otro"), http.StatusConflict, "rename_not_required")
	h.expect(h.enter(a, id), http.StatusOK, "")
	// The old one, reserved 30 days.
	h.expect(h.create(b, "Groserio", "solmarch"), http.StatusConflict, "name_taken")
	h.advance(30*day+time.Second, b)
	h.expect(h.create(b, "Groserio", "solmarch"), http.StatusCreated, "")
}

// Renaming with the character in the world: character_busy.
func TestRenameWhileInTheWorld(t *testing.T) {
	h := newHarness(t)
	a := h.newPlayer("a@example.org")
	id := h.mustCreate(a, "Groserio", "vardheim")
	h.exec(`update characters set must_rename = true where character_id = $1`, id)
	zone := h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")
	h.lease(id, zone, h.clock.Now().Add(30*time.Second))
	h.expect(h.do(call{method: "POST", path: path("/v1/characters/{id}/rename", id), token: a.token,
		body: map[string]any{"name": "Educado"}}), http.StatusConflict, "character_busy")
}
