package accounts

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/persistence"
)

// ProgressExporter is what the export uses from the progression store: ProgressStore.Export
// (progresion.md §3.5), {"record": ..., "ops": [...]} with record null in a tombstone and without
// staff data.
type ProgressExporter interface {
	Export(ctx context.Context, q persistence.Querier, characterID int64) (json.RawMessage, error)
}

// exportFormat versions the export file.
const exportFormat = 1

// Retention of the sessions and logins that are exported (§11.1: 30 days).
const accessRetention = 30 * 24 * time.Hour

// Export returns the account's data in JSON (§11.2, with the password and once a day; also with the
// privacy session) and the file name, eldmark-datos-<date>.json.
//
// It includes the account (without the hash), the acceptances, the consents, the 30-day sessions
// and logins, the entitlements, the realms, the characters (with their stats and progression), the
// ignored players (by name), the account's own sanctions (without author), the reports made and the
// chat sent within the retention period. The progression is characters[i].progress, from
// ProgressStore.Export (P9a): the record and the ledger's own data for each unpurged character and,
// for each tombstone of the account, what remains of its ledger (without record; null if nothing
// remains). Everything comes from the same snapshot of the database.
func (s *Service) Export(ctx context.Context, sess *Session, password string, meta ClientMeta) ([]byte, string, error) {
	if password == "" || len(password) > maxPasswordBytes {
		return nil, "", errValidation(map[string]string{"password": "required"})
	}
	ok, err := s.CheckPassword(ctx, sess.AccountID, sess.Email, password, meta.IP)
	if err := s.passwordError(ctx, sess, ok, err, meta); err != nil {
		return nil, "", err
	}
	now := s.clock.Now()
	var last *time.Time
	if err := s.pool.QueryRow(ctx, `select max(at) from auth_events where account_id = $1 and kind = 'export' and at > $2`,
		sess.AccountID, now.Add(-ExportEvery)).Scan(&last); err != nil {
		return nil, "", err
	}
	if last != nil {
		return nil, "", errRateLimited(last.Add(ExportEvery).Sub(now))
	}
	out := map[string]any{"format": exportFormat, "exported_at": now.UTC().Format(time.RFC3339)}
	since := now.Add(-accessRetention)
	queries := []struct {
		key, sql string
		args     []any
		single   bool
	}{
		{"account", `select account_id::text, email, email_verified_at, role, status, age_confirmed_at, created_at,
			deletion_requested_at, purge_after from accounts where account_id = $1`, nil, true},
		{"legal_acceptances", `select kind, version, accepted_at from legal_acceptances where account_id = $1
			order by accepted_at, kind`, nil, false},
		{"consents", `select purpose, granted, updated_at from consents where account_id = $1 order by purpose`, nil, false},
		{"sessions", `select created_at, rotated_at, revoked_at, revoke_reason, scope, host(ip) as ip, user_agent,
			client_protocol from sessions where account_id = $1 and created_at > $2 order by created_at`, []any{since}, false},
		{"access_events", `select kind, host(ip) as ip, user_agent, at from auth_events
			where account_id = $1 and at > $2 order by at`, []any{since}, false},
		{"entitlements", `select world_id, kind, ref, quantity, source, granted_at, expires_at, revoked_at
			from entitlements where account_id = $1 order by granted_at`, nil, false},
		{"realms", `select world_id, realm, unlock_at from account_realms where account_id = $1 order by world_id`, nil, false},
		{"characters", `select c.character_id::text, c.world_id, c.name, c.realm, c.must_rename, c.created_at,
			c.last_entered_at, c.deleted_at, c.restore_until, c.purged_at, p.kills, p.deaths, p.assists, p.captures,
			p.gate_damage, p.defend_s from characters c left join character_pvp_stats p using (character_id)
			where c.account_id = $1 order by c.character_id`, nil, false},
		{"ignores", `select ignored_name, created_at from ignores where account_id = $1 order by created_at`, nil, false},
		{"sanctions", `select world_id, kind, reason, starts_at, ends_at, revoked_at, created_at from sanctions
			where account_id = $1 order by created_at`, nil, false},
		{"reports", `select report_id::text, world_id, target_name, category, comment, status, created_at, closed_at
			from reports where reporter_account_id = $1 order by created_at`, nil, false},
		{"chat", `select sent_at, zone_id, zone_channel, channel, sender_character_id::text,
			target_character_id::text, text from chat_messages where sender_account_id = $1 order by sent_at, id`, nil, false},
	}
	err = db.InTx(ctx, s.pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		for _, q := range queries {
			rows, err := tx.Query(ctx, q.sql, append([]any{sess.AccountID}, q.args...)...)
			if err != nil {
				return err
			}
			list, err := collectExport(rows)
			if err != nil {
				return err
			}
			if q.single {
				if len(list) == 1 {
					out[q.key] = list[0]
				}
				continue
			}
			out[q.key] = list
		}
		chars, _ := out["characters"].([]map[string]any)
		return s.exportProgress(ctx, tx, chars)
	})
	if err != nil {
		return nil, "", err
	}
	body, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return nil, "", err
	}
	if err := s.event(ctx, s.pool, sess.AccountID, "export", meta, now); err != nil {
		return nil, "", err
	}
	return body, "eldmark-datos-" + now.UTC().Format("2006-01-02") + ".json", nil
}

// exportProgress sets characters[i].progress (§11.2) with ProgressStore.Export, in the export's
// transaction: an unpurged character's, in full; a tombstone's, only if it still has a ledger (the
// one-year retention empties it and afterwards deletes the tombstone). Without a store it does
// nothing.
func (s *Service) exportProgress(ctx context.Context, tx pgx.Tx, chars []map[string]any) error {
	if s.progress == nil {
		return nil
	}
	for _, c := range chars {
		text, _ := c["character_id"].(string)
		id, err := strconv.ParseInt(text, 10, 64)
		if err != nil {
			return fmt.Errorf("accounts: exportación: character_id %q", text)
		}
		raw, err := s.progress.Export(ctx, tx, id)
		if err != nil {
			return err
		}
		if c["purged_at"] != nil {
			var tomb struct {
				Ops []json.RawMessage `json:"ops"`
			}
			if err := json.Unmarshal(raw, &tomb); err != nil {
				return fmt.Errorf("accounts: exportación del progreso de %d: %w", id, err)
			}
			if len(tomb.Ops) == 0 {
				c["progress"] = nil
				continue
			}
		}
		c["progress"] = raw
	}
	return nil
}

// collectExport reads the rows as maps, with dates in RFC 3339 and UTC.
func collectExport(rows pgx.Rows) ([]map[string]any, error) {
	list, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		return nil, err
	}
	for _, row := range list {
		for k, v := range row {
			if t, ok := v.(time.Time); ok {
				row[k] = t.UTC().Format(time.RFC3339)
			}
		}
	}
	if list == nil {
		list = []map[string]any{}
	}
	return list, nil
}
