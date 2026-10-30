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

// Propósitos de account_tokens.
const (
	purposeVerify = "verify_email"
	purposeReset  = "reset_password"
	purposeChange = "change_email"
	purposeRevert = "revert_email"
)

// issueToken guarda un enlace de un solo uso y devuelve su token.
func issueToken(ctx context.Context, q execer, accountID int64, purpose, email string, expires, now time.Time) (string, error) {
	token, hash := newToken()
	_, err := q.Exec(ctx, `insert into account_tokens (token_hash, account_id, purpose, email, expires_at, created_at)
		values ($1, $2, $3, $4, $5, $6)`, hash, accountID, purpose, nullString(email), expires, now)
	return token, err
}

// linkToken es un enlace consumido.
type linkToken struct {
	accountID int64
	purpose   string
	email     string    // change_email: el nuevo; revert_email: el viejo; verify y reset: al que se mandó
	createdAt time.Time // revert_email: su orden entre los de la cuenta (§4.3)
}

// consumeToken marca como usado un enlace de alguno de los propósitos dados. Usado o caducado:
// 400 validation con fields.token = "used" o "expired" (y, como la transacción se deshace, nada
// cambia); desconocido o de otro propósito, "invalid".
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

// invalidateLinks invalida los enlaces pendientes de la cuenta, en la misma transacción que el
// cambio (§4.3). Los revert_email no: quien robó la cuenta no puede quitarle al dueño la vuelta atrás
// cambiando el correo otra vez. Solo los anula gastar otro más antiguo ([invalidateLaterReverts]).
func invalidateLinks(ctx context.Context, tx pgx.Tx, accountID int64, now time.Time) error {
	_, err := tx.Exec(ctx, `update account_tokens set used_at = $2
		where account_id = $1 and used_at is null and purpose <> 'revert_email'`, accountID, now)
	return err
}

// invalidateLaterReverts anula los revert_email de la cuenta emitidos después de uno que se acaba
// de gastar (§4.3): los de los correos que vinieron detrás. En una cadena de cambios A→B→C, el
// enlace del dueño (el que llegó a A) es siempre el más antiguo, así que gastarlo deja muerto el que
// llegó a B; el de B, gastado antes, no toca el de A. El orden es created_at, que en una cuenta no
// se repite ([revertCreatedAt]).
func invalidateLaterReverts(ctx context.Context, tx pgx.Tx, accountID int64, after, now time.Time) error {
	_, err := tx.Exec(ctx, `update account_tokens set used_at = $3
		where account_id = $1 and purpose = 'revert_email' and used_at is null and created_at > $2`, accountID, after, now)
	return err
}

// revertCreatedAt es el created_at de un revert_email nuevo de la cuenta: now (en µs, la precisión
// de la base) o, si la cuenta ya tiene uno igual o posterior (el mismo instante, un reloj que
// retrocede), 1 µs después del último. Así el orden de §4.3 nunca tiene empates.
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

// emailReserved dice si el correo está reservado por un revert_email vivo (sin usar y sin caducar)
// de una cuenta distinta de except (§4.3): mientras el dueño pueda volver a su correo viejo, nadie
// más lo toma. Un registro o un cambio de correo hacia él se tratan como hacia un correo con cuenta.
func emailReserved(ctx context.Context, q querier, email string, except int64, now time.Time) (bool, error) {
	var reserved bool
	err := q.QueryRow(ctx, `select exists (select 1 from account_tokens where purpose = 'revert_email'
		and used_at is null and expires_at > $3 and email = $1 and account_id <> $2)`, email, except, now).Scan(&reserved)
	return reserved, err
}

// lockAccount bloquea la fila de la cuenta (for no key update, el orden de §5.3) y devuelve su
// correo y su estado. Una cuenta purgada no existe.
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

// LinkResult dice qué hizo un enlace de /verify: verificar el correo o confirmar el cambio.
type LinkResult string

// Resultados de [Service.ConfirmLink].
const (
	LinkVerified LinkResult = "verified"
	LinkChanged  LinkResult = "changed"
)

// ConfirmLink atiende el enlace de la página /verify, que vale para verify_email y para
// change_email (los dos confirman un correo).
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

// VerifyEmail verifica el correo con un enlace verify_email.
func (s *Service) VerifyEmail(ctx context.Context, token string) error {
	now := s.clock.Now()
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		t, err := consumeToken(ctx, tx, token, now, purposeVerify)
		if err != nil {
			return err
		}
		email, _, err := lockAccount(ctx, tx, t.accountID)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && t.email != "" && t.email != email) {
			// La cuenta ya no existe o cambió de correo después del enlace.
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

// ResendVerification manda otro enlace verify_email; los anteriores dejan de valer. Con el correo
// ya verificado no hace nada (la respuesta es la misma).
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

// resetTimeout acota lo que sigue en segundo plano de una petición de recuperación.
const resetTimeout = 30 * time.Second

// RequestPasswordReset manda un enlace de recuperación si el correo tiene cuenta. La respuesta es
// siempre la misma (202), exista o no, y no espera a la base: tras validar el correo y gastar la
// ficha del límite, buscar la cuenta, guardar el enlace y mandarlo siguen en segundo plano
// ([Service.Wait]). Antes, con cuenta se confirmaba una escritura (y su fsync) y sin ella solo se
// leía: el tiempo de la respuesta delataba qué correos tienen cuenta (§4.2). Un fallo de la base ya
// no da 503: se registra.
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

// passwordReset es la parte en segundo plano de [Service.RequestPasswordReset]: los dos caminos
// escriben su fila password_reset en auth_events (sin cuenta, con account_id nulo, como
// register_blocked); con cuenta, además el enlace y el correo.
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

// Wait espera a que termine lo que sigue en segundo plano (las recuperaciones de contraseña): serve
// lo llama al parar, antes de cerrar la cola de correo, y las pruebas antes de mirar la base.
func (s *Service) Wait() { s.background.Wait() }

// ConfirmPasswordReset cambia la contraseña con un enlace reset_password: revoca todas las
// sesiones (password_changed) e invalida los enlaces.
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

// ChangePassword cambia la contraseña con la actual (CheckPassword): revoca las demás sesiones
// (password_changed) e invalida los enlaces.
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

// RequestEmailChange pide cambiar el correo (con la contraseña). La respuesta es siempre 202: al
// correo nuevo va change_email o, si ya tiene cuenta, register_existing.
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
	// El límite de correos cuenta el destinatario, la IP y también la cuenta que lo pide: con
	// una sesión no se puede escribir a muchos correos distintos.
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
			// Un correo reservado por el revert_email de otra cuenta cuenta como con cuenta (§4.3).
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

// ConfirmEmailChange cambia el correo con un enlace change_email y lo da por verificado: revoca
// las sesiones (email_changed), invalida los enlaces y manda al correo viejo un aviso con un
// enlace revert_email de 7 días.
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

// setEmail cambia el correo de la cuenta y lo da por verificado; clearPassword deja la cuenta sin
// contraseña (revert_email). Si otra cuenta tiene ya ese correo, o lo reserva con un revert_email
// vivo (§4.3), el enlace no vale (fields.token = "unavailable").
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

// RevertEmail vuelve al correo viejo con un enlace revert_email: anula los revert_email de la cuenta
// emitidos después ([invalidateLaterReverts]), revoca todas las sesiones (email_reverted), deja la
// cuenta sin contraseña (password_hash = null), invalida los enlaces y manda al correo recuperado un
// enlace para elegir contraseña.
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

// RequestDeletion pide el borrado de la cuenta (con la contraseña; también con la sesión de
// privacidad): la purga llega a los 14 días y revoca las demás sesiones (deletion). Si ya estaba
// pedido, devuelve la fecha que tenía.
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

// CancelDeletion cancela el borrado en plazo. Sin borrado pedido no hace nada; con el plazo
// vencido (la purga horaria aún no ha pasado) responde 409 deletion_expired.
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
