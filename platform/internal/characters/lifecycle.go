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

// ownCharacter bloquea (for no key update, como la purga, §11.2) la fila de un personaje de la
// cuenta sin purgar; 404 si no existe, es de otra cuenta o es una lápida.
func ownCharacter(ctx context.Context, tx pgx.Tx, accountID, characterID int64) (*characterRow, error) {
	c, err := scanCharacter(tx.QueryRow(ctx, `select `+characterColumns+` from characters
		where character_id = $1 and account_id = $2 and purged_at is null for no key update`, characterID, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, httpx.ErrNotFound
	}
	return c, err
}

// leaseIsAlive dice si el personaje tiene un arrendamiento vivo a la hora now.
func leaseIsAlive(ctx context.Context, tx pgx.Tx, characterID int64, now time.Time) (bool, error) {
	var alive bool
	err := tx.QueryRow(ctx, `select exists (select 1 from character_leases l where l.character_id = $1 and `+
		leaseAlive+`$2)`, characterID, now).Scan(&alive)
	return alive, err
}

// Delete borra un personaje (§4.4) con plazo para restaurarlo y devuelve hasta cuándo. Bloquea
// primero la fila de la cuenta, el orden de la reclamación (§5.3): el borrado y la reclamación de
// ese personaje van en serie, y queda borrado y sin arrendamiento o vivo y con él. confirmName
// tiene que dar la misma clave de NameRules que el nombre (400 validation). Con arrendamiento vivo,
// 409 character_busy; con 5 borrados en 24 h, 429. El nombre queda reservado hasta
// restore_until + 30 días, o solo hasta restore_until si el personaje tiene menos de 24 h de vida y
// menos de 1 h jugada. Si era el último vivo de la cuenta en el mundo, el reino se libera a los 30
// días.
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

// Restore restaura un personaje borrado en plazo (§4.4): bloquea la cuenta y después la fila del
// personaje (como la purga) y vuelve a mirar restore_until y purged_at, así que una restauración
// en el límite y la purga horaria no se cruzan. Su nombre vuelve a estar activo (si alguien lo
// tuviera, 409 name_taken) y el reino de la cuenta deja de estar por liberarse. Fuera de plazo, 404;
// un personaje que no está borrado se devuelve tal cual.
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

// Rename cambia el nombre de un personaje con el renombrado forzado (must_rename, §9.5): sin él,
// 409 rename_not_required. El nombre nuevo pasa las mismas comprobaciones que al crear (también
// el mismo nombre con otras mayúsculas o tildes, que es el mismo: name_taken) y el viejo queda
// reservado 30 días. Con el personaje en el mundo, 409 character_busy.
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
