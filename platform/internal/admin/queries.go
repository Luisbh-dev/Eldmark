package admin

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// AuditQuery is the filters of audit (§9.1: admin --actor <email> audit --since 2026-11-01
// [--actor-name <name>] [--target <name>]).
type AuditQuery struct {
	Since, Until time.Time // Until zero: no cap
	World        int16     // the world in which names are resolved
	ActorName    string    // a character: the rows of its account as actor
	Target       string    // a character: the rows about it or about its account
	Command      string
	Limit        int
}

// AuditRow is an audit_log row, with the characters' current names to read it.
type AuditRow struct {
	ID                int64
	At                time.Time
	WorldID           *int16
	ZoneID            *string
	Source            string
	ActorAccountID    *int64
	ActorCharacterID  *int64
	ActorName         *string
	Command           string
	TargetAccountID   *int64
	TargetCharacterID *int64
	TargetName        *string
	Args              json.RawMessage
	EventKey          *string
}

// Audit is the audit query (read, moderator), from oldest to newest starting at Since. The query
// itself leaves its audit row (the --target filter's target in target_account_id and
// target_character_id; in args since, until, the --actor-name filter's actor_account_id, command
// and limit; never the names typed).
func (s *Service) Audit(ctx context.Context, actor *Actor, q AuditQuery) ([]AuditRow, error) {
	if q.Since.IsZero() {
		return nil, errors.New("audit necesita --since")
	}
	n := limit(q.Limit)
	var out []AuditRow
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		out = nil
		var actorFilter, targetAccount, targetCharacter int64
		if q.ActorName != "" {
			c, err := s.character(ctx, tx, q.World, q.ActorName)
			if err != nil {
				return err
			}
			actorFilter = c.AccountID
		}
		if q.Target != "" {
			c, err := s.character(ctx, tx, q.World, q.Target)
			if err != nil {
				return err
			}
			targetAccount, targetCharacter = c.AccountID, c.ID
		}
		var until *time.Time
		if !q.Until.IsZero() {
			until = &q.Until
		}
		rows, err := tx.Query(ctx, `select l.id, l.at, l.world_id, l.zone_id, l.source, l.actor_account_id,
				l.actor_character_id, ac.name, l.command, l.target_account_id, l.target_character_id, tc.name, l.args,
				l.event_key
			from audit_log l
			left join characters ac on ac.character_id = l.actor_character_id
			left join characters tc on tc.character_id = l.target_character_id
			where l.at >= $1 and ($2::timestamptz is null or l.at < $2)
			  and ($3::bigint = 0 or l.actor_account_id = $3)
			  and ($4::bigint = 0 or l.target_character_id = $5 or l.target_account_id = $4)
			  and ($6 = '' or l.command = $6)
			order by l.at, l.id limit $7`, q.Since, until, actorFilter, targetAccount, targetCharacter, q.Command, n)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (AuditRow, error) {
			var r AuditRow
			err := row.Scan(&r.ID, &r.At, &r.WorldID, &r.ZoneID, &r.Source, &r.ActorAccountID, &r.ActorCharacterID,
				&r.ActorName, &r.Command, &r.TargetAccountID, &r.TargetCharacterID, &r.TargetName, &r.Args, &r.EventKey)
			return r, err
		})
		if err != nil {
			return err
		}
		args := map[string]any{"since": q.Since.UTC().Format(time.RFC3339), "limit": n}
		if until != nil {
			args["until"] = until.UTC().Format(time.RFC3339)
		}
		if actorFilter != 0 {
			args["actor_account_id"] = idString(actorFilter)
		}
		if q.Command != "" {
			args["command"] = q.Command
		}
		return s.audit(ctx, tx, actor, entry{world: worldIf(q.ActorName != "" || q.Target != "", q.World),
			command: "audit", targetAccount: targetAccount, targetCharacter: targetCharacter, args: args}, s.clock.Now())
	})
	return out, err
}

func worldIf(cond bool, w int16) int16 {
	if cond {
		return w
	}
	return 0
}

// ChatQuery is the filters of chat (§9.2: admin --actor <email> chat --character <name> --from ...
// --to ...).
type ChatQuery struct {
	World     int16
	Character string
	From, To  time.Time // [From, To)
	Limit     int
}

// ChatLine is a message of the chat log.
type ChatLine struct {
	ID                int64
	SentAt            time.Time
	ZoneID            string
	ZoneChannel       int16
	Channel           int16
	SenderCharacterID int64
	SenderName        *string
	TargetCharacterID *int64
	TargetName        *string
	Text              string
}

// Chat is the chat log query (read, moderator, SOC-15): the messages the character sent and the
// whispers it received, between From (inclusive) and To (exclusive), with the zone and its copy
// (zone_channel), from oldest to newest. It leaves the chat row with the character in
// target_character_id and its account in target_account_id, and args {from, to, limit, os_user}:
// the name typed is not stored.
func (s *Service) Chat(ctx context.Context, actor *Actor, q ChatQuery) (*Character, []ChatLine, error) {
	if q.From.IsZero() || q.To.IsZero() || !q.To.After(q.From) {
		return nil, nil, errors.New("chat necesita --from y --to, con --to después de --from")
	}
	n := limit(q.Limit)
	var who *Character
	var out []ChatLine
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		out = nil
		c, err := s.character(ctx, tx, q.World, q.Character)
		if err != nil {
			return err
		}
		who = c
		rows, err := tx.Query(ctx, `select m.id, m.sent_at, m.zone_id, m.zone_channel, m.channel, m.sender_character_id,
				sc.name, m.target_character_id, tc.name, m.text
			from chat_messages m
			left join characters sc on sc.character_id = m.sender_character_id
			left join characters tc on tc.character_id = m.target_character_id
			where m.world_id = $1 and (m.sender_character_id = $2 or m.target_character_id = $2)
			  and m.sent_at >= $3 and m.sent_at < $4
			order by m.sent_at, m.id limit $5`, c.WorldID, c.ID, q.From, q.To, n)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (ChatLine, error) {
			var l ChatLine
			err := row.Scan(&l.ID, &l.SentAt, &l.ZoneID, &l.ZoneChannel, &l.Channel, &l.SenderCharacterID, &l.SenderName,
				&l.TargetCharacterID, &l.TargetName, &l.Text)
			return l, err
		})
		if err != nil {
			return err
		}
		return s.audit(ctx, tx, actor, entry{world: c.WorldID, command: "chat", targetAccount: c.AccountID,
			targetCharacter: c.ID, args: map[string]any{"from": q.From.UTC().Format(time.RFC3339),
				"to": q.To.UTC().Format(time.RFC3339), "limit": n}}, s.clock.Now())
	})
	if err != nil {
		return nil, nil, err
	}
	return who, out, nil
}
