package progress

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/zones"
)

// La sección progress de un guardado (progresion.md §9.3): el ProgressRecord de §3.4 sin los campos de solo
// lectura y con el diario (ops). parseSection la lee con las reglas de S1; las demás comprobaciones miran
// estos tipos ya leídos.

// FormatVersion es el progress_format que se admite (ProgressRecord.FORMAT, el record_format de la zona).
const FormatVersion = 1

// maxChannel es el mayor canal (last_channel smallint).
const maxChannel = math.MaxInt16

// Claves de la sección y de sus partes, como las escribe la zona (ProgressRecord.SAVE_KEYS, LOCATION_KEYS,
// EconomyOp.DICTIONARY_KEYS, LedgerEntry.DICTIONARY_KEYS, ItemEvent.DICTIONARY_KEYS e ItemInstance).
var (
	sectionKeys = []string{"active_weapon_slot", "bag_slots", "health", "items", "level", "location", "ops",
		"played_seconds", "progress_format", "realm_points", "starter_granted", "timers", "wallets", "xp_total"}
	locationKeys = []string{"channel", "in_combat", "x", "y", "yaw", "z", "zone_id"}
	walletKeys   = []string{"balance", "currency"}
	itemKeys     = []string{"affixes", "bound", "container", "count", "def_id", "durability", "rarity", "seed",
		"slot", "uid"}
	timerKeys = []string{"ends_at_unix", "key"}
	opKeys    = []string{"actor_account_id", "detail", "items", "kind", "ledger", "note", "op_id", "ref_op_id"}
	entryKeys = []string{"balance_after", "currency", "delta", "reason", "ref_id", "ref_kind"}
	eventKeys = []string{"count_delta", "def_id", "reason", "uid"}
	// Solo en la reclamación (progresion.md §3.4): en un guardado son un error de S1.
	readOnlyKeys         = map[string]bool{"race_id": true, "appearance": true, "starter_template_id": true}
	readOnlyLocationKeys = map[string]bool{"saved_at_unix": true}
)

// section es la sección progress de un guardado, ya leída.
type section struct {
	level            int64
	xpTotal          int64
	realmPoints      int64
	playedSeconds    int64
	bagSlots         int64
	starterGranted   bool
	activeWeaponSlot int64
	health           *int64
	location         *location
	wallets          []wallet
	items            []item
	timers           []timer
	ops              []op
}

type location struct {
	zoneID       string
	channel      int64
	x, y, z, yaw float64
	inCombat     bool
}

type wallet struct{ currency, balance int64 }

// item es un objeto vivo de la foto (la entrada de §3.4).
type item struct {
	uid, count      int64
	defID           string
	container, slot int64
	durability      *int64
	rarity, seed    int64
	bound           bool
	affixes         []int64
}

type timer struct {
	key    string
	endsAt int64
}

// op es una operación del diario (la entrada de ops de §9.3).
type op struct {
	opID   int64
	kind   int64
	actor  *int64
	refOp  *int64
	note   *string
	detail json.RawMessage // un objeto JSON que cabe en jsonb
	ledger []entry
	items  []event
}

type entry struct{ currency, delta, balanceAfter, reason, refKind, refID int64 }

type event struct {
	uid        *int64
	defID      string
	countDelta int64
	reason     int64
}

// s1 es un error de S1 en path.
func s1(path, format string, args ...any) error {
	return &persistence.InvalidSaveError{Check: "S1", Detail: path + ": " + fmt.Sprintf(format, args...)}
}

// object es un objeto JSON con sus claves ya comprobadas.
type object struct {
	path   string
	fields map[string]json.RawMessage
}

// readObject lee raw como un objeto con exactamente las claves keys: una que falta, una que no conoce o una de
// readOnly (de solo lectura) son errores de S1.
func readObject(raw json.RawMessage, path string, keys []string, readOnly map[string]bool) (object, error) {
	o := object{path: path}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return o, s1(path, "no es un objeto")
	}
	if err := json.Unmarshal(trimmed, &o.fields); err != nil {
		return o, s1(path, "no es un objeto: %v", err)
	}
	extra := make([]string, 0)
	for k := range o.fields {
		if readOnly[k] {
			return o, s1(path, "%s es de solo lectura (solo va en la reclamación)", k)
		}
		if !containsString(keys, k) {
			extra = append(extra, k)
		}
	}
	if len(extra) > 0 {
		sort.Strings(extra)
		return o, s1(path, "clave desconocida: %s", strings.Join(extra, ", "))
	}
	for _, k := range keys {
		if _, ok := o.fields[k]; !ok {
			return o, s1(path, "falta %s", k)
		}
	}
	return o, nil
}

func containsString(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func isNull(raw json.RawMessage) bool { return string(bytes.TrimSpace(raw)) == "null" }

// int lee un entero exacto (admite 820.0, como escribe Godot).
func (o object) int(key string) (int64, error) {
	var v jsonx.Int
	if err := json.Unmarshal(o.fields[key], &v); err != nil {
		return 0, s1(o.path+"."+key, "no es un número entero")
	}
	return int64(v), nil
}

// nullableInt lee un entero exacto o null.
func (o object) nullableInt(key string) (*int64, error) {
	if isNull(o.fields[key]) {
		return nil, nil
	}
	v, err := o.int(key)
	return &v, err
}

// id lee un id: una cadena decimal de min a 2^53 − 1 (S1).
func (o object) id(key string, min int64) (int64, error) {
	var v jsonx.ID
	if err := json.Unmarshal(o.fields[key], &v); err != nil || int64(v) < min || int64(v) > jsonx.MaxSafeInt {
		return 0, s1(o.path+"."+key, "no es un id: una cadena decimal de %d a 2^53 − 1", min)
	}
	return int64(v), nil
}

// nullableID lee un id desde 1 o null.
func (o object) nullableID(key string) (*int64, error) {
	if isNull(o.fields[key]) {
		return nil, nil
	}
	v, err := o.id(key, 1)
	return &v, err
}

func (o object) bool(key string) (bool, error) {
	var v bool
	if isNull(o.fields[key]) || json.Unmarshal(o.fields[key], &v) != nil {
		return false, s1(o.path+"."+key, "no es true ni false")
	}
	return v, nil
}

func (o object) string(key string) (string, error) {
	var v string
	if isNull(o.fields[key]) || json.Unmarshal(o.fields[key], &v) != nil {
		return "", s1(o.path+"."+key, "no es una cadena")
	}
	return v, nil
}

// real lee un número que cabe en una columna real.
func (o object) real(key string) (float64, error) {
	var v float64
	if isNull(o.fields[key]) || json.Unmarshal(o.fields[key], &v) != nil || math.Abs(v) > math.MaxFloat32 {
		return 0, s1(o.path+"."+key, "no es un número que quepa en real")
	}
	return v, nil
}

// list lee una lista JSON (no null).
func (o object) list(key string) ([]json.RawMessage, error) {
	var v []json.RawMessage
	if isNull(o.fields[key]) || json.Unmarshal(o.fields[key], &v) != nil {
		return nil, s1(o.path+"."+key, "no es una lista")
	}
	return v, nil
}

// parseSection es S1 (progresion.md §13.3): progress_format 1, claves conocidas y ninguna de solo lectura, ids
// en cadena de 1 a 2^53 − 1 (seed y ref_id desde 0), los demás enteros exactos y location.zone_id igual a
// zoneID (la de la instancia que reclamó). Los rangos de cada campo los miran S2–S7; aquí solo lo que no tiene
// otra comprobación (el canal y las coordenadas, que la base no admitiría) y que detail sea un objeto que
// cabe en jsonb.
func parseSection(raw json.RawMessage, zoneID string) (*section, error) {
	o, err := readObject(raw, "progress", sectionKeys, readOnlyKeys)
	if err != nil {
		return nil, err
	}
	format, err := o.int("progress_format")
	if err != nil {
		return nil, err
	}
	if format != FormatVersion {
		return nil, s1("progress.progress_format", "es %d y solo se admite %d", format, FormatVersion)
	}
	sec := &section{}
	for _, f := range []struct {
		key string
		dst *int64
	}{{"level", &sec.level}, {"xp_total", &sec.xpTotal}, {"realm_points", &sec.realmPoints},
		{"played_seconds", &sec.playedSeconds}, {"bag_slots", &sec.bagSlots},
		{"active_weapon_slot", &sec.activeWeaponSlot}} {
		if *f.dst, err = o.int(f.key); err != nil {
			return nil, err
		}
	}
	if sec.starterGranted, err = o.bool("starter_granted"); err != nil {
		return nil, err
	}
	if sec.health, err = o.nullableInt("health"); err != nil {
		return nil, err
	}
	if !isNull(o.fields["location"]) {
		if sec.location, err = parseLocation(o.fields["location"], zoneID); err != nil {
			return nil, err
		}
	}
	if sec.wallets, err = parseList(o, "wallets", parseWallet); err != nil {
		return nil, err
	}
	if sec.items, err = parseList(o, "items", parseItem); err != nil {
		return nil, err
	}
	if sec.timers, err = parseList(o, "timers", parseTimer); err != nil {
		return nil, err
	}
	if sec.ops, err = parseList(o, "ops", parseOp); err != nil {
		return nil, err
	}
	return sec, nil
}

// parseList lee la lista key de o con parse, elemento a elemento.
func parseList[T any](o object, key string, parse func(json.RawMessage, string) (T, error)) ([]T, error) {
	raws, err := o.list(key)
	if err != nil {
		return nil, err
	}
	out := make([]T, 0, len(raws))
	for i, raw := range raws {
		v, err := parse(raw, fmt.Sprintf("%s.%s[%d]", o.path, key, i))
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func parseLocation(raw json.RawMessage, zoneID string) (*location, error) {
	o, err := readObject(raw, "progress.location", locationKeys, readOnlyLocationKeys)
	if err != nil {
		return nil, err
	}
	l := &location{}
	if l.zoneID, err = o.string("zone_id"); err != nil {
		return nil, err
	}
	if l.zoneID != zoneID {
		return nil, s1("progress.location.zone_id", "es %q y la instancia que guarda es de %q", l.zoneID, zoneID)
	}
	if l.channel, err = o.int("channel"); err != nil {
		return nil, err
	}
	if l.channel < 0 || l.channel > maxChannel {
		return nil, s1("progress.location.channel", "fuera de rango (0–%d): %d", maxChannel, l.channel)
	}
	for _, f := range []struct {
		key string
		dst *float64
	}{{"x", &l.x}, {"y", &l.y}, {"z", &l.z}, {"yaw", &l.yaw}} {
		if *f.dst, err = o.real(f.key); err != nil {
			return nil, err
		}
	}
	if l.inCombat, err = o.bool("in_combat"); err != nil {
		return nil, err
	}
	return l, nil
}

func parseWallet(raw json.RawMessage, path string) (wallet, error) {
	o, err := readObject(raw, path, walletKeys, nil)
	if err != nil {
		return wallet{}, err
	}
	var w wallet
	if w.currency, err = o.int("currency"); err != nil {
		return w, err
	}
	w.balance, err = o.int("balance")
	return w, err
}

func parseItem(raw json.RawMessage, path string) (item, error) {
	o, err := readObject(raw, path, itemKeys, nil)
	if err != nil {
		return item{}, err
	}
	var it item
	if it.uid, err = o.id("uid", 1); err != nil {
		return it, err
	}
	if it.defID, err = o.string("def_id"); err != nil {
		return it, err
	}
	for _, f := range []struct {
		key string
		dst *int64
	}{{"container", &it.container}, {"slot", &it.slot}, {"count", &it.count}, {"rarity", &it.rarity}} {
		if *f.dst, err = o.int(f.key); err != nil {
			return it, err
		}
	}
	if it.durability, err = o.nullableInt("durability"); err != nil {
		return it, err
	}
	if it.bound, err = o.bool("bound"); err != nil {
		return it, err
	}
	if it.seed, err = o.id("seed", 0); err != nil {
		return it, err
	}
	affixes, err := o.list("affixes")
	if err != nil {
		return it, err
	}
	it.affixes = make([]int64, 0, len(affixes))
	for i, a := range affixes {
		var v jsonx.Int
		if err := json.Unmarshal(a, &v); err != nil {
			return it, s1(fmt.Sprintf("%s.affixes[%d]", path, i), "no es un número entero")
		}
		it.affixes = append(it.affixes, int64(v))
	}
	return it, nil
}

func parseTimer(raw json.RawMessage, path string) (timer, error) {
	o, err := readObject(raw, path, timerKeys, nil)
	if err != nil {
		return timer{}, err
	}
	var t timer
	if t.key, err = o.string("key"); err != nil {
		return t, err
	}
	t.endsAt, err = o.int("ends_at_unix")
	return t, err
}

func parseOp(raw json.RawMessage, path string) (op, error) {
	o, err := readObject(raw, path, opKeys, nil)
	if err != nil {
		return op{}, err
	}
	var p op
	if p.opID, err = o.id("op_id", 1); err != nil {
		return p, err
	}
	if p.kind, err = o.int("kind"); err != nil {
		return p, err
	}
	if p.actor, err = o.nullableID("actor_account_id"); err != nil {
		return p, err
	}
	if p.refOp, err = o.nullableID("ref_op_id"); err != nil {
		return p, err
	}
	if !isNull(o.fields["note"]) {
		note, err := o.string("note")
		if err != nil {
			return p, err
		}
		p.note = &note
	}
	p.detail = bytes.TrimSpace(o.fields["detail"])
	if !zones.IsJSONObject(p.detail) {
		return p, s1(path+".detail", "no es un objeto JSON que quepa en jsonb")
	}
	if p.ledger, err = parseList(o, "ledger", parseEntry); err != nil {
		return p, err
	}
	p.items, err = parseList(o, "items", parseEvent)
	return p, err
}

func parseEntry(raw json.RawMessage, path string) (entry, error) {
	o, err := readObject(raw, path, entryKeys, nil)
	if err != nil {
		return entry{}, err
	}
	var e entry
	for _, f := range []struct {
		key string
		dst *int64
	}{{"currency", &e.currency}, {"delta", &e.delta}, {"balance_after", &e.balanceAfter}, {"reason", &e.reason},
		{"ref_kind", &e.refKind}} {
		if *f.dst, err = o.int(f.key); err != nil {
			return e, err
		}
	}
	e.refID, err = o.id("ref_id", 0)
	return e, err
}

func parseEvent(raw json.RawMessage, path string) (event, error) {
	o, err := readObject(raw, path, eventKeys, nil)
	if err != nil {
		return event{}, err
	}
	var e event
	if e.uid, err = o.nullableID("uid"); err != nil {
		return e, err
	}
	if e.defID, err = o.string("def_id"); err != nil {
		return e, err
	}
	if e.countDelta, err = o.int("count_delta"); err != nil {
		return e, err
	}
	e.reason, err = o.int("reason")
	return e, err
}
