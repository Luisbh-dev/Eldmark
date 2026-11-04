package progress

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
)

// What leaves the store outside the save path: the data export (GDPR, progresion.md §3.5) and the
// bodies of the operation and ledger routes (progresion.md §13.2), with ids as strings.

// exportOp is an operation in the export: without actor_account_id, note or detail (staff data on
// GM and REVERSAL operations; empty on the others).
type exportOp struct {
	OpID          jsonx.ID      `json:"op_id"`
	Kind          int16         `json:"kind"`
	ZoneID        *string       `json:"zone_id"`
	RefOpID       *jsonx.ID     `json:"ref_op_id"`
	CreatedAtUnix int64         `json:"created_at_unix"`
	Ledger        []exportEntry `json:"ledger"`
	Items         []exportEvent `json:"items"`
}

type exportEntry struct {
	EntryID       jsonx.ID `json:"entry_id"`
	Currency      int16    `json:"currency"`
	Seq           int64    `json:"seq"`
	Delta         int64    `json:"delta"`
	BalanceAfter  int64    `json:"balance_after"`
	Reason        int16    `json:"reason"`
	RefKind       int16    `json:"ref_kind"`
	RefID         jsonx.ID `json:"ref_id"`
	CreatedAtUnix int64    `json:"created_at_unix"`
}

type exportEvent struct {
	UID        *jsonx.ID `json:"uid"`
	DefID      string    `json:"def_id"`
	CountDelta int32     `json:"count_delta"`
	Reason     int16     `json:"reason"`
}

// Export implements persistence.ProgressStore (progresion.md §3.5): {"record": …, "ops": […]},
// with the claim record (null for a tombstone, which no longer has state) and, in order, the
// operations the character takes part in with its own entries and events (those of other
// participants are not included). None of them includes actor_account_id, note or detail.
func (s *Store) Export(ctx context.Context, q persistence.Querier, characterID int64) (json.RawMessage, error) {
	out := struct {
		Record *record     `json:"record"`
		Ops    []*exportOp `json:"ops"`
	}{Ops: []*exportOp{}}
	rec, err := s.loadRecord(ctx, q, characterID)
	switch {
	case err == nil:
		out.Record = rec
	case !errors.Is(err, persistence.ErrNotFound):
		return nil, err
	}
	rows, err := q.Query(ctx, `select e.op_id, e.kind, e.zone_id, e.ref_op_id, e.created_at
		from economy_ops e join op_participants p on p.op_id = e.op_id
		where p.character_id = $1 order by e.created_at, e.op_id`, characterID)
	if err != nil {
		return nil, err
	}
	byID := map[int64]*exportOp{}
	out.Ops, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (*exportOp, error) {
		var opID int64
		var refOp *int64
		var created time.Time
		o := &exportOp{Ledger: []exportEntry{}, Items: []exportEvent{}}
		if err := row.Scan(&opID, &o.Kind, &o.ZoneID, &refOp, &created); err != nil {
			return nil, err
		}
		o.OpID, o.RefOpID, o.CreatedAtUnix = jsonx.ID(opID), idPtr(refOp), created.Unix()
		byID[opID] = o
		return o, nil
	})
	if err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `select op_id, entry_id, currency, seq, delta, balance_after, reason, ref_kind, ref_id,
		created_at from ledger_entries where character_id = $1 order by entry_id`, characterID)
	if err != nil {
		return nil, err
	}
	_, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (struct{}, error) {
		var opID, entryID, refID int64
		var created time.Time
		var e exportEntry
		if err := row.Scan(&opID, &entryID, &e.Currency, &e.Seq, &e.Delta, &e.BalanceAfter, &e.Reason, &e.RefKind,
			&refID, &created); err != nil {
			return struct{}{}, err
		}
		e.EntryID, e.RefID, e.CreatedAtUnix = jsonx.ID(entryID), jsonx.ID(refID), created.Unix()
		if o := byID[opID]; o != nil {
			o.Ledger = append(o.Ledger, e)
		}
		return struct{}{}, nil
	})
	if err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `select op_id, uid, def_id, count_delta, reason from item_events where character_id = $1
		order by event_id`, characterID)
	if err != nil {
		return nil, err
	}
	_, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (struct{}, error) {
		var opID int64
		var uid *int64
		var e exportEvent
		if err := row.Scan(&opID, &uid, &e.DefID, &e.CountDelta, &e.Reason); err != nil {
			return struct{}{}, err
		}
		e.UID = idPtr(uid)
		if o := byID[opID]; o != nil {
			o.Items = append(o.Items, e)
		}
		return struct{}{}, nil
	})
	if err != nil {
		return nil, err
	}
	return json.Marshal(out)
}

func idPtr(v *int64) *jsonx.ID {
	if v == nil {
		return nil
	}
	id := jsonx.ID(*v)
	return &id
}

// opView is the body of GET /internal/v1/ops/{op_id} (progresion.md §13.2).
type opView struct {
	OpID           jsonx.ID         `json:"op_id"`
	Kind           int16            `json:"kind"`
	ActorAccountID *jsonx.ID        `json:"actor_account_id"`
	RefOpID        *jsonx.ID        `json:"ref_op_id"`
	ZoneID         *string          `json:"zone_id"`
	Note           *string          `json:"note"`
	Detail         json.RawMessage  `json:"detail"`
	CreatedAtUnix  int64            `json:"created_at_unix"`
	Participants   []jsonx.ID       `json:"participants"`
	ReversedBy     *jsonx.ID        `json:"reversed_by"`
	Ledger         []opEntryView    `json:"ledger"`
	Items          []opEventView    `json:"items"`
	Instances      []opInstanceView `json:"instances"`
}

type opEntryView struct {
	CharacterID  jsonx.ID `json:"character_id"`
	Currency     int16    `json:"currency"`
	Seq          int64    `json:"seq"`
	Delta        int64    `json:"delta"`
	BalanceAfter int64    `json:"balance_after"`
	Reason       int16    `json:"reason"`
	RefKind      int16    `json:"ref_kind"`
	RefID        jsonx.ID `json:"ref_id"`
}

type opEventView struct {
	CharacterID jsonx.ID  `json:"character_id"`
	UID         *jsonx.ID `json:"uid"`
	DefID       string    `json:"def_id"`
	CountDelta  int32     `json:"count_delta"`
	Reason      int16     `json:"reason"`
}

type opInstanceView struct {
	UID        jsonx.ID `json:"uid"`
	DefID      string   `json:"def_id"`
	Count      int32    `json:"count"`
	Durability *int16   `json:"durability"`
	Rarity     int16    `json:"rarity"`
	Bound      bool     `json:"bound"`
	Seed       jsonx.ID `json:"seed"`
	Affixes    []int32  `json:"affixes"`
	Retired    bool     `json:"retired"`
}

// Op implements persistence.ProgressStore: {"op": …} with the operation, its participants, who
// reverted it, all its entries and events, and the item_instances rows of the uids in its events
// (retired ones too: the reversal of a DESTROY copies their fields, progresion.md §10).
// persistence.ErrNotFound if it does not exist or if no participant has its lease in instance (in
// the same query: the platform does not read op_participants).
func (s *Store) Op(ctx context.Context, q persistence.Querier, opID int64, instance [16]byte) (json.RawMessage, error) {
	v := opView{OpID: jsonx.ID(opID)}
	var actor, refOp, reversedBy *int64
	var created time.Time
	var detail []byte
	err := q.QueryRow(ctx, `select e.kind, e.actor_account_id, e.ref_op_id, e.zone_id, e.note, e.detail, e.created_at,
			r.reversal_op_id
		from economy_ops e left join op_reversals r on r.op_id = e.op_id
		where e.op_id = $1 and exists (select 1 from op_participants p
			join character_leases l on l.character_id = p.character_id
			where p.op_id = e.op_id and l.zone_instance_id = $2)`, opID, instance).Scan(&v.Kind, &actor, &refOp,
		&v.ZoneID, &v.Note, &detail, &created, &reversedBy)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, persistence.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	v.ActorAccountID, v.RefOpID, v.ReversedBy = idPtr(actor), idPtr(refOp), idPtr(reversedBy)
	v.Detail, v.CreatedAtUnix = json.RawMessage(detail), created.Unix()
	rows, err := q.Query(ctx, `select character_id from op_participants where op_id = $1 order by character_id`, opID)
	if err != nil {
		return nil, err
	}
	if v.Participants, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (jsonx.ID, error) {
		var id int64
		err := row.Scan(&id)
		return jsonx.ID(id), err
	}); err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `select character_id, currency, seq, delta, balance_after, reason, ref_kind, ref_id
		from ledger_entries where op_id = $1 order by entry_id`, opID)
	if err != nil {
		return nil, err
	}
	if v.Ledger, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (opEntryView, error) {
		var e opEntryView
		var character, refID int64
		err := row.Scan(&character, &e.Currency, &e.Seq, &e.Delta, &e.BalanceAfter, &e.Reason, &e.RefKind, &refID)
		e.CharacterID, e.RefID = jsonx.ID(character), jsonx.ID(refID)
		return e, err
	}); err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `select character_id, uid, def_id, count_delta, reason from item_events where op_id = $1
		order by event_id`, opID)
	if err != nil {
		return nil, err
	}
	var uids []int64
	if v.Items, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (opEventView, error) {
		var e opEventView
		var character int64
		var uid *int64
		err := row.Scan(&character, &uid, &e.DefID, &e.CountDelta, &e.Reason)
		e.CharacterID, e.UID = jsonx.ID(character), idPtr(uid)
		if uid != nil {
			uids = append(uids, *uid)
		}
		return e, err
	}); err != nil {
		return nil, err
	}
	v.Instances = []opInstanceView{}
	if len(uids) > 0 {
		rows, err = q.Query(ctx, `select uid, def_id, count, durability, rarity, bound, seed, affixes, retired_at is not null
			from item_instances where uid = any($1) order by uid`, uids)
		if err != nil {
			return nil, err
		}
		if v.Instances, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (opInstanceView, error) {
			var it opInstanceView
			var uid, seed int64
			err := row.Scan(&uid, &it.DefID, &it.Count, &it.Durability, &it.Rarity, &it.Bound, &seed, &it.Affixes,
				&it.Retired)
			it.UID, it.Seed = jsonx.ID(uid), jsonx.ID(seed)
			if it.Affixes == nil {
				it.Affixes = []int32{}
			}
			return it, err
		}); err != nil {
			return nil, err
		}
	}
	return json.Marshal(map[string]opView{"op": v})
}

// ledgerView is an entry of GET /internal/v1/characters/{id}/ledger (progresion.md §13.2).
type ledgerView struct {
	EntryID       jsonx.ID `json:"entry_id"`
	OpID          jsonx.ID `json:"op_id"`
	Currency      int16    `json:"currency"`
	Seq           int64    `json:"seq"`
	Delta         int64    `json:"delta"`
	BalanceAfter  int64    `json:"balance_after"`
	Reason        int16    `json:"reason"`
	RefKind       int16    `json:"ref_kind"`
	RefID         jsonx.ID `json:"ref_id"`
	CreatedAtUnix int64    `json:"created_at_unix"`
}

// MaxLedgerLimit is the largest limit of Ledger (the route validates it beforehand).
const MaxLedgerLimit = 100

// Ledger implements persistence.ProgressStore: {"entries": […]} with the character's limit most
// recent entries (by entry_id, descending) before beforeEntryID (0: unbounded).
// persistence.ErrNotFound if the character has no progress.
func (s *Store) Ledger(ctx context.Context, q persistence.Querier, characterID int64, limit int,
	beforeEntryID int64) (json.RawMessage, error) {
	if limit < 1 || limit > MaxLedgerLimit {
		return nil, fmt.Errorf("progress: limit fuera de 1–%d: %d", MaxLedgerLimit, limit)
	}
	var exists bool
	if err := q.QueryRow(ctx, `select exists (select 1 from character_progress where character_id = $1)`,
		characterID).Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		return nil, persistence.ErrNotFound
	}
	rows, err := q.Query(ctx, `select entry_id, op_id, currency, seq, delta, balance_after, reason, ref_kind, ref_id,
			created_at
		from ledger_entries where character_id = $1 and ($2::bigint = 0 or entry_id < $2)
		order by entry_id desc limit $3`, characterID, beforeEntryID, limit)
	if err != nil {
		return nil, err
	}
	entries, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (ledgerView, error) {
		var e ledgerView
		var entryID, opID, refID int64
		var created time.Time
		err := row.Scan(&entryID, &opID, &e.Currency, &e.Seq, &e.Delta, &e.BalanceAfter, &e.Reason, &e.RefKind, &refID,
			&created)
		e.EntryID, e.OpID, e.RefID, e.CreatedAtUnix = jsonx.ID(entryID), jsonx.ID(opID), jsonx.ID(refID), created.Unix()
		return e, err
	})
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string][]ledgerView{"entries": entries})
}
