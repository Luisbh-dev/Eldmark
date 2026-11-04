package accounts

import (
	"context"
	"errors"
	"log/slog"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/passwords"
	"eldmark/platform/internal/ratelimit"
)

// Purposes of account_tokens.
const (
	purposeVerify = "verify_email"
	purposeReset  = "reset_password"
	purposeChange = "change_email"
	purposeRevert = "revert_email"
)

// issueToken stores a single-use link and returns its token.
func issueToken(ctx context.Context, q execer, accountID int64, purpose, email string, expires, now time.Time) (string, error) {
	token, hash := newToken()
	_, err := q.Exec(ctx, `insert into account_tokens (token_hash, account_id, purpose, email, expires_at, created_at)
		values ($1, $2, $3, $4, $5, $6)`, hash, accountID, purpose, nullString(email), expires, now)
	return token, err
}

// linkToken is a consumed link.
type linkToken struct {
	accountID int64
	purpose   string
	email     string    // change_email: the new one; revert_email: the old one; verify and reset: the one it was sent to
	createdAt time.Time // revert_email: its order among the account's (§4.3)
}

// consumeToken marks a link of any of the given purposes as used. Used or expired: 400 validation
// with fields.token = "used" or "expired" (and, since the transaction is rolled back, nothing
// changes); unknown or of another purpose, "invalid".
func consumeToken(ctx context.Context, tx pgx.Tx, token string, now time.Time, purposes ...string) (linkToken, error) {
	if !ValidToken(token) {
		return linkToken{}, errLink("invalid")
	}
	hash := hashToken(token)
	var t linkToken
	var email *string
	var expires time.Time
	var used *time.Time
	err := tx.QueryRow(ctx, `select account_id, purpose, email, expires_at, used_at, created_at from account_tokens
		where token_hash = $1 for update`, hash).Scan(&t.accountID, &t.purpose, &email, &expires, &used, &t.createdAt)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !slices.Contains(purposes, t.purpose)) {
		return linkToken{}, errLink("invalid")
	}
	if err != nil {
		return linkToken{}, err
	}
	if used != nil {
		return linkToken{}, errLink("used")
	}
	if !now.Before(expires) {
		return linkToken{}, errLink("expired")
	}
	if _, err := tx.Exec(ctx, `update account_tokens set used_at = $2 where token_hash = $1`, hash, now); err != nil {
		return linkToken{}, err
	}
	if email != nil {
		t.email = *email
	}
	return t, nil
}

// invalidateLinks invalidates the account's pending links, in the same transaction as the change
// (§4.3). Not the revert_email ones: whoever stole the account cannot take away the owner's way back
// by changing the email again. They are only voided by spending an older one
// ([invalidateLaterReverts]).
func invalidateLinks(ctx context.Context, tx pgx.Tx, accountID int64, now time.Time) error {
	_, err := tx.Exec(ctx, `update account_tokens set used_at = $2
		where account_id = $1 and used_at is null and purpose <> 'revert_email'`, accountID, now)
	return err
}

// invalidateLaterReverts voids the account's revert_email links issued after one that has just been
// spent (§4.3): those of the emails that came after. In a chain of changes A->B->C, the owner's link
// (the one that went to A) is always the oldest, so spending it kills the one that went to B; B's,
// spent earlier, does not touch A's. The order is created_at, which is never repeated within an
// account ([revertCreatedAt]).
func invalidateLaterReverts(ctx context.Context, tx pgx.Tx, accountID int64, after, now time.Time) error {
	_, err := tx.Exec(ctx, `update account_tokens set used_at = $3
		where account_id = $1 and purpose = 'revert_email' and used_at is null and created_at > $2`, accountID, after, now)
	return err
}

// revertCreatedAt is the created_at of a new revert_email of the account: now (in µs, the
// database's precision) or, if the account already has one equal or later (the same instant, a clock
// going backwards), 1 µs after the last one. That way the §4.3 order never has ties.
func revertCreatedAt(ctx context.Context, tx pgx.Tx, accountID int64, now time.Time) (time.Time, error) {
	created := now.Truncate(time.Microsecond)
	var last *time.Time
	if err := tx.QueryRow(ctx, `select max(created_at) from account_tokens where account_id = $1 and purpose = 'revert_email'`,
		accountID).Scan(&last); err != nil {
		return time.Time{}, err
	}
	if last != nil && !created.After(*last) {
		created = last.Add(time.Microsecond)
	}
	return created, nil
}

// emailReserved says whether the email is reserved by a live revert_email (unused and unexpired) of
// an account other than except (§4.3): while the owner can go back to their old email, nobody else
// takes it. A registration or an email change to it is treated as to an email with an account.
func emailReserved(ctx context.Context, q querier, email string, except int64, now time.Time) (bool, error) {
	var reserved bool
	err := q.QueryRow(ctx, `select exists (select 1 from account_tokens where purpose = 'revert_email'
		and used_at is null and expires_at > $3 and email = $1 and account_id <> $2)`, email, except, now).Scan(&reserved)
	return reserved, err
}

// lockAccount locks the account's row (for no key update, the order of §5.3) and returns its email
// and its status. A purged account does not exist.
func lockAccount(ctx context.Context, tx pgx.Tx, accountID int64) (email, status string, err error) {
	var e *string
	err = tx.QueryRow(ctx, `select email, status from accounts where account_id = $1 for no key update`, accountID).
		Scan(&e, &status)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (status == "purged" || e == nil)) {
		return "", "", pgx.ErrNoRows
	}
	if err != nil {
		return "", "", err
	}
	return *e, status, nil
}

// LinkResult says what a /verify link did: verify the email or confirm the change.
type LinkResult string

// Results of [Service.ConfirmLink].
const (
	LinkVerified LinkResult = "verified"
	LinkChanged  LinkResult = "changed"
)

// ConfirmLink handles the link of the /verify page, which is valid for verify_email and for
// change_email (both confirm an email).
func (s *Service) ConfirmLink(ctx context.Context, token string) (LinkResult, error) {
	if !ValidToken(token) {
		return "", errLink("invalid")
	}
	var purpose string
	err := s.pool.QueryRow(ctx, `select purpose from account_tokens where token_hash = $1`, hashToken(token)).Scan(&purpose)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", errLink("invalid")
	}
	if err != nil {
		return "", err
	}
	switch purpose {
	case purposeVerify:
		return LinkVerified, s.VerifyEmail(ctx, token)
	case purposeChange:
		return LinkChanged, s.ConfirmEmailChange(ctx, token)
	}
	return "", errLink("invalid")
}

// VerifyEmail verifies the email with a verify_email link.
func (s *Service) VerifyEmail(ctx context.Context, token string) error {
	now := s.clock.Now()
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		t, err := consumeToken(ctx, tx, token, now, purposeVerify)
		if err != nil {
			return err
		}
		email, _, err := lockAccount(ctx, tx, t.accountID)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && t.email != "" && t.email != email) {
			// The account no longer exists or changed email after the link.
			return errLink("invalid")
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `update accounts set email_verified_at = coalesce(email_verified_at, $2)
			where account_id = $1`, t.accountID, now)
		return err
	})
}

// ResendVerification sends another verify_email link; the previous ones stop being valid. With the
// email already verified it does nothing (the response is the same).
func (s *Service) ResendVerification(ctx context.Context, sess *Session, meta ClientMeta) error {
	now := s.clock.Now()
	var verified bool
	if err := s.pool.QueryRow(ctx, `select email_verified_at is not null from accounts where account_id = $1`,
		sess.AccountID).Scan(&verified); err != nil {
		return err
	}
	if verified {
		return nil
	}
	if err := s.allowMail(sess.Email, meta.IP, now); err != nil {
		return err
	}
	var token string
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		email, _, err := lockAccount(ctx, tx, sess.AccountID)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `update account_tokens set used_at = $2
			where account_id = $1 and purpose = 'verify_email' and used_at is null`, sess.AccountID, now); err != nil {
			return err
		}
		token, err = issueToken(ctx, tx, sess.AccountID, purposeVerify, email, now.Add(VerifyTTL), now)
		return err
	})
	if err != nil {
		return err
	}
	s.sendMail(ctx, mail.VerifyEmail, sess.Email, mail.Data{Link: s.link("verify", token)})
	return nil
}

// resetTimeout bounds what continues in the background of a recovery request.
const resetTimeout = 30 * time.Second

// RequestPasswordReset sends a recovery link if the email has an account. The response is always
// the same (202), whether it exists or not, and does not wait for the database: after validating the
// email and spending the limit token, looking up the account, storing the link and sending it
// continue in the background ([Service.Wait]). Before, with an account a write (and its fsync) was
// committed and without one it was only read: the response time revealed which emails have an
// account (§4.2). A database failure no longer gives 503: it is logged.
func (s *Service) RequestPasswordReset(ctx context.Context, email string, meta ClientMeta) error {
	email = NormalizeEmail(email)
	if !ValidEmail(email) {
		return errValidation(map[string]string{"email": "invalid"})
	}
	now := s.clock.Now()
	if err := s.allowMail(email, meta.IP, now); err != nil {
		return err
	}
	s.background.Add(1)
	go func() {
		defer s.background.Done()
		bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), resetTimeout)
		defer cancel()
		s.passwordReset(bg, email, meta, now)
	}()
	return nil
}

// passwordReset is the background part of [Service.RequestPasswordReset]: both paths write their
// password_reset row in auth_events (without an account, with a null account_id, like
// register_blocked); with an account, also the link and the email.
func (s *Service) passwordReset(ctx context.Context, email string, meta ClientMeta, now time.Time) {
	var token string
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		token = ""
		var accountID int64
		err := tx.QueryRow(ctx, `select account_id from accounts where email = $1 and status <> 'purged'`, email).Scan(&accountID)
		if errors.Is(err, pgx.ErrNoRows) {
			return s.event(ctx, tx, 0, "password_reset", meta, now)
		}
		if err != nil {
			return err
		}
		if token, err = issueToken(ctx, tx, accountID, purposeReset, email, now.Add(ResetTTL), now); err != nil {
			return err
		}
		return s.event(ctx, tx, accountID, "password_reset", meta, now)
	})
	if err != nil {
		s.log.LogAttrs(ctx, slog.LevelError, "no se ha podido atender una recuperación de contraseña",
			slog.String("req", logx.RequestID(ctx)), slog.String("to", logx.MaskEmail(email)), slog.String("err", err.Error()))
		return
	}
	if token != "" {
		s.sendMail(ctx, mail.ResetPassword, email, mail.Data{Link: s.link("reset", token)})
	}
}

// Wait waits for what continues in the background (the password recoveries) to finish: serve calls
// it on shutdown, before closing the mail queue, and the tests before looking at the database.
func (s *Service) Wait() { s.background.Wait() }

// ConfirmPasswordReset changes the password with a reset_password link: it revokes all sessions
// (password_changed) and invalidates the links.
func (s *Service) ConfirmPasswordReset(ctx context.Context, token, newPassword string) error {
	if problem := PasswordProblem(newPassword, ""); problem != "" {
		return errValidation(map[string]string{"new_password": problem})
	}
	if !ValidToken(token) {
		return errLink("invalid")
	}
	phc, err := passwords.HashContext(ctx, newPassword, s.params)
	if err != nil {
		return err
	}
	now := s.clock.Now()
	var accountID int64
	err = db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		t, err := consumeToken(ctx, tx, token, now, purposeReset)
		if err != nil {
			return err
		}
		accountID = t.accountID
		email, _, err := lockAccount(ctx, tx, t.accountID)
		if errors.Is(err, pgx.ErrNoRows) {
			return errLink("invalid")
		}
		if err != nil {
			return err
		}
		if problem := PasswordProblem(newPassword, email); problem != "" {
			return errValidation(map[string]string{"new_password": problem})
		}
		if _, err := tx.Exec(ctx, `update accounts set password_hash = $2 where account_id = $1`, t.accountID, phc); err != nil {
			return err
		}
		if err := revokeSessions(ctx, tx, t.accountID, 0, "password_changed", now); err != nil {
			return err
		}
		return invalidateLinks(ctx, tx, t.accountID, now)
	})
	if err != nil {
		return err
	}
	s.resetFailures(accountID)
	return nil
}

// ChangePassword changes the password with the current one (CheckPassword): it revokes the other
// sessions (password_changed) and invalidates the links.
func (s *Service) ChangePassword(ctx context.Context, sess *Session, current, newPassword string, meta ClientMeta) error {
	fields := map[string]string{}
	if current == "" || len(current) > maxPasswordBytes {
		fields["current_password"] = "required"
	}
	if problem := PasswordProblem(newPassword, sess.Email); problem != "" {
		fields["new_password"] = problem
	}
	if len(fields) > 0 {
		return errValidation(fields)
	}
	ok, err := s.CheckPassword(ctx, sess.AccountID, sess.Email, current, meta.IP)
	if err := s.passwordError(ctx, sess, ok, err, meta); err != nil {
		return err
	}
	phc, err := passwords.HashContext(ctx, newPassword, s.params)
	if err != nil {
		return err
	}
	now := s.clock.Now()
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		if _, _, err := lockAccount(ctx, tx, sess.AccountID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `update accounts set password_hash = $2 where account_id = $1`, sess.AccountID, phc); err != nil {
			return err
		}
		if err := revokeSessions(ctx, tx, sess.AccountID, sess.ID, "password_changed", now); err != nil {
			return err
		}
		return invalidateLinks(ctx, tx, sess.AccountID, now)
	})
}

// RequestEmailChange requests changing the email (with the password). The response is always 202:
// the new email gets change_email or, if it already has an account, register_existing.
func (s *Service) RequestEmailChange(ctx context.Context, sess *Session, newEmail, password string, meta ClientMeta) error {
	newEmail = NormalizeEmail(newEmail)
	fields := map[string]string{}
	if !ValidEmail(newEmail) {
		fields["new_email"] = "invalid"
	}
	if password == "" || len(password) > maxPasswordBytes {
		fields["password"] = "required"
	}
	if len(fields) > 0 {
		return errValidation(fields)
	}
	ok, err := s.CheckPassword(ctx, sess.AccountID, sess.Email, password, meta.IP)
	if err := s.passwordError(ctx, sess, ok, err, meta); err != nil {
		return err
	}
	now := s.clock.Now()
	// The email limit counts the recipient, the IP and also the account that requests it: with one
	// session it is not possible to write to many different emails.
	if ok, wait := ratelimit.AllowAll(now,
		ratelimit.Key{Limiter: s.limits.mailAccount, Key: emailHash(newEmail)},
		ratelimit.Key{Limiter: s.limits.mailAccount, Key: accountKey(sess.AccountID, "")},
		ratelimit.Key{Limiter: s.limits.mailIP, Key: httpx.AddrGroup(meta.IP)}); !ok {
		return errRateLimited(wait)
	}
	tpl := mail.RegisterExisting
	var data mail.Data
	err = db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		tpl, data = mail.RegisterExisting, mail.Data{}
		var taken bool
		if err := tx.QueryRow(ctx, `select exists (select 1 from accounts where email = $1)`, newEmail).Scan(&taken); err != nil {
			return err
		}
		if !taken {
			// An email reserved by another account's revert_email counts as having an account (§4.3).
			var err error
			if taken, err = emailReserved(ctx, tx, newEmail, sess.AccountID, now); err != nil {
				return err
			}
		}
		if taken {
			return nil
		}
		if _, _, err := lockAccount(ctx, tx, sess.AccountID); err != nil {
			return err
		}
		token, err := issueToken(ctx, tx, sess.AccountID, purposeChange, newEmail, now.Add(ChangeEmailTTL), now)
		if err != nil {
			return err
		}
		tpl, data = mail.ChangeEmail, mail.Data{Link: s.link("verify", token)}
		return nil
	})
	if err != nil {
		return err
	}
	s.sendMail(ctx, tpl, newEmail, data)
	return nil
}

// ConfirmEmailChange changes the email with a change_email link and marks it as verified: it
// revokes the sessions (email_changed), invalidates the links and sends the old email a notice with
// a 7-day revert_email link.
func (s *Service) ConfirmEmailChange(ctx context.Context, token string) error {
	now := s.clock.Now()
	var oldEmail, newEmail, revert string
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		t, err := consumeToken(ctx, tx, token, now, purposeChange)
		if err != nil {
			return err
		}
		oldEmail, _, err = lockAccount(ctx, tx, t.accountID)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && t.email == "") {
			return errLink("invalid")
		}
		if err != nil {
			return err
		}
		newEmail = t.email
		if err := setEmail(ctx, tx, t.accountID, newEmail, now, false); err != nil {
			return err
		}
		if err := revokeSessions(ctx, tx, t.accountID, 0, "email_changed", now); err != nil {
			return err
		}
		if err := invalidateLinks(ctx, tx, t.accountID, now); err != nil {
			return err
		}
		created, err := revertCreatedAt(ctx, tx, t.accountID, now)
		if err != nil {
			return err
		}
		revert, err = issueToken(ctx, tx, t.accountID, purposeRevert, oldEmail, now.Add(RevertTTL), created)
		if err != nil {
			return err
		}
		return s.event(ctx, tx, t.accountID, "email_changed", ClientMeta{}, now)
	})
	if err != nil {
		return err
	}
	s.sendMail(ctx, mail.EmailChanged, oldEmail, mail.Data{Link: s.link("revert", revert), NewEmail: logx.MaskEmail(newEmail)})
	return nil
}

// setEmail changes the account's email and marks it as verified; clearPassword leaves the account
// without a password (revert_email). If another account already has that email, or reserves it with
// a live revert_email (§4.3), the link is not valid (fields.token = "unavailable").
func setEmail(ctx context.Context, tx pgx.Tx, accountID int64, email string, now time.Time, clearPassword bool) error {
	var taken bool
	if err := tx.QueryRow(ctx, `select exists (select 1 from accounts where email = $1 and account_id <> $2)`,
		email, accountID).Scan(&taken); err != nil {
		return err
	}
	if !taken {
		var err error
		if taken, err = emailReserved(ctx, tx, email, accountID, now); err != nil {
			return err
		}
	}
	if taken {
		return errLink("unavailable")
	}
	_, err := tx.Exec(ctx, `update accounts set email = $2, email_verified_at = $3,
		password_hash = case when $4 then null else password_hash end where account_id = $1`, accountID, email, now, clearPassword)
	if db.SQLState(err) == "23505" {
		return errLink("unavailable")
	}
	return err
}

// RevertEmail goes back to the old email with a revert_email link: it voids the account's
// revert_email links issued afterwards ([invalidateLaterReverts]), revokes all sessions
// (email_reverted), leaves the account without a password (password_hash = null), invalidates the
// links and sends the recovered email a link to choose a password.
func (s *Service) RevertEmail(ctx context.Context, token string) error {
	now := s.clock.Now()
	var email, reset string
	var accountID int64
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		t, err := consumeToken(ctx, tx, token, now, purposeRevert)
		if err != nil {
			return err
		}
		accountID = t.accountID
		if _, _, err = lockAccount(ctx, tx, t.accountID); errors.Is(err, pgx.ErrNoRows) || (err == nil && t.email == "") {
			return errLink("invalid")
		} else if err != nil {
			return err
		}
		email = t.email
		if err := invalidateLaterReverts(ctx, tx, t.accountID, t.createdAt, now); err != nil {
			return err
		}
		if err := setEmail(ctx, tx, t.accountID, email, now, true); err != nil {
			return err
		}
		if err := revokeSessions(ctx, tx, t.accountID, 0, "email_reverted", now); err != nil {
			return err
		}
		if err := invalidateLinks(ctx, tx, t.accountID, now); err != nil {
			return err
		}
		reset, err = issueToken(ctx, tx, t.accountID, purposeReset, email, now.Add(ResetTTL), now)
		if err != nil {
			return err
		}
		return s.event(ctx, tx, t.accountID, "email_reverted", ClientMeta{}, now)
	})
	if err != nil {
		return err
	}
	s.resetFailures(accountID)
	s.sendMail(ctx, mail.EmailReverted, email, mail.Data{Link: s.link("reset", reset)})
	return nil
}

// RequestDeletion requests the account's deletion (with the password; also with the privacy
// session): the purge arrives after 14 days and revokes the other sessions (deletion). If it was
// already requested, it returns the date it had.
func (s *Service) RequestDeletion(ctx context.Context, sess *Session, password string, meta ClientMeta) (time.Time, error) {
	if password == "" || len(password) > maxPasswordBytes {
		return time.Time{}, errValidation(map[string]string{"password": "required"})
	}
	ok, err := s.CheckPassword(ctx, sess.AccountID, sess.Email, password, meta.IP)
	if err := s.passwordError(ctx, sess, ok, err, meta); err != nil {
		return time.Time{}, err
	}
	now := s.clock.Now()
	var purgeAt time.Time
	err = db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		_, status, err := lockAccount(ctx, tx, sess.AccountID)
		if err != nil {
			return err
		}
		if status == "pending_deletion" {
			return tx.QueryRow(ctx, `select purge_after from accounts where account_id = $1`, sess.AccountID).Scan(&purgeAt)
		}
		purgeAt = now.Add(DeletionGrace)
		if _, err := tx.Exec(ctx, `update accounts set status = 'pending_deletion', deletion_requested_at = $2,
			purge_after = $3 where account_id = $1`, sess.AccountID, now, purgeAt); err != nil {
			return err
		}
		return revokeSessions(ctx, tx, sess.AccountID, sess.ID, "deletion", now)
	})
	return purgeAt, err
}

// CancelDeletion cancels the deletion within the period. Without a requested deletion it does
// nothing; with the period elapsed (the hourly purge has not yet run) it answers 409
// deletion_expired.
func (s *Service) CancelDeletion(ctx context.Context, sess *Session) error {
	now := s.clock.Now()
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		_, status, err := lockAccount(ctx, tx, sess.AccountID)
		if err != nil || status != "pending_deletion" {
			return err
		}
		tag, err := tx.Exec(ctx, `update accounts set status = 'active', deletion_requested_at = null, purge_after = null
			where account_id = $1 and purge_after > $2`, sess.AccountID, now)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return errDeletionExpired()
		}
		return nil
	})
}
