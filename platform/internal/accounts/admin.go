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

// Lo que usa la orden admin (P7a, §9.1 y §11.2): revocar las sesiones de una cuenta, purgarla sin
// esperar y crear cuentas de prueba o del equipo.

// Errores de [Service.CreateAccount].
var (
	ErrEmailInvalid    = errors.New("accounts: el correo no vale")
	ErrEmailTaken      = errors.New("accounts: ya hay una cuenta con ese correo")
	ErrPasswordInvalid = errors.New("accounts: la contraseña no vale (de 10 a 128 caracteres y distinta del correo)")
	ErrRoleInvalid     = errors.New("accounts: rol desconocido")
)

// RevokeSessions revoca todas las sesiones vivas de la cuenta con ese motivo
// (sessions.revoke_reason: role_changed en set-role, deletion en purge-now, admin…), dentro de la
// transacción de quien llama, y devuelve cuántas revocó. El latido expulsa a su personaje (§6:
// session_revoked).
func RevokeSessions(ctx context.Context, tx pgx.Tx, accountID int64, reason string, now time.Time) (int64, error) {
	tag, err := tx.Exec(ctx, `update sessions set revoked_at = $2, revoke_reason = $3
		where account_id = $1 and revoked_at is null`, accountID, now, reason)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// PurgeNow purga la cuenta ya, sin esperar los 14 días (admin purge-now, §11.2: petición expresa),
// como la purga horaria: lápida de la cuenta y de sus personajes, purge_log y la huella del correo
// si tiene sanciones. Devuelve false si la cuenta no existe o ya estaba purgada, y un error que
// envuelve [ErrCharactersBusy] si algún personaje sigue en el mundo (entonces no purga nada).
func (s *Service) PurgeNow(ctx context.Context, accountID int64) (bool, error) {
	return s.purgeAccount(ctx, accountID, purgeRequested, s.clock.Now())
}

// NewAccount es una cuenta que crea la orden admin (cuentas de prueba o del equipo).
type NewAccount struct {
	Email    string
	Password string
	Role     string
}

// CreateAccount crea, en la transacción tx, una cuenta ya verificada, con la edad confirmada y los
// textos legales vigentes aceptados (las crea el equipo: admin create-account y bootstrap, para
// pruebas y para el personal), sin consentimientos y con el rol dado. El correo se normaliza.
// Devuelve el account_id, o [ErrEmailInvalid], [ErrEmailTaken], [ErrPasswordInvalid] o
// [ErrRoleInvalid].
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

// LookupAccount devuelve el id, el rol y el estado de la cuenta con ese correo (ya normalizado o
// no), o 0 si no hay ninguna (una purgada no tiene correo).
func (s *Service) LookupAccount(ctx context.Context, email string) (id int64, role, status string, err error) {
	err = s.pool.QueryRow(ctx, `select account_id, role, status from accounts where email = $1`,
		NormalizeEmail(email)).Scan(&id, &role, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, "", "", nil
	}
	return id, role, status, err
}
