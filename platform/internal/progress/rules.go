// Package progress is the Go side of character progress (progresion.md §13.2): the rules
// exported by Godot and the store that implements persistence.ProgressStore (progresion.md P7).
//
// From progresion.md P3 comes [LoadRules]: it reads from progression_rules.json
// (internal/gamedata) the sections of progresion.md §13.4 (races, appearance, level_curve,
// currencies, reasons, containers and combat; items and starter_templates since P1) and applies
// with them the appearance rule of CharacterAppearance.validate ([Rules.ValidAppearance]), the
// level curve ([Rules.LevelFor], [Rules.TotalTo]) and the object and template lookups
// ([Rules.Item], [Rules.SelectableTemplate]). The two implementations give the same results with
// the same data: the cases in tests/fixtures/progression/appearance_cases.json are read by
// test_character_appearance.gd and by this package's tests.
//
// From progresion.md P7 come [Rules.ValidateCreate] (persistence.CreateValidator) and [Store]
// (persistence.ProgressStore): the 0010_progress tables, the save with S1–S8 (checks.go and
// write.go, with the cases from tests/fixtures/progression/save_cases.json that the zone
// generates), the summaries, the purge and the retention, the export and the operation and
// ledger routes.
package progress

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
)

// Race is a people in the races section: its realm (NetProtocol.Realm code, 1–3) and the indices
// it allows from each list of the appearance catalog (from 0; hair and beard too, although in the
// 8 B they go with +1).
type Race struct {
	ID            string `json:"id"`
	Realm         int16  `json:"realm"`
	AllowsNoHair  bool   `json:"allows_no_hair"`
	AllowsNoBeard bool   `json:"allows_no_beard"`
	Bodies        []int  `json:"bodies"`
	Heads         []int  `json:"heads"`
	Hairs         []int  `json:"hairs"`
	Beards        []int  `json:"beards"`
	Marks         []int  `json:"marks"`
	SkinTones     []int  `json:"skin_tones"`
	HairColors    []int  `json:"hair_colors"`
	EyeColors     []int  `json:"eye_colors"`
}

// Part is a catalog piece with the bodies it fits (empty = all).
type Part struct {
	ID     string `json:"id"`
	Bodies []int  `json:"bodies"`
}

// fits says whether the piece fits the given body.
func (p Part) fits(body int) bool {
	return len(p.Bodies) == 0 || contains(p.Bodies, body)
}

// Appearance is the appearance section: the shaped pieces and how many bodies and colors there are.
type Appearance struct {
	BodyCount      int    `json:"body_count"`
	Heads          []Part `json:"heads"`
	Hairs          []Part `json:"hairs"`
	Beards         []Part `json:"beards"`
	Marks          []Part `json:"marks"`
	SkinToneCount  int    `json:"skin_tone_count"`
	HairColorCount int    `json:"hair_color_count"`
	EyeColorCount  int    `json:"eye_color_count"`
}

// LevelCurve is the level_curve section: the XP from each level to the next (progresion.md §6.1).
type LevelCurve struct {
	LevelCap                int     `json:"level_cap"`
	XPToNext                []int64 `json:"xp_to_next"`
	AttributePointsPerLevel int     `json:"attribute_points_per_level"`
}

// Currency is a currency in the currencies section (progresion.md §5.1).
type Currency struct {
	Code int    `json:"code"`
	ID   string `json:"id"`
	Cap  int64  `json:"cap"`
}

// Range is a closed range of reason codes.
type Range struct {
	Min int `json:"min"`
	Max int `json:"max"`
}

// Reasons is the reasons section (progresion.md §5.3): ranges of sources, sinks and internal
// ones, the reasons by name and the operation types by name.
type Reasons struct {
	Ranges struct {
		Source   Range `json:"source"`
		Sink     Range `json:"sink"`
		Internal Range `json:"internal"`
	} `json:"ranges"`
	Codes   map[string]int `json:"codes"`
	OpKinds map[string]int `json:"op_kinds"`
}

// Containers is the containers section (progresion.md §4.1).
type Containers struct {
	Bag struct {
		Code         int `json:"code"`
		DefaultSlots int `json:"default_slots"`
		MaxSlots     int `json:"max_slots"`
	} `json:"bag"`
	Equipment struct {
		Code      int `json:"code"`
		Slots     int `json:"slots"`
		OpenSlots int `json:"open_slots"`
	} `json:"equipment"`
	Open []int `json:"open"`
}

// Combat is the combat section: maximum health (CombatRules.health_max), for S6.
type Combat struct {
	HealthMax int `json:"health_max"`
}

// Item categories (ItemDefinition.Category, progresion.md §2.1).
const (
	CategoryWeapon     = 1
	CategoryArmor      = 2
	CategoryConsumable = 3
	CategoryMaterial   = 4
	CategoryQuest      = 5
	CategoryMisc       = 6
)

// Equipment slots of a definition (ItemDefinition.EquipSlot): SlotWeapon covers both weapon
// slots; armor goes from SlotHead to SlotFeet.
const (
	SlotNone   = 0
	SlotWeapon = 1
	SlotHead   = 2
	SlotFeet   = 6
)

// MaxStack is the cap of a stack (ItemDefinition.MAX_STACK).
const MaxStack = 999

// Item is a definition in the items section (progresion.md §2.1): what S5 looks at for each object.
type Item struct {
	ID            string `json:"id"`
	Category      int    `json:"category"`
	EquipSlot     int    `json:"equip_slot"`
	MaxStack      int    `json:"max_stack"`
	HasDurability bool   `json:"has_durability"`
	RequiredLevel int    `json:"required_level"`
}

// StarterTemplate is a selectable template in the starter_templates section (progresion.md
// §2.5): its id and the objects of its weapons in slot order.
type StarterTemplate struct {
	ID      string   `json:"id"`
	Weapons []string `json:"weapons"`
}

// Rules are the progresion.md rules read from progression_rules.json. They are read-only: they
// are safe to share between goroutines.
type Rules struct {
	Races      []Race // in catalog order: byte 0 of the appearance is the position + 1
	Appearance Appearance
	LevelCurve LevelCurve
	Currencies []Currency
	Reasons    Reasons
	Containers Containers
	Combat     Combat
	Items      []Item            // in net id order (alphabetical)
	Templates  []StarterTemplate // the EquipmentTemplate entries with selectable = true

	items     map[string]int // id → position in Items
	templates map[string]int // id → position in Templates

	// What the store (P7) looks at, resolved by name in check: this way a reason or a type whose
	// number changes in Godot changes here with the file.
	kinds        opKinds
	kindReasons  map[int]map[int]bool // operation type → reasons of its entries and events (S2)
	realmReasons map[int]bool         // merit reasons that give realm points (I9: 3–5)
	reversal     int                  // the REVERSAL reason
	merits       int                  // the merits currency code
	currencyCaps map[int]int64        // code → cap
}

// opKinds are the operation types (EconomyOp.Kind, progresion.md §5.3) by their name in reasons.op_kinds.
type opKinds struct{ player, gameplay, starterKit, gm, reversal, migration int }

// kindReasonNames are the reasons of each operation type that S2 admits (progresion.md §13.3,
// the zone's EconomyOp.KIND_REASONS): PLAYER 64; GAMEPLAY 2–6 and 65; STARTER_KIT 1; GM 7 and 66; REVERSAL 128.
var kindReasonNames = map[string][]string{
	"player":      {"player_destroy"},
	"gameplay":    {"camp_refill", "pvp_kill", "pvp_assist", "objective", "npc_kill", "consume"},
	"starter_kit": {"starter_kit"},
	"gm":          {"gm_grant", "gm_remove"},
	"reversal":    {"reversal"},
	"migration":   {"migration"},
}

// realmReasonNames are the reasons of the gameplay merits that raise realm points (I9,
// EconomyReason.gives_realm_points).
var realmReasonNames = []string{"pvp_kill", "pvp_assist", "objective"}

// Maximum sizes of each list so that its index fits in the 8 B (AppearanceCatalog.MAX_SIZES).
const (
	maxRaces     = 255
	maxBodies    = 256
	maxHeads     = 256
	maxHairs     = 255
	maxBeards    = 255
	maxMarks     = 15
	maxColors    = 256
	maxEyeColors = 16
)

var (
	idPattern     = regexp.MustCompile(`^[a-z0-9_]{1,32}$`)
	itemIDPattern = regexp.MustCompile(`^[a-z0-9_]{3,32}$`) // ItemDefinition.ID_PATTERN
)

// LoadRules reads the progresion.md sections of a progression_rules.json (gamedata.Raw()) and
// checks that they make sense. Each section is read strictly (unknown fields and mismatched types
// are errors); sections belonging to others (names, protocol_version) and those this package does
// not read yet do not count.
func LoadRules(raw []byte) (*Rules, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		return nil, fmt.Errorf("progress: progression_rules.json no es JSON válido: %w", err)
	}
	r := &Rules{}
	sections := []struct {
		key string
		dst any
	}{
		{"races", &r.Races}, {"appearance", &r.Appearance}, {"level_curve", &r.LevelCurve},
		{"currencies", &r.Currencies}, {"reasons", &r.Reasons}, {"containers", &r.Containers},
		{"combat", &r.Combat}, {"items", &r.Items}, {"starter_templates", &r.Templates},
	}
	for _, s := range sections {
		v, ok := top[s.key]
		if !ok {
			return nil, fmt.Errorf("progress: falta la sección %q de progression_rules.json", s.key)
		}
		if err := jsonx.DecodeBytes(v, s.dst); err != nil {
			return nil, fmt.Errorf("progress: sección %q: %w", s.key, err)
		}
	}
	if err := r.check(); err != nil {
		return nil, err
	}
	return r, nil
}

// check verifies the same as AppearanceCatalog.get_errors and LevelCurve.get_errors, plus what Go
// needs from the other sections.
func (r *Rules) check() error {
	var errs []error
	fail := func(format string, args ...any) { errs = append(errs, fmt.Errorf("progress: "+format, args...)) }
	a := r.Appearance
	sizes := []struct {
		name     string
		n, max   int
		required bool
	}{
		{"races", len(r.Races), maxRaces, false}, {"bodies", a.BodyCount, maxBodies, true},
		{"heads", len(a.Heads), maxHeads, true}, {"hairs", len(a.Hairs), maxHairs, false},
		{"beards", len(a.Beards), maxBeards, false}, {"marks", len(a.Marks), maxMarks, false},
		{"skin_tones", a.SkinToneCount, maxColors, true}, {"hair_colors", a.HairColorCount, maxColors, true},
		{"eye_colors", a.EyeColorCount, maxEyeColors, true},
	}
	for _, s := range sizes {
		if s.n > s.max {
			fail("appearance: %s tiene %d entradas y caben %d", s.name, s.n, s.max)
		}
		if s.required && s.n < 1 {
			fail("appearance: %s está vacía: ninguna apariencia sería válida", s.name)
		}
	}
	for _, l := range []struct {
		name  string
		parts []Part
	}{{"heads", a.Heads}, {"hairs", a.Hairs}, {"beards", a.Beards}, {"marks", a.Marks}} {
		seen := map[string]bool{}
		for i, p := range l.parts {
			if !idPattern.MatchString(p.ID) || seen[p.ID] {
				fail("appearance: %s[%d] con un id que no vale o repetido: %q", l.name, i, p.ID)
			}
			seen[p.ID] = true
			for _, b := range p.Bodies {
				if b < 0 || b >= a.BodyCount {
					fail("appearance: %s[%d] (%s): el cuerpo %d no existe", l.name, i, p.ID, b)
				}
			}
		}
	}
	seenRace := map[string]bool{}
	for _, race := range r.Races {
		if !idPattern.MatchString(race.ID) || seenRace[race.ID] {
			fail("races: id que no vale o repetido: %q", race.ID)
		}
		seenRace[race.ID] = true
		if race.Realm < 1 || race.Realm > 3 {
			fail("races: %s: el reino %d no es un reino jugable (1–3)", race.ID, race.Realm)
		}
		lists := []struct {
			name    string
			indices []int
			size    int
		}{
			{"bodies", race.Bodies, a.BodyCount}, {"heads", race.Heads, len(a.Heads)},
			{"hairs", race.Hairs, len(a.Hairs)}, {"beards", race.Beards, len(a.Beards)},
			{"marks", race.Marks, len(a.Marks)}, {"skin_tones", race.SkinTones, a.SkinToneCount},
			{"hair_colors", race.HairColors, a.HairColorCount}, {"eye_colors", race.EyeColors, a.EyeColorCount},
		}
		for _, l := range lists {
			seen := map[int]bool{}
			for _, i := range l.indices {
				if i < 0 || i >= l.size || seen[i] {
					fail("races: %s: %s %d no existe o está repetido", race.ID, l.name, i)
				}
				seen[i] = true
			}
		}
		for _, l := range []struct {
			name    string
			indices []int
		}{{"bodies", race.Bodies}, {"skin_tones", race.SkinTones}, {"hair_colors", race.HairColors},
			{"eye_colors", race.EyeColors}} {
			if len(l.indices) == 0 {
				fail("races: %s: no permite ningún %s", race.ID, l.name)
			}
		}
		for _, body := range race.Bodies {
			if !anyFits(race.Heads, a.Heads, body) {
				fail("races: %s: ninguna cabeza encaja con el cuerpo %d", race.ID, body)
			}
			if !race.AllowsNoHair && !anyFits(race.Hairs, a.Hairs, body) {
				fail("races: %s: sin pelo compatible con el cuerpo %d y sin allows_no_hair", race.ID, body)
			}
			if !race.AllowsNoBeard && !anyFits(race.Beards, a.Beards, body) {
				fail("races: %s: sin barba compatible con el cuerpo %d y sin allows_no_beard", race.ID, body)
			}
		}
	}
	c := r.LevelCurve
	if c.LevelCap < 2 || len(c.XPToNext) != c.LevelCap-1 {
		fail("level_curve: %d valores para el tope %d", len(c.XPToNext), c.LevelCap)
	}
	for i, xp := range c.XPToNext {
		if xp <= 0 {
			fail("level_curve: xp_to_next[%d] = %d no es mayor que 0", i, xp)
		}
	}
	if c.AttributePointsPerLevel < 0 {
		fail("level_curve: attribute_points_per_level negativo")
	}
	if len(r.Currencies) == 0 {
		fail("currencies: no hay ninguna moneda")
	}
	seenCode := map[int]bool{}
	for _, cur := range r.Currencies {
		if cur.Code < 1 || seenCode[cur.Code] || cur.Cap <= 0 || !idPattern.MatchString(cur.ID) {
			fail("currencies: moneda que no vale o repetida: %+v", cur)
		}
		seenCode[cur.Code] = true
	}
	rg := r.Reasons.Ranges
	if !(rg.Source.Min >= 1 && rg.Source.Min <= rg.Source.Max && rg.Source.Max < rg.Sink.Min &&
		rg.Sink.Min <= rg.Sink.Max && rg.Sink.Max < rg.Internal.Min && rg.Internal.Min <= rg.Internal.Max &&
		rg.Internal.Max <= 255) {
		fail("reasons: rangos que no tienen sentido: %+v", rg)
	}
	for name, code := range r.Reasons.Codes {
		if code < rg.Source.Min || code > rg.Internal.Max {
			fail("reasons: el motivo %s (%d) no está en ningún rango", name, code)
		}
	}
	if len(r.Reasons.Codes) == 0 || len(r.Reasons.OpKinds) == 0 {
		fail("reasons: faltan los motivos o los tipos de operación")
	}
	if len(r.Containers.Open) == 0 || r.Containers.Bag.DefaultSlots < 1 ||
		r.Containers.Bag.MaxSlots < r.Containers.Bag.DefaultSlots || r.Containers.Equipment.Slots < 1 {
		fail("containers: valores que no tienen sentido: %+v", r.Containers)
	}
	if r.Combat.HealthMax < 1 {
		fail("combat: health_max tiene que ser mayor que 0")
	}
	r.checkItems(fail)
	r.resolveEconomy(fail)
	return errors.Join(errs...)
}

// resolveEconomy looks up by name the operation types, reasons and merits currency that S2, S3
// and S6 use, and fails if any is missing.
func (r *Rules) resolveEconomy(fail func(format string, args ...any)) {
	kind := func(name string) int {
		v, ok := r.Reasons.OpKinds[name]
		if !ok {
			fail("reasons: falta el tipo de operación %q", name)
		}
		return v
	}
	reason := func(name string) int {
		v, ok := r.Reasons.Codes[name]
		if !ok {
			fail("reasons: falta el motivo %q", name)
		}
		return v
	}
	r.kinds = opKinds{player: kind("player"), gameplay: kind("gameplay"), starterKit: kind("starter_kit"),
		gm: kind("gm"), reversal: kind("reversal"), migration: kind("migration")}
	r.kindReasons = map[int]map[int]bool{}
	for name, reasons := range kindReasonNames {
		set := map[int]bool{}
		for _, rn := range reasons {
			set[reason(rn)] = true
		}
		r.kindReasons[kind(name)] = set
	}
	r.realmReasons = map[int]bool{}
	for _, rn := range realmReasonNames {
		r.realmReasons[reason(rn)] = true
	}
	r.reversal = reason("reversal")
	r.currencyCaps = map[int]int64{}
	r.merits = 0
	for _, c := range r.Currencies {
		r.currencyCaps[c.Code] = c.Cap
		if c.ID == "merits" {
			r.merits = c.Code
		}
	}
	if r.merits == 0 {
		fail("currencies: falta la moneda merits (los puntos de reino, I9)")
	}
}

// signMatches says whether the sign of delta fits the range of reason (progresion.md §5.2):
// sources > 0, sinks < 0 and internal ones, anything other than 0. A reason outside the ranges
// never fits.
func (r *Rules) signMatches(reason int, delta int64) bool {
	rg := r.Reasons.Ranges
	switch {
	case delta == 0:
		return false
	case reason >= rg.Source.Min && reason <= rg.Source.Max:
		return delta > 0
	case reason >= rg.Sink.Min && reason <= rg.Sink.Max:
		return delta < 0
	case reason >= rg.Internal.Min && reason <= rg.Internal.Max:
		return true
	}
	return false
}

// ValidateCreate implements persistence.CreateValidator (plataforma.md §4.4 step 5, progresion.md
// §13.2): the race exists and belongs to realm realm (NetProtocol.Realm code), the 8 B are valid
// for it ([Rules.ValidAppearance]) and the template is selectable ([Rules.SelectableTemplate]). It
// returns nil or a *persistence.ValidationError with one field per failure: race_id "unknown"
// (does not exist) or "wrong_realm" (belongs to another realm), appearance "invalid" (only checked
// with a valid race) and starter_template_id "not_selectable".
func (r *Rules) ValidateCreate(realm int16, raceID string, appearance [8]byte, templateID string) error {
	fields := map[string]string{}
	switch i := r.RaceIndex(raceID); {
	case i < 0:
		fields["race_id"] = "unknown"
	case r.Races[i].Realm != realm:
		fields["race_id"] = "wrong_realm"
	case !r.ValidAppearance(realm, raceID, appearance):
		fields["appearance"] = "invalid"
	}
	if !r.SelectableTemplate(templateID) {
		fields["starter_template_id"] = "not_selectable"
	}
	if len(fields) > 0 {
		return &persistence.ValidationError{Fields: fields}
	}
	return nil
}

var _ persistence.CreateValidator = (*Rules)(nil)

// checkItems checks items and starter_templates with the ItemDatabase rules (progresion.md §2.1)
// and fills in the indices for Item and SelectableTemplate.
func (r *Rules) checkItems(fail func(format string, args ...any)) {
	if len(r.Items) == 0 {
		fail("items: no hay ningún objeto")
	}
	if len(r.Items) > 0xFFFF {
		fail("items: hay %d objetos y caben %d", len(r.Items), 0xFFFF)
	}
	r.items = make(map[string]int, len(r.Items))
	for i, it := range r.Items {
		if !itemIDPattern.MatchString(it.ID) {
			fail("items[%d]: el id %q no tiene el formato %s", i, it.ID, itemIDPattern)
		}
		if _, dup := r.items[it.ID]; dup {
			fail("items: el id %q está repetido", it.ID)
		}
		if i > 0 && it.ID <= r.Items[i-1].ID {
			fail("items: %q no sigue el orden alfabético (el de los net ids)", it.ID)
		}
		r.items[it.ID] = i
		if it.Category < CategoryWeapon || it.Category > CategoryMisc {
			fail("items: %s: categoría fuera de rango (%d)", it.ID, it.Category)
		}
		if it.EquipSlot < SlotNone || it.EquipSlot > SlotFeet {
			fail("items: %s: ranura fuera de rango (%d)", it.ID, it.EquipSlot)
		}
		switch it.Category {
		case CategoryWeapon:
			if it.EquipSlot != SlotWeapon {
				fail("items: %s: un arma va en la ranura WEAPON", it.ID)
			}
		case CategoryArmor:
			if it.EquipSlot < SlotHead || it.EquipSlot > SlotFeet {
				fail("items: %s: una armadura va en una ranura de HEAD a FEET", it.ID)
			}
		default:
			if it.EquipSlot != SlotNone {
				fail("items: %s: solo las armas y las armaduras se equipan", it.ID)
			}
		}
		if it.MaxStack < 1 || it.MaxStack > MaxStack {
			fail("items: %s: max_stack fuera de rango (1-%d): %d", it.ID, MaxStack, it.MaxStack)
		}
		if (it.EquipSlot != SlotNone || it.HasDurability) && it.MaxStack != 1 {
			fail("items: %s: un equipable o un objeto con durabilidad no se apila", it.ID)
		}
		if it.RequiredLevel < 1 || it.RequiredLevel > r.LevelCurve.LevelCap {
			fail("items: %s: required_level fuera de rango (1-%d): %d", it.ID, r.LevelCurve.LevelCap, it.RequiredLevel)
		}
	}
	r.templates = make(map[string]int, len(r.Templates))
	for i, t := range r.Templates {
		if !idPattern.MatchString(t.ID) {
			fail("starter_templates[%d]: el id %q no vale", i, t.ID)
		}
		if _, dup := r.templates[t.ID]; dup {
			fail("starter_templates: el id %q está repetido", t.ID)
		}
		r.templates[t.ID] = i
		if len(t.Weapons) < 1 || len(t.Weapons) > 2 {
			fail("starter_templates: %s: debe llevar una o dos armas (lleva %d)", t.ID, len(t.Weapons))
		}
		for _, w := range t.Weapons {
			if it, ok := r.Item(w); !ok || it.Category != CategoryWeapon {
				fail("starter_templates: %s: %q no es un arma de items", t.ID, w)
			}
		}
	}
}

// Item returns the definition of object id from the items section.
func (r *Rules) Item(id string) (Item, bool) {
	i, ok := r.items[id]
	if !ok {
		return Item{}, false
	}
	return r.Items[i], true
}

// SelectableTemplate says whether id is a selectable starter template (starter_templates), the
// rule for starter_template_id when creating the character (plataforma.md §4.4 step 5).
func (r *Rules) SelectableTemplate(id string) bool {
	_, ok := r.templates[id]
	return ok
}

// ValidAppearance is CharacterAppearance.validate (progresion.md §7.2): true if the 8 B are valid
// for a character of realm realm (NetProtocol.Realm code) and of people raceID. raceID exists,
// belongs to that realm and byte 0 is its position + 1; each index is in the people's lists and
// exists; head, hair, beard and marks fit the body; a 0 for hair or beard only if the people
// allows it; no marks is always valid.
func (r *Rules) ValidAppearance(realm int16, raceID string, appearance [8]byte) bool {
	index := int(appearance[0]) - 1
	if index < 0 || index >= len(r.Races) {
		return false
	}
	race := r.Races[index]
	if race.ID != raceID || race.Realm != realm {
		return false
	}
	a := r.Appearance
	body := int(appearance[1])
	if !allowed(race.Bodies, body, a.BodyCount) || !partFits(race.Heads, a.Heads, int(appearance[2]), body) {
		return false
	}
	hair, beard := int(appearance[3]), int(appearance[4])
	eyes, marks := int(appearance[7]&0x0F), int(appearance[7]>>4)
	switch {
	case hair == 0 && !race.AllowsNoHair, hair != 0 && !partFits(race.Hairs, a.Hairs, hair-1, body):
		return false
	case beard == 0 && !race.AllowsNoBeard, beard != 0 && !partFits(race.Beards, a.Beards, beard-1, body):
		return false
	case marks != 0 && !partFits(race.Marks, a.Marks, marks-1, body):
		return false
	}
	return allowed(race.SkinTones, int(appearance[5]), a.SkinToneCount) &&
		allowed(race.HairColors, int(appearance[6]), a.HairColorCount) &&
		allowed(race.EyeColors, eyes, a.EyeColorCount)
}

// RaceIndex returns the position of people raceID in Races, or -1.
func (r *Rules) RaceIndex(raceID string) int {
	for i, race := range r.Races {
		if race.ID == raceID {
			return i
		}
	}
	return -1
}

// TotalTo is LevelCurve.total_to: the total XP to reach level (0 at level 1; outside
// 1..LevelCap, the nearest end).
func (r *Rules) TotalTo(level int) int64 {
	level = max(1, min(level, r.LevelCurve.LevelCap))
	var total int64
	for i := 0; i < level-1 && i < len(r.LevelCurve.XPToNext); i++ {
		total += r.LevelCurve.XPToNext[i]
	}
	return total
}

// LevelFor is LevelCurve.level_for (I8): the highest level whose TotalTo does not exceed xpTotal.
func (r *Rules) LevelFor(xpTotal int64) int {
	level := 1
	var total int64
	for level < r.LevelCurve.LevelCap && level-1 < len(r.LevelCurve.XPToNext) {
		total += r.LevelCurve.XPToNext[level-1]
		if xpTotal < total {
			break
		}
		level++
	}
	return level
}

func contains(list []int, v int) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func allowed(list []int, index, size int) bool {
	return index >= 0 && index < size && contains(list, index)
}

func partFits(list []int, parts []Part, index, body int) bool {
	return allowed(list, index, len(parts)) && parts[index].fits(body)
}

func anyFits(list []int, parts []Part, body int) bool {
	for _, i := range list {
		if i >= 0 && i < len(parts) && parts[i].fits(body) {
			return true
		}
	}
	return false
}
