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

// Forts (§6, §8): the empty list on first startup (also in starting), the first PUT creates the
// row with the instance's zone, versions with version_conflict, a fort of another zone gives 403
// and the GET returns only those of the instance's zone.
func TestFortresses(t *testing.T) {
	p := platformtest.New(t)
	vado := p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, vado.Register(nil), 200, "")
	if got := list(t, vado); len(got) != 0 {
		t.Fatal("first startup: empty list")
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
		t.Fatalf("the current version in the error: %s", res.Raw)
	}
	res = put(vado, "fuerte_norte", 1, record(2))
	platformtest.Expect(t, res, 200, "")
	if res.Int("version") != 2 {
		t.Fatal(res.Raw)
	}
	platformtest.Expect(t, put(vado, "fuerte_sur", 3, record(1)), 409, "version_conflict") // does not exist: version 0

	other := p.NewZone(1, "test_world", 0).Start()
	platformtest.Expect(t, put(other, "fuerte_norte", 2, record(3)), 403, "forbidden")
	platformtest.Expect(t, put(other, "fuerte_oeste", 0, record(3)), 200, "")

	got := list(t, vado)
	if len(got) != 1 {
		t.Fatalf("only the zone's own: %v", got)
	}
	f := got[0].(map[string]any)
	if f["fortress_id"] != "fuerte_norte" || f["version"].(json.Number).String() != "2" ||
		f["record"].(map[string]any)["owner"].(json.Number).String() != "2" {
		t.Fatalf("log: %v", f)
	}
	if got := list(t, other); len(got) != 1 || got[0].(map[string]any)["fortress_id"] != "fuerte_oeste" {
		t.Fatalf("the other zone: %v", got)
	}
	var updatedBy string
	p.Scalar(&updatedBy, `select updated_by::text from fortresses where fortress_id = 'fuerte_norte'`)
	if updatedBy != vado.ID {
		t.Fatal(updatedBy)
	}
	// Invalid bodies.
	platformtest.Expect(t, put(vado, "Fuerte", 2, record(1)), 400, "validation")
	platformtest.Expect(t, put(vado, "fuerte_norte", 2, []int{1}), 400, "validation")
	platformtest.Expect(t, put(vado, "fuerte_norte", -1, record(1)), 400, "validation")
	// A record that jsonb does not accept (a NUL): 400 validation, not a 500 that the zone retries.
	if res := put(vado, "fuerte_norte", 2, map[string]any{"owner": "a\x00b"}); res.Status != 400 || res.Field("record") != "invalid" {
		t.Fatal(res.Raw)
	}
	// A zone of another world with the same zone_id does not see those of world 1.
	w2 := p.NewZone(2, "vado_gris", 0).Start()
	if got := list(t, w2); len(got) != 0 {
		t.Fatalf("another world: %v", got)
	}
	platformtest.Expect(t, put(w2, "fuerte_norte", 0, record(1)), 200, "")
}

// War events (§8): they are inserted with world_id and instance; resending does not duplicate; a
// bad entry, one from another instance or one for a fort of another zone goes to rejected and the
// rest are inserted.
func TestWarEvents(t *testing.T) {
	p := platformtest.New(t)
	vado := p.NewZone(1, "vado_gris", 0).Start()
	other := p.NewZone(1, "test_world", 0).Start()
	platformtest.Expect(t, put(other, "fuerte_ajeno", 0, record(1)), 200, "")
	ev := func(key, fortress string, event int) map[string]any {
		return map[string]any{"key": key, "fortress_id": fortress, "event": event, "realm": 1, "at_unix": 1800000000}
	}
	far := func(key string, at int64) map[string]any {
		e := ev(key, "fuerte_norte", 3)
		e["at_unix"] = at
		return e
	}
	batch := map[string]any{"zone_instance_id": vado.ID, "events": []any{
		ev(vado.ID+":1", "fuerte_norte", 3),
		ev(vado.ID+":2", "fuerte_norte", 6),
		ev(other.ID+":3", "fuerte_norte", 7),       // key from another instance
		ev(vado.ID+":4", "fuerte_ajeno", 6),        // fort of another zone
		ev(vado.ID+":5", "fuerte_norte", 9),        // event out of range
		map[string]any{"key": vado.ID + ":6"},      // missing fields
		ev("op:5", "fuerte_norte", 3),              // op: is not valid in war
		ev(vado.ID+":07", "fuerte_norte", 3),       // sequence with a leading zero
		map[string]any{"key": 5, "fortress_id": 1}, // no readable key
		far(vado.ID+":8", 9000000000000000),        // date out of range (before, a 500 and the batch stuck)
		far(vado.ID+":9", 1<<53-1),                 // pgx overflowed it silently
	}}
	res := vado.Do("POST", "/internal/v1/war-events", batch)
	platformtest.Expect(t, res, 200, "")
	rejected := res.Body["rejected"].([]any)
	want := []string{other.ID + ":3", vado.ID + ":4", vado.ID + ":5", vado.ID + ":6", "op:5", vado.ID + ":07", "",
		vado.ID + ":8", vado.ID + ":9"}
	if len(rejected) != len(want) {
		t.Fatalf("rejected: %v", rejected)
	}
	for i, k := range want {
		if rejected[i] != k {
			t.Fatalf("rejected[%d] = %v, expected %q", i, rejected[i], k)
		}
	}
	if n := p.Count(`select count(*) from fortress_events where world_id = 1 and zone_instance_id = $1`, vado.ID); n != 2 {
		t.Fatalf("inserted: %d", n)
	}
	// Resending the batch does not duplicate anything; a clean batch gives 204.
	vado.Do("POST", "/internal/v1/war-events", batch)
	platformtest.Expect(t, vado.Do("POST", "/internal/v1/war-events", map[string]any{"zone_instance_id": vado.ID,
		"events": []any{ev(vado.ID+":1", "fuerte_norte", 3)}}), 204, "")
	if n := p.Count(`select count(*) from fortress_events`); n != 2 {
		t.Fatalf("no duplicates: %d", n)
	}
	// A batch with a broken outer object: 400.
	platformtest.Expect(t, vado.Do("POST", "/internal/v1/war-events", map[string]any{"zone_instance_id": vado.ID}), 400,
		"bad_request")
	platformtest.Expect(t, vado.Do("POST", "/internal/v1/war-events", map[string]any{"zone_instance_id": vado.ID,
		"events": []any{}, "world_id": 1}), 400, "bad_request")
}
