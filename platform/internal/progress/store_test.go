package progress_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
)

// Create, save and reload: Load returns the §3.4 record of a new character with the defaults and,
// after the kit and some play time, the snapshot of the last save field by field, with the
// read-only fields and location.saved_at_unix (PRG-10).
func TestCreateLoad(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	fresh := w.load(42)
	want := map[string]any{"progress_format": json.Number("1"), "race_id": "race_vardheim",
		"appearance": "AQAAAQEAAgE=", "starter_template_id": "squire", "starter_granted": false,
		"level": json.Number("1"), "xp_total": json.Number("0"), "realm_points": json.Number("0"),
		"played_seconds": json.Number("0"), "bag_slots": json.Number("30"), "active_weapon_slot": json.Number("0"),
		"health": nil, "location": nil, "items": []any{}, "timers": []any{},
		"wallets": []any{map[string]any{"currency": json.Number("1"), "balance": json.Number("0")},
			map[string]any{"currency": json.Number("2"), "balance": json.Number("0")}}}
	if !reflect.DeepEqual(fresh, want) {
		t.Fatalf("new character:\n%v\nexpected\n%v", fresh, want)
	}
	for i := 0; i < 2; i++ {
		_, body := c.step(t, "valid_kit_and_play", i)
		if got, version := w.apply(42, body); got != "applied" || version != int64(i+1) {
			t.Fatalf("step %d: %s, save_version %d", i, got, version)
		}
	}
	_, play := c.step(t, "valid_kit_and_play", 1)
	saved := w.load(42)
	expected := decodeMap(t, play)
	delete(expected, "ops")
	expected["race_id"], expected["appearance"], expected["starter_template_id"] = "race_vardheim", "AQAAAQEAAgE=", "squire"
	expected["location"].(map[string]any)["saved_at_unix"] = json.Number(id(c.NowUnix))
	for k, v := range expected {
		if !sameJSON(t, saved[k], v) {
			t.Errorf("%s: %v, expected %v", k, saved[k], v)
		}
	}
	if len(saved) != len(expected) {
		t.Errorf("keys: %d, expected %d", len(saved), len(expected))
	}
}

// sameJSON compares two values by their JSON (numbers, as json.Number: 0 and 0.0 are the same).
func sameJSON(t testing.TB, a, b any) bool {
	t.Helper()
	norm := func(v any) any {
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		var out any
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	return reflect.DeepEqual(norm(a), norm(b))
}

func decodeMap(t testing.TB, raw json.RawMessage) map[string]any {
	t.Helper()
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&m); err != nil {
		t.Fatal(err)
	}
	return m
}

// ValidateCreate with the cases from appearance_cases.json (the same as
// test_character_appearance.gd), a race from another realm, one that does not exist and a
// template that is not selectable: nil or a *persistence.ValidationError with its fields.
func TestValidateCreate(t *testing.T) {
	r := embedded(t)
	data, err := os.ReadFile(sharedAppearanceCases)
	if err != nil {
		t.Fatal(err)
	}
	var cases []appearanceCase
	if err := jsonx.DecodeBytes(data, &cases); err != nil {
		t.Fatal(err)
	}
	fieldsOf := func(err error) map[string]string {
		t.Helper()
		if err == nil {
			return nil
		}
		var ve *persistence.ValidationError
		if !errors.As(err, &ve) {
			t.Fatalf("not a *persistence.ValidationError: %v", err)
		}
		return ve.Fields
	}
	for _, c := range cases {
		b, err := base64.StdEncoding.DecodeString(c.Appearance)
		if err != nil || len(b) != 8 {
			continue // those of another size are rejected by the API before validating (they are not [8]byte)
		}
		got := fieldsOf(r.ValidateCreate(c.Realm, c.RaceID, [8]byte(b), "squire"))
		var want map[string]string
		if !c.Valid {
			switch i := r.RaceIndex(c.RaceID); {
			case i < 0:
				want = map[string]string{"race_id": "unknown"}
			case r.Races[i].Realm != c.Realm:
				want = map[string]string{"race_id": "wrong_realm"}
			default:
				want = map[string]string{"appearance": "invalid"}
			}
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("case \"%s\": %v, expected %v", c.Case, got, want)
		}
	}
	vardheim := [8]byte{1, 0, 0, 1, 1, 3, 2, 1}
	for _, c := range []struct {
		name     string
		realm    int16
		race     string
		template string
		want     map[string]string
	}{
		{"válido", 1, "race_vardheim", "marksman", nil},
		{"raza de otro reino", 2, "race_vardheim", "squire", map[string]string{"race_id": "wrong_realm"}},
		{"raza que no existe", 1, "race_elfo", "squire", map[string]string{"race_id": "unknown"}},
		{"plantilla que no es selectable", 1, "race_vardheim", "veteran",
			map[string]string{"starter_template_id": "not_selectable"}},
		{"las dos cosas", 2, "race_vardheim", "",
			map[string]string{"race_id": "wrong_realm", "starter_template_id": "not_selectable"}},
	} {
		if got := fieldsOf(r.ValidateCreate(c.realm, c.race, vardheim, c.template)); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %v, expected %v", c.name, got, c.want)
		}
	}
}

// Summaries of several characters: one that has never entered (no location), one that has saved
// (zone, channel, level and played time) and one that does not exist (not returned).
func TestSummaries(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	_, play := c.step(t, "valid_kit_and_play", 1)
	w.apply(42, kit)
	w.apply(42, play)
	level2 := edit(t, play, func(m map[string]any) {
		m["ops"], m["xp_total"], m["level"], m["played_seconds"] = []any{}, 600, 2, 180
		m["location"].(map[string]any)["channel"] = 3
	})
	if got, _ := w.apply(42, level2); got != "applied" {
		t.Fatalf("level up: %s", got)
	}
	sums, err := w.store.Summaries(context.Background(), w.pool, []int64{42, 43, 999})
	if err != nil {
		t.Fatal(err)
	}
	appearance := [8]byte{1, 0, 0, 1, 1, 0, 2, 1}
	want := map[int64]persistence.Summary{
		42: {RaceID: "race_vardheim", Appearance: appearance, Level: 2, LastZoneID: "vado_gris", LastChannel: 3,
			PlayedSeconds: 180},
		43: {RaceID: "race_vardheim", Appearance: appearance, Level: 1},
	}
	if !reflect.DeepEqual(sums, want) {
		t.Fatalf("summaries:\n%+v\nexpected\n%+v", sums, want)
	}
	if empty, err := w.store.Summaries(context.Background(), w.pool, nil); err != nil || len(empty) != 0 {
		t.Fatalf("without ids: %v %v", empty, err)
	}
}

// Export returns the record and the ledger's own data (the operations with their entries and
// events); for GM and REVERSAL operations, without actor_account_id, note or detail; for a
// tombstone, without a record and with the ledger.
func TestExport(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	for i := 0; i < 3; i++ {
		_, body := c.step(t, "valid_reversal", i)
		if got, _ := w.apply(42, body); got != "applied" {
			t.Fatalf("step %d: %s", i, got)
		}
	}
	export := func() map[string]any {
		raw, err := w.store.Export(context.Background(), w.pool, 42)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(raw, []byte("actor_account_id")) || bytes.Contains(raw, []byte("devolución")) ||
			bytes.Contains(raw, []byte("currency_add")) || bytes.Contains(raw, []byte(`"detail"`)) {
			t.Fatalf("the export carries staff data: %s", raw)
		}
		return decodeMap(t, raw)
	}
	out := export()
	rec, ok := out["record"].(map[string]any)
	if !ok || rec["race_id"] != "race_vardheim" || len(rec["items"].([]any)) != 4 {
		t.Fatalf("log: %v", out["record"])
	}
	ops := out["ops"].([]any)
	kinds := map[string]string{}
	for _, o := range ops {
		op := o.(map[string]any)
		kinds[op["op_id"].(string)] = op["kind"].(json.Number).String()
		if len(op) != 7 {
			t.Errorf("operation with other keys: %v", op)
		}
	}
	want := map[string]string{"1025": "3", "1030": "1", "1031": "2", "1032": "4", "1033": "5"}
	if !reflect.DeepEqual(kinds, want) {
		t.Fatalf("operations: %v, expected %v", kinds, want)
	}
	for _, o := range ops {
		op := o.(map[string]any)
		if op["op_id"] == "1033" {
			entries := op["ledger"].([]any)
			e := entries[0].(map[string]any)
			if op["ref_op_id"] != "1032" || len(entries) != 1 || e["delta"].(json.Number).String() != "-50" ||
				e["seq"].(json.Number).String() != "3" || e["ref_id"] != "1032" {
				t.Fatalf("REVERSAL: %v", op)
			}
		}
		if op["op_id"] == "1025" && len(op["items"].([]any)) != 4 {
			t.Fatalf("kit: %v", op)
		}
	}
	// The tombstone: without a record, with the ledger.
	w.purgeAccount(7)
	out = export()
	if out["record"] != nil || len(out["ops"].([]any)) != 5 {
		t.Fatalf("tombstone: %v", out)
	}
	if _, err := w.store.Load(context.Background(), w.pool, 42); !errors.Is(err, persistence.ErrNotFound) {
		t.Fatalf("Load of a tombstone: %v", err)
	}
	if raw, err := w.store.Export(context.Background(), w.pool, 4242); err != nil ||
		!strings.Contains(string(raw), `"record":null`) || !strings.Contains(string(raw), `"ops":[]`) {
		t.Fatalf("a character with nothing: %s %v", raw, err)
	}
}
