package progress

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// write is S8 (progression.md §13.3): it writes the already checked save in the caller's
// transaction. character_progress whole with saved_at and save_version + 1 (which it returns);
// balances with their last_seq; objects (it inserts new ones without on conflict, so a uid that
// already exists, from another character or retired, is a 23505 on the primary key; it updates
// those that move; it retires those that are missing); operations (without on conflict: a
// repeated op_id is a 23505 on economy_ops_pkey), their participants, entries with their seq,
// events and reversals; one audit_log row per GM or REVERSAL (op:<op_id>, on conflict do
// nothing); and the set of timers. It does not touch characters.
func (a *apply) write(ctx context.Context, tx pgx.Tx) (int64, error) {
	sec, id := a.sec, a.key.CharacterID
	var health *int32
	if sec.health != nil {
		h := int32(*sec.health)
		health = &h
	}
	var zoneID *string
	var channel *int16
	var x, y, z, yaw *float32
	inCombat := false
	if l := sec.location; l != nil {
		ch := int16(l.channel)
		fx, fy, fz, fyaw := float32(l.x), float32(l.y), float32(l.z), float32(l.yaw)
		zoneID, channel, x, y, z, yaw, inCombat = &l.zoneID, &ch, &fx, &fy, &fz, &fyaw, l.inCombat
	}
	var version int64
	err := tx.QueryRow(ctx, `update character_progress set starter_granted = $2, level = $3, xp_total = $4,
			realm_points = $5, played_seconds = $6, bag_slots = $7, health = $8, active_weapon_slot = $9,
			last_zone_id = $10, last_channel = $11, pos_x = $12, pos_y = $13, pos_z = $14, yaw = $15,
			last_in_combat = $16, saved_at = $17, save_version = save_version + 1
		where character_id = $1 returning save_version`, id, sec.starterGranted, sec.level, sec.xpTotal,
		sec.realmPoints, sec.playedSeconds, sec.bagSlots, health, sec.activeWeaponSlot, zoneID, channel, x, y, z, yaw,
		inCombat, a.now).Scan(&version)
	if err != nil {
		return 0, err
	}
	seqs, err := a.writeWallets(ctx, tx)
	if err != nil {
		return 0, err
	}
	if err := a.writeItems(ctx, tx); err != nil {
		return 0, err
	}
	if err := a.writeOps(ctx, tx, seqs); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `delete from character_timers where character_id = $1`, id); err != nil {
		return 0, err
	}
	if len(sec.timers) > 0 {
		b := &pgx.Batch{}
		for _, t := range sec.timers {
			b.Queue(`insert into character_timers (character_id, key, ends_at) values ($1, $2, $3)`, id, t.key,
				time.Unix(t.endsAt, 0).UTC())
		}
		if err := sendBatch(ctx, tx, b); err != nil {
			return 0, err
		}
	}
	return version, nil
}

// writeWallets changes each balance that has entries by the sum of its deltas, with the guard
// from progression.md §5.4 (update … set balance = balance + delta where … and balance + delta
// between 0 and the cap): a transaction that did not see the right balance touches no row and the
// save is rolled back. It returns, per currency, the seq of the first entry in the body (last_seq + 1).
func (a *apply) writeWallets(ctx context.Context, tx pgx.Tx) (map[int64]int64, error) {
	sums := map[int64]int64{}
	counts := map[int64]int64{}
	for _, o := range a.sec.ops {
		for _, e := range o.ledger {
			sums[e.currency] += e.delta
			counts[e.currency]++
		}
	}
	first := map[int64]int64{}
	codes := make([]int64, 0, len(counts))
	for code := range counts {
		codes = append(codes, code)
	}
	sort.Slice(codes, func(i, j int) bool { return codes[i] < codes[j] })
	for _, code := range codes {
		if _, ok := a.db.wallets[code]; !ok {
			if _, err := tx.Exec(ctx, `insert into character_wallets (character_id, currency) values ($1, $2)
				on conflict do nothing`, a.key.CharacterID, code); err != nil {
				return nil, err
			}
		}
		var balance, lastSeq int64
		err := tx.QueryRow(ctx, `update character_wallets set balance = balance + $3, last_seq = last_seq + $4
			where character_id = $1 and currency = $2 and balance + $3 between 0 and $5
			returning balance, last_seq`, a.key.CharacterID, code, sums[code], counts[code],
			a.s.rules.currencyCaps[int(code)]).Scan(&balance, &lastSeq)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, checkError("S3", "el saldo de la moneda %d quedaría fuera de 0–tope al aplicar (otro guardado "+
				"lo ha cambiado)", code)
		}
		if err != nil {
			return nil, err
		}
		if want := a.photoBalance(code); balance != want {
			return nil, checkError("S3", "el saldo de la moneda %d queda en %d y la foto dice %d (otro guardado lo ha "+
				"cambiado)", code, balance, want)
		}
		first[code] = lastSeq - counts[code] + 1
	}
	return first, nil
}

func (a *apply) photoBalance(code int64) int64 {
	for _, w := range a.sec.wallets {
		if w.currency == code {
			return w.balance
		}
	}
	return 0
}

// writeItems retires the live objects missing from the snapshot, updates those that move or
// change quantity, durability or binding, and inserts the new ones (created_op: the operation
// with an event that adds that uid; null if it was born from a split). The slot constraint is
// deferred: a swap fits in the transaction.
func (a *apply) writeItems(ctx context.Context, tx pgx.Tx) error {
	id := a.key.CharacterID
	inPhoto := map[int64]bool{}
	for _, it := range a.sec.items {
		inPhoto[it.uid] = true
	}
	var gone []int64
	for uid := range a.db.items {
		if !inPhoto[uid] {
			gone = append(gone, uid)
		}
	}
	if len(gone) > 0 {
		if _, err := tx.Exec(ctx, `update item_instances set retired_at = $3, container = null, slot = null
			where character_id = $1 and uid = any($2) and retired_at is null`, id, gone, a.now); err != nil {
			return err
		}
	}
	created := map[int64]int64{}
	for _, o := range a.sec.ops {
		for _, e := range o.items {
			if e.uid != nil && e.countDelta > 0 {
				if _, ok := created[*e.uid]; !ok {
					created[*e.uid] = o.opID
				}
			}
		}
	}
	b := &pgx.Batch{}
	for _, it := range a.sec.items {
		durability := smallintPtr(it.durability)
		affixes := make([]int32, 0, len(it.affixes))
		for _, v := range it.affixes {
			affixes = append(affixes, int32(v))
		}
		if a.newID[it.uid] {
			var createdOp *int64
			if op, ok := created[it.uid]; ok {
				createdOp = &op
			}
			b.Queue(`insert into item_instances (uid, character_id, container, slot, def_id, count, durability, rarity,
					bound, seed, affixes, created_op) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
				it.uid, id, it.container, it.slot, it.defID, it.count, durability, it.rarity, it.bound, it.seed, affixes,
				createdOp)
			continue
		}
		old := a.db.items[it.uid]
		if old.container == it.container && old.slot == it.slot && old.count == it.count && old.bound == it.bound &&
			equalPtr(old.durability, it.durability) {
			continue
		}
		b.Queue(`update item_instances set container = $3, slot = $4, count = $5, durability = $6, bound = $7
			where character_id = $1 and uid = $2 and retired_at is null`, id, it.uid, it.container, it.slot, it.count,
			durability, it.bound)
	}
	return sendBatch(ctx, tx, b)
}

// writeOps inserts the journal's operations in order: the operation, its participant, its
// entries (with their currency's seq), its events, the reversal and, for GM and REVERSAL, the
// audit_log row.
func (a *apply) writeOps(ctx context.Context, tx pgx.Tx, seqs map[int64]int64) error {
	if len(a.sec.ops) == 0 {
		return nil
	}
	id := a.key.CharacterID
	b := &pgx.Batch{}
	for _, o := range a.sec.ops {
		b.Queue(`insert into economy_ops (op_id, kind, actor_account_id, ref_op_id, zone_id, note, detail, created_at)
			values ($1, $2, $3, $4, $5, $6, $7, $8)`, o.opID, o.kind, o.actor, o.refOp, a.key.ZoneID, o.note,
			string(o.detail), a.now)
		b.Queue(`insert into op_participants (op_id, character_id) values ($1, $2)`, o.opID, id)
		for _, e := range o.ledger {
			b.Queue(`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason,
					ref_kind, ref_id, created_at) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`, id, e.currency,
				seqs[e.currency], o.opID, e.delta, e.balanceAfter, e.reason, e.refKind, e.refID, a.now)
			seqs[e.currency]++
		}
		for _, e := range o.items {
			b.Queue(`insert into item_events (op_id, character_id, def_id, uid, reason, count_delta, created_at)
				values ($1, $2, $3, $4, $5, $6, $7)`, o.opID, id, e.defID, e.uid, e.reason, e.countDelta, a.now)
		}
		if int(o.kind) == a.s.rules.kinds.reversal {
			b.Queue(`insert into op_reversals (op_id, reversal_op_id) values ($1, $2)`, *o.refOp, o.opID)
		}
		if d := a.gm[o.opID]; d != nil {
			source := "zone"
			if d.source == sourceConsole {
				source = "console"
			}
			b.Queue(`insert into audit_log (world_id, zone_id, source, actor_account_id, actor_character_id, command,
					target_account_id, target_character_id, args, at, event_key)
				values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) on conflict (event_key) do nothing`,
				a.key.WorldID, a.key.ZoneID, source, o.actor, d.actorChar, d.command, a.db.accountID, id,
				string(d.auditArgs), time.Unix(d.atUnix, 0).UTC(), fmt.Sprintf("op:%d", o.opID))
		}
	}
	return sendBatch(ctx, tx, b)
}

// sendBatch sends the statements in b and returns the first error.
func sendBatch(ctx context.Context, tx pgx.Tx, b *pgx.Batch) error {
	if b.Len() == 0 {
		return nil
	}
	br := tx.SendBatch(ctx, b)
	for i := 0; i < b.Len(); i++ {
		if _, err := br.Exec(); err != nil {
			_ = br.Close()
			return err
		}
	}
	return br.Close()
}

func smallintPtr(v *int64) *int16 {
	if v == nil {
		return nil
	}
	s := int16(*v)
	return &s
}

func equalPtr(a, b *int64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
