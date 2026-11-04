package admin

import (
	"context"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/sanctions"
)

// defaultBlockReason is the reason for a block without --reason.
const defaultBlockReason = "bloqueado por la moderación"

// NameBlock is the result of names block|unblock.
type NameBlock struct {
	Key     string      // the NameRules key being blocked
	Changed bool        // false: it was already blocked (block) or was not (unblock)
	Holders []Character // live characters with that name (block): they are renamed with sanction add ... rename
}

// BlockName is names block (admin, SOC-13): it puts the name's NameRules key in name_blacklist
// (create and rename answer 422 reserved, §4.4). It does not touch the characters that already have
// it: it returns them so that a rename can be applied to them. It leaves the names block row with
// the term in args (it already lives in name_blacklist, §9.1).
func (s *Service) BlockName(ctx context.Context, actor *Actor, name, reason string) (*NameBlock, error) {
	key, err := s.nameKey(name)
	if err != nil {
		return nil, err
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = defaultBlockReason
	}
	res := &NameBlock{Key: key}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		res.Changed, res.Holders = false, nil
		if err := lockActor(ctx, tx, actor, sanctions.RoleAdmin); err != nil {
			return err
		}
		now := s.clock.Now()
		tag, err := tx.Exec(ctx, `insert into name_blacklist (name_key, reason, added_by, added_at) values ($1, $2, $3, $4)
			on conflict (name_key) do nothing`, key, reason, actor.AccountID, now)
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `select character_id, account_id, world_id, name from characters
			where name_key = $1 and purged_at is null and deleted_at is null order by world_id, character_id`, key)
		if err != nil {
			return err
		}
		res.Holders, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Character, error) {
			var c Character
			err := row.Scan(&c.ID, &c.AccountID, &c.WorldID, &c.Name)
			return c, err
		})
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return nil
		}
		res.Changed = true
		return s.audit(ctx, tx, actor, entry{command: "names block", args: map[string]any{"term": key}}, now)
	})
	if err != nil {
		return nil, err
	}
	return res, nil
}

// UnblockName is names unblock (admin): it removes the name's key from name_blacklist. It leaves
// the names unblock row with the term in args.
func (s *Service) UnblockName(ctx context.Context, actor *Actor, name string) (*NameBlock, error) {
	key, err := s.nameKey(name)
	if err != nil {
		return nil, err
	}
	res := &NameBlock{Key: key}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		res.Changed = false
		if err := lockActor(ctx, tx, actor, sanctions.RoleAdmin); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `delete from name_blacklist where name_key = $1`, key)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		res.Changed = true
		return s.audit(ctx, tx, actor, entry{command: "names unblock", args: map[string]any{"term": key}}, s.clock.Now())
	})
	if err != nil {
		return nil, err
	}
	return res, nil
}

// nameKey is the NameRules key of a blacklist term: letters only (the key of a valid name has
// nothing else), 1 to 64 B.
func (s *Service) nameKey(name string) (string, error) {
	key := s.names.NormalizeKey(strings.TrimSpace(name))
	if key == "" || len(key) > 64 {
		return "", ErrInvalidName
	}
	for _, r := range key {
		if !unicode.IsLetter(r) {
			return "", ErrInvalidName
		}
	}
	return key, nil
}
