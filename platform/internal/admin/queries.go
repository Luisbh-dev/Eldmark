package admin

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// AuditQuery son los filtros de audit (§9.1: admin --actor <correo> audit --since 2026-11-01
// [--actor-name <nombre>] [--target <nombre>]).
type AuditQuery struct {
	Since, Until time.Time // Until cero: sin tope
	World        int16     // el mundo en el que se resuelven los nombres
	ActorName    string    // un personaje: las filas de su cuenta como actor
	Target       string    // un personaje: las filas sobre él o sobre su cuenta
	Command      string
	Limit        int
}

// AuditRow es una fila de audit_log, con los nombres de ahora de los personajes para leerla.
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

// Audit es la consulta de la auditoría (lectura, moderator), de la más vieja a la más nueva desde
// Since. La propia consulta deja su fila audit (el objetivo del filtro --target en
// target_account_id y target_character_id; en args since, until, actor_account_id del filtro
// --actor-name, command y limit; nunca los nombres escritos).
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

// ChatQuery son los filtros de chat (§9.2: admin --actor <correo> chat --character <nombre> --from
// … --to …).
type ChatQuery struct {
	World     int16
	Character string
	From, To  time.Time // [From, To)
	Limit     int
}

// ChatLine es un mensaje del registro del chat.
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

// Chat es la consulta del registro del chat (lectura, moderator, SOC-15): los mensajes que mandó el
// personaje y los susurros que recibió, entre From (incluida) y To (excluida), con la zona y su
// copia (zone_channel), del más viejo al más nuevo. Deja la fila chat con el personaje en
// target_character_id y su cuenta en target_account_id, y args {from, to, limit, os_user}: el
// nombre escrito no se guarda.
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
