package admin

import (
	"context"
	"errors"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/sanctions"
)

// bootstrapLock pone en serie dos bootstrap a la vez (pg_advisory_xact_lock).
const bootstrapLock = 4815162343

// RoleChange es el resultado de set-role.
type RoleChange struct {
	AccountID int64
	From, To  string
	Changed   bool  // false: ya tenía ese rol (no se toca nada ni se audita)
	Revoked   int64 // sesiones revocadas (role_changed)
}

// SetRole cambia el rol de la cuenta del correo (§9.1). En una transacción que bloquea las filas
// del --actor y del objetivo en orden de id (como las sanciones: el rol que miran no cambia a
// mitad), vuelve a mirar que el --actor sea admin, cambia el rol, revoca todas las sesiones del
// objetivo (role_changed: el latido expulsa a su personaje en HEARTBEAT_S como mucho, y vuelve a
// entrar con el rol nuevo) y deja la fila fija de §9.1, la que lee S2 ([sanctions.RoleAt]):
// source = 'cli', command = 'set-role', actor_account_id del --actor, target_account_id, args
// {from, to, os_user} y at = ahora. Sobre la propia cuenta, [ErrSelf]: así no se queda nadie sin
// admin por error.
func (s *Service) SetRole(ctx context.Context, actor *Actor, email, role string) (*RoleChange, error) {
	if sanctions.Rank(role) < 0 {
		return nil, accounts.ErrRoleInvalid
	}
	target, _, _, err := s.accounts.LookupAccount(ctx, email)
	if err != nil {
		return nil, err
	}
	if target == 0 {
		return nil, ErrAccountNotFound
	}
	if target == actor.AccountID {
		return nil, ErrSelf
	}
	var res *RoleChange
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		res = &RoleChange{AccountID: target, To: role}
		ids := []int64{actor.AccountID, target}
		slices.Sort(ids)
		rows, err := tx.Query(ctx, `select account_id, role, status from accounts where account_id = any($1)
			order by account_id for no key update`, ids)
		if err != nil {
			return err
		}
		roles, statuses := map[int64]string{}, map[int64]string{}
		for rows.Next() {
			var id int64
			var r, st string
			if err := rows.Scan(&id, &r, &st); err != nil {
				rows.Close()
				return err
			}
			roles[id], statuses[id] = r, st
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		if statuses[actor.AccountID] != "active" || roles[actor.AccountID] != sanctions.RoleAdmin {
			return &ActorError{Reason: "la cuenta de --actor ha dejado de poder usar esta orden"}
		}
		if st, ok := statuses[target]; !ok || st == "purged" {
			return ErrAccountNotFound
		}
		res.From = roles[target]
		if res.From == role {
			return nil
		}
		now := s.clock.Now()
		if _, err := tx.Exec(ctx, `update accounts set role = $2 where account_id = $1`, target, role); err != nil {
			return err
		}
		if res.Revoked, err = accounts.RevokeSessions(ctx, tx, target, "role_changed", now); err != nil {
			return err
		}
		res.Changed = true
		return s.audit(ctx, tx, actor, entry{command: sanctions.CommandSetRole, targetAccount: target,
			args: map[string]any{"from": res.From, "to": role}}, now)
	})
	if err != nil {
		return nil, err
	}
	if res.Changed {
		s.log.Info("rol cambiado", "account", target, "from", res.From, "to", role, "actor", actor.AccountID)
	}
	return res, nil
}

// CreateAccount crea una cuenta de prueba o del equipo (§12: dev.sh crea así las suyas), ya
// verificada y con los textos vigentes aceptados, con el rol dado; deja la fila create-account
// (args {role, os_user}).
func (s *Service) CreateAccount(ctx context.Context, actor *Actor, email, password, role string) (int64, error) {
	if err := s.publishLegal(ctx); err != nil {
		return 0, err
	}
	var id int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockActor(ctx, tx, actor, sanctions.RoleAdmin); err != nil {
			return err
		}
		var err error
		id, err = s.accounts.CreateAccount(ctx, tx, accounts.NewAccount{Email: email, Password: password, Role: role})
		if err != nil {
			return err
		}
		return s.audit(ctx, tx, actor, entry{command: "create-account", targetAccount: id,
			args: map[string]any{"role": role}}, s.clock.Now())
	})
	return id, err
}

// Bootstrap crea la primera cuenta admin, la que hará de --actor de las demás: solo si no hay
// ninguna cuenta admin sin purgar (si no, [ErrHasAdmin]) y siempre una cuenta nueva (un correo con
// cuenta da accounts.ErrEmailTaken: a una cuenta existente se le da el rol con set-role). No lleva
// --actor; su fila (command bootstrap) va sin actor_account_id.
func (s *Service) Bootstrap(ctx context.Context, email, password string) (int64, error) {
	if err := s.publishLegal(ctx); err != nil {
		return 0, err
	}
	var id int64
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `select pg_advisory_xact_lock($1)`, int64(bootstrapLock)); err != nil {
			return err
		}
		var admins int
		if err := tx.QueryRow(ctx, `select count(*) from accounts where role = 'admin' and status <> 'purged'`).
			Scan(&admins); err != nil {
			return err
		}
		if admins > 0 {
			return ErrHasAdmin
		}
		var err error
		id, err = s.accounts.CreateAccount(ctx, tx, accounts.NewAccount{Email: email, Password: password,
			Role: sanctions.RoleAdmin})
		if err != nil {
			return err
		}
		return s.audit(ctx, tx, nil, entry{command: "bootstrap", targetAccount: id}, s.clock.Now())
	})
	return id, err
}

// publishLegal publica los textos vigentes que falten en legal_documents (como serve al arrancar).
func (s *Service) publishLegal(ctx context.Context) error {
	_, err := s.legal.Sync(ctx, s.pool, s.strictLegal)
	return err
}

// PurgeResult es el resultado de purge-now.
type PurgeResult struct {
	AccountID int64
	Revoked   int64 // sesiones revocadas (deletion)
	Purged    bool  // false: ya estaba purgada
}

// PurgeNow purga la cuenta del correo sin esperar los 14 días (§11.2, petición expresa): revoca sus
// sesiones (deletion: el latido expulsa a su personaje con guardado final) y deja la fila
// purge-now (args {os_user}, sin el correo); espera hasta wait (§11.2: [DefaultPurgeWait]) a que
// se liberen sus arrendamientos y, si alguno sigue vivo, devuelve [ErrBusy] y no purga nada. Si
// no, la purga de accounts (lápida de la cuenta y de sus personajes, purge_log).
func (s *Service) PurgeNow(ctx context.Context, actor *Actor, email string, wait time.Duration) (*PurgeResult, error) {
	target, _, _, err := s.accounts.LookupAccount(ctx, email)
	if err != nil {
		return nil, err
	}
	if target == 0 {
		return nil, ErrAccountNotFound
	}
	if target == actor.AccountID {
		return nil, ErrSelf
	}
	res := &PurgeResult{AccountID: target}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockActor(ctx, tx, actor, sanctions.RoleAdmin); err != nil {
			return err
		}
		now := s.clock.Now()
		var err error
		if res.Revoked, err = accounts.RevokeSessions(ctx, tx, target, "deletion", now); err != nil {
			return err
		}
		return s.audit(ctx, tx, actor, entry{command: "purge-now", targetAccount: target}, now)
	})
	if err != nil {
		return nil, err
	}
	if err := s.waitLeases(ctx, target, wait); err != nil {
		return res, err
	}
	res.Purged, err = s.accounts.PurgeNow(ctx, target)
	if errors.Is(err, accounts.ErrCharactersBusy) {
		return res, ErrBusy
	}
	if err != nil {
		return res, err
	}
	s.log.Info("cuenta purgada con purge-now", "account", target, "actor", actor.AccountID)
	return res, nil
}

// waitLeases espera hasta wait (tiempo real) a que la cuenta no tenga ningún personaje con un
// arrendamiento vivo (a la hora del reloj del servicio); si no, [ErrBusy].
func (s *Service) waitLeases(ctx context.Context, accountID int64, wait time.Duration) error {
	deadline := time.Now().Add(wait)
	for {
		var alive int
		err := s.pool.QueryRow(ctx, `select count(*) from character_leases l join characters c using (character_id)
			where c.account_id = $1 and l.zone_instance_id is not null and l.expires_at > $2`,
			accountID, s.clock.Now()).Scan(&alive)
		if err != nil {
			return err
		}
		if alive == 0 {
			return nil
		}
		if !time.Now().Before(deadline) {
			return ErrBusy
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(s.purgePoll):
		}
	}
}
