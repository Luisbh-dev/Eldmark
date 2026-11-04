package progress_test

import (
	"encoding/json"
	"net/http"
	"reflect"
	"strconv"
	"testing"
	"time"

	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/progress"
)

// The whole platform with the real store (what serve assembles): creation validates race,
// appearance and template with the exported rules; the claim brings the Load record; the save
// applies S1–S8 through the internal API (applied, duplicate and invalid_save with its check); the
// character list reads Summaries; the next claim brings what was saved; and the operation and
// ledger routes respond with the bodies from here.
func TestThroughThePlatform(t *testing.T) {
	rules := embedded(t)
	p := platformtest.NewWithProgress(t, func(now func() time.Time) persistence.ProgressStore {
		return progress.New(rules, now)
	}, rules)
	z := p.NewZone(1, "vado_gris", 0).Start()
	for _, first := range []string{"1", "1025"} {
		res := z.Do("POST", "/internal/v1/id-blocks", map[string]any{"zone_instance_id": z.ID})
		if res.Status != http.StatusOK || res.String("first") != first {
			t.Fatalf("bloque: %d %s", res.Status, res.Raw)
		}
	}
	pl := p.NewPlayer("aneira@example.org")
	for _, tc := range []struct {
		race, appearance, template string
		fields                     map[string]any
	}{
		{"race_vardheim", platformtest.Appearance, "squire", map[string]any{"appearance": "invalid"}},
		{"race_solmarch", "AgAAAAAHAAA=", "squire", map[string]any{"race_id": "wrong_realm"}},
		{"race_vardheim", "AQAAAQEDAgE=", "veteran", map[string]any{"starter_template_id": "not_selectable"}},
	} {
		res := p.PublicDo("POST", "/v1/worlds/1/characters", pl.Token, map[string]any{"name": "Aneira",
			"realm": "vardheim", "race_id": tc.race, "appearance": tc.appearance, "starter_template_id": tc.template})
		platformtest.Expect(t, res, http.StatusBadRequest, "validation")
		if got := res.ErrValue("fields"); !reflect.DeepEqual(got, tc.fields) {
			t.Errorf("%v: fields %v", tc, got)
		}
	}
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	ticket, _ := p.MustEnter(pl, id)
	res := z.Claim(ticket, id)
	platformtest.Expect(t, res, http.StatusOK, "")
	lease := res.String("lease_id")
	claimed := res.Body["progress"].(map[string]any)
	if claimed["race_id"] != "race_vardheim" || claimed["appearance"] != "AQAAAQEDAgE=" ||
		claimed["starter_template_id"] != "squire" || claimed["location"] != nil || claimed["starter_granted"] != false ||
		len(claimed["items"].([]any)) != 0 || len(claimed["wallets"].([]any)) != 2 {
		t.Fatalf("reclamación de un personaje nuevo: %v", claimed)
	}

	c := loadCases(t)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	envelope := func(seq int, body json.RawMessage) []byte {
		return platformtest.Marshal(map[string]any{"save_format": 1, "character_id": strconv.FormatInt(id, 10),
			"zone_instance_id": z.ID, "lease_id": lease, "seq": seq, "reason": 1, "release_lease": false,
			"progress": body})
	}
	res = z.Save(id, envelope(1, kit))
	platformtest.Expect(t, res, http.StatusOK, "")
	if res.Body["applied"] != true || res.Int("save_version") != 1 {
		t.Fatalf("kit: %s", res.Raw)
	}
	p.Clock.Advance(time.Minute)
	saved := p.Clock.Now()
	moved := edit(t, kit, func(m map[string]any) {
		m["ops"], m["played_seconds"], m["health"] = []any{}, 120, 820
		m["location"].(map[string]any)["x"] = 30.5
	})
	second := envelope(2, moved)
	for _, want := range []string{"applied", "duplicate"} {
		res = z.Save(id, second)
		platformtest.Expect(t, res, http.StatusOK, "")
		if res.Body[want] != true || res.Int("save_version") != 2 {
			t.Fatalf("%s: %s", want, res.Raw)
		}
	}
	equipped := edit(t, moved, func(m map[string]any) {
		for _, it := range m["items"].([]any) {
			item := it.(map[string]any)
			if item["def_id"] == "potion_stamina" {
				item["container"], item["slot"] = 1, 1
			}
		}
	})
	res = z.Save(id, envelope(3, equipped))
	platformtest.Expect(t, res, http.StatusBadRequest, "invalid_save")
	if fields := res.ErrValue("fields").(map[string]any); fields["check"] != "S5" {
		t.Fatalf("poción en el equipo: %s", res.Raw)
	}
	platformtest.Expect(t, z.Release(id, lease), http.StatusNoContent, "")

	res = p.PublicDo("GET", "/v1/worlds/1/characters", pl.Token, nil)
	listed := res.Body["characters"].([]any)[0].(map[string]any)
	if listed["level"] != json.Number("1") || listed["last_zone_id"] != "vado_gris" ||
		listed["played_seconds"] != json.Number("120") || listed["race_id"] != "race_vardheim" {
		t.Fatalf("lista: %s", res.Raw)
	}

	ticket, _ = p.MustEnter(pl, id)
	res = z.Claim(ticket, id)
	platformtest.Expect(t, res, http.StatusOK, "")
	again := res.Body["progress"].(map[string]any)
	location := again["location"].(map[string]any)
	if again["starter_granted"] != true || again["health"] != json.Number("820") || len(again["items"].([]any)) != 4 ||
		location["x"] != json.Number("30.5") || location["zone_id"] != "vado_gris" ||
		location["saved_at_unix"] != json.Number(strconv.FormatInt(saved.Unix(), 10)) {
		t.Fatalf("reclamación siguiente: %v", again)
	}

	res = z.Do("GET", "/internal/v1/ops/1025?zone_instance_id="+z.ID, nil)
	platformtest.Expect(t, res, http.StatusOK, "")
	op := res.Body["op"].(map[string]any)
	if op["kind"] != json.Number("3") || !reflect.DeepEqual(op["participants"], []any{strconv.FormatInt(id, 10)}) ||
		len(op["items"].([]any)) != 4 || len(op["instances"].([]any)) != 4 {
		t.Fatalf("operación: %s", res.Raw)
	}
	platformtest.Expect(t, z.Do("GET", "/internal/v1/ops/9999?zone_instance_id="+z.ID, nil), http.StatusNotFound, "not_found")
	res = z.Do("GET", "/internal/v1/characters/"+strconv.FormatInt(id, 10)+"/ledger?zone_instance_id="+z.ID, nil)
	platformtest.Expect(t, res, http.StatusOK, "")
	if entries, ok := res.Body["entries"].([]any); !ok || len(entries) != 0 {
		t.Fatalf("libro: %s", res.Raw)
	}
}
