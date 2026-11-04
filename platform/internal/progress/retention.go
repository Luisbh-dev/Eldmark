package progress

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Retention is how long a character's ledger is kept after its purge (progresion.md §3.5, PRG-39;
// legal review pending, §16).
const Retention = 365 * 24 * time.Hour

// RetentionBatch is the most that each PurgeRetention call deletes from each append-only table.
const RetentionBatch = 10_000

// PurgeRetention implements persistence.ProgressStore (progresion.md §3.5). In the caller's
// transaction and with set local eldmark.retention_purge = 'on' (the only flag that allows
// deleting from the append-only tables; it is removed at the end), it deletes, for characters
// purged more than a year ago, at most [RetentionBatch] from each table: their entries, their
// item events and, afterwards, their participations that no longer have either; finally, the
// reversals and operations left without participants (those of other characters stay). deleted is
// how much it deleted in total: the hourly job from plataforma.md §2.5 calls it again, one
// transaction at a time, while it is greater than 0. emptied are the characters purged more than
// a year ago with no row in op_participants (including those that never had any): the platform
// deletes those rows from characters in the same transaction.
func (s *Store) PurgeRetention(ctx context.Context, tx pgx.Tx) (int64, []int64, error) {
	cutoff := s.now().Add(-Retention)
	if _, err := tx.Exec(ctx, `select set_config('eldmark.retention_purge', 'on', true)`); err != nil {
		return 0, nil, err
	}
	var deleted int64
	for _, sql := range []string{
		`delete from ledger_entries where entry_id in (select l.entry_id from ledger_entries l
			join characters c on c.character_id = l.character_id where c.purged_at < $1 limit $2)`,
		`delete from item_events where event_id in (select e.event_id from item_events e
			join characters c on c.character_id = e.character_id where c.purged_at < $1 limit $2)`,
	} {
		tag, err := tx.Exec(ctx, sql, cutoff, RetentionBatch)
		if err != nil {
			return 0, nil, err
		}
		deleted += tag.RowsAffected()
	}
	rows, err := tx.Query(ctx, `delete from op_participants p where (p.op_id, p.character_id) in (
			select q.op_id, q.character_id from op_participants q join characters c on c.character_id = q.character_id
			where c.purged_at < $1
			  and not exists (select 1 from ledger_entries l where l.op_id = q.op_id and l.character_id = q.character_id)
			  and not exists (select 1 from item_events e where e.op_id = q.op_id and e.character_id = q.character_id)
			limit $2)
		returning p.op_id`, cutoff, RetentionBatch)
	if err != nil {
		return 0, nil, err
	}
	ops, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return 0, nil, err
	}
	deleted += int64(len(ops))
	if len(ops) > 0 {
		for _, sql := range []string{
			`delete from op_reversals r where (r.op_id = any($1) or r.reversal_op_id = any($1))
				and (not exists (select 1 from op_participants p where p.op_id = r.op_id)
				  or not exists (select 1 from op_participants p where p.op_id = r.reversal_op_id))`,
			`delete from economy_ops e where e.op_id = any($1)
				and not exists (select 1 from op_participants p where p.op_id = e.op_id)`,
		} {
			tag, err := tx.Exec(ctx, sql, ops)
			if err != nil {
				return 0, nil, err
			}
			deleted += tag.RowsAffected()
		}
	}
	if _, err := tx.Exec(ctx, `select set_config('eldmark.retention_purge', '', true)`); err != nil {
		return 0, nil, err
	}
	rows, err = tx.Query(ctx, `select c.character_id from characters c where c.purged_at < $1
		and not exists (select 1 from op_participants p where p.character_id = c.character_id)
		order by c.character_id`, cutoff)
	if err != nil {
		return 0, nil, err
	}
	emptied, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return 0, nil, err
	}
	return deleted, emptied, nil
}
