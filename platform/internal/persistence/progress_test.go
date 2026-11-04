package persistence_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"eldmark/platform/internal/persistence"
)

func TestErrorsAreMatchedByPointer(t *testing.T) {
	var err error = fmt.Errorf("guardado: %w", &persistence.InvalidSaveError{Check: "S4", Detail: "objetos"})
	var invalid *persistence.InvalidSaveError
	if !errors.As(err, &invalid) || invalid.Check != "S4" || invalid.Detail != "objetos" {
		t.Errorf("errors.As con *InvalidSaveError: %v", err)
	}
	if invalid.Error() != "invalid_save S4: objetos" {
		t.Errorf("Error() = %q", invalid.Error())
	}
	err = fmt.Errorf("crear: %w", &persistence.ValidationError{Fields: map[string]string{"race_id": "wrong_realm",
		"appearance": "invalid"}})
	var validation *persistence.ValidationError
	if !errors.As(err, &validation) || validation.Fields["race_id"] != "wrong_realm" {
		t.Errorf("errors.As con *ValidationError: %v", err)
	}
	if validation.Error() != "validation: appearance=invalid, race_id=wrong_realm" {
		t.Errorf("Error() = %q", validation.Error())
	}
	if !errors.Is(fmt.Errorf("op: %w", persistence.ErrNotFound), persistence.ErrNotFound) {
		t.Error("ErrNotFound con errors.Is")
	}
}

func TestProvisionalValidator(t *testing.T) {
	v := persistence.ProvisionalValidator{}
	var appearance [8]byte
	cases := []struct {
		realm    int16
		race     string
		template string
		want     map[string]string
	}{
		{1, "race_vardheim", "squire", nil},
		{2, "race_solmarch", "marksman", nil},
		{3, "race_askarra", "a", nil},
		{1, "race_solmarch", "squire", map[string]string{"race_id": "wrong_realm"}},
		{2, "race_elfo", "squire", map[string]string{"race_id": "unknown"}},
		{1, "", "squire", map[string]string{"race_id": "unknown"}},
		{1, "race_vardheim", "Squire", map[string]string{"starter_template_id": "not_selectable"}},
		{1, "race_vardheim", "", map[string]string{"starter_template_id": "not_selectable"}},
		{1, "race_vardheim", "abcdefghijklmnopqrstuvwxyz0123456", map[string]string{"starter_template_id": "not_selectable"}},
		{1, "race_askarra", "x-y", map[string]string{"race_id": "wrong_realm", "starter_template_id": "not_selectable"}},
	}
	for _, c := range cases {
		err := v.ValidateCreate(c.realm, c.race, appearance, c.template)
		if c.want == nil {
			if err != nil {
				t.Errorf("%d %q %q: %v", c.realm, c.race, c.template, err)
			}
			continue
		}
		var ve *persistence.ValidationError
		if !errors.As(err, &ve) || fmt.Sprint(ve.Fields) != fmt.Sprint(c.want) {
			t.Errorf("%d %q %q: %v, se esperaba %v", c.realm, c.race, c.template, err, c.want)
		}
	}
}

func TestMemoryProgressStore(t *testing.T) {
	ctx := context.Background()
	m := persistence.NewMemoryProgressStore()
	params := persistence.CreateParams{RaceID: "race_vardheim", Appearance: [8]byte{1, 0, 2, 1, 0, 3, 2, 0x21},
		StarterTemplateID: "squire"}
	if err := m.Create(ctx, nil, 1, 41, params); err != nil {
		t.Fatal(err)
	}
	if err := m.Create(ctx, nil, 1, 41, params); err == nil {
		t.Error("crear dos veces el mismo personaje")
	}
	raw, err := m.Load(ctx, nil, 41)
	if err != nil {
		t.Fatal(err)
	}
	var rec map[string]any
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatal(err)
	}
	if rec["race_id"] != "race_vardheim" || rec["appearance"] != "AQACAQADAiE=" || rec["starter_template_id"] != "squire" ||
		rec["level"] != 1.0 || rec["location"] != nil || rec["progress_format"] != 1.0 {
		t.Errorf("registro nuevo: %v", rec)
	}
	sums, _ := m.Summaries(ctx, nil, []int64{41, 99})
	if len(sums) != 1 || sums[41].Level != 1 || sums[41].RaceID != "race_vardheim" || sums[41].Appearance != params.Appearance {
		t.Errorf("resumen: %+v", sums)
	}

	key := persistence.SaveKey{WorldID: 1, CharacterID: 41, ZoneID: "vado_gris"}
	body := `{"progress_format": 1.0, "level": 7, "played_seconds": 5400, "location": {"zone_id": "vado_gris",
		"channel": 2}, "ops": [{"op_id": "5120"}]}`
	v, err := m.Apply(ctx, nil, key, json.RawMessage(body))
	if err != nil || v != 1 {
		t.Fatalf("Apply: %d, %v", v, err)
	}
	// Like S2: an op_id already stored is no longer valid; a new one is.
	var invalidS2 *persistence.InvalidSaveError
	if _, err := m.Apply(ctx, nil, key, json.RawMessage(body)); !errors.As(err, &invalidS2) || invalidS2.Check != "S2" {
		t.Errorf("op_id repetido: %v", err)
	}
	body = strings.Replace(body, `"5120"`, `"5121"`, 1)
	if v, _ := m.Apply(ctx, nil, key, json.RawMessage(body)); v != 2 {
		t.Errorf("save_version sube: %d", v)
	}
	sums, _ = m.Summaries(ctx, nil, []int64{41})
	if s := sums[41]; s.Level != 7 || s.PlayedSeconds != 5400 || s.LastZoneID != "vado_gris" || s.LastChannel != 2 {
		t.Errorf("resumen tras guardar: %+v", s)
	}
	raw, _ = m.Load(ctx, nil, 41)
	rec = nil
	_ = json.Unmarshal(raw, &rec)
	if _, ok := rec["ops"]; ok || rec["level"] != 7.0 || rec["race_id"] != "race_vardheim" {
		t.Errorf("la reclamación siguiente trae lo aplicado sin ops: %v", rec)
	}
	for _, bad := range []string{`[]`, `{"level": 2}`, `{"progress_format": 2}`, `nope`} {
		var invalid *persistence.InvalidSaveError
		if _, err := m.Apply(ctx, nil, key, json.RawMessage(bad)); !errors.As(err, &invalid) || invalid.Check != "S1" {
			t.Errorf("Apply(%s): %v", bad, err)
		}
	}
	m.SetApplyHook(func(persistence.SaveKey, json.RawMessage) error {
		return &persistence.InvalidSaveError{Check: "S4", Detail: "de prueba"}
	})
	if _, err := m.Apply(ctx, nil, key, json.RawMessage(body)); err == nil {
		t.Error("el gancho decide")
	}
	m.SetApplyHook(nil)

	m.SetSummary(41, persistence.Summary{Level: 3, PlayedSeconds: 10})
	if sums, _ := m.Summaries(ctx, nil, []int64{41}); sums[41].Level != 3 {
		t.Error("SetSummary")
	}
	if _, err := m.Ledger(ctx, nil, 41, 20, 0); err != nil {
		t.Error(err)
	}
	if _, err := m.Op(ctx, nil, 5120, [16]byte{}); !errors.Is(err, persistence.ErrNotFound) {
		t.Error("Op")
	}
	if err := m.Purge(ctx, nil, 41); err != nil || m.Has(41) {
		t.Fatal("Purge")
	}
	if _, err := m.Load(ctx, nil, 41); !errors.Is(err, persistence.ErrNotFound) {
		t.Error("Load de un purgado")
	}
	if _, err := m.Ledger(ctx, nil, 41, 20, 0); !errors.Is(err, persistence.ErrNotFound) {
		t.Error("Ledger de un purgado")
	}
	raw, _ = m.Export(ctx, nil, 41)
	if string(raw) != `{"ops":[],"record":null}` {
		t.Errorf("Export de una lápida: %s", raw)
	}
	if err := m.Create(ctx, nil, 1, 41, params); err != nil {
		t.Error("un id purgado se puede volver a crear en el falso")
	}
	if n, emptied, err := m.PurgeRetention(ctx, nil); n != 0 || emptied != nil || err != nil {
		t.Error("PurgeRetention")
	}
}
