// Package progress es el lado Go del progreso de los personajes (progresion.md §13.2): las reglas
// exportadas por Godot y el almacén que implementa persistence.ProgressStore (progresion.md P7).
//
// De progresion.md P3 es [LoadRules]: lee de progression_rules.json (internal/gamedata) las secciones de
// progresion.md §13.4 (races, appearance, level_curve, currencies, reasons, containers y combat; items y
// starter_templates desde P1) y aplica con ellas la regla de la apariencia de CharacterAppearance.validate
// ([Rules.ValidAppearance]), la curva de niveles ([Rules.LevelFor], [Rules.TotalTo]) y las búsquedas de
// objetos y plantillas ([Rules.Item], [Rules.SelectableTemplate]). Las dos implementaciones dan lo mismo con
// los mismos datos: los casos de tests/fixtures/progression/appearance_cases.json los leen
// test_character_appearance.gd y las pruebas de este paquete.
//
// De progresion.md P7 son [Rules.ValidateCreate] (persistence.CreateValidator) y [Store]
// (persistence.ProgressStore): las tablas de 0010_progress, el guardado con S1–S8 (checks.go y write.go,
// con los casos de tests/fixtures/progression/save_cases.json que genera la zona), los resúmenes, la purga y la
// retención, la exportación y las rutas de operación y libro.
package progress

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
)

// Race es un pueblo de la sección races: su reino (código de NetProtocol.Realm, 1–3) y los índices que
// permite de cada lista del catálogo de la apariencia (desde 0; el pelo y la barba también, aunque en los
// 8 B vayan con +1).
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

// Part es una pieza del catálogo con los cuerpos con los que encaja (vacío = todos).
type Part struct {
	ID     string `json:"id"`
	Bodies []int  `json:"bodies"`
}

// fits dice si la pieza encaja con el cuerpo body.
func (p Part) fits(body int) bool {
	return len(p.Bodies) == 0 || contains(p.Bodies, body)
}

// Appearance es la sección appearance: las piezas con forma y cuántos cuerpos y colores hay.
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

// LevelCurve es la sección level_curve: la XP de cada nivel al siguiente (progresion.md §6.1).
type LevelCurve struct {
	LevelCap                int     `json:"level_cap"`
	XPToNext                []int64 `json:"xp_to_next"`
	AttributePointsPerLevel int     `json:"attribute_points_per_level"`
}

// Currency es una moneda de la sección currencies (progresion.md §5.1).
type Currency struct {
	Code int    `json:"code"`
	ID   string `json:"id"`
	Cap  int64  `json:"cap"`
}

// Range es un rango cerrado de códigos de motivo.
type Range struct {
	Min int `json:"min"`
	Max int `json:"max"`
}

// Reasons es la sección reasons (progresion.md §5.3): rangos de fuentes, sumideros e internos, los
// motivos por nombre y los tipos de operación por nombre.
type Reasons struct {
	Ranges struct {
		Source   Range `json:"source"`
		Sink     Range `json:"sink"`
		Internal Range `json:"internal"`
	} `json:"ranges"`
	Codes   map[string]int `json:"codes"`
	OpKinds map[string]int `json:"op_kinds"`
}

// Containers es la sección containers (progresion.md §4.1).
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

// Combat es la sección combat: la vida máxima (CombatRules.health_max), para S6.
type Combat struct {
	HealthMax int `json:"health_max"`
}

// Categorías de objeto (ItemDefinition.Category, progresion.md §2.1).
const (
	CategoryWeapon     = 1
	CategoryArmor      = 2
	CategoryConsumable = 3
	CategoryMaterial   = 4
	CategoryQuest      = 5
	CategoryMisc       = 6
)

// Ranuras de equipo de una definición (ItemDefinition.EquipSlot): SlotWeapon vale para las dos ranuras de
// arma; las armaduras van de SlotHead a SlotFeet.
const (
	SlotNone   = 0
	SlotWeapon = 1
	SlotHead   = 2
	SlotFeet   = 6
)

// MaxStack es el tope de una pila (ItemDefinition.MAX_STACK).
const MaxStack = 999

// Item es una definición de la sección items (progresion.md §2.1): lo que S5 mira de cada objeto.
type Item struct {
	ID            string `json:"id"`
	Category      int    `json:"category"`
	EquipSlot     int    `json:"equip_slot"`
	MaxStack      int    `json:"max_stack"`
	HasDurability bool   `json:"has_durability"`
	RequiredLevel int    `json:"required_level"`
}

// StarterTemplate es una plantilla elegible de la sección starter_templates (progresion.md §2.5): su id y
// los objetos de sus armas en orden de ranura.
type StarterTemplate struct {
	ID      string   `json:"id"`
	Weapons []string `json:"weapons"`
}

// Rules son las reglas de progresion.md leídas de progression_rules.json. Son de solo lectura: valen
// entre gorrutinas.
type Rules struct {
	Races      []Race // en el orden del catálogo: el byte 0 de la apariencia es la posición + 1
	Appearance Appearance
	LevelCurve LevelCurve
	Currencies []Currency
	Reasons    Reasons
	Containers Containers
	Combat     Combat
	Items      []Item            // en orden de net id (alfabético)
	Templates  []StarterTemplate // las EquipmentTemplate con selectable = true

	items     map[string]int // id → posición en Items
	templates map[string]int // id → posición en Templates

	// Lo que mira el almacén (P7), resuelto por nombre en check: así un motivo o un tipo que cambie de número
	// en Godot cambia aquí con el archivo.
	kinds        opKinds
	kindReasons  map[int]map[int]bool // tipo de operación → motivos de sus apuntes y eventos (S2)
	realmReasons map[int]bool         // motivos de méritos que dan puntos de reino (I9: 3–5)
	reversal     int                  // el motivo REVERSAL
	merits       int                  // el código de la moneda de los méritos
	currencyCaps map[int]int64        // código → tope
}

// opKinds son los tipos de operación (EconomyOp.Kind, progresion.md §5.3) por su nombre en reasons.op_kinds.
type opKinds struct{ player, gameplay, starterKit, gm, reversal, migration int }

// kindReasonNames son los motivos de cada tipo de operación que admite S2 (progresion.md §13.3, el
// EconomyOp.KIND_REASONS de la zona): PLAYER 64; GAMEPLAY 2–6 y 65; STARTER_KIT 1; GM 7 y 66; REVERSAL 128.
var kindReasonNames = map[string][]string{
	"player":      {"player_destroy"},
	"gameplay":    {"camp_refill", "pvp_kill", "pvp_assist", "objective", "npc_kill", "consume"},
	"starter_kit": {"starter_kit"},
	"gm":          {"gm_grant", "gm_remove"},
	"reversal":    {"reversal"},
	"migration":   {"migration"},
}

// realmReasonNames son los motivos de los méritos de juego que suben los puntos de reino (I9,
// EconomyReason.gives_realm_points).
var realmReasonNames = []string{"pvp_kill", "pvp_assist", "objective"}

// Tamaños máximos de cada lista para que su índice quepa en los 8 B (AppearanceCatalog.MAX_SIZES).
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

// LoadRules lee las secciones de progresion.md de un progression_rules.json (gamedata.Raw()) y
// comprueba que tienen sentido. Cada sección se lee estricta (campos desconocidos y tipos que no casan
// son errores); las secciones de otros (names, protocol_version) y las que aún no lee este paquete no
// cuentan.
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

// check comprueba lo mismo que AppearanceCatalog.get_errors y LevelCurve.get_errors, más lo que Go
// necesita de las demás secciones.
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

// resolveEconomy busca por su nombre los tipos de operación, los motivos y la moneda de los méritos que
// usan S2, S3 y S6, y falla si alguno no está.
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

// signMatches dice si el signo de delta cuadra con el rango de reason (progresion.md §5.2): fuentes > 0,
// sumideros < 0 e internos, cualquiera distinto de 0. Un motivo fuera de los rangos no cuadra nunca.
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

// ValidateCreate implementa persistence.CreateValidator (plataforma.md §4.4 paso 5, progresion.md §13.2):
// la raza existe y es del reino realm (código de NetProtocol.Realm), los 8 B valen para ella
// ([Rules.ValidAppearance]) y la plantilla es elegible ([Rules.SelectableTemplate]). Devuelve nil o un
// *persistence.ValidationError con un campo por fallo: race_id «unknown» (no existe) o «wrong_realm» (es de
// otro reino), appearance «invalid» (solo se mira con una raza que vale) y starter_template_id
// «not_selectable».
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

// checkItems comprueba items y starter_templates con las reglas de ItemDatabase (progresion.md §2.1) y
// rellena los índices de Item y SelectableTemplate.
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

// Item devuelve la definición del objeto id de la sección items.
func (r *Rules) Item(id string) (Item, bool) {
	i, ok := r.items[id]
	if !ok {
		return Item{}, false
	}
	return r.Items[i], true
}

// SelectableTemplate dice si id es una plantilla de inicio elegible (starter_templates), la regla de
// starter_template_id al crear el personaje (plataforma.md §4.4 paso 5).
func (r *Rules) SelectableTemplate(id string) bool {
	_, ok := r.templates[id]
	return ok
}

// ValidAppearance es CharacterAppearance.validate (progresion.md §7.2): true si los 8 B valen para un
// personaje del reino realm (código de NetProtocol.Realm) y del pueblo raceID. raceID existe, es de ese
// reino y el byte 0 es su posición + 1; cada índice está en las listas del pueblo y existe; cabeza, pelo,
// barba y marcas encajan con el cuerpo; un 0 de pelo o barba solo si el pueblo lo admite; sin marcas vale
// siempre.
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

// RaceIndex devuelve la posición del pueblo raceID en Races, o -1.
func (r *Rules) RaceIndex(raceID string) int {
	for i, race := range r.Races {
		if race.ID == raceID {
			return i
		}
	}
	return -1
}

// TotalTo es LevelCurve.total_to: la XP total para llegar a level (0 en el nivel 1; fuera de
// 1..LevelCap, el extremo más cercano).
func (r *Rules) TotalTo(level int) int64 {
	level = max(1, min(level, r.LevelCurve.LevelCap))
	var total int64
	for i := 0; i < level-1 && i < len(r.LevelCurve.XPToNext); i++ {
		total += r.LevelCurve.XPToNext[i]
	}
	return total
}

// LevelFor es LevelCurve.level_for (I8): el mayor nivel cuyo TotalTo no pasa de xpTotal.
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
