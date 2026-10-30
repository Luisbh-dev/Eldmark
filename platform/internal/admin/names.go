package admin

import (
	"context"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/sanctions"
)

// defaultBlockReason es el motivo de un bloqueo sin --reason.
const defaultBlockReason = "bloqueado por la moderación"

// NameBlock es el resultado de names block|unblock.
type NameBlock struct {
	Key     string      // la clave de NameRules que se bloquea
	Changed bool        // false: ya estaba bloqueada (block) o no lo estaba (unblock)
	Holders []Character // personajes vivos con ese nombre (block): se renombran con sanction add … rename
}

// BlockName es names block (admin, SOC-13): pone la clave de NameRules del nombre en
// name_blacklist (crear y renombrar responden 422 reserved, §4.4). No toca a los personajes que ya
// lo llevan: los devuelve para que se les ponga un renombrado. Deja la fila names block con el
// término en args (ya vive en name_blacklist, §9.1).
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

// UnblockName es names unblock (admin): quita la clave del nombre de name_blacklist. Deja la fila
// names unblock con el término en args.
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

// nameKey es la clave de NameRules de un término de la lista negra: solo letras (la clave de un
// nombre válido no tiene otra cosa), de 1 a 64 B.
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
