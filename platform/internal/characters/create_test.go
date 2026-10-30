package characters_test

import (
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"
)

func TestCreateAndList(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	res := h.create(p, "Aneira", "vardheim")
	h.expect(res, http.StatusCreated, "")
	c := res.character()
	id := idOf(t, c)
	if c["name"] != "Aneira" || c["realm"] != "vardheim" || c["race_id"] != "race_vardheim" || c["appearance"] != appearance ||
		c["level"] != 1.0 || c["last_zone_id"] != nil || c["played_seconds"] != 0.0 || c["must_rename"] != false ||
		c["deleted_at"] != nil || c["restore_until"] != nil || c["created_at"] != float64(h.clock.Now().Unix()) {
		t.Fatalf("personaje creado: %v", c)
	}
	list := h.list(p)
	if list.body["realm"] != "vardheim" || list.body["unlock_at"] != nil || list.body["slots"] != 6.0 || list.body["used"] != 1.0 {
		t.Fatalf("lista: %s", list.raw)
	}
	chars := list.body["characters"].([]any)
	if len(chars) != 1 || chars[0].(map[string]any)["name"] != "Aneira" {
		t.Fatalf("lista: %s", list.raw)
	}
	// La identidad en la base, la clave del nombre, el reino de la cuenta y el apunte del límite.
	if h.count(`select count(*) from characters where character_id = $1 and name_key = 'aneira' and realm = 1
		and account_id = $2`, id, p.id) != 1 ||
		h.count(`select count(*) from character_names where world_id = 1 and name_key = 'aneira' and status = 'active'
		and character_id = $1`, id) != 1 ||
		h.count(`select count(*) from account_realms where account_id = $1 and world_id = 1 and realm = 1`, p.id) != 1 ||
		h.count(`select count(*) from character_pvp_stats where character_id = $1`, id) != 1 ||
		h.count(`select count(*) from auth_events where account_id = $1 and kind = 'character_create'`, p.id) != 1 {
		t.Fatal("faltan filas de la creación")
	}
	if !h.progress.Has(id) {
		t.Error("ProgressStore.Create no se llamó")
	}
	account := h.do(call{method: "GET", path: "/v1/account", token: p.token})
	if realms, _ := account.body["realms"].(map[string]any); realms["1"] != "vardheim" {
		t.Errorf("GET /v1/account: %s", account.raw)
	}
	// Otra cuenta no ve los personajes de esta.
	other := h.newPlayer("otra@example.org")
	if l := h.list(other); l.body["used"] != 0.0 || l.body["realm"] != nil {
		t.Errorf("lista de otra cuenta: %s", l.raw)
	}
}

func TestUnknownWorldAndBadIDs(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	for _, path := range []string{"/v1/worlds/9/characters", "/v1/worlds/abc/characters", "/v1/worlds/0/characters",
		"/v1/worlds/9/name-check?name=Ana"} {
		h.expect(h.do(call{method: "GET", path: path, token: p.token}), http.StatusNotFound, "not_found")
	}
	h.expect(h.do(call{method: "POST", path: "/v1/worlds/9/characters", token: p.token, body: createBody("Ana", "vardheim")}),
		http.StatusNotFound, "not_found")
	for _, path := range []string{"/v1/characters/abc/enter", "/v1/characters/0/enter", "/v1/characters/-1/enter",
		"/v1/characters/99999/enter"} {
		h.expect(h.do(call{method: "POST", path: path, token: p.token}), http.StatusNotFound, "not_found")
	}
	// Sin sesión, 401; sin protocolo… (lo prueba accounts).
	h.expect(h.do(call{method: "GET", path: "/v1/worlds/1/characters"}), http.StatusUnauthorized, "unauthorized")
}

// «Anéira» frente a «ANEIRA» y «Aneira»: el mismo nombre por tildes y mayúsculas (SOC-13).
func TestNameCollisionsByAccentAndCase(t *testing.T) {
	h := newHarness(t)
	a := h.newPlayer("a@example.org")
	b := h.newPlayer("b@example.org")
	h.mustCreate(a, "Anéira", "vardheim")
	for _, name := range []string{"ANEIRA", "Aneira", "AnEiRá", "Anéira"} {
		h.expect(h.create(b, name, "solmarch"), http.StatusConflict, "name_taken")
		res := h.nameCheck(b, name)
		if res.status != 200 || res.body["available"] != false || res.body["code"] != "name_taken" || res.body["reason"] != "" {
			t.Errorf("name-check %s: %s", name, res.raw)
		}
	}
	// La misma cuenta tampoco.
	h.expect(h.create(a, "Aneira", "vardheim"), http.StatusConflict, "name_taken")
	res := h.nameCheck(b, "Bruno")
	if res.body["available"] != true || res.body["code"] != "" {
		t.Errorf("name-check libre: %s", res.raw)
	}
	h.mustCreate(b, "Bruno", "solmarch")
}

// Dos creaciones a la vez con el mismo nombre: una gana y las demás reciben name_taken, nunca un
// 500 (SOC-13).
func TestConcurrentCreationsWithTheSameName(t *testing.T) {
	h := newHarness(t)
	const n = 8
	players := make([]*player, n)
	for i := range players {
		players[i] = h.newPlayer(fmt.Sprintf("p%d@example.org", i))
	}
	for round, name := range []string{"Concurrente", "Simultanea", "Carrera"} {
		var wg sync.WaitGroup
		results := make([]*response, n)
		start := make(chan struct{})
		for i := range players {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				results[i] = h.create(players[i], name, "vardheim")
			}()
		}
		close(start)
		wg.Wait()
		created := 0
		for _, res := range results {
			switch {
			case res.status == http.StatusCreated:
				created++
			case res.status == http.StatusConflict && res.errCode() == "name_taken":
			default:
				t.Fatalf("ronda %d: %d %s", round, res.status, res.raw)
			}
		}
		if created != 1 {
			t.Fatalf("ronda %d (%s): %d creaciones", round, name, created)
		}
		if h.count(`select count(*) from characters where name_key = lower($1)`, name) != 1 {
			t.Fatalf("ronda %d: más de una fila en characters", round)
		}
	}
}

func TestNameInvalidAndBlacklist(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	cases := map[string]string{"ana": "not_capitalized", "Al": "too_short", "Ana Bo": "has_space", "Ana1": "has_digit",
		"Ana-Bo": "invalid_character", "Abcdefghijklmnopq": "too_long", "Admin": "reserved", "CAPITÁN": "reserved"}
	for name, reason := range cases {
		res := h.create(p, name, "vardheim")
		h.expect(res, http.StatusUnprocessableEntity, "name_invalid")
		if res.errValue("reason") != reason || res.errValue("message") == "" {
			t.Errorf("%s: %s", name, res.raw)
		}
		check := h.nameCheck(p, name)
		if check.body["available"] != false || check.body["code"] != "name_invalid" || check.body["reason"] != reason {
			t.Errorf("name-check %s: %s", name, check.raw)
		}
	}
	// La lista negra (la edita admin names block, P7a) se compara con la clave.
	h.exec(`insert into name_blacklist (name_key, reason) values ('malnombre', 'ofensivo')`)
	for _, name := range []string{"Malnombre", "MALNOMBRE", "Málnombre"} {
		res := h.create(p, name, "vardheim")
		h.expect(res, http.StatusUnprocessableEntity, "name_invalid")
		if res.errValue("reason") != "reserved" {
			t.Errorf("%s: %s", name, res.raw)
		}
	}
	// Ninguno gastó el límite diario ni dejó filas.
	if h.count(`select count(*) from characters`) != 0 || h.count(`select count(*) from character_names`) != 0 {
		t.Error("una creación rechazada dejó filas")
	}
	h.mustCreate(p, "Valido", "vardheim")
	// name-check sin nombre: 400.
	h.expect(h.do(call{method: "GET", path: "/v1/worlds/1/name-check", token: p.token}), http.StatusBadRequest, "validation")
}

func TestRealmLockedClosedAndUnlocked(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Aneira", "vardheim")
	res := h.create(p, "Brenna", "solmarch")
	h.expect(res, http.StatusConflict, "realm_locked")
	if res.errValue("realm") != "vardheim" || res.errValue("unlock_at") != nil || res.errValue("message") != "Tu cuenta es de Vardheim" {
		t.Fatalf("realm_locked: %s", res.raw)
	}
	h.expect(h.create(p, "Brenna", "askarra"), http.StatusConflict, "realm_closed")
	res = h.create(p, "Brenna", "elfos")
	h.expect(res, http.StatusBadRequest, "validation")
	if res.errField("realm") != "invalid" {
		t.Errorf("reino desconocido: %s", res.raw)
	}
	// Borrar el último vivo: el reino se libera a los 30 días.
	h.expect(h.remove(p, id, "aneira"), http.StatusOK, "")
	res = h.create(p, "Brenna", "solmarch")
	h.expect(res, http.StatusConflict, "realm_locked")
	unlock := h.clock.Now().Add(30 * day).Unix()
	if res.errValue("unlock_at") != float64(unlock) {
		t.Fatalf("unlock_at: %s (se esperaba %d)", res.raw, unlock)
	}
	if l := h.list(p); l.body["unlock_at"] != float64(unlock) {
		t.Errorf("la lista dice unlock_at: %s", l.raw)
	}
	// Otro de Vardheim sí se puede crear, y deja de estar por liberarse.
	h.advance(day, p)
	other := h.mustCreate(p, "Corvo", "vardheim")
	if l := h.list(p); l.body["unlock_at"] != nil || l.body["realm"] != "vardheim" {
		t.Errorf("con un vivo, el reino no se libera: %s", l.raw)
	}
	h.expect(h.remove(p, other, "Corvo"), http.StatusOK, "")
	h.advance(30*day-time.Second, p)
	h.expect(h.create(p, "Brenna", "solmarch"), http.StatusConflict, "realm_locked")
	h.advance(time.Second, p)
	res = h.create(p, "Brenna", "solmarch")
	h.expect(res, http.StatusCreated, "")
	if l := h.list(p); l.body["realm"] != "solmarch" || l.body["unlock_at"] != nil {
		t.Errorf("reino cambiado: %s", l.raw)
	}
}

// Huecos: 6 más los derechos; un borrado en plazo ocupa hueco y uno fuera de plazo no.
func TestSlots(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	names := []string{"Uno", "Dos", "Tres", "Cuatro", "Cinco", "Seis", "Siete", "Ocho"}
	var ids []int64
	for i := range 6 {
		if i == 5 {
			h.advance(day, p) // el límite de 5 creaciones al día
		}
		ids = append(ids, h.mustCreate(p, names[i], "vardheim"))
	}
	h.expect(h.create(p, "Siete", "vardheim"), http.StatusConflict, "slots_full")
	h.advance(2*day, p) // más de 24 h de vida: el nombre se reserva 30 días más
	h.expect(h.remove(p, ids[0], "Uno"), http.StatusOK, "")
	res := h.create(p, "Siete", "vardheim")
	h.expect(res, http.StatusConflict, "slots_full")
	if l := h.list(p); l.body["used"] != 6.0 || len(l.body["characters"].([]any)) != 6 {
		t.Fatalf("el borrado en plazo ocupa hueco y sale en la lista: %s", l.raw)
	}
	// Un derecho de un hueco más (PRG-41).
	h.exec(`insert into entitlements (account_id, world_id, kind, quantity, source) values ($1, 1, 'character_slots', 1, 'grant')`, p.id)
	h.mustCreate(p, "Siete", "vardheim")
	if l := h.list(p); l.body["slots"] != 7.0 || l.body["used"] != 7.0 {
		t.Fatalf("huecos con el derecho: %s", l.raw)
	}
	h.expect(h.create(p, "Ocho", "vardheim"), http.StatusConflict, "slots_full")
	// Pasado el plazo de restaurar, el borrado deja de ocupar (aunque aún no se haya purgado).
	h.advance(7*day+time.Second, p)
	h.mustCreate(p, "Ocho", "vardheim")
	if l := h.list(p); l.body["used"] != 7.0 {
		t.Fatalf("el borrado fuera de plazo no ocupa ni sale: %s", l.raw)
	}
	// Un derecho caducado o revocado no cuenta.
	h.exec(`update entitlements set revoked_at = $1 where account_id = $2`, h.clock.Now(), p.id)
	if l := h.list(p); l.body["slots"] != 6.0 {
		t.Errorf("derecho revocado: %s", l.raw)
	}
}

// El sexto personaje creado en un día: 429 con lo que falta.
func TestDailyCreateLimit(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	start := h.clock.Now()
	for i, name := range []string{"Uno", "Dos", "Tres", "Cuatro", "Cinco"} {
		h.setClock(start.Add(time.Duration(i)*time.Hour), p)
		h.mustCreate(p, name, "vardheim")
	}
	res := h.create(p, "Seis", "vardheim")
	h.expect(res, http.StatusTooManyRequests, "rate_limited")
	// La primera salió hace 4 h: faltan 20 h.
	if res.errValue("retry_after_s") != float64(20*3600) || res.header.Get("Retry-After") != "72000" {
		t.Fatalf("retry_after_s: %s %v", res.raw, res.header)
	}
	h.setClock(start.Add(day-time.Second), p)
	h.expect(h.create(p, "Seis", "vardheim"), http.StatusTooManyRequests, "rate_limited")
	h.setClock(start.Add(day+time.Second), p)
	h.mustCreate(p, "Seis", "vardheim")
}

// Raza de otro reino, plantilla que no vale y apariencia que no son 8 B: 400 validation con sus
// campos (la validación provisional, §4.4 paso 5).
func TestCreateValidation(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	body := createBody("Aneira", "vardheim")
	body["race_id"] = "race_solmarch"
	res := h.do(call{method: "POST", path: "/v1/worlds/1/characters", token: p.token, body: body})
	h.expect(res, http.StatusBadRequest, "validation")
	if res.errField("race_id") != "wrong_realm" {
		t.Errorf("raza de otro reino: %s", res.raw)
	}
	body = createBody("Aneira", "vardheim")
	body["starter_template_id"] = "Escudero!"
	res = h.do(call{method: "POST", path: "/v1/worlds/1/characters", token: p.token, body: body})
	h.expect(res, http.StatusBadRequest, "validation")
	if res.errField("starter_template_id") != "not_selectable" {
		t.Errorf("plantilla: %s", res.raw)
	}
	for _, bad := range []string{"AQID", "no es base64!", "AQIDBAUGBwgJ", ""} {
		body = createBody("Aneira", "vardheim")
		body["appearance"] = bad
		res = h.do(call{method: "POST", path: "/v1/worlds/1/characters", token: p.token, body: body})
		h.expect(res, http.StatusBadRequest, "validation")
		if res.errField("appearance") != "invalid" {
			t.Errorf("apariencia %q: %s", bad, res.raw)
		}
	}
	res = h.do(call{method: "POST", path: "/v1/worlds/1/characters", token: p.token, body: map[string]any{"name": "Aneira"}})
	h.expect(res, http.StatusBadRequest, "validation")
	if res.errField("realm") != "required" || res.errField("appearance") != "required" || res.errField("race_id") != "required" ||
		res.errField("starter_template_id") != "required" {
		t.Errorf("campos que faltan: %s", res.raw)
	}
	body = createBody("Aneira", "vardheim")
	body["world_id"] = 1
	h.expect(h.do(call{method: "POST", path: "/v1/worlds/1/characters", token: p.token, body: body}),
		http.StatusBadRequest, "bad_request")
	// Nada de esto creó filas ni gastó el límite.
	if h.count(`select count(*) from characters`) != 0 || h.count(`select count(*) from auth_events where kind = 'character_create'`) != 0 {
		t.Error("una creación rechazada dejó filas")
	}
	h.mustCreate(p, "Aneira", "vardheim")
}

func TestPendingDeletionAndSanctionedAccounts(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	h.expect(h.do(call{method: "POST", path: "/v1/account/deletion", token: p.token, body: map[string]any{"password": password}}),
		http.StatusAccepted, "")
	res := h.create(p, "Aneira", "vardheim")
	h.expect(res, http.StatusForbidden, "account_pending_deletion")
	if res.errValue("deletion_at") != float64(h.clock.Now().Add(14*day).Unix()) {
		t.Errorf("deletion_at: %s", res.raw)
	}
	h.expect(h.do(call{method: "DELETE", path: "/v1/account/deletion", token: p.token}), http.StatusNoContent, "")
	h.mustCreate(p, "Aneira", "vardheim")

	// Una cuenta suspendida solo tiene la sesión de privacidad: las rutas de personajes dan 403.
	s := h.newPlayer("sancionada@example.org")
	h.exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', 'insultos', $2, $3)`,
		s.id, h.clock.Now(), h.clock.Now().Add(day))
	h.login(s)
	for _, c := range []call{{method: "GET", path: "/v1/worlds/1/characters"}, {method: "POST", path: "/v1/worlds/1/characters",
		body: createBody("Sancion", "vardheim")}, {method: "GET", path: "/v1/worlds/1/name-check?name=Ana"},
		{method: "POST", path: "/v1/characters/1/enter"}} {
		c.token = s.token
		res := h.do(c)
		h.expect(res, http.StatusForbidden, "account_suspended")
		if res.errValue("reason") != "insultos" {
			t.Errorf("%s %s: %s", c.method, c.path, res.raw)
		}
	}
}

func TestNameCheckRateLimit(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	for i := range 30 {
		if res := h.nameCheck(p, "Ana"); res.status != http.StatusOK {
			t.Fatalf("comprobación %d: %s", i, res.raw)
		}
	}
	h.expect(h.nameCheck(p, "Ana"), http.StatusTooManyRequests, "rate_limited")
	h.clock.Advance(2 * time.Second)
	h.expect(h.nameCheck(p, "Ana"), http.StatusOK, "")
}

// Cuentas distintas que crean a la vez con nombres distintos no se estorban: ningún 503 por
// conflictos de serialización.
func TestConcurrentCreationsOfDifferentAccounts(t *testing.T) {
	h := newHarness(t)
	const n = 8
	players := make([]*player, n)
	for i := range players {
		players[i] = h.newPlayer(fmt.Sprintf("p%d@example.org", i))
	}
	letters := "abcdefghijklmnopqrstuvwxyz"
	for round := range 4 {
		var wg sync.WaitGroup
		results := make([]*response, n)
		start := make(chan struct{})
		for i := range players {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				results[i] = h.create(players[i], "Pj"+string(letters[round])+string(letters[i]), "solmarch")
			}()
		}
		close(start)
		wg.Wait()
		for i, res := range results {
			if res.status != http.StatusCreated {
				t.Fatalf("ronda %d, jugador %d: %d %s", round, i, res.status, res.raw)
			}
		}
	}
}
