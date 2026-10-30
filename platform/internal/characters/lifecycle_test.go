package characters_test

import (
	"net/http"
	"testing"
	"time"

	"eldmark/platform/internal/persistence"
)

// Borrar, restaurar y el nombre reservado: un personaje con más de 24 h de vida reserva su nombre
// 7 días y 30 más.
func TestDeleteRestoreAndReservedName(t *testing.T) {
	h := newHarness(t)
	a := h.newPlayer("a@example.org")
	b := h.newPlayer("b@example.org")
	id := h.mustCreate(a, "Brenna", "vardheim")
	h.advance(2*day, a, b)

	res := h.remove(a, id, "Brena")
	h.expect(res, http.StatusBadRequest, "validation")
	if res.errField("confirm_name") != "mismatch" {
		t.Fatalf("confirmación equivocada: %s", res.raw)
	}
	h.expect(h.do(call{method: "DELETE", path: path("/v1/characters/{id}", id), token: a.token, body: map[string]any{}}),
		http.StatusBadRequest, "validation")
	// La confirmación vale con la misma clave de NameRules.
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
		t.Fatalf("reservado hasta %v", reserved)
	}
	c := h.list(a).body["characters"].([]any)[0].(map[string]any)
	if c["deleted_at"] != float64(h.clock.Now().Unix()) || c["restore_until"] != float64(restoreUntil.Unix()) {
		t.Errorf("la lista enseña el borrado con su fecha límite: %v", c)
	}
	h.expect(h.remove(a, id, "Brenna"), http.StatusNotFound, "not_found") // ya borrado
	h.expect(h.enter(a, id), http.StatusNotFound, "not_found")
	if h.count(`select count(*) from auth_events where account_id = $1 and kind = 'character_delete'`, a.id) != 1 {
		t.Error("falta el apunte character_delete")
	}

	// Mientras tanto nadie puede usar el nombre.
	h.expect(h.create(b, "Brenna", "solmarch"), http.StatusConflict, "name_taken")
	if res := h.nameCheck(b, "brenna"); res.body["code"] != "name_invalid" {
		t.Errorf("name-check en minúscula: %s", res.raw)
	}
	if res := h.nameCheck(b, "Brenna"); res.body["code"] != "name_taken" {
		t.Errorf("name-check: %s", res.raw)
	}

	// Restaurar en plazo: vuelve con su nombre.
	h.advance(6*day, a, b)
	res = h.restore(a, id)
	h.expect(res, http.StatusOK, "")
	if c := res.character(); c["deleted_at"] != nil || c["restore_until"] != nil || c["name"] != "Brenna" {
		t.Fatalf("restaurado: %s", res.raw)
	}
	if h.count(`select count(*) from character_names where name_key = 'brenna' and status = 'active'
		and reserved_until is null and character_id = $1`, id) != 1 {
		t.Error("el nombre vuelve a estar activo")
	}
	h.expect(h.restore(a, id), http.StatusOK, "") // restaurar uno vivo lo devuelve tal cual

	// Borrar otra vez y dejar pasar el plazo: ya no se restaura, y el nombre sigue reservado 30 días.
	h.expect(h.remove(a, id, "Brenna"), http.StatusOK, "")
	h.advance(7*day+time.Second, a, b)
	h.expect(h.restore(a, id), http.StatusNotFound, "not_found")
	h.expect(h.create(b, "Brenna", "solmarch"), http.StatusConflict, "name_taken")
	h.advance(30*day, a, b)
	h.expect(h.create(b, "Brenna", "solmarch"), http.StatusCreated, "")
	h.expect(h.restore(a, id), http.StatusNotFound, "not_found")
}

// Crear y borrar enseguida (menos de 24 h de vida y menos de 1 h jugada) libera el nombre en
// restore_until, sin los 30 días más (PL-SEG12).
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
	// El viejo ya no se puede restaurar (y su nombre es de otro).
	h.expect(h.restore(a, id), http.StatusNotFound, "not_found")

	// Con 1 h jugada no es de prueba aunque tenga menos de 24 h: 30 días más.
	other := h.mustCreate(a, "Jugado", "vardheim")
	h.progress.SetSummary(other, persistence.Summary{RaceID: "race_vardheim", Level: 2, PlayedSeconds: 3600})
	h.expect(h.remove(a, other, "Jugado"), http.StatusOK, "")
	var reserved time.Time
	h.scalar(&reserved, `select reserved_until from character_names where name_key = 'jugado'`)
	if !reserved.Equal(h.clock.Now().Add(37 * day)) {
		t.Errorf("con 1 h jugada, reservado hasta %v", reserved)
	}
}

// Con el personaje en el mundo (arrendamiento vivo) no se borra; y 5 borrados al día como mucho.
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
	// Un arrendamiento caducado o liberado no cuenta.
	h.advance(21*time.Second, p)
	for i, name := range []string{"Uno", "Dos", "Tres", "Cuatro", "Cinco"} {
		h.expect(h.remove(p, ids[i], name), http.StatusOK, "")
	}
	res = h.remove(p, ids[5], "Seis")
	h.expect(res, http.StatusTooManyRequests, "rate_limited")
	if h.count(`select count(*) from characters where deleted_at is null`) != 1 {
		t.Error("el sexto borrado no debería haberse hecho")
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
		t.Error("otra cuenta ha cambiado el personaje")
	}
}

// El renombrado forzado: enter da rename_required, el nombre nuevo pasa las reglas y el viejo
// queda reservado 30 días.
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
		t.Errorf("la lista dice must_rename: %v", c)
	}
	res := rename("nuevo")
	h.expect(res, http.StatusUnprocessableEntity, "name_invalid")
	h.expect(rename("GROSERIO"), http.StatusConflict, "name_taken") // el mismo nombre con otras mayúsculas
	h.expect(rename("Ocupado"), http.StatusConflict, "name_taken")
	h.expect(h.do(call{method: "POST", path: path("/v1/characters/{id}/rename", id), token: a.token, body: map[string]any{}}),
		http.StatusBadRequest, "validation")
	res = rename("Educado")
	h.expect(res, http.StatusOK, "")
	if c := res.character(); c["name"] != "Educado" || c["must_rename"] != false {
		t.Fatalf("renombrado: %s", res.raw)
	}
	h.expect(rename("Otro"), http.StatusConflict, "rename_not_required")
	h.expect(h.enter(a, id), http.StatusOK, "")
	// El viejo, reservado 30 días.
	h.expect(h.create(b, "Groserio", "solmarch"), http.StatusConflict, "name_taken")
	h.advance(30*day+time.Second, b)
	h.expect(h.create(b, "Groserio", "solmarch"), http.StatusCreated, "")
}

// Renombrar con el personaje en el mundo: character_busy.
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
