package accounts

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/passwords"
	"eldmark/platform/legal"
)

// RegisterRequest es el cuerpo de POST /v1/accounts.
type RegisterRequest struct {
	Email        *string       `json:"email"`
	Password     *string       `json:"password"`
	AgeConfirmed *bool         `json:"age_confirmed"`
	Accept       LegalVersions `json:"accept"`
	Consents     Consents      `json:"consents"`
}

// Register crea una cuenta sin delatar cuáles existen (§4.2): con el cuerpo válido, la respuesta
// es siempre la misma (202 {}). Un correo nuevo crea la cuenta y recibe verify_email; uno que ya
// tiene cuenta no crea nada y recibe register_existing; uno de sanctioned_email_hashes no crea nada
// y recibe register_blocked. Los tres caminos gastan del mismo límite de correos y calculan el hash
// de la contraseña, así que tardan lo mismo.
func (s *Service) Register(ctx context.Context, req RegisterRequest, meta ClientMeta) error {
	fields := map[string]string{}
	email := ""
	if req.Email == nil {
		fields["email"] = "required"
	} else if email = NormalizeEmail(*req.Email); !ValidEmail(email) {
		fields["email"] = "invalid"
	}
	if req.Password == nil {
		fields["password"] = "required"
	} else if problem := PasswordProblem(*req.Password, email); problem != "" {
		fields["password"] = problem
	}
	if req.AgeConfirmed == nil || !*req.AgeConfirmed {
		fields["age_confirmed"] = "required"
	}
	s.checkVersions(req.Accept, "accept.", fields)
	req.Consents.check("consents.", fields)
	if len(fields) > 0 {
		return errValidation(fields)
	}
	now := s.clock.Now()
	if ok, wait := s.limits.register.Allow(groupOf(meta), now); !ok {
		return errRateLimited(wait)
	}
	if err := s.allowMail(email, meta.IP, now); err != nil {
		return err
	}
	phc, err := passwords.HashContext(ctx, *req.Password, s.params)
	if err != nil {
		return err
	}
	tpl, data, err := s.register(ctx, email, phc, req.Consents, meta, now)
	if db.SQLState(err) == "23505" && db.Constraint(err) == "accounts_email_key" {
		// Dos registros a la vez con el mismo correo: el segundo es el de un correo con cuenta.
		tpl, data, err = s.register(ctx, email, phc, req.Consents, meta, now)
	}
	if err != nil {
		return err
	}
	s.sendMail(ctx, tpl, email, data)
	return nil
}

func (s *Service) register(ctx context.Context, email, phc string, consents Consents, meta ClientMeta,
	now time.Time) (mail.Template, mail.Data, error) {
	var tpl mail.Template
	var data mail.Data
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		var existing int64
		err := tx.QueryRow(ctx, `select account_id from accounts where email = $1`, email).Scan(&existing)
		if err == nil {
			tpl, data = mail.RegisterExisting, mail.Data{}
			return s.event(ctx, tx, existing, "register_existing", meta, now)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var until time.Time
		err = tx.QueryRow(ctx, `select until from sanctioned_email_hashes where hmac = $1 and until > $2`,
			s.sanctionedHMAC(email), now).Scan(&until)
		if err == nil {
			tpl, data = mail.RegisterBlocked, mail.Data{Until: until}
			return s.event(ctx, tx, 0, "register_blocked", meta, now)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var accountID int64
		if err := tx.QueryRow(ctx, `insert into accounts (email, password_hash, age_confirmed_at, created_at)
			values ($1, $2, $3, $3) returning account_id`, email, phc, now).Scan(&accountID); err != nil {
			return err
		}
		for _, kind := range legal.Kinds {
			if _, err := tx.Exec(ctx, `insert into legal_acceptances (account_id, kind, version, accepted_at)
				values ($1, $2, $3, $4)`, accountID, kind, s.legal.Current(kind).Version, now); err != nil {
				return err
			}
		}
		if err := saveConsents(ctx, tx, accountID, consents, now); err != nil {
			return err
		}
		token, err := issueToken(ctx, tx, accountID, "verify_email", email, now.Add(VerifyTTL), now)
		if err != nil {
			return err
		}
		tpl, data = mail.VerifyEmail, mail.Data{Link: s.link("verify", token)}
		return s.event(ctx, tx, accountID, "register", meta, now)
	})
	return tpl, data, err
}
