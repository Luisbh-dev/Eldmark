package characters

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/persistence"
)

// Purger purges characters (platform.md §11.2): it leaves the tombstone (the characters row
// without a name, with purged_at) and the append-only parts of the progression, which the retention
// deletes after a year. It implements accounts.CharacterPurger.
type Purger struct {
	pool     *pgxpool.Pool
	progress persistence.ProgressStore
	clock    clock.Clock
	log      *slog.Logger
}

// NewPurger prepares the character purge.
func NewPurger(pool *pgxpool.Pool, progress persistence.ProgressStore, c clock.Clock, log *slog.Logger) *Purger {
	if c == nil {
		c = clock.System{}
	}
	if log == nil {
		log = logx.Discard()
	}
	return &Purger{pool: pool, progress: progress, clock: c, log: log}
}

// purgePath is the path of a purge, which decides what is checked again with the row locked.
type purgePath int

const (
	pathExpired purgePath = iota // when restore_until expires (hourly job)
	pathAccount                  // with the account: only null purged_at (the account rules)
)

// ErrBusy is a character with a live lease: it is not purged (§11.2, step 3).
var ErrBusy = errors.New("characters: el personaje tiene un arrendamiento vivo")

// purge purges a character inside tx, with the §11.2 locks in the save order (first the lease, then
// the characters row): it returns whether it purged it. With a live lease it returns ErrBusy and
// touches nothing.
func (p *Purger) purge(ctx context.Context, tx pgx.Tx, characterID int64, at time.Time, path purgePath) (bool, error) {
	// 1. The lease, if there is a row.
	var leaseInstance *[16]byte
	var leaseExpires *time.Time
	err := tx.QueryRow(ctx, `select zone_instance_id, expires_at from character_leases where character_id = $1 for update`,
		characterID).Scan(&leaseInstance, &leaseExpires)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, err
	}
	// 2. The character's row, and whether it is still due.
	var deletedAt, restoreUntil, purgedAt *time.Time
	err = tx.QueryRow(ctx, `select deleted_at, restore_until, purged_at from characters where character_id = $1
		for no key update`, characterID).Scan(&deletedAt, &restoreUntil, &purgedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	switch path {
	case pathExpired:
		if deletedAt == nil || restoreUntil == nil || restoreUntil.After(at) || purgedAt != nil {
			return false, nil // restored, still within the window or already purged
		}
	case pathAccount:
		if purgedAt != nil {
			return false, nil
		}
	}
	// 3. With a live lease it is not purged: the next round retries it.
	if leaseInstance != nil && leaseExpires != nil && leaseExpires.After(at) {
		return false, ErrBusy
	}
	// 4. The progression, the identity and the tombstone.
	if err := p.progress.Purge(ctx, tx, characterID); err != nil {
		return false, err
	}
	if path == pathAccount {
		// With the account, a living character's name stays reserved 30 days (a deleted one's already has
		// its reservation).
		if _, err := tx.Exec(ctx, `update character_names set status = 'reserved', reserved_until = $2
			where character_id = $1 and status = 'active'`, characterID, at.Add(NameReservation)); err != nil {
			return false, err
		}
	}
	for _, sql := range []string{
		`delete from character_pvp_stats where character_id = $1`,
		`delete from character_leases where character_id = $1`,
		`delete from enter_tickets where character_id = $1`,
		`update character_names set character_id = null where character_id = $1`,
	} {
		if _, err := tx.Exec(ctx, sql, characterID); err != nil {
			return false, err
		}
	}
	if _, err := tx.Exec(ctx, `update characters set name = null, name_key = null, purged_at = $2 where character_id = $1`,
		characterID, at); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `insert into purge_log (kind, id, purged_at) values ('character', $1, $2)
		on conflict do nothing`, characterID, at); err != nil {
		return false, err
	}
	return true, nil
}

// PurgeAccountCharacters implements accounts.CharacterPurger: it purges, inside the account purge's
// transaction (which already locked its row), all its unpurged characters, living or deleted. If
// any has a live lease it returns an error that wraps accounts.ErrCharactersBusy, and the account
// is not purged.
func (p *Purger) PurgeAccountCharacters(ctx context.Context, tx pgx.Tx, accountID int64, at time.Time) error {
	rows, err := tx.Query(ctx, `select character_id from characters where account_id = $1 and purged_at is null
		order by character_id`, accountID)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := p.purge(ctx, tx, id, at, pathAccount); err != nil {
			if errors.Is(err, ErrBusy) {
				return fmt.Errorf("%w (personaje %d)", accounts.ErrCharactersBusy, id)
			}
			return err
		}
	}
	return nil
}

// ReapplyPurge purges again, after restoring a backup, a character that purge_log considers purged
// (admin reapply-purges, §11.2), in its own transaction: the account's path (a null purged_at is
// enough, even if the backup brings it alive or deleted and still restorable) with at, the original
// purged_at from purges.txt, instead of the current time; the ledger's year and the name's 30 days
// derive from it. It returns false if the character does not exist in the backup or was already
// purged. reapply-purges deletes all the leases beforehand; if one is still alive anyway, it
// returns [ErrBusy] and touches nothing.
func (p *Purger) ReapplyPurge(ctx context.Context, characterID int64, at time.Time) (bool, error) {
	var done bool
	err := db.InTx(ctx, p.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		var err error
		done, err = p.purge(ctx, tx, characterID, at, pathAccount)
		return err
	})
	return done, err
}

// PurgeExpired is the hourly job for deleted characters (§11.1): it purges, each in its own
// transaction, those past their restore_until. One with a live lease is logged and left for the next
// round; the others continue.
func (p *Purger) PurgeExpired(ctx context.Context) error {
	now := p.clock.Now()
	rows, err := p.pool.Query(ctx, `select character_id from characters where deleted_at is not null
		and restore_until <= $1 and purged_at is null order by character_id`, now)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	var errs []error
	for _, id := range ids {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		var done bool
		err := db.InTx(ctx, p.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
			var err error
			done, err = p.purge(ctx, tx, id, now, pathExpired)
			return err
		})
		switch {
		case errors.Is(err, ErrBusy):
			p.log.Warn("personaje sin purgar: está en el mundo; se reintenta en la vuelta siguiente", "character", id)
		case err != nil:
			errs = append(errs, fmt.Errorf("personaje %d: %w", id, err))
		case done:
			p.log.Info("personaje purgado", "character", id)
		}
	}
	return errors.Join(errs...)
}

// Purger returns the service's character purge (the same one that accounts receives).
func (s *Service) Purger() *Purger { return s.purger }
