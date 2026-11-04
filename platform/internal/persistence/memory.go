package persistence

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"sync"

	"github.com/jackc/pgx/v5"
)

// MemoryProgressStore is the fake of [ProgressStore] (plataforma.md §7.5): it keeps the progression
// in memory, without tables. Only the platform's tests use it (platformtest); serve and the admin
// command use the real store of progresion.md P7 (internal/progress).
//
// It does not see transactions: if the caller's is rolled back, what was written here stays. When
// creating a character it does not matter (a retried creation gets another character_id); tests that
// need it look at the database. It is safe across goroutines.
type MemoryProgressStore struct {
	mu    sync.Mutex
	chars map[int64]*memoryCharacter
	// applyHook, if not nil, decides Apply's result before saving anything (tests: an
	// *InvalidSaveError, a database error...).
	applyHook func(key SaveKey, progress json.RawMessage) error
	// applyTxHook, if not nil, runs inside the save's transaction before saving anything (tests:
	// writing something that fails on COMMIT).
	applyTxHook func(ctx context.Context, tx pgx.Tx, key SaveKey, progress json.RawMessage) error
	// ops are the op_ids already applied (for the fake's S2) and Op's operations.
	appliedOps map[int64]bool
	ops        map[int64]memoryOp
}

// memoryOp is an operation of the fake: the body that Op returns and its participants.
type memoryOp struct {
	participants []int64
	body         json.RawMessage
}

type memoryCharacter struct {
	worldID     int16
	params      CreateParams
	summary     Summary
	saveVersion int64
	applied     map[string]any // the last section applied, without ops; nil if none
	purged      bool
}

// NewMemoryProgressStore returns an empty store.
func NewMemoryProgressStore() *MemoryProgressStore {
	return &MemoryProgressStore{chars: map[int64]*memoryCharacter{}, appliedOps: map[int64]bool{},
		ops: map[int64]memoryOp{}}
}

// SetApplyTxHook sets (or removes, with nil) the function that runs inside Apply's transaction
// before saving anything; if it returns an error, Apply returns it.
func (m *MemoryProgressStore) SetApplyTxHook(hook func(ctx context.Context, tx pgx.Tx, key SaveKey,
	progress json.RawMessage) error) {
	m.mu.Lock()
	m.applyTxHook = hook
	m.mu.Unlock()
}

// AddOp adds an operation that Op will return with body if any of its participants has a lease on
// the instance asking.
func (m *MemoryProgressStore) AddOp(opID int64, participants []int64, body json.RawMessage) {
	m.mu.Lock()
	m.ops[opID] = memoryOp{participants: append([]int64(nil), participants...), body: body}
	m.mu.Unlock()
}

// SaveVersion returns the character's save_version (0 if it has no progression).
func (m *MemoryProgressStore) SaveVersion(characterID int64) int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.chars[characterID]; ok {
		return c.saveVersion
	}
	return 0
}

// Applied returns the last progress section applied (without ops), or nil.
func (m *MemoryProgressStore) Applied(characterID int64) map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.chars[characterID]; ok && c.applied != nil {
		out := make(map[string]any, len(c.applied))
		for k, v := range c.applied {
			out[k] = v
		}
		return out
	}
	return nil
}

// SetApplyHook sets (or removes, with nil) the function that decides Apply's result.
func (m *MemoryProgressStore) SetApplyHook(hook func(key SaveKey, progress json.RawMessage) error) {
	m.mu.Lock()
	m.applyHook = hook
	m.mu.Unlock()
}

// SetSummary changes the summary of a created character (tests: last zone, play time...).
func (m *MemoryProgressStore) SetSummary(characterID int64, s Summary) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.chars[characterID]; ok {
		c.summary = s
	}
}

// Has says whether the character has unpurged progression.
func (m *MemoryProgressStore) Has(characterID int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.chars[characterID]
	return ok && !c.purged
}

// Create implements [ProgressStore].
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

// record builds the claim's ProgressRecord (progresion.md §3.4): a new character's or the last one
// applied, with the read-only fields.
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

// Load implements [ProgressStore]: [ErrNotFound] if the character has no progression.
func (m *MemoryProgressStore) Load(_ context.Context, _ Querier, characterID int64) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, err := m.get(characterID)
	if err != nil {
		return nil, err
	}
	return json.Marshal(c.record())
}

// Apply implements [ProgressStore]. It only checks that the section is an object with
// progress_format 1 (S1), that the character exists and, like S2, that no op_id in ops was applied
// before; it stores the section without ops and extracts from it the level, the play time and the
// last zone for the summary.
func (m *MemoryProgressStore) Apply(ctx context.Context, tx pgx.Tx, key SaveKey, progress json.RawMessage) (int64, error) {
	m.mu.Lock()
	txHook := m.applyTxHook
	m.mu.Unlock()
	if txHook != nil {
		// Outside the lock: the function talks to the database.
		if err := txHook(ctx, tx, key, progress); err != nil {
			return 0, err
		}
	}
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
	opIDs, err := sectionOps(section["ops"])
	if err != nil {
		return 0, err
	}
	for _, id := range opIDs {
		if m.appliedOps[id] {
			return 0, &InvalidSaveError{Check: "S2", Detail: fmt.Sprintf("la operación %d ya está guardada", id)}
		}
	}
	for _, id := range opIDs {
		m.appliedOps[id] = true
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

// sectionOps reads the op_ids from the section's ops list (decimal strings); without ops, none.
func sectionOps(v any) ([]int64, error) {
	if v == nil {
		return nil, nil
	}
	list, ok := v.([]any)
	if !ok {
		return nil, &InvalidSaveError{Check: "S1", Detail: "ops no es una lista"}
	}
	ids := make([]int64, 0, len(list))
	for _, item := range list {
		op, ok := item.(map[string]any)
		s, okID := op["op_id"].(string)
		id, err := strconv.ParseInt(s, 10, 64)
		if !ok || !okID || err != nil || id < 1 {
			return nil, &InvalidSaveError{Check: "S1", Detail: "una operación sin op_id"}
		}
		ids = append(ids, id)
	}
	return ids, nil
}

// whole reads an integer number from the JSON, also with null decimals (Godot writes 7.0).
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

// Summaries implements [ProgressStore]: only those with unpurged progression.
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

// Purge implements [ProgressStore]: it deletes the progression (there is no ledger to leave).
func (m *MemoryProgressStore) Purge(_ context.Context, _ pgx.Tx, characterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.chars[characterID]; ok {
		c.purged, c.applied = true, nil
	}
	return nil
}

// PurgeRetention implements [ProgressStore]: the fake has no ledger, so it deletes nothing nor
// gives empty tombstones (the real retention deletes them, progresion.md P7).
func (m *MemoryProgressStore) PurgeRetention(context.Context, pgx.Tx) (int64, []int64, error) {
	return 0, nil, nil
}

// Export implements [ProgressStore]: {"record": ..., "ops": []}, with record null in a tombstone.
func (m *MemoryProgressStore) Export(_ context.Context, _ Querier, characterID int64) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var rec any
	if c, err := m.get(characterID); err == nil {
		rec = c.record()
	}
	return json.Marshal(map[string]any{"record": rec, "ops": []any{}})
}

// Op implements [ProgressStore]: the operations from [MemoryProgressStore.AddOp], if any of their
// participants has character_leases.zone_instance_id = instance (the same query that the real store
// will do with a join of op_participants); otherwise, [ErrNotFound].
func (m *MemoryProgressStore) Op(ctx context.Context, q Querier, opID int64, instance [16]byte) (json.RawMessage, error) {
	m.mu.Lock()
	op, ok := m.ops[opID]
	m.mu.Unlock()
	if !ok {
		return nil, ErrNotFound
	}
	var inside bool
	if err := q.QueryRow(ctx, `select exists (select 1 from character_leases
		where character_id = any($1) and zone_instance_id = $2)`, op.participants, instance).Scan(&inside); err != nil {
		return nil, err
	}
	if !inside {
		return nil, ErrNotFound
	}
	return op.body, nil
}

// Ledger implements [ProgressStore]: an empty ledger, or [ErrNotFound] if the character has no
// progression.
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
