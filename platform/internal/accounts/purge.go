package accounts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
)

// Plazos de la huella de los correos sancionados (§11.2).
const (
	sanctionMemory   = 90 * 24 * time.Hour  // reincidencia: 90 días
	sanctionedMaxAge = 365 * 24 * time.Hour // 1 año como mucho desde la purga
)

// ErrHasCharacters es la causa de una purga que no se hace porque la cuenta tiene personajes sin
// purgar y no hay [CharacterPurger].
var ErrHasCharacters = errors.New("accounts: la cuenta tiene personajes sin purgar")

// ErrCharactersBusy es la causa (errors.Is) de una purga que no se hace porque algún personaje de
// la cuenta tiene un arrendamiento vivo (§11.2, paso 3): el [CharacterPurger] la devuelve y la
// purga horaria lo vuelve a intentar en la vuelta siguiente.
var ErrCharactersBusy = errors.New("accounts: un personaje de la cuenta está en el mundo")

// Motivos de una purga: qué condición se vuelve a mirar con la fila bloqueada.
type purgeReason int

const (
	purgeUnverified purgeReason = iota // sin verificar a los 7 días (staging y production)
	purgeDeletion                      // borrado pedido, con purge_after vencido
)

func (r purgeReason) String() string {
	if r == purgeUnverified {
		return "sin verificar"
	}
	return "borrado pedido"
}

// PurgeDue es el trabajo horario de las cuentas (§4.3, §11.1): purga las que pidieron el borrado
// y cumplieron los 14 días y, en staging y production, las que no verificaron el correo en 7 días.
// Una cuenta que no se puede purgar ahora (con personajes y sin CharacterPurger) se registra y se
// vuelve a intentar en la vuelta siguiente; el resto sigue.
func (s *Service) PurgeDue(ctx context.Context) error {
	now := s.clock.Now()
	type due struct {
		id     int64
		reason purgeReason
	}
	var list []due
	rows, err := s.pool.Query(ctx, `select account_id from accounts where status = 'pending_deletion' and purge_after <= $1
		order by account_id`, now)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, id := range ids {
		list = append(list, due{id, purgeDeletion})
	}
	if s.cfg.Env.Deployed() {
		rows, err := s.pool.Query(ctx, `select account_id from accounts where status = 'active'
			and email_verified_at is null and created_at <= $1 order by account_id`, now.Add(-UnverifiedTTL))
		if err != nil {
			return err
		}
		ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		for _, id := range ids {
			list = append(list, due{id, purgeUnverified})
		}
	}
	var errs []error
	for _, d := range list {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		done, err := s.purgeAccount(ctx, d.id, d.reason, now)
		switch {
		case errors.Is(err, ErrHasCharacters):
			s.log.Warn("cuenta sin purgar: tiene personajes y aún no hay quien los purgue", "account", d.id,
				"reason", d.reason.String())
		case errors.Is(err, ErrCharactersBusy):
			s.log.Warn("cuenta sin purgar: un personaje está en el mundo; se reintenta en la vuelta siguiente",
				"account", d.id, "reason", d.reason.String())
		case err != nil:
			errs = append(errs, fmt.Errorf("cuenta %d: %w", d.id, err))
		case done:
			s.log.Info("cuenta purgada", "account", d.id, "reason", d.reason.String())
		}
	}
	return errors.Join(errs...)
}

// purgeAccount purga la cuenta (§11.2) si, con su fila bloqueada, sigue cumpliendo la condición
// del motivo; devuelve si la purgó. Queda la lápida de accounts (sin correo ni hash, status
// purged) y la fila de purge_log; se borran sus ignorados en los dos sentidos, sesiones, enlaces,
// consentimientos, aceptaciones, derechos, reinos, accesos, chat enviado (lo copiado a un reporte
// sigue en report_evidence) y correos de prueba, y sus sanciones se quedan sin motivo.
func (s *Service) purgeAccount(ctx context.Context, accountID int64, reason purgeReason, now time.Time) (bool, error) {
	done := false
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		done = false
		var email *string
		var status string
		var verified bool
		var created time.Time
		var purgeAfter *time.Time
		// Primero la fila de la cuenta: el orden de la reclamación (§5.3) y del borrado de
		// personajes (§4.4).
		err := tx.QueryRow(ctx, `select email, status, email_verified_at is not null, created_at, purge_after
			from accounts where account_id = $1 for no key update`, accountID).
			Scan(&email, &status, &verified, &created, &purgeAfter)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		switch reason {
		case purgeUnverified:
			if status != "active" || verified || created.After(now.Add(-UnverifiedTTL)) {
				return nil
			}
		case purgeDeletion:
			if status != "pending_deletion" || purgeAfter == nil || purgeAfter.After(now) {
				return nil
			}
		}
		var characters int
		if err := tx.QueryRow(ctx, `select count(*) from characters where account_id = $1 and purged_at is null`,
			accountID).Scan(&characters); err != nil {
			return err
		}
		if characters > 0 {
			if s.characters == nil {
				return ErrHasCharacters
			}
			if err := s.characters.PurgeAccountCharacters(ctx, tx, accountID, now); err != nil {
				return err
			}
		}
		if email != nil {
			if err := s.rememberSanctionedEmail(ctx, tx, accountID, *email, now); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `delete from outbound_mail where to_email = $1`, *email); err != nil {
				return err
			}
		}
		for _, sql := range []string{
			`delete from ignores where account_id = $1 or ignored_account_id = $1`,
			`delete from sessions where account_id = $1`,
			`delete from account_tokens where account_id = $1`,
			`delete from consents where account_id = $1`,
			`delete from legal_acceptances where account_id = $1`,
			`delete from entitlements where account_id = $1`,
			`delete from account_realms where account_id = $1`,
			`delete from auth_events where account_id = $1`,
			`delete from chat_messages where sender_account_id = $1`,
			`update sanctions set reason = '' where account_id = $1`,
		} {
			if _, err := tx.Exec(ctx, sql, accountID); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `update accounts set email = null, password_hash = null, status = 'purged', purged_at = $2
			where account_id = $1`, accountID, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `insert into purge_log (kind, id, purged_at) values ('account', $1, $2)
			on conflict do nothing`, accountID, now); err != nil {
			return err
		}
		done = true
		return nil
	})
	return done, err
}

// rememberSanctionedEmail guarda la huella HMAC del correo si la cuenta tiene una sanción vigente o
// de los últimos 90 días (§11.2), para que el registro lo rechace: cada sanción sin revocar cuenta
// hasta 90 días después de su fin (una expulsión permanente, el tope; un aviso o un renombrado,
// sin duración, desde que se puso), con 1 año como mucho desde la purga.
func (s *Service) rememberSanctionedEmail(ctx context.Context, tx pgx.Tx, accountID int64, email string, now time.Time) error {
	rows, err := tx.Query(ctx, `select ends_at, created_at, kind = 'ban' and ends_at is null from sanctions
		where account_id = $1 and revoked_at is null`, accountID)
	if err != nil {
		return err
	}
	defer rows.Close()
	limit := now.Add(sanctionedMaxAge)
	var until time.Time
	for rows.Next() {
		var ends *time.Time
		var created time.Time
		var permanent bool
		if err := rows.Scan(&ends, &created, &permanent); err != nil {
			return err
		}
		end := created
		if ends != nil {
			end = *ends
		}
		candidate := end.Add(sanctionMemory)
		if permanent {
			candidate = limit
		}
		until = later(until, candidate)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !until.After(now) {
		return nil
	}
	if until.After(limit) {
		until = limit
	}
	_, err = tx.Exec(ctx, `insert into sanctioned_email_hashes (hmac, until) values ($1, $2)
		on conflict (hmac) do update set until = greatest(sanctioned_email_hashes.until, excluded.until)`,
		s.sanctionedHMAC(email), until)
	return err
}

func later(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}
