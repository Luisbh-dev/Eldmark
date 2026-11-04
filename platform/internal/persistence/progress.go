// Package persistence is the character's persistence in the platform (plataforma.md §7, TEC-25).
//
// This file is the boundary with docs/progresion.md (plataforma.md §7.5, progresion.md §13.2): the
// [ProgressStore] interface with its types and errors, and the creation validation
// ([CreateValidator], [ValidationError]) with its provisional implementation
// ([ProvisionalValidator]). They are implemented by internal/progress (progresion.md P7), which
// imports this package (never the other way around: there is no cycle), and serve uses them in all
// environments; the fake ([MemoryProgressStore]) and the provisional one remain for tests.
package persistence

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/config"
)

// InvalidSaveError is a save that does not pass S1-S7 (progresion.md §13.3): the response is 400
// invalid_save with fields.check and fields.detail. It is always returned as a pointer (errors.As
// with *InvalidSaveError).
type InvalidSaveError struct{ Check, Detail string }

func (e *InvalidSaveError) Error() string { return "invalid_save " + e.Check + ": " + e.Detail }

// ErrNotFound is what does not exist or cannot be seen (Op and Ledger): 404 not_found.
var ErrNotFound = errors.New("not_found")

// CreateParams is what the character receives on creation, already validated (plataforma.md §4.4
// step 5).
type CreateParams struct {
	RaceID            string
	Appearance        [8]byte
	StarterTemplateID string
}

// SaveKey identifies a save: the world and the zone come from the instance that claimed
// (InstanceID is character_leases.claimed_by).
type SaveKey struct {
	WorldID     int16
	CharacterID int64
	InstanceID  [16]byte
	ZoneID      string
}

// Summary is what the platform reads from the progression outside the save: the character list,
// enter and the name reservation exception (plataforma.md §4.4 and §4.5). Empty LastZoneID: it has
// never entered.
type Summary struct {
	RaceID        string
	Appearance    [8]byte
	Level         int
	LastZoneID    string
	LastChannel   int
	PlayedSeconds int64
}

// Querier is a query inside the caller's transaction or connection: pgx.Tx and *pgxpool.Pool
// satisfy it.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ProgressStore is the progression store (progresion.md §13.2). Everything goes inside the caller's
// transaction or connection; at the boundary, raw JSON travels.
type ProgressStore interface {
	// Create stores the initial progression of a newly created character (§4.4 step 6).
	Create(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64, p CreateParams) error
	// Load returns the claim's ProgressRecord (progresion.md §3.4).
	Load(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)
	// Apply applies a save's progress section with S1-S8 and returns the new save_version.
	Apply(ctx context.Context, tx pgx.Tx, key SaveKey, progress json.RawMessage) (saveVersion int64, err error)
	// Summaries returns the summary of each character that has progression.
	Summaries(ctx context.Context, q Querier, characterIDs []int64) (map[int64]Summary, error)
	// Purge deletes the progression state and leaves the append-only part (progresion.md §3.5).
	Purge(ctx context.Context, tx pgx.Tx, characterID int64) error
	// PurgeRetention deletes the ledger retained for more than a year; emptied are the tombstones that
	// have been left without a ledger, which the platform deletes (progresion.md §3.5).
	PurgeRetention(ctx context.Context, tx pgx.Tx) (deleted int64, emptied []int64, err error)
	// Export gives a character's progression for the data export (progresion.md §3.5).
	Export(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)
	// Op returns an operation if any of its participants has a lease on instance; otherwise,
	// [ErrNotFound].
	Op(ctx context.Context, q Querier, opID int64, instance [16]byte) (json.RawMessage, error)
	// Ledger returns a character's entries, most recent first (limit from 1 to 100).
	Ledger(ctx context.Context, q Querier, characterID int64, limit int, beforeEntryID int64) (json.RawMessage, error)
}

// CreateValidator validates a new character's race, appearance and starting template (plataforma.md
// §4.4 step 5, progresion.md §13.2). realm is the NetProtocol.Realm code. It returns nil or a
// *[ValidationError].
type CreateValidator interface {
	ValidateCreate(realm int16, raceID string, appearance [8]byte, templateID string) error
}

// ValidationError is a creation that is not valid: the response is 400 validation with these fields
// as is ({"race_id": "wrong_realm"}, {"appearance": "invalid"},
// {"starter_template_id": "not_selectable"}). It is always returned as a pointer.
type ValidationError struct{ Fields map[string]string }

func (e *ValidationError) Error() string {
	keys := make([]string, 0, len(e.Fields))
	for k := range e.Fields {
		keys = append(keys, k+"="+e.Fields[k])
	}
	sort.Strings(keys)
	return "validation: " + strings.Join(keys, ", ")
}

// templatePattern is the template that the provisional validation admits.
var templatePattern = regexp.MustCompile(`^[a-z0-9_]{1,32}$`)

// ProvisionalValidator is the creation validation from before progresion.md P7 (plataforma.md §4.4
// step 5): race_id = "race_" + the realm's text id, any 8 B of appearance (the zone corrects an
// invalid one on load, progresion.md §7.2) and a template that satisfies ^[a-z0-9_]{1,32}$. serve
// uses *progress.Rules; this one remains for tests that create characters without the exported
// rules.
type ProvisionalValidator struct{}

// ValidateCreate implements [CreateValidator]. A race from another realm is wrong_realm; an id that
// is not any race's, unknown.
func (ProvisionalValidator) ValidateCreate(realm int16, raceID string, _ [8]byte, templateID string) error {
	fields := map[string]string{}
	if raceID != "race_"+config.Realm(realm).String() {
		fields["race_id"] = "unknown"
		for _, r := range []config.Realm{config.RealmVardheim, config.RealmSolmarch, config.RealmAskarra} {
			if raceID == "race_"+r.String() {
				fields["race_id"] = "wrong_realm"
			}
		}
	}
	if !templatePattern.MatchString(templateID) {
		fields["starter_template_id"] = "not_selectable"
	}
	if len(fields) > 0 {
		return &ValidationError{Fields: fields}
	}
	return nil
}
