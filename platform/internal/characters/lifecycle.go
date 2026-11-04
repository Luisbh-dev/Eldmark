package characters

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/names"
)

// ownCharacter locks (for no key update, like the purge, §11.2) the row of an unpurged character of
// the account; 404 if it does not exist, belongs to another account or is a tombstone.
func ownCharacter(ctx context.Context, tx pgx.Tx, accountID, characterID int64) (*characterRow, error) {
	c, err := scanCharacter(tx.QueryRow(ctx, `select `+characterColumns+` from characters
		where character_id = $1 and account_id = $2 and purged_at is null for no key update`, characterID, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, httpx.ErrNotFound
	}
	return c, err
}

// leaseIsAlive says whether the character has a live lease at time now.
func leaseIsAlive(ctx context.Context, tx pgx.Tx, characterID int64, now time.Time) (bool, error) {
	var alive bool
	err := tx.QueryRow(ctx, `select exists (select 1 from character_leases l where l.character_id = $1 and `+
		leaseAlive+`$2)`, characterID, now).Scan(&alive)
	return alive, err
}

// Delete deletes a character (§4.4) with a window to restore it and returns until when. It locks
// the account's row first, the claim's order (§5.3): that character's deletion and claim run in
// series, and it ends up deleted and without a lease or alive and with one. confirmName has to give
// the same NameRules key as the name (400 validation). With a live lease, 409 character_busy; with
// 5 deletions in 24 h, 429. The name stays reserved until restore_until + 30 days, or only until
// restore_until if the character has less than 24 h of life and less than 1 h played. If it was the
// account's last living character in the world, the realm is freed after 30 days.
func (s *Service) Delete(ctx context.Context, sess *accounts.Session, characterID int64, confirmName *string,
	meta accounts.ClientMeta) (time.Time, error) {
	if confirmName == nil {
		return time.Time{}, errValidation(map[string]string{"confirm_name": "required"})
	}
	now := s.clock.Now()
	restoreUntil := now.Add(RestoreWindow)
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		if _, _, err := lockAccount(ctx, tx, sess.AccountID); err != nil {
			return err
		}
		c, err := ownCharacter(ctx, tx, sess.AccountID, characterID)
		if err != nil {
			return err
		}
		if c.DeletedAt != nil {
			return httpx.ErrNotFound
		}
		if s.names.NormalizeKey(*confirmName) != c.NameKey {
			return errValidation(map[string]string{"confirm_name": "mismatch"})
		}
		busy, err := leaseIsAlive(ctx, tx, c.ID, now)
		if err != nil {
			return err
		}
		if busy {
			return errCharacterBusy()
		}
		if err := dailyLimit(ctx, tx, sess.AccountID, "character_delete", now); err != nil {
			return err
		}
		sums, err := s.summaries(ctx, tx, []int64{c.ID})
		if err != nil {
			return err
		}
		reservedUntil := restoreUntil.Add(NameReservation)
		if now.Sub(c.CreatedAt) < TrialAge && sums[c.ID].PlayedSeconds < TrialPlayedSeconds {
			reservedUntil = restoreUntil
		}
		if _, err := tx.Exec(ctx, `update characters set deleted_at = $2, restore_until = $3 where character_id = $1`,
			c.ID, now, restoreUntil); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `update character_names set status = 'reserved', reserved_until = $4
			where world_id = $1 and name_key = $2 and character_id = $3`, c.WorldID, c.NameKey, c.ID, reservedUntil); err != nil {
			return err
		}
		var alive int
		if err := tx.QueryRow(ctx, `select count(*) from characters where account_id = $1 and world_id = $2
			and deleted_at is null and purged_at is null`, sess.AccountID, c.WorldID).Scan(&alive); err != nil {
			return err
		}
		if alive == 0 {
			if _, err := tx.Exec(ctx, `update account_realms set unlock_at = $3 where account_id = $1 and world_id = $2`,
				sess.AccountID, c.WorldID, now.Add(RealmUnlockDelay)); err != nil {
				return err
			}
		}
		return s.accounts.Event(ctx, tx, sess.AccountID, "character_delete", meta, now)
	})
	if err != nil {
		return time.Time{}, err
	}
	return restoreUntil, nil
}

// Restore restores a character deleted within the window (§4.4): it locks the account and then the
// character's row (like the purge) and checks restore_until and purged_at again, so a restoration at
// the limit and the hourly purge do not cross. Its name becomes active again (if someone had it, 409
// name_taken) and the account's realm is no longer about to be freed. Outside the window, 404; a
// character that is not deleted is returned as is.
func (s *Service) Restore(ctx context.Context, sess *accounts.Session, characterID int64) (*CharacterView, error) {
	now := s.clock.Now()
	var view *CharacterView
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		view = nil
		if _, _, err := lockAccount(ctx, tx, sess.AccountID); err != nil {
			return err
		}
		c, err := ownCharacter(ctx, tx, sess.AccountID, characterID)
		if err != nil {
			return err
		}
		if c.DeletedAt == nil {
			view, err = s.viewOf(ctx, tx, c)
			return err
		}
		if c.RestoreUntil == nil || !c.RestoreUntil.After(now) {
			return httpx.ErrNotFound
		}
		var current = c.Realm
		var unlockAt *time.Time
		err = tx.QueryRow(ctx, `select realm, unlock_at from account_realms where account_id = $1 and world_id = $2
			for update`, sess.AccountID, c.WorldID).Scan(&current, &unlockAt)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			if _, err := tx.Exec(ctx, `insert into account_realms (account_id, world_id, realm) values ($1, $2, $3)`,
				sess.AccountID, c.WorldID, c.Realm); err != nil {
				return err
			}
		case err != nil:
			return err
		case current != c.Realm:
			return errRealmLocked(current, unlockAt)
		}
		var got int64
		err = tx.QueryRow(ctx, `insert into character_names (world_id, name_key, character_id, status, reserved_until)
			values ($1, $2, $3, 'active', null)
			on conflict (world_id, name_key) do update set character_id = excluded.character_id, status = 'active',
			  reserved_until = null
			where character_names.character_id = $3
			   or (character_names.status = 'reserved' and character_names.reserved_until <= $4)
			returning character_id`, c.WorldID, c.NameKey, c.ID, now).Scan(&got)
		if errors.Is(err, pgx.ErrNoRows) {
			return errNameTaken()
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `update characters set deleted_at = null, restore_until = null where character_id = $1`,
			c.ID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `update account_realms set unlock_at = null where account_id = $1 and world_id = $2`,
			sess.AccountID, c.WorldID); err != nil {
			return err
		}
		c.DeletedAt, c.RestoreUntil = nil, nil
		view, err = s.viewOf(ctx, tx, c)
		return err
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// Rename changes a character's name with the forced rename (must_rename, §9.5): without it, 409
// rename_not_required. The new name passes the same checks as on creation (also the same name with
// other capitalization or accents, which is the same: name_taken) and the old one stays reserved 30
// days. With the character in the world, 409 character_busy.
func (s *Service) Rename(ctx context.Context, sess *accounts.Session, characterID int64, name *string) (*CharacterView, error) {
	if name == nil {
		return nil, errValidation(map[string]string{"name": "required"})
	}
	now := s.clock.Now()
	var view *CharacterView
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		view = nil
		if _, _, err := lockAccount(ctx, tx, sess.AccountID); err != nil {
			return err
		}
		c, err := ownCharacter(ctx, tx, sess.AccountID, characterID)
		if err != nil {
			return err
		}
		if c.DeletedAt != nil {
			return httpx.ErrNotFound
		}
		if !c.MustRename {
			return errRenameNotRequired()
		}
		busy, err := leaseIsAlive(ctx, tx, c.ID, now)
		if err != nil {
			return err
		}
		if busy {
			return errCharacterBusy()
		}
		reason, key, err := s.checkName(ctx, tx, *name)
		if err != nil {
			return err
		}
		if reason != names.OK {
			return s.errNameInvalid(reason)
		}
		if key == c.NameKey {
			return errNameTaken()
		}
		if err := claimName(ctx, tx, c.WorldID, key, c.ID, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `update character_names set status = 'reserved', reserved_until = $4
			where world_id = $1 and name_key = $2 and character_id = $3`, c.WorldID, c.NameKey, c.ID,
			now.Add(RenameReservation)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `update characters set name = $2, name_key = $3, must_rename = false
			where character_id = $1`, c.ID, *name, key); err != nil {
			return err
		}
		c.Name, c.NameKey, c.MustRename = *name, key, false
		view, err = s.viewOf(ctx, tx, c)
		return err
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}
