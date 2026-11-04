package social

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/zones"
)

// audit_log sources that a zone can send (§9.1): the zone's console and everything else (/gm and
// DEBUG_COMMAND). The cli and platform rows are written only by the platform.
const (
	SourceZone    = "zone"
	SourceConsole = "console"
)

// commandPattern is the shape of a zone command: the CLI's ones contain hyphens or spaces
// ("set-role", "reports show"), so they never match.
var commandPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}$`)

// reservedCommands are the commands that only the platform writes (§6, "Batches"): a zone cannot
// send them in its batch.
var reservedCommands = map[string]bool{
	"sanction_denied": true, // the authorization of a sanction (§9.5)
	"sanction":        true, // a created sanction (§9.5)
	"zone_replace":    true, // a registration with replace (§5.3)
	"set_role":        true, // in case it is written without a hyphen
}

// chatMessage is a valid entry of the chat batch.
type chatMessage struct {
	key           string
	channel       int16
	sender        int64
	senderAccount int64
	target        *int64
	text          string
	sentAt        time.Time
}

// Chat inserts the messages of a chat batch (§9.2: {key, channel, sender_character_id,
// target_character_id, text, sent_at_unix}) with the instance's world_id, zone_id and
// zone_channel and sender_account_id from characters, and returns the rejected keys: an entry
// missing a field or with an invalid one, with a key that does not belong to the instance, or
// with a sender that is not a character of the instance's world.
func (s *Service) Chat(ctx context.Context, inst *zones.Instance, entries []json.RawMessage) ([]string, error) {
	keys := zones.NewKeyChecker(inst, s.pool)
	rejected := []string{}
	var valid []chatMessage
	senders := map[int64]bool{}
	for _, raw := range entries {
		m, ok, err := parseChat(ctx, keys, raw)
		if err != nil {
			return nil, err
		}
		if !ok {
			rejected = append(rejected, zones.EntryKey(raw))
			continue
		}
		valid = append(valid, m)
		senders[m.sender] = true
	}
	accounts := map[int64]int64{}
	if len(senders) > 0 {
		ids := make([]int64, 0, len(senders))
		for id := range senders {
			ids = append(ids, id)
		}
		rows, err := s.pool.Query(ctx, `select character_id, account_id from characters
			where character_id = any($1) and world_id = $2`, ids, inst.WorldID)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var c, a int64
			if err := rows.Scan(&c, &a); err != nil {
				rows.Close()
				return nil, err
			}
			accounts[c] = a
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	var rows [][]any
	var rowKeys []string
	for _, m := range valid {
		account, ok := accounts[m.sender]
		if !ok {
			rejected = append(rejected, m.key)
			continue
		}
		rows = append(rows, []any{inst.WorldID, inst.ZoneID, inst.Channel, m.channel, m.sender, account, m.target,
			m.text, m.sentAt, m.key})
		rowKeys = append(rowKeys, m.key)
	}
	failed, err := zones.InsertEach(ctx, s.pool, `insert into chat_messages (world_id, zone_id, zone_channel, channel,
		sender_character_id, sender_account_id, target_character_id, text, sent_at, message_key)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) on conflict (message_key) do nothing`, rows, rowKeys)
	if err != nil {
		return nil, err
	}
	rejected = append(rejected, failed...)
	if len(rejected) > 0 {
		// Only the keys: chat text never goes to the log (§2.3).
		s.log.Warn("mensajes de chat rechazados", "zone_instance", inst.IDString(), "keys", rejected)
	}
	return rejected, nil
}

func parseChat(ctx context.Context, keys *zones.KeyChecker, raw json.RawMessage) (chatMessage, bool, error) {
	e, ok := zones.ParseEntry(raw, "key", "channel", "sender_character_id", "target_character_id", "text", "sent_at_unix")
	if !ok {
		return chatMessage{}, false, nil
	}
	key, okKey := e.String("key")
	channel, okChannel := e.Int("channel")
	sender, okSender := e.ID("sender_character_id", false)
	target, okTarget := e.ID("target_character_id", true)
	text, okText := e.String("text")
	sent, okSent := e.Int("sent_at_unix")
	if !okKey || !okChannel || !okSender || !okTarget || !okText || !okSent || channel < 0 || channel > 255 ||
		*sender < 1 || (target != nil && *target < 1) || utf8.RuneCountInString(text) > maxChatText ||
		strings.ContainsRune(text, 0) || sent < 0 || sent > zones.MaxUnix {
		return chatMessage{}, false, nil
	}
	valid, err := keys.Valid(ctx, key, false)
	if err != nil || !valid {
		return chatMessage{}, false, err
	}
	return chatMessage{key: key, channel: int16(channel), sender: *sender, target: target, text: text,
		sentAt: time.Unix(sent, 0).UTC()}, true, nil
}

// Audit inserts the entries of an audit batch (§9.1: {key, actor_account_id, actor_character_id,
// command, target_character_id, target_account_id, args, at_unix, source}) into audit_log with
// the instance's world_id and zone_id, at = to_timestamp(at_unix) and on conflict (event_key) do
// nothing (the save writes the same row of an operation with the same key, op:<op_id>), and
// returns the rejected keys: an entry missing a field or with an invalid one; with a key that
// does not belong to the instance or an op:<op_id> outside its id blocks; with a source other
// than zone and console (the cli and platform rows are written only by the platform), console
// with an actor or zone without one; or with a CLI or platform command.
func (s *Service) Audit(ctx context.Context, inst *zones.Instance, entries []json.RawMessage) ([]string, error) {
	keys := zones.NewKeyChecker(inst, s.pool)
	rejected := []string{}
	var rows [][]any
	var rowKeys []string
	for _, raw := range entries {
		args, ok, err := parseAudit(ctx, keys, raw)
		if err != nil {
			return nil, err
		}
		if !ok {
			rejected = append(rejected, zones.EntryKey(raw))
			continue
		}
		rows = append(rows, append([]any{inst.WorldID, inst.ZoneID}, args...))
		rowKeys = append(rowKeys, args[len(args)-1].(string))
	}
	failed, err := zones.InsertEach(ctx, s.pool, `insert into audit_log (world_id, zone_id, source, actor_account_id,
		actor_character_id, command, target_account_id, target_character_id, args, at, event_key)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) on conflict (event_key) do nothing`, rows, rowKeys)
	if err != nil {
		return nil, err
	}
	rejected = append(rejected, failed...)
	if len(rejected) > 0 {
		s.log.Warn("entradas de auditoría rechazadas", "zone_instance", inst.IDString(), "keys", rejected)
	}
	return rejected, nil
}

// parseAudit reads an audit entry and returns the row's arguments (without world_id or zone_id),
// with the key at the end.
func parseAudit(ctx context.Context, keys *zones.KeyChecker, raw json.RawMessage) ([]any, bool, error) {
	e, ok := zones.ParseEntry(raw, "key", "actor_account_id", "actor_character_id", "command", "target_character_id",
		"target_account_id", "args", "at_unix", "source")
	if !ok {
		return nil, false, nil
	}
	key, okKey := e.String("key")
	actor, okActor := e.ID("actor_account_id", true)
	actorChar, okActorChar := e.ID("actor_character_id", true)
	command, okCommand := e.String("command")
	targetChar, okTargetChar := e.ID("target_character_id", true)
	targetAccount, okTargetAccount := e.ID("target_account_id", true)
	args, okArgs := e.Object("args")
	at, okAt := e.Int("at_unix")
	source, okSource := e.String("source")
	if !okKey || !okActor || !okActorChar || !okCommand || !okTargetChar || !okTargetAccount || !okArgs || !okAt ||
		!okSource || at < 0 || at > zones.MaxUnix || !commandPattern.MatchString(command) || reservedCommands[command] {
		return nil, false, nil
	}
	switch source {
	case SourceConsole:
		if actor != nil || actorChar != nil {
			return nil, false, nil
		}
	case SourceZone:
		if actor == nil {
			return nil, false, nil
		}
	default:
		return nil, false, nil
	}
	valid, err := keys.Valid(ctx, key, true)
	if err != nil || !valid {
		return nil, false, err
	}
	return []any{source, actor, actorChar, command, targetAccount, targetChar, args, time.Unix(at, 0).UTC(), key}, true, nil
}

func (s *Service) chatBatch(w http.ResponseWriter, r *http.Request) {
	s.batch(w, r, "messages", s.Chat)
}

func (s *Service) auditBatch(w http.ResponseWriter, r *http.Request) {
	s.batch(w, r, "entries", s.Audit)
}

// batch handles a batch: in any instance state (§6.1), 204 or 200 {rejected}.
func (s *Service) batch(w http.ResponseWriter, r *http.Request, field string,
	insert func(context.Context, *zones.Instance, []json.RawMessage) ([]string, error)) {
	batch, e := zones.DecodeBatch(w, r, field)
	if e != nil {
		httpx.WriteError(w, e)
		return
	}
	ctx := r.Context()
	inst, err := s.guard.Instance(ctx, zones.ScopeFrom(ctx), batch.InstanceID, zones.OpAny)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	rejected, err := insert(ctx, inst, batch.Entries)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	zones.BatchResponse(w, rejected)
}

// ChatRetention is how long chat is kept (§11.1: 30 days, all channels); what was copied into a
// report remains in report_evidence.
const ChatRetention = 30 * 24 * time.Hour

// chatPurgeBatch is the size of each delete in the chat retention (§11.1: batches of 10 000).
const chatPurgeBatch = 10000

// PurgeChat is the chat retention (§11.1), the hourly chat_retention job: it deletes messages
// with sent_at older than [ChatRetention], in batches of 10 000 (each one its own statement)
// until none remain. It returns how many it deleted.
func (s *Service) PurgeChat(ctx context.Context) (int64, error) {
	cutoff := s.clock.Now().Add(-ChatRetention)
	var total int64
	for {
		tag, err := s.pool.Exec(ctx, `delete from chat_messages where id in (
			select id from chat_messages where sent_at < $1 order by sent_at limit $2)`, cutoff, chatPurgeBatch)
		if err != nil {
			return total, err
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < chatPurgeBatch {
			return total, nil
		}
		if err := ctx.Err(); err != nil {
			return total, err
		}
	}
}

// ChatRetentionJob is [Service.PurgeChat] as a periodic app job (it logs what was deleted).
func (s *Service) ChatRetentionJob(ctx context.Context) error {
	n, err := s.PurgeChat(ctx)
	if n > 0 {
		s.log.Info("chat caducado borrado", "messages", n)
	}
	return err
}
