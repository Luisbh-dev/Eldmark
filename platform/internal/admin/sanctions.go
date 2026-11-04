package admin

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/sanctions"
)

// Caps of a CLI sanction (those of the internal API, §9.5).
const (
	maxReason      = 500
	maxSanctionDur = 10 * 365 * 24 * time.Hour
	maxReportIDs   = 20
)

// SanctionOrder is sanction add: the target by name (or "#id") in the world, the kind, the duration
// (mute and suspension), the reason and the reports.
type SanctionOrder struct {
	World     int16
	Target    string
	Kind      string
	Duration  time.Duration
	Reason    string
	ReportIDs []int64
}

// Sanction is sanction add (admin): the same checks as the zone with the --actor's account (§9.5,
// [sanctions.Create]): the minimum role of §9.1 for that kind and duration and a target of lower
// role (without the lease, which belongs to the zone). If it does not authorize it, [DeniedError]
// and the sanction_denied row is left; if it does, the sanction and the sanction row, both with
// source = 'cli' and args.os_user.
func (s *Service) Sanction(ctx context.Context, actor *Actor, o SanctionOrder) (*sanctions.Created, *Character, error) {
	o.Reason = strings.TrimSpace(o.Reason)
	switch {
	case sanctions.MinRole(o.Kind, 0) == "":
		return nil, nil, errors.New("tipo de sanción desconocido: warning, mute, suspension, ban o rename")
	case sanctions.Timed(o.Kind) && (o.Duration < time.Minute || o.Duration > maxSanctionDur || o.Duration%time.Minute != 0):
		return nil, nil, errors.New("un silencio o una suspensión necesitan --duration en minutos enteros (de 1 min a 10 años)")
	case !sanctions.Timed(o.Kind) && o.Duration != 0:
		return nil, nil, errors.New("solo el silencio y la suspensión llevan --duration (la expulsión es permanente)")
	case o.Reason == "" || utf8.RuneCountInString(o.Reason) > maxReason || strings.ContainsRune(o.Reason, 0):
		return nil, nil, errors.New("hace falta --reason, de 500 caracteres como mucho")
	case len(o.ReportIDs) > maxReportIDs:
		return nil, nil, errors.New("demasiados reportes (20 como mucho)")
	}
	reports := []int64{}
	for _, id := range o.ReportIDs {
		if !slices.Contains(reports, id) {
			reports = append(reports, id)
		}
	}
	var created *sanctions.Created
	var denied sanctions.Denial
	var target *Character
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		created, denied = nil, ""
		var err error
		if target, err = s.character(ctx, tx, o.World, o.Target); err != nil {
			return err
		}
		created, denied, err = sanctions.Create(ctx, tx, sanctions.Request{WorldID: target.WorldID,
			Source: sanctions.SourceCLI, AuthorAccountID: actor.AccountID, RequireRole: sanctions.RoleAdmin,
			TargetAccountID: target.AccountID, TargetCharacterID: target.ID, Kind: o.Kind, Duration: o.Duration,
			Reason: o.Reason, ReportIDs: reports, Args: map[string]any{"os_user": s.osUser}, Now: s.clock.Now()})
		if errors.Is(err, sanctions.ErrUnknownReports) {
			return ErrUnknownReports
		}
		return err
	})
	if err != nil {
		return nil, nil, err
	}
	if denied != "" {
		return nil, target, &DeniedError{Denial: denied}
	}
	s.log.Info("sanción creada con la CLI", "sanction", created.SanctionID, "kind", o.Kind, "actor", actor.AccountID)
	return created, target, nil
}

// States of a sanction in sanction list.
const (
	StateActive   = "vigente"
	StateExpired  = "caducada"
	StateRevoked  = "revocada"
	StateNoted    = "anotada"   // a warning: no mechanical effect, counts toward repeat offenses
	StatePending  = "pendiente" // a rename that has not been done yet
	StateComplied = "cumplida"  // a rename already done
)

// SanctionInfo is a sanction of the account.
type SanctionInfo struct {
	ID          int64
	Kind        string
	WorldID     *int16
	CharacterID *int64
	Reason      string
	AuthorID    *int64
	StartsAt    time.Time
	EndsAt      *time.Time
	RevokedAt   *time.Time
	RevokedBy   *int64
	Reports     []int64
	State       string
}

// state is the sanction's state at time now: revoked; a warning, noted; a mute or a suspension,
// current until ends_at and expired afterwards; a ban, current; a rename, pending while the
// character has must_rename and fulfilled afterwards.
func state(i *SanctionInfo, mustRename bool, now time.Time) string {
	switch {
	case i.RevokedAt != nil:
		return StateRevoked
	case i.Kind == sanctions.KindWarning:
		return StateNoted
	case i.Kind == sanctions.KindRename:
		if mustRename {
			return StatePending
		}
		return StateComplied
	case i.EndsAt != nil && !i.EndsAt.After(now):
		return StateExpired
	case i.StartsAt.After(now):
		return StatePending
	}
	return StateActive
}

// Sanctions is sanction list (read, moderator): the sanctions of the character's account, from
// newest to oldest, with their state. It leaves the sanction list row with the character and its
// account as target.
func (s *Service) Sanctions(ctx context.Context, actor *Actor, world int16, target string) (*Character, []SanctionInfo, error) {
	var who *Character
	var out []SanctionInfo
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		out = nil
		c, err := s.character(ctx, tx, world, target)
		if err != nil {
			return err
		}
		who = c
		now := s.clock.Now()
		rows, err := tx.Query(ctx, `select s.sanction_id, s.kind, s.world_id, s.character_id, s.reason,
				s.author_account_id, s.starts_at, s.ends_at, s.revoked_at, s.revoked_by,
				coalesce(c.must_rename, false),
				coalesce((select array_agg(report_id order by report_id) from sanction_reports r
					where r.sanction_id = s.sanction_id), '{}')
			from sanctions s left join characters c on c.character_id = s.character_id
			where s.account_id = $1 order by s.starts_at desc, s.sanction_id desc`, c.AccountID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (SanctionInfo, error) {
			var i SanctionInfo
			var mustRename bool
			err := row.Scan(&i.ID, &i.Kind, &i.WorldID, &i.CharacterID, &i.Reason, &i.AuthorID, &i.StartsAt, &i.EndsAt,
				&i.RevokedAt, &i.RevokedBy, &mustRename, &i.Reports)
			i.State = state(&i, mustRename, now)
			return i, err
		})
		if err != nil {
			return err
		}
		return s.audit(ctx, tx, actor, entry{world: c.WorldID, command: "sanction list", targetAccount: c.AccountID,
			targetCharacter: c.ID}, now)
	})
	if err != nil {
		return nil, nil, err
	}
	return who, out, nil
}

// RevokeSanction is sanction revoke (admin): it lifts a sanction (revoked_at, revoked_by). A revoked
// rename removes must_rename if the character has no other unrevoked one placed afterwards. It
// leaves the sanction revoke row with the sanction's target and args {sanction_id, kind, os_user}.
func (s *Service) RevokeSanction(ctx context.Context, actor *Actor, id int64) (*SanctionInfo, error) {
	var info *SanctionInfo
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		info = nil
		if err := lockActor(ctx, tx, actor, sanctions.RoleAdmin); err != nil {
			return err
		}
		i := &SanctionInfo{ID: id}
		var account int64
		err := tx.QueryRow(ctx, `select account_id, kind, world_id, character_id, revoked_at from sanctions
			where sanction_id = $1 for update`, id).Scan(&account, &i.Kind, &i.WorldID, &i.CharacterID, &i.RevokedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrSanctionNotFound
		}
		if err != nil {
			return err
		}
		if i.RevokedAt != nil {
			return ErrAlreadyRevoked
		}
		now := s.clock.Now()
		if _, err := tx.Exec(ctx, `update sanctions set revoked_at = $2, revoked_by = $3 where sanction_id = $1`,
			id, now, actor.AccountID); err != nil {
			return err
		}
		if i.Kind == sanctions.KindRename && i.CharacterID != nil {
			// Without the date of the last rename it is not known which earlier rename is fulfilled: the newest
			// rules. If there is another unrevoked one placed afterwards, it is still needed.
			if _, err := tx.Exec(ctx, `update characters set must_rename = false where character_id = $1
				and not exists (select 1 from sanctions where character_id = $1 and kind = 'rename'
					and revoked_at is null and sanction_id > $2)`, *i.CharacterID, id); err != nil {
				return err
			}
		}
		i.RevokedAt, i.RevokedBy, i.State = &now, &actor.AccountID, StateRevoked
		info = i
		var world int16
		if i.WorldID != nil {
			world = *i.WorldID
		}
		return s.audit(ctx, tx, actor, entry{world: world, command: "sanction revoke", targetAccount: account,
			targetCharacter: deref(i.CharacterID), args: map[string]any{"sanction_id": idString(id), "kind": i.Kind}}, now)
	})
	if err != nil {
		return nil, err
	}
	return info, nil
}
