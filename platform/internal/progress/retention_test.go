package progress_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
)

// The purge of a character with a kit and entries within its account's purge leaves the
// characters tombstone without progress state and with the ledger; the append-only tables admit
// neither UPDATE nor DELETE without the retention flag (not even in the transaction after one that
// set it) and the tombstone cannot be deleted with a ledger.
func TestPurgeKeepsLedger(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	for i := 0; i < 3; i++ {
		_, body := c.step(t, "valid_reversal", i)
		w.apply(42, body)
	}
	w.exec(`insert into character_timers (character_id, key, ends_at) values (42, 'unstuck', now())`)
	w.purgeAccount(7)
	var purged bool
	w.scalar(&purged, `select name is null and purged_at is not null from characters where character_id = 42`)
	if !purged {
		t.Fatal("the characters row is not a tombstone")
	}
	for _, table := range []string{"character_progress", "character_wallets", "item_instances", "character_timers"} {
		if n := w.count(`select count(*) from ` + table + ` where character_id = 42`); n != 0 {
			t.Errorf("%s: %d rows remain", table, n)
		}
	}
	for table, want := range map[string]int{"op_participants": 5, "ledger_entries": 4, "item_events": 7} {
		if n := w.count(`select count(*) from ` + table + ` where character_id = 42`); n != want {
			t.Errorf("%s: %d rows, expected %d", table, n, want)
		}
	}
	if n := w.count(`select count(*) from economy_ops`); n != 5 || w.count(`select count(*) from op_reversals`) != 1 {
		t.Errorf("operations: %d", n)
	}
	ctx := context.Background()
	for _, sql := range []string{
		`delete from ledger_entries where character_id = 42`,
		`update ledger_entries set delta = 1 where character_id = 42`,
		`delete from item_events where character_id = 42`,
		`delete from op_reversals`,
		`update economy_ops set note = 'otra'`,
		`truncate op_participants cascade`,
	} {
		if _, err := w.pool.Exec(ctx, sql); db.SQLState(err) != "P0001" {
			t.Errorf("%s: %v (expected P0001, from append-only)", sql, err)
		}
	}
	if _, err := w.pool.Exec(ctx, `delete from characters where character_id = 42`); db.SQLState(err) != "23503" {
		t.Errorf("deleting the tombstone with ledger: %v", err)
	}
	// The flag is only valid within its transaction.
	w.tx(func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `select set_config('eldmark.retention_purge', 'on', true)`)
		return err
	})
	if _, err := w.pool.Exec(ctx, `delete from item_events where character_id = 42`); db.SQLState(err) != "P0001" {
		t.Errorf("after a transaction with the mark: %v", err)
	}
	// An hourly purge of the already purged character does nothing (and Purge on nothing does not fail).
	w.tx(func(tx pgx.Tx) error { return w.store.Purge(ctx, tx, 42) })
}

// With the clock at +366 days, PurgeRetention deletes the purged character's ledger in successive
// calls until it returns 0, returns its tombstone (and that of one purged without a ledger) in
// emptied and leaves other characters' operations: the two-participant one stays with the one who
// is still alive. Before the year it touches nothing.
func TestRetention(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	for i := 0; i < 3; i++ {
		_, body := c.step(t, "valid_reversal", i)
		w.apply(42, body)
	}
	_, kit := c.step(t, "valid_kit_and_play", 0)
	w.apply(43, edit(t, kit, func(m map[string]any) {
		m["ops"].([]any)[0].(map[string]any)["op_id"] = "1500"
		for _, it := range m["items"].([]any) {
			item := it.(map[string]any)
			item["uid"] = shift(item["uid"].(string), 500)
		}
		for _, e := range m["ops"].([]any)[0].(map[string]any)["items"].([]any) {
			ev := e.(map[string]any)
			ev["uid"] = shift(ev["uid"].(string), 500)
		}
	}))
	w.exec(`insert into economy_ops (op_id, kind, zone_id) values (1600, 2, 'vado_gris')`)
	w.exec(`insert into op_participants (op_id, character_id) values (1600, 42), (1600, 43)`)
	w.exec(`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
		values (42, 2, 2, 1600, 5, 35, 3), (43, 2, 1, 1600, 5, 5, 3)`)
	w.purgeAccount(7) // 42
	w.exec(`update characters set purged_at = now(), name = null, name_key = null where character_id = 49`)
	// retention calls PurgeRetention like the hourly job, one transaction at a time while it deletes
	// anything, and returns the total and all the empty tombstones.
	retention := func() (int64, []int64) {
		var total int64
		var all []int64
		for i := 0; ; i++ {
			var deleted int64
			w.tx(func(tx pgx.Tx) error {
				var emptied []int64
				var err error
				deleted, emptied, err = w.store.PurgeRetention(context.Background(), tx)
				if err != nil {
					return err
				}
				all = append(all, emptied...)
				// The platform deletes the empty tombstones in the same transaction.
				for _, id := range emptied {
					if _, err := tx.Exec(context.Background(), `delete from characters where character_id = $1`,
						id); err != nil {
						return err
					}
				}
				return nil
			})
			total += deleted
			if deleted == 0 || i > 10 {
				return total, all
			}
		}
	}
	if deleted, emptied := retention(); deleted != 0 || len(emptied) != 0 {
		t.Fatalf("before the year: %d deleted, empty ones %v", deleted, emptied)
	}
	w.clock.advance(366 * 24 * time.Hour)
	w.exec(`update characters set purged_at = $1 where character_id = 49`, w.clock.now().Add(-366*24*time.Hour))
	deleted, emptied := retention()
	// 42: 5 entries, 7 events and 6 participations; 5 operations that are only theirs and 1 reversal.
	if deleted != 5+7+6+5+1 {
		t.Errorf("deleted: %d", deleted)
	}
	if !reflect.DeepEqual(emptied, []int64{42, 49}) {
		t.Errorf("empty tombstones: %v", emptied)
	}
	for table, want := range map[string]int{"ledger_entries": 0, "item_events": 0, "op_participants": 0} {
		if n := w.count(`select count(*) from ` + table + ` where character_id = 42`); n != want {
			t.Errorf("%s de 42: %d", table, n)
		}
	}
	if n := w.count(`select count(*) from characters where character_id in (42, 49)`); n != 0 {
		t.Errorf("the empty tombstones remain: %d", n)
	}
	if n := w.count(`select count(*) from economy_ops`); n != 2 {
		t.Errorf("operations remaining: %d (the ones from 43: 1500, and the two-party one, 1600)", n)
	}
	var participants []int64
	rows, err := w.pool.Query(context.Background(), `select character_id from op_participants where op_id = 1600`)
	if err != nil {
		t.Fatal(err)
	}
	if participants, err = pgx.CollectRows(rows, pgx.RowTo[int64]); err != nil || !reflect.DeepEqual(participants, []int64{43}) {
		t.Errorf("participants of the two-party operation: %v %v", participants, err)
	}
	if n := w.count(`select count(*) from ledger_entries where character_id = 43`); n != 1 {
		t.Errorf("43's ledger: %d", n)
	}
	// Nothing is left to delete.
	if deleted, emptied := retention(); deleted != 0 || len(emptied) != 0 {
		t.Errorf("another round: %d, %v", deleted, emptied)
	}
}
