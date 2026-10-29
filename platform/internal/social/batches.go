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

// Fuentes de audit_log que puede mandar una zona (§9.1): la consola de la zona y lo demás (/gm y
// DEBUG_COMMAND). Las filas cli y platform solo las escribe la plataforma.
const (
	SourceZone    = "zone"
	SourceConsole = "console"
)

// commandPattern es la forma de un command de la zona: los de la CLI llevan guiones o espacios
// («set-role», «reports show»), así que nunca casan.
var commandPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}$`)

// reservedCommands son los command que solo escribe la plataforma (§6, «Lotes»): una zona no los
// puede mandar en su lote.
var reservedCommands = map[string]bool{
	"sanction_denied": true, // la autorización de una sanción (§9.5)
	"sanction":        true, // una sanción creada (§9.5)
	"zone_replace":    true, // un registro con replace (§5.3)
	"set_role":        true, // por si se escribe sin guion
}

// chatMessage es una entrada válida del lote de chat.
type chatMessage struct {
	key           string
	channel       int16
	sender        int64
	senderAccount int64
	target        *int64
	text          string
	sentAt        time.Time
}

// Chat inserta los mensajes de un lote de chat (§9.2: {key, channel, sender_character_id,
// target_character_id, text, sent_at_unix}) con world_id, zone_id y zone_channel de la instancia y
// sender_account_id de characters, y devuelve las claves rechazadas: una entrada sin algún campo o
// con uno que no vale, con una key que no es de la instancia, o con un emisor que no es un personaje
// del mundo de la instancia.
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
		// Solo las claves: el texto del chat nunca va al registro (§2.3).
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
		strings.ContainsRune(text, 0) || sent < 0 {
		return chatMessage{}, false, nil
	}
	valid, err := keys.Valid(ctx, key, false)
	if err != nil || !valid {
		return chatMessage{}, false, err
	}
	return chatMessage{key: key, channel: int16(channel), sender: *sender, target: target, text: text,
		sentAt: time.Unix(sent, 0).UTC()}, true, nil
}

// Audit inserta las entradas de un lote de auditoría (§9.1: {key, actor_account_id,
// actor_character_id, command, target_character_id, target_account_id, args, at_unix, source}) en
// audit_log con world_id y zone_id de la instancia, at = to_timestamp(at_unix) y on conflict
// (event_key) do nothing (el guardado escribe la misma fila de una operación con la misma key,
// op:<op_id>), y devuelve las claves rechazadas: una entrada sin algún campo o con uno que no vale;
// con una key que no es de la instancia o un op:<op_id> fuera de sus bloques de ids; con source
// distinto de zone y console (las filas cli y platform solo las escribe la plataforma), console con
// actor o zone sin él; o con un command de la CLI o de la plataforma.
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

// parseAudit lee una entrada de auditoría y devuelve los argumentos de la fila (sin world_id ni
// zone_id), con la key al final.
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
		!okSource || at < 0 || !commandPattern.MatchString(command) || reservedCommands[command] {
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

// batch atiende un lote: en cualquier estado de la instancia (§6.1), 204 o 200 {rejected}.
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

// ChatRetention es lo que se conserva el chat (§11.1: 30 días, todos los canales); lo copiado a un
// reporte sigue en report_evidence.
const ChatRetention = 30 * 24 * time.Hour

// chatPurgeBatch es el tamaño de cada borrado de la retención del chat (§11.1: lotes de 10 000).
const chatPurgeBatch = 10000

// PurgeChat es la retención del chat (§11.1), el trabajo horario chat_retention: borra los
// mensajes con sent_at de hace más de [ChatRetention], en lotes de 10 000 (cada uno, su propia
// sentencia) hasta que no quede ninguno. Devuelve cuántos borró.
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

// ChatRetentionJob es [Service.PurgeChat] como trabajo periódico de app (registra lo borrado).
func (s *Service) ChatRetentionJob(ctx context.Context) error {
	n, err := s.PurgeChat(ctx)
	if n > 0 {
		s.log.Info("chat caducado borrado", "messages", n)
	}
	return err
}
