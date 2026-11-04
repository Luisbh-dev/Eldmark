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

// bootstrapLock serializes two simultaneous bootstraps (pg_advisory_xact_lock).
const bootstrapLock = 4815162343

// RoleChange is the result of set-role.
type RoleChange struct {
	AccountID int64
	From, To  string
	Changed   bool  // false: it already had that role (nothing is touched or audited)
	Revoked   int64 // sessions revoked (role_changed)
}

// SetRole changes the role of the email's account (§9.1). In a transaction that locks the rows of
// the --actor and the target in id order (like the sanctions: the role they look at does not change
// midway), it checks again that the --actor is admin, changes the role, revokes all the target's
// sessions (role_changed: the heartbeat kicks out its character within HEARTBEAT_S at most, and it
// logs back in with the new role) and leaves the fixed row of §9.1, the one S2 reads
// ([sanctions.RoleAt]): source = 'cli', command = 'set-role', the --actor's actor_account_id,
// target_account_id, args {from, to, os_user} and at = now. On the account itself, [ErrSelf]: that
// way nobody is left without an admin by mistake.
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

// CreateAccount creates a test or team account (§12: dev.sh creates its own this way), already
// verified and with the current texts accepted, with the given role; it leaves the create-account
// row (args {role, os_user}).
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

// Bootstrap creates the first admin account, the one that will act as --actor for the others: only
// if there is no unpurged admin account (otherwise, [ErrHasAdmin]) and always a new account (an
// email with an account gives accounts.ErrEmailTaken: an existing account is given the role with
// set-role). It takes no --actor; its row (command bootstrap) goes without actor_account_id.
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

// publishLegal publishes any current texts missing from legal_documents (like serve at startup).
func (s *Service) publishLegal(ctx context.Context) error {
	_, err := s.legal.Sync(ctx, s.pool, s.strictLegal)
	return err
}

// PurgeResult is the result of purge-now.
type PurgeResult struct {
	AccountID int64
	Revoked   int64 // sessions revoked (deletion)
	Purged    bool  // false: it was already purged
}

// PurgeNow purges the email's account without waiting the 14 days (§11.2, express request): it
// revokes its sessions (deletion: the heartbeat kicks out its character with a final save) and
// leaves the purge-now row (args {os_user}, without the email); it waits up to wait (§11.2:
// [DefaultPurgeWait]) for its leases to be released and, if any is still alive, returns [ErrBusy]
// and purges nothing. Otherwise, the accounts purge (tombstone of the account and its characters,
// purge_log).
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

// waitLeases waits up to wait (real time) for the account to have no character with a live lease
// (at the service clock's time); otherwise, [ErrBusy].
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
