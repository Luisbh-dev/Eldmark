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

// Purger purga personajes (plataforma.md §11.2): deja la lápida (la fila de characters sin nombre,
// con purged_at) y lo de solo añadir del progreso, que la retención borra al año. Implementa
// accounts.CharacterPurger.
type Purger struct {
	pool     *pgxpool.Pool
	progress persistence.ProgressStore
	clock    clock.Clock
	log      *slog.Logger
}

// NewPurger prepara la purga de personajes.
func NewPurger(pool *pgxpool.Pool, progress persistence.ProgressStore, c clock.Clock, log *slog.Logger) *Purger {
	if c == nil {
		c = clock.System{}
	}
	if log == nil {
		log = logx.Discard()
	}
	return &Purger{pool: pool, progress: progress, clock: c, log: log}
}

// purgePath es el camino de una purga, que decide qué se vuelve a mirar con la fila bloqueada.
type purgePath int

const (
	pathExpired purgePath = iota // al vencer restore_until (trabajo horario)
	pathAccount                  // con la cuenta: solo purged_at nulo (manda la cuenta)
)

// errBusy es un personaje con un arrendamiento vivo: no se purga.
var errBusy = errors.New("characters: el personaje tiene un arrendamiento vivo")

// purge purga un personaje dentro de tx, con los bloqueos de §11.2 en el orden del guardado
// (primero el arrendamiento, después la fila de characters): devuelve si lo purgó. Con un
// arrendamiento vivo devuelve errBusy y no toca nada.
func (p *Purger) purge(ctx context.Context, tx pgx.Tx, characterID int64, at time.Time, path purgePath) (bool, error) {
	// 1. El arrendamiento, si hay fila.
	var leaseInstance *[16]byte
	var leaseExpires *time.Time
	err := tx.QueryRow(ctx, `select zone_instance_id, expires_at from character_leases where character_id = $1 for update`,
		characterID).Scan(&leaseInstance, &leaseExpires)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, err
	}
	// 2. La fila del personaje, y si sigue tocando.
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
			return false, nil // restaurado, aún en plazo o ya purgado
		}
	case pathAccount:
		if purgedAt != nil {
			return false, nil
		}
	}
	// 3. Con un arrendamiento vivo no se purga: la vuelta siguiente lo reintenta.
	if leaseInstance != nil && leaseExpires != nil && leaseExpires.After(at) {
		return false, errBusy
	}
	// 4. El progreso, la identidad y la lápida.
	if err := p.progress.Purge(ctx, tx, characterID); err != nil {
		return false, err
	}
	if path == pathAccount {
		// Con la cuenta, el nombre de un personaje vivo queda reservado 30 días (el de uno borrado
		// ya tiene su reserva).
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

// PurgeAccountCharacters implementa accounts.CharacterPurger: purga, dentro de la transacción de
// la purga de la cuenta (que ya bloqueó su fila), todos sus personajes sin purgar, vivos o
// borrados. Si alguno tiene un arrendamiento vivo devuelve un error que envuelve
// accounts.ErrCharactersBusy, y la cuenta no se purga.
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
			if errors.Is(err, errBusy) {
				return fmt.Errorf("%w (personaje %d)", accounts.ErrCharactersBusy, id)
			}
			return err
		}
	}
	return nil
}

// PurgeExpired es el trabajo horario de los personajes borrados (§11.1): purga, cada uno en su
// transacción, los que pasaron su restore_until. Uno con arrendamiento vivo se registra y queda
// para la vuelta siguiente; los demás siguen.
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
		case errors.Is(err, errBusy):
			p.log.Warn("personaje sin purgar: está en el mundo; se reintenta en la vuelta siguiente", "character", id)
		case err != nil:
			errs = append(errs, fmt.Errorf("personaje %d: %w", id, err))
		case done:
			p.log.Info("personaje purgado", "character", id)
		}
	}
	return errors.Join(errs...)
}

// Purger devuelve la purga de personajes del servicio (la misma que recibe accounts).
func (s *Service) Purger() *Purger { return s.purger }
