package persistence

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"sync"

	"github.com/jackc/pgx/v5"
)

// MemoryProgressStore es el falso de [ProgressStore] (plataforma.md §7.5): guarda el progreso en
// memoria, sin tablas. Lo usan las pruebas de la plataforma y, hasta que exista el almacén de
// progresion.md P7, serve en dev y test (en staging y production no arranca con él): lo que guarda
// se pierde al reiniciar.
//
// No ve las transacciones: si la de quien llama se deshace, lo escrito aquí se queda. Al crear un
// personaje no importa (una creación reintentada recibe otro character_id); las pruebas que lo
// necesiten miran la base. Es seguro entre gorrutinas.
type MemoryProgressStore struct {
	mu    sync.Mutex
	chars map[int64]*memoryCharacter
	// applyHook, si no es nil, decide el resultado de Apply antes de guardar nada (pruebas: un
	// *InvalidSaveError, un error de la base…).
	applyHook func(key SaveKey, progress json.RawMessage) error
}

type memoryCharacter struct {
	worldID     int16
	params      CreateParams
	summary     Summary
	saveVersion int64
	applied     map[string]any // la última sección aplicada, sin ops; nil si ninguna
	purged      bool
}

// NewMemoryProgressStore devuelve un almacén vacío.
func NewMemoryProgressStore() *MemoryProgressStore {
	return &MemoryProgressStore{chars: map[int64]*memoryCharacter{}}
}

// SetApplyHook pone (o quita, con nil) la función que decide el resultado de Apply.
func (m *MemoryProgressStore) SetApplyHook(hook func(key SaveKey, progress json.RawMessage) error) {
	m.mu.Lock()
	m.applyHook = hook
	m.mu.Unlock()
}

// SetSummary cambia el resumen de un personaje creado (pruebas: última zona, tiempo jugado…).
func (m *MemoryProgressStore) SetSummary(characterID int64, s Summary) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.chars[characterID]; ok {
		c.summary = s
	}
}

// Has dice si el personaje tiene progreso sin purgar.
func (m *MemoryProgressStore) Has(characterID int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.chars[characterID]
	return ok && !c.purged
}

// Create implementa [ProgressStore].
func (m *MemoryProgressStore) Create(_ context.Context, _ pgx.Tx, worldID int16, characterID int64, p CreateParams) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.chars[characterID]; ok && !c.purged {
		return fmt.Errorf("persistence: el personaje %d ya tiene progreso", characterID)
	}
	m.chars[characterID] = &memoryCharacter{worldID: worldID, params: p,
		summary: Summary{RaceID: p.RaceID, Appearance: p.Appearance, Level: 1}}
	return nil
}

func (m *MemoryProgressStore) get(characterID int64) (*memoryCharacter, error) {
	c, ok := m.chars[characterID]
	if !ok || c.purged {
		return nil, ErrNotFound
	}
	return c, nil
}

// record arma el ProgressRecord de la reclamación (progresion.md §3.4): el de un personaje nuevo
// o lo último aplicado, con los campos de solo lectura.
func (c *memoryCharacter) record() map[string]any {
	rec := map[string]any{"progress_format": 1, "starter_granted": false, "level": 1, "xp_total": 0,
		"realm_points": 0, "played_seconds": 0, "bag_slots": 30, "active_weapon_slot": 0, "health": nil,
		"location": nil, "wallets": []any{}, "items": []any{}, "timers": []any{}}
	for k, v := range c.applied {
		rec[k] = v
	}
	rec["race_id"] = c.params.RaceID
	rec["appearance"] = base64.StdEncoding.EncodeToString(c.params.Appearance[:])
	rec["starter_template_id"] = c.params.StarterTemplateID
	return rec
}

// Load implementa [ProgressStore]: [ErrNotFound] si el personaje no tiene progreso.
func (m *MemoryProgressStore) Load(_ context.Context, _ Querier, characterID int64) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, err := m.get(characterID)
	if err != nil {
		return nil, err
	}
	return json.Marshal(c.record())
}

// Apply implementa [ProgressStore]. Solo comprueba que la sección es un objeto con
// progress_format 1 (S1) y que el personaje existe; guarda la sección sin ops y saca de ella el
// nivel, el tiempo jugado y la última zona del resumen.
func (m *MemoryProgressStore) Apply(_ context.Context, _ pgx.Tx, key SaveKey, progress json.RawMessage) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.applyHook != nil {
		if err := m.applyHook(key, progress); err != nil {
			return 0, err
		}
	}
	c, err := m.get(key.CharacterID)
	if err != nil {
		return 0, &InvalidSaveError{Check: "S1", Detail: "el personaje no tiene progreso"}
	}
	var section map[string]any
	dec := json.NewDecoder(bytes.NewReader(progress))
	dec.UseNumber()
	if err := dec.Decode(&section); err != nil || section == nil {
		return 0, &InvalidSaveError{Check: "S1", Detail: "la sección progress no es un objeto JSON"}
	}
	if f, ok := whole(section["progress_format"]); !ok || f != 1 {
		return 0, &InvalidSaveError{Check: "S1", Detail: "progress_format distinto de 1"}
	}
	delete(section, "ops")
	c.applied = section
	if v, ok := whole(section["level"]); ok {
		c.summary.Level = int(v)
	}
	if v, ok := whole(section["played_seconds"]); ok {
		c.summary.PlayedSeconds = v
	}
	if loc, ok := section["location"].(map[string]any); ok {
		if zone, ok := loc["zone_id"].(string); ok {
			c.summary.LastZoneID = zone
		}
		if v, ok := whole(loc["channel"]); ok {
			c.summary.LastChannel = int(v)
		}
	}
	c.saveVersion++
	return c.saveVersion, nil
}

// whole lee un número entero del JSON, también con decimales nulos (Godot escribe 7.0).
func whole(v any) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	if err != nil || f != math.Trunc(f) || math.Abs(f) > 1<<53 {
		return 0, false
	}
	return int64(f), true
}

// Summaries implementa [ProgressStore]: solo los que tienen progreso sin purgar.
func (m *MemoryProgressStore) Summaries(_ context.Context, _ Querier, characterIDs []int64) (map[int64]Summary, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[int64]Summary, len(characterIDs))
	for _, id := range characterIDs {
		if c, err := m.get(id); err == nil {
			out[id] = c.summary
		}
	}
	return out, nil
}

// Purge implementa [ProgressStore]: borra el progreso (no hay libro que dejar).
func (m *MemoryProgressStore) Purge(_ context.Context, _ pgx.Tx, characterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.chars[characterID]; ok {
		c.purged, c.applied = true, nil
	}
	return nil
}

// PurgeRetention implementa [ProgressStore]: el falso no tiene libro, así que no borra nada ni da
// lápidas vacías (las borra la retención de verdad, progresion.md P7).
func (m *MemoryProgressStore) PurgeRetention(context.Context, pgx.Tx) (int64, []int64, error) {
	return 0, nil, nil
}

// Export implementa [ProgressStore]: {"record": …, "ops": []}, con record null en una lápida.
func (m *MemoryProgressStore) Export(_ context.Context, _ Querier, characterID int64) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var rec any
	if c, err := m.get(characterID); err == nil {
		rec = c.record()
	}
	return json.Marshal(map[string]any{"record": rec, "ops": []any{}})
}

// Op implementa [ProgressStore]: el falso no tiene operaciones.
func (m *MemoryProgressStore) Op(context.Context, Querier, int64, [16]byte) (json.RawMessage, error) {
	return nil, ErrNotFound
}

// Ledger implementa [ProgressStore]: un libro vacío, o [ErrNotFound] si el personaje no tiene
// progreso.
func (m *MemoryProgressStore) Ledger(_ context.Context, _ Querier, characterID int64, _ int, _ int64) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, err := m.get(characterID); err != nil {
		return nil, err
	}
	return json.RawMessage(`{"entries":[]}`), nil
}

var _ ProgressStore = (*MemoryProgressStore)(nil)
var _ CreateValidator = ProvisionalValidator{}
