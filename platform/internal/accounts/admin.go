package accounts

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/passwords"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/legal"
)

// What the admin command uses (P7a, §9.1 and §11.2): revoking an account's sessions, purging it
// without waiting and creating test or team accounts.

// Errors of [Service.CreateAccount].
var (
	ErrEmailInvalid    = errors.New("accounts: el correo no vale")
	ErrEmailTaken      = errors.New("accounts: ya hay una cuenta con ese correo")
	ErrEmailReserved   = errors.New("accounts: el correo lo reserva el enlace revert_email vivo de otra cuenta (§4.3)")
	ErrPasswordInvalid = errors.New("accounts: la contraseña no vale (de 10 a 128 caracteres y distinta del correo)")
	ErrRoleInvalid     = errors.New("accounts: rol desconocido")
)

// RevokeSessions revokes all the account's live sessions with that reason (sessions.revoke_reason:
// role_changed in set-role, deletion in purge-now, admin...), inside the caller's transaction, and
// returns how many it revoked. The heartbeat kicks out its character (§6: session_revoked).
func RevokeSessions(ctx context.Context, tx pgx.Tx, accountID int64, reason string, now time.Time) (int64, error) {
	tag, err := tx.Exec(ctx, `update sessions set revoked_at = $2, revoke_reason = $3
		where account_id = $1 and revoked_at is null`, accountID, now, reason)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// PurgeNow purges the account right away, without waiting the 14 days (admin purge-now, §11.2:
// express request), like the hourly purge: tombstone of the account and its characters, purge_log
// and the email's fingerprint if it has sanctions. It returns false if the account does not exist
// or was already purged, and an error that wraps [ErrCharactersBusy] if any character is still in
// the world (then it purges nothing).
func (s *Service) PurgeNow(ctx context.Context, accountID int64) (bool, error) {
	return s.purgeAccount(ctx, accountID, purgeRequested, s.clock.Now())
}

// ReapplyPurge purges again, after restoring a backup, an account that purge_log considers purged
// (admin reapply-purges, §11.2): like [Service.PurgeNow], but with at, the original purged_at from
// purges.txt, instead of the current time, so that restoring does not extend any retention (the
// sanctions' one and the cap on sanctioned_email_hashes derive from it). It returns false if the
// account does not exist in the backup or was already purged. It runs without leases
// (reapply-purges deletes them first); if one is still alive anyway, the error wraps
// [ErrCharactersBusy] and nothing is purged.
func (s *Service) ReapplyPurge(ctx context.Context, accountID int64, at time.Time) (bool, error) {
	return s.purgeAccount(ctx, accountID, purgeReapplied, at)
}

// NewAccount is an account created by the admin command (test or team accounts).
type NewAccount struct {
	Email    string
	Password string
	Role     string
}

// CreateAccount creates, in transaction tx, an already verified account, with age confirmed and the
// current legal texts accepted (the team creates them: admin create-account and bootstrap, for
// tests and for staff), without consents and with the given role. The email is normalized. It
// returns the account_id, or [ErrEmailInvalid], [ErrEmailTaken], [ErrEmailReserved],
// [ErrPasswordInvalid] or [ErrRoleInvalid].
func (s *Service) CreateAccount(ctx context.Context, tx pgx.Tx, a NewAccount) (int64, error) {
	email := NormalizeEmail(a.Email)
	if !ValidEmail(email) {
		return 0, ErrEmailInvalid
	}
	if PasswordProblem(a.Password, email) != "" {
		return 0, ErrPasswordInvalid
	}
	if sanctions.Rank(a.Role) < 0 {
		return 0, ErrRoleInvalid
	}
	phc, err := passwords.HashContext(ctx, a.Password, s.params)
	if err != nil {
		return 0, err
	}
	now := s.clock.Now()
	if reserved, err := emailReserved(ctx, tx, email, 0, now); err != nil {
		return 0, err
	} else if reserved {
		return 0, ErrEmailReserved
	}
	var accountID int64
	err = tx.QueryRow(ctx, `insert into accounts (email, password_hash, email_verified_at, role, age_confirmed_at, created_at)
		values ($1, $2, $3, $4, $3, $3) on conflict (email) do nothing returning account_id`,
		email, phc, now, a.Role).Scan(&accountID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrEmailTaken
	}
	if err != nil {
		return 0, err
	}
	for _, kind := range legal.Kinds {
		if _, err := tx.Exec(ctx, `insert into legal_acceptances (account_id, kind, version, accepted_at)
			values ($1, $2, $3, $4)`, accountID, kind, s.legal.Current(kind).Version, now); err != nil {
			return 0, err
		}
	}
	no := false
	if err := saveConsents(ctx, tx, accountID, Consents{CrashReports: &no, Analytics: &no}, now); err != nil {
		return 0, err
	}
	return accountID, nil
}

// LookupAccount returns the id, the role and the status of the account with that email (already
// normalized or not), or 0 if there is none (a purged one has no email).
func (s *Service) LookupAccount(ctx context.Context, email string) (id int64, role, status string, err error) {
	err = s.pool.QueryRow(ctx, `select account_id, role, status from accounts where email = $1`,
		NormalizeEmail(email)).Scan(&id, &role, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, "", "", nil
	}
	return id, role, status, err
}
