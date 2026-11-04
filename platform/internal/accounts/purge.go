package accounts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
)

// Retention periods of the sanctioned emails' fingerprint (§11.2).
const (
	sanctionMemory   = 90 * 24 * time.Hour  // repeat offense: 90 days
	sanctionedMaxAge = 365 * 24 * time.Hour // 1 year at most from the purge
)

// ErrHasCharacters is the cause of a purge that is not done because the account has unpurged
// characters and there is no [CharacterPurger].
var ErrHasCharacters = errors.New("accounts: la cuenta tiene personajes sin purgar")

// ErrCharactersBusy is the cause (errors.Is) of a purge that is not done because some character of
// the account has a live lease (§11.2, step 3): the [CharacterPurger] returns it and the hourly
// purge tries again in the next round.
var ErrCharactersBusy = errors.New("accounts: un personaje de la cuenta está en el mundo")

// Reasons for a purge: which condition is checked again with the row locked.
type purgeReason int

const (
	purgeUnverified purgeReason = iota // unverified after 7 days (staging and production)
	purgeDeletion                      // deletion requested, with purge_after elapsed
	purgeRequested                     // admin purge-now: any unpurged account (§11.2)
	purgeReapplied                     // admin reapply-purges: any unpurged account, with purged_at from purges.txt
)

func (r purgeReason) String() string {
	switch r {
	case purgeUnverified:
		return "sin verificar"
	case purgeRequested:
		return "purge-now"
	case purgeReapplied:
		return "reapply-purges"
	}
	return "borrado pedido"
}

// PurgeDue is the hourly accounts job (§4.3, §11.1): it purges those that requested deletion and
// reached the 14 days and, in staging and production, those that did not verify the email within 7
// days. An account that cannot be purged now (with characters and without a CharacterPurger) is
// logged and tried again in the next round; the rest continue.
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

// purgeAccount purges the account (§11.2) if, with its row locked, it still meets the reason's
// condition; it returns whether it purged it. What remains is the accounts tombstone (without email
// or hash, status purged) and the purge_log row; its ignored players in both directions, sessions,
// links, consents, acceptances, entitlements, realms, logins, sent chat (what was copied into a
// report stays in report_evidence) and test emails are deleted, and its sanctions are left without
// a reason.
func (s *Service) purgeAccount(ctx context.Context, accountID int64, reason purgeReason, now time.Time) (bool, error) {
	done := false
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		done = false
		var email *string
		var status string
		var verified bool
		var created time.Time
		var purgeAfter *time.Time
		// The account's row first: the claim order (§5.3) and the character deletion order (§4.4).
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
		case purgeRequested, purgeReapplied:
			if status == "purged" {
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

// rememberSanctionedEmail stores the email's HMAC fingerprint if the account has a current sanction
// or one from the last 90 days (§11.2), so that registration rejects it: each unrevoked sanction
// counts up to 90 days after its end (a permanent ban, the cap; a warning or a rename, with no
// duration, from when it was applied), with 1 year at most from the purge.
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
