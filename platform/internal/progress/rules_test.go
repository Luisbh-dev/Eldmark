package progress_test

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/progress"
)

// Los casos que comparte con test_character_appearance.gd (progresion.md §7.2). Las pruebas de Go corren
// en el directorio del paquete.
const sharedAppearanceCases = "../../../tests/fixtures/progression/appearance_cases.json"

type appearanceCase struct {
	Case       string `json:"case"`
	Realm      int16  `json:"realm"`
	RaceID     string `json:"race_id"`
	Appearance string `json:"appearance"`
	Valid      bool   `json:"valid"`
}

func embedded(t *testing.T) *progress.Rules {
	t.Helper()
	r, err := progress.LoadRules(gamedata.Raw())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// valid aplica la regla a unos bytes cualesquiera, como la plataforma con el base64 de la API: lo que no
// son 8 B no vale.
func valid(r *progress.Rules, realm int16, raceID string, b []byte) bool {
	if len(b) != 8 {
		return false
	}
	return r.ValidAppearance(realm, raceID, [8]byte(b))
}

func TestSharedAppearanceCasesWithGodot(t *testing.T) {
	data, err := os.ReadFile(sharedAppearanceCases)
	if err != nil {
		t.Fatal(err)
	}
	var cases []appearanceCase
	if err := jsonx.DecodeBytes(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 30 {
		t.Fatalf("solo %d casos", len(cases))
	}
	r := embedded(t)
	validCount := 0
	for _, c := range cases {
		b, err := base64.StdEncoding.DecodeString(c.Appearance)
		if err != nil {
			t.Errorf("%s: %q no es base64: %v", c.Case, c.Appearance, err)
			continue
		}
		if got := valid(r, c.Realm, c.RaceID, b); got != c.Valid {
			t.Errorf("caso «%s» (%s, reino %d, %s): %v, se esperaba %v", c.Case, c.Appearance, c.Realm, c.RaceID, got, c.Valid)
		}
		if c.Valid {
			validCount++
		}
	}
	if validCount < 5 || validCount == len(cases) {
		t.Errorf("%d casos válidos de %d: hacen falta de los dos", validCount, len(cases))
	}
}

// La regla de los cuerpos con unas reglas de dos cuerpos (las del repositorio solo tienen uno), las mismas
// que el catálogo de prueba de test_character_appearance.gd.
func TestPartOfAnotherBody(t *testing.T) {
	r := twoBodyRules(t)
	cases := []struct {
		name  string
		b     [8]byte
		valid bool
	}{
		{"cuerpo 0 con sus piezas", [8]byte{1, 0, 0, 1, 1, 0, 0, 0}, true},
		{"cabeza del cuerpo 1 con el cuerpo 0", [8]byte{1, 0, 1, 1, 1, 0, 0, 0}, false},
		{"cuerpo 1 con su cabeza, el pelo de todos y sin barba", [8]byte{1, 1, 1, 1, 0, 0, 0, 0}, true},
		{"barba del cuerpo 0 con el cuerpo 1", [8]byte{1, 1, 1, 1, 1, 0, 0, 0}, false},
		{"marcas del cuerpo 0 con el cuerpo 1", [8]byte{1, 1, 1, 1, 0, 0, 0, 0x10}, false},
		{"marcas del cuerpo 0 con el cuerpo 0", [8]byte{1, 0, 0, 1, 1, 0, 0, 0x10}, true},
		{"sin pelo, que la raza no admite", [8]byte{1, 0, 0, 0, 1, 0, 0, 0}, false},
	}
	for _, c := range cases {
		if got := r.ValidAppearance(1, "race_test", c.b); got != c.valid {
			t.Errorf("%s: %v, se esperaba %v", c.name, got, c.valid)
		}
	}
}

func twoBodyRules(t *testing.T) *progress.Rules {
	t.Helper()
	var top map[string]json.RawMessage
	if err := json.Unmarshal(gamedata.Raw(), &top); err != nil {
		t.Fatal(err)
	}
	top["races"] = json.RawMessage(`[{"id": "race_test", "realm": 1, "allows_no_hair": false,
		"allows_no_beard": true, "bodies": [0, 1], "heads": [0, 1], "hairs": [0], "beards": [0], "marks": [0],
		"skin_tones": [0], "hair_colors": [0], "eye_colors": [0]}]`)
	top["appearance"] = json.RawMessage(`{"body_count": 2, "heads": [{"id": "head_a", "bodies": [0]},
		{"id": "head_b", "bodies": [1]}], "hairs": [{"id": "hair_any", "bodies": []}],
		"beards": [{"id": "beard_a", "bodies": [0]}], "marks": [{"id": "marks_a", "bodies": [0]}],
		"skin_tone_count": 1, "hair_color_count": 1, "eye_color_count": 1}`)
	raw, err := json.Marshal(top)
	if err != nil {
		t.Fatal(err)
	}
	r, err := progress.LoadRules(raw)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// Las reglas incrustadas son las de Godot: tres razas en el orden del catálogo, la curva de §6.1 y los
// valores de §4.1, §5.1 y §5.3.
func TestEmbeddedRules(t *testing.T) {
	r := embedded(t)
	wantRaces := []struct {
		id    string
		realm int16
	}{{"race_vardheim", 1}, {"race_solmarch", 2}, {"race_askarra", 3}}
	if len(r.Races) != len(wantRaces) {
		t.Fatalf("%d razas, se esperaban %d", len(r.Races), len(wantRaces))
	}
	for i, w := range wantRaces {
		if r.Races[i].ID != w.id || r.Races[i].Realm != w.realm || r.RaceIndex(w.id) != i {
			t.Errorf("raza %d: %+v, se esperaba %s del reino %d", i, r.Races[i], w.id, w.realm)
		}
	}
	if r.RaceIndex("race_elf") != -1 {
		t.Error("RaceIndex de una raza que no existe")
	}
	if r.LevelCurve.LevelCap != 40 || len(r.LevelCurve.XPToNext) != 39 {
		t.Fatalf("curva: tope %d con %d valores", r.LevelCurve.LevelCap, len(r.LevelCurve.XPToNext))
	}
	for level, want := range map[int]int64{1: 0, 2: 500, 6: 5350, 11: 25060, 21: 140320, 40: 783780, 41: 783780, 0: 0} {
		if got := r.TotalTo(level); got != want {
			t.Errorf("TotalTo(%d) = %d, se esperaba %d", level, got, want)
		}
	}
	for level := 1; level <= 40; level++ {
		if got := r.LevelFor(r.TotalTo(level)); got != level {
			t.Errorf("LevelFor(TotalTo(%d)) = %d", level, got)
		}
		if level > 1 {
			if got := r.LevelFor(r.TotalTo(level) - 1); got != level-1 {
				t.Errorf("LevelFor(TotalTo(%d) − 1) = %d", level, got)
			}
		}
	}
	if r.LevelFor(12345) != 8 || r.LevelFor(-1) != 1 || r.LevelFor(1<<40) != 40 {
		t.Errorf("LevelFor: 12345 → %d, −1 → %d, 2^40 → %d", r.LevelFor(12345), r.LevelFor(-1), r.LevelFor(1<<40))
	}
	if len(r.Currencies) != 2 || r.Currencies[0].Cap != 1_000_000_000 || r.Currencies[1].ID != "merits" {
		t.Errorf("monedas: %+v", r.Currencies)
	}
	if r.Reasons.Codes["reversal"] != 128 || r.Reasons.OpKinds["gm"] != 4 || r.Reasons.Ranges.Sink.Min != 64 {
		t.Errorf("motivos: %+v", r.Reasons)
	}
	if r.Containers.Bag.DefaultSlots != 30 || r.Containers.Equipment.OpenSlots != 2 || len(r.Containers.Open) != 2 {
		t.Errorf("contenedores: %+v", r.Containers)
	}
	if r.Combat.HealthMax != 1000 {
		t.Errorf("vida máxima %d", r.Combat.HealthMax)
	}
}

// Los objetos de progresion.md §2.4 y las plantillas elegibles de habilidades.md, como los exporta Godot.
func TestEmbeddedItemsAndTemplates(t *testing.T) {
	r := embedded(t)
	want := []progress.Item{
		{ID: "bow_vado", Category: progress.CategoryWeapon, EquipSlot: progress.SlotWeapon, MaxStack: 1, RequiredLevel: 1},
		{ID: "potion_health", Category: progress.CategoryConsumable, EquipSlot: progress.SlotNone, MaxStack: 15, RequiredLevel: 1},
		{ID: "potion_stamina", Category: progress.CategoryConsumable, EquipSlot: progress.SlotNone, MaxStack: 15, RequiredLevel: 1},
		{ID: "sword_shield_vado", Category: progress.CategoryWeapon, EquipSlot: progress.SlotWeapon, MaxStack: 1, RequiredLevel: 1},
	}
	if len(r.Items) != len(want) {
		t.Fatalf("%d objetos, se esperaban %d: %+v", len(r.Items), len(want), r.Items)
	}
	for i, w := range want {
		got, ok := r.Item(w.ID)
		if !ok || got != w || r.Items[i] != w {
			t.Errorf("objeto %d: %+v (Item: %+v, %v), se esperaba %+v", i, r.Items[i], got, ok, w)
		}
	}
	if _, ok := r.Item("potion_regen"); ok {
		t.Error("Item de un objeto que no existe")
	}
	if len(r.Templates) != 2 || r.Templates[0].ID != "marksman" || r.Templates[1].ID != "squire" ||
		strings.Join(r.Templates[0].Weapons, ",") != "bow_vado,sword_shield_vado" ||
		strings.Join(r.Templates[1].Weapons, ",") != "sword_shield_vado" {
		t.Errorf("plantillas: %+v", r.Templates)
	}
	for id, want := range map[string]bool{"marksman": true, "squire": true, "": false, "npc_guard": false, "Squire": false} {
		if got := r.SelectableTemplate(id); got != want {
			t.Errorf("SelectableTemplate(%q) = %v", id, got)
		}
	}
}

// Cada byte, uno a uno, fuera de lo que permiten las reglas incrustadas (lo mismo que
// test_validate_rejects_each_index_out_of_range en Godot).
func TestEachIndexOutOfRange(t *testing.T) {
	r := embedded(t)
	base := [8]byte{1, 0, 0, 1, 1, 0, 2, 1}
	if !r.ValidAppearance(1, "race_vardheim", base) {
		t.Fatal("la base no vale")
	}
	a := r.Appearance
	// El primer valor que ya no existe en cada byte (el pelo y la barba van con +1).
	limits := []int{len(r.Races) + 1, a.BodyCount, len(a.Heads), len(a.Hairs) + 1, len(a.Beards) + 1,
		a.SkinToneCount, a.HairColorCount}
	for i, limit := range limits {
		for _, v := range []byte{byte(limit), 200, 255} {
			b := base
			b[i] = v
			if r.ValidAppearance(1, "race_vardheim", b) {
				t.Errorf("byte %d = %d vale", i, v)
			}
		}
	}
	for _, v := range []byte{0x07, 0x0F, 0x11, 0xF1} {
		b := base
		b[7] = v
		if r.ValidAppearance(1, "race_vardheim", b) {
			t.Errorf("byte 7 = %#x vale", v)
		}
	}
	for _, realm := range []int16{0, 2, 3, 4, -1} {
		if r.ValidAppearance(realm, "race_vardheim", base) {
			t.Errorf("vale en el reino %d", realm)
		}
	}
}

func TestLoadRulesRejectsBrokenFiles(t *testing.T) {
	// mutate devuelve el archivo incrustado con un cambio hecho sobre su JSON.
	mutate := func(change func(m map[string]any)) []byte {
		var m map[string]any
		if err := json.Unmarshal(gamedata.Raw(), &m); err != nil {
			t.Fatal(err)
		}
		change(m)
		b, err := json.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	obj := func(m map[string]any, path ...any) map[string]any {
		var v any = m
		for _, p := range path {
			switch k := p.(type) {
			case string:
				v = v.(map[string]any)[k]
			case int:
				v = v.([]any)[k]
			}
		}
		return v.(map[string]any)
	}
	cases := map[string][]byte{
		"no es JSON":           []byte(`{`),
		"sin races":            mutate(func(m map[string]any) { delete(m, "races") }),
		"sin appearance":       mutate(func(m map[string]any) { delete(m, "appearance") }),
		"sin level_curve":      mutate(func(m map[string]any) { delete(m, "level_curve") }),
		"sin currencies":       mutate(func(m map[string]any) { delete(m, "currencies") }),
		"sin reasons":          mutate(func(m map[string]any) { delete(m, "reasons") }),
		"sin containers":       mutate(func(m map[string]any) { delete(m, "containers") }),
		"sin combat":           mutate(func(m map[string]any) { delete(m, "combat") }),
		"campo desconocido":    mutate(func(m map[string]any) { obj(m, "races", 0)["allows_no_mustache"] = true }),
		"tipo que no casa":     mutate(func(m map[string]any) { obj(m, "races", 0)["realm"] = "vardheim" }),
		"reino 4":              mutate(func(m map[string]any) { obj(m, "races", 2)["realm"] = 4 }),
		"raza repetida":        mutate(func(m map[string]any) { obj(m, "races", 2)["id"] = "race_vardheim" }),
		"índice que no existe": mutate(func(m map[string]any) { obj(m, "races", 0)["skin_tones"] = []int{99} }),
		"índice repetido":      mutate(func(m map[string]any) { obj(m, "races", 0)["skin_tones"] = []int{0, 0} }),
		"raza sin ojos":        mutate(func(m map[string]any) { obj(m, "races", 1)["eye_colors"] = []int{} }),
		"curva corta":          mutate(func(m map[string]any) { obj(m, "level_curve")["level_cap"] = 41 }),
		"curva con un 0": mutate(func(m map[string]any) {
			obj(m, "level_curve")["xp_to_next"].([]any)[3] = 0
		}),
		"17 colores de ojos": mutate(func(m map[string]any) { obj(m, "appearance")["eye_color_count"] = 17 }),
		"sin cuerpos":        mutate(func(m map[string]any) { obj(m, "appearance")["body_count"] = 0 }),
		"pieza de un cuerpo que no existe": mutate(func(m map[string]any) {
			obj(m, "appearance", "hairs", 0)["bodies"] = []int{7}
		}),
		"id de pieza con mayúsculas": mutate(func(m map[string]any) { obj(m, "appearance", "heads", 0)["id"] = "Head" }),
		"sin pelo compatible y sin allows_no_hair": mutate(func(m map[string]any) {
			obj(m, "appearance")["body_count"] = 2
			obj(m, "appearance", "hairs", 0)["bodies"] = []int{1}
		}),
		"moneda repetida":       mutate(func(m map[string]any) { obj(m, "currencies", 1)["code"] = 1 }),
		"sin monedas":           mutate(func(m map[string]any) { m["currencies"] = []any{} }),
		"motivo fuera de rango": mutate(func(m map[string]any) { obj(m, "reasons", "codes")["reversal"] = 300 }),
		"rangos al revés":       mutate(func(m map[string]any) { obj(m, "reasons", "ranges", "sink")["min"] = 10 }),
		"bolsa vacía":           mutate(func(m map[string]any) { obj(m, "containers", "bag")["default_slots"] = 0 }),
		"vida 0":                mutate(func(m map[string]any) { obj(m, "combat")["health_max"] = 0 }),
		"sin items":             mutate(func(m map[string]any) { delete(m, "items") }),
		"sin starter_templates": mutate(func(m map[string]any) { delete(m, "starter_templates") }),
		"items vacía":           mutate(func(m map[string]any) { m["items"] = []any{} }),
		"objeto con un campo desconocido": mutate(func(m map[string]any) {
			obj(m, "items", 0)["camp_refill"] = 3
		}),
		"id de objeto corto":   mutate(func(m map[string]any) { obj(m, "items", 0)["id"] = "bo" }),
		"objeto repetido":      mutate(func(m map[string]any) { obj(m, "items", 1)["id"] = "bow_vado" }),
		"objetos desordenados": mutate(func(m map[string]any) { obj(m, "items", 0)["id"] = "zzz_bow" }),
		"categoría 7":          mutate(func(m map[string]any) { obj(m, "items", 1)["category"] = 7 }),
		"categoría 0":          mutate(func(m map[string]any) { obj(m, "items", 1)["category"] = 0 }),
		"ranura 7":             mutate(func(m map[string]any) { obj(m, "items", 0)["equip_slot"] = 7 }),
		"arma sin ranura":      mutate(func(m map[string]any) { obj(m, "items", 0)["equip_slot"] = 0 }),
		"poción equipable":     mutate(func(m map[string]any) { obj(m, "items", 1)["equip_slot"] = 1 }),
		"armadura en el arma": mutate(func(m map[string]any) {
			obj(m, "items", 0)["category"] = 2
		}),
		"pila 1000":            mutate(func(m map[string]any) { obj(m, "items", 1)["max_stack"] = 1000 }),
		"pila 0":               mutate(func(m map[string]any) { obj(m, "items", 1)["max_stack"] = 0 }),
		"arma apilable":        mutate(func(m map[string]any) { obj(m, "items", 0)["max_stack"] = 2 }),
		"durabilidad apilable": mutate(func(m map[string]any) { obj(m, "items", 1)["has_durability"] = true }),
		"nivel 41":             mutate(func(m map[string]any) { obj(m, "items", 1)["required_level"] = 41 }),
		"nivel 0":              mutate(func(m map[string]any) { obj(m, "items", 1)["required_level"] = 0 }),
		"plantilla repetida":   mutate(func(m map[string]any) { obj(m, "starter_templates", 1)["id"] = "marksman" }),
		"plantilla sin armas":  mutate(func(m map[string]any) { obj(m, "starter_templates", 1)["weapons"] = []any{} }),
		"plantilla con tres armas": mutate(func(m map[string]any) {
			obj(m, "starter_templates", 1)["weapons"] = []any{"bow_vado", "bow_vado", "sword_shield_vado"}
		}),
		"plantilla con un arma sin objeto": mutate(func(m map[string]any) {
			obj(m, "starter_templates", 1)["weapons"] = []any{""}
		}),
		"plantilla con una poción": mutate(func(m map[string]any) {
			obj(m, "starter_templates", 1)["weapons"] = []any{"potion_health"}
		}),
		"plantilla con un id que no vale": mutate(func(m map[string]any) { obj(m, "starter_templates", 0)["id"] = "Marksman" }),
	}
	for name, text := range cases {
		_, err := progress.LoadRules(text)
		if err == nil {
			t.Errorf("%s: se esperaba un error", name)
			continue
		}
		t.Logf("%s: %v", name, strings.ReplaceAll(err.Error(), "\n", " | "))
	}
	// Las secciones que este paquete no lee (las de plataforma.md, las de fases siguientes) no molestan.
	if _, err := progress.LoadRules(mutate(func(m map[string]any) { m["vendors"] = []any{map[string]any{"id": "x"}} })); err != nil {
		t.Errorf("una sección más no debería romper nada: %v", err)
	}
	// Sin plantillas elegibles el archivo vale (ninguna creación pasaría la validación de P7).
	if _, err := progress.LoadRules(mutate(func(m map[string]any) { m["starter_templates"] = []any{} })); err != nil {
		t.Errorf("starter_templates vacía: %v", err)
	}
	if _, err := progress.LoadRules(mutate(func(map[string]any) {})); err != nil {
		t.Errorf("el archivo pasado por map[string]any sigue valiendo: %v", err)
	}
}
