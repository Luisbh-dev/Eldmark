package war_test

import (
	"encoding/json"
	"os"
	"testing"

	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func record(owner int) map[string]any {
	return map[string]any{"schema": 1, "owner": owner, "phase": "consolidating", "phase_ends_at_unix": 1800000120,
		"captain_alive": false, "captain_respawn_at_unix": 1800000300, "gate_health": 2600, "capture_realm": 0,
		"capture_progress": 0, "last_reset_at_unix": 1799999000}
}

func put(z *platformtest.Zone, fortress string, expected int, rec any) *platformtest.Response {
	return z.Do("PUT", "/internal/v1/fortresses/"+fortress, map[string]any{"zone_instance_id": z.ID,
		"expected_version": expected, "record": rec})
}

func list(t *testing.T, z *platformtest.Zone) []any {
	t.Helper()
	res := z.Do("GET", "/internal/v1/fortresses?zone_instance_id="+z.ID, nil)
	platformtest.Expect(t, res, 200, "")
	return res.Body["fortresses"].([]any)
}

// Fortalezas (§6, §8): la lista vacía del primer arranque (también en starting), el primer PUT
// crea la fila con la zona de la instancia, versiones con version_conflict, una fortaleza de otra
// zona da 403 y el GET solo devuelve las de la zona de la instancia.
func TestFortresses(t *testing.T) {
	p := platformtest.New(t)
	vado := p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, vado.Register(nil), 200, "")
	if got := list(t, vado); len(got) != 0 {
		t.Fatal("primer arranque: lista vacía")
	}
	platformtest.Expect(t, put(vado, "fuerte_norte", 0, record(1)), 409, "instance_not_live")
	platformtest.Expect(t, vado.Live(), 204, "")

	res := put(vado, "fuerte_norte", 0, record(1))
	platformtest.Expect(t, res, 200, "")
	if res.Int("version") != 1 {
		t.Fatal(res.Raw)
	}
	res = put(vado, "fuerte_norte", 0, record(2))
	platformtest.Expect(t, res, 409, "version_conflict")
	if res.ErrValue("version").(json.Number).String() != "1" {
		t.Fatalf("la versión actual en el error: %s", res.Raw)
	}
	res = put(vado, "fuerte_norte", 1, record(2))
	platformtest.Expect(t, res, 200, "")
	if res.Int("version") != 2 {
		t.Fatal(res.Raw)
	}
	platformtest.Expect(t, put(vado, "fuerte_sur", 3, record(1)), 409, "version_conflict") // no existe: versión 0

	other := p.NewZone(1, "test_world", 0).Start()
	platformtest.Expect(t, put(other, "fuerte_norte", 2, record(3)), 403, "forbidden")
	platformtest.Expect(t, put(other, "fuerte_oeste", 0, record(3)), 200, "")

	got := list(t, vado)
	if len(got) != 1 {
		t.Fatalf("solo las de la zona: %v", got)
	}
	f := got[0].(map[string]any)
	if f["fortress_id"] != "fuerte_norte" || f["version"].(json.Number).String() != "2" ||
		f["record"].(map[string]any)["owner"].(json.Number).String() != "2" {
		t.Fatalf("registro: %v", f)
	}
	if got := list(t, other); len(got) != 1 || got[0].(map[string]any)["fortress_id"] != "fuerte_oeste" {
		t.Fatalf("la otra zona: %v", got)
	}
	var updatedBy string
	p.Scalar(&updatedBy, `select updated_by::text from fortresses where fortress_id = 'fuerte_norte'`)
	if updatedBy != vado.ID {
		t.Fatal(updatedBy)
	}
	// Cuerpos que no valen.
	platformtest.Expect(t, put(vado, "Fuerte", 2, record(1)), 400, "validation")
	platformtest.Expect(t, put(vado, "fuerte_norte", 2, []int{1}), 400, "validation")
	platformtest.Expect(t, put(vado, "fuerte_norte", -1, record(1)), 400, "validation")
	// Una zona de otro mundo con el mismo zone_id no ve las del mundo 1.
	w2 := p.NewZone(2, "vado_gris", 0).Start()
	if got := list(t, w2); len(got) != 0 {
		t.Fatalf("otro mundo: %v", got)
	}
	platformtest.Expect(t, put(w2, "fuerte_norte", 0, record(1)), 200, "")
}

// Eventos de guerra (§8): se insertan con world_id e instancia; reenviar no duplica; una entrada
// mala, de otra instancia o de una fortaleza de otra zona va a rejected y las demás se insertan.
func TestWarEvents(t *testing.T) {
	p := platformtest.New(t)
	vado := p.NewZone(1, "vado_gris", 0).Start()
	other := p.NewZone(1, "test_world", 0).Start()
	platformtest.Expect(t, put(other, "fuerte_ajeno", 0, record(1)), 200, "")
	ev := func(key, fortress string, event int) map[string]any {
		return map[string]any{"key": key, "fortress_id": fortress, "event": event, "realm": 1, "at_unix": 1800000000}
	}
	batch := map[string]any{"zone_instance_id": vado.ID, "events": []any{
		ev(vado.ID+":1", "fuerte_norte", 3),
		ev(vado.ID+":2", "fuerte_norte", 6),
		ev(other.ID+":3", "fuerte_norte", 7),       // key de otra instancia
		ev(vado.ID+":4", "fuerte_ajeno", 6),        // fortaleza de otra zona
		ev(vado.ID+":5", "fuerte_norte", 9),        // evento fuera de rango
		map[string]any{"key": vado.ID + ":6"},      // le faltan campos
		ev("op:5", "fuerte_norte", 3),              // op: no vale en la guerra
		ev(vado.ID+":07", "fuerte_norte", 3),       // secuencia con un cero delante
		map[string]any{"key": 5, "fortress_id": 1}, // sin key legible
	}}
	res := vado.Do("POST", "/internal/v1/war-events", batch)
	platformtest.Expect(t, res, 200, "")
	rejected := res.Body["rejected"].([]any)
	want := []string{other.ID + ":3", vado.ID + ":4", vado.ID + ":5", vado.ID + ":6", "op:5", vado.ID + ":07", ""}
	if len(rejected) != len(want) {
		t.Fatalf("rejected: %v", rejected)
	}
	for i, k := range want {
		if rejected[i] != k {
			t.Fatalf("rejected[%d] = %v, se esperaba %q", i, rejected[i], k)
		}
	}
	if n := p.Count(`select count(*) from fortress_events where world_id = 1 and zone_instance_id = $1`, vado.ID); n != 2 {
		t.Fatalf("insertados: %d", n)
	}
	// Reenviar el lote no duplica nada; un lote limpio da 204.
	vado.Do("POST", "/internal/v1/war-events", batch)
	platformtest.Expect(t, vado.Do("POST", "/internal/v1/war-events", map[string]any{"zone_instance_id": vado.ID,
		"events": []any{ev(vado.ID+":1", "fuerte_norte", 3)}}), 204, "")
	if n := p.Count(`select count(*) from fortress_events`); n != 2 {
		t.Fatalf("sin duplicados: %d", n)
	}
	// Un lote con el objeto de fuera roto: 400.
	platformtest.Expect(t, vado.Do("POST", "/internal/v1/war-events", map[string]any{"zone_instance_id": vado.ID}), 400,
		"bad_request")
	platformtest.Expect(t, vado.Do("POST", "/internal/v1/war-events", map[string]any{"zone_instance_id": vado.ID,
		"events": []any{}, "world_id": 1}), 400, "bad_request")
}
