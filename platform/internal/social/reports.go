package social

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/zones"
)

// Report categories (reports.category).
var reportCategories = []string{"language", "harassment", "cheating", "bot", "offensive_name", "other"}

// ReportRequest is the body of POST /internal/v1/reports (§9.4). It has no world_id: the name is
// resolved in the instance's world.
type ReportRequest struct {
	ZoneInstanceID      string          `json:"zone_instance_id"`
	ReporterCharacterID jsonx.ID        `json:"reporter_character_id"`
	TargetName          string          `json:"target_name"`
	Category            string          `json:"category"`
	Comment             string          `json:"comment"`
	Context             json.RawMessage `json:"context"`
	Evidence            []Evidence      `json:"evidence"`
}

// Evidence is a message that the reporter received (the evidence the zone attaches).
type Evidence struct {
	SenderName string    `json:"sender_name"`
	Channel    jsonx.Int `json:"channel"`
	Text       string    `json:"text"`
	SentAtUnix jsonx.Int `json:"sent_at_unix"`
}

func (req *ReportRequest) validate() map[string]string {
	fields := map[string]string{}
	if req.ReporterCharacterID < 1 {
		fields["reporter_character_id"] = "invalid"
	}
	if req.TargetName == "" || len(req.TargetName) > 64 {
		fields["target_name"] = "invalid"
	}
	if !slices.Contains(reportCategories, req.Category) {
		fields["category"] = "invalid"
	}
	if utf8.RuneCountInString(req.Comment) > MaxReportComment || strings.ContainsRune(req.Comment, 0) {
		fields["comment"] = "too_long"
	}
	if !zones.IsJSONObject(req.Context) {
		fields["context"] = "invalid"
	}
	if len(req.Evidence) > MaxEvidence {
		fields["evidence"] = "too_many"
	}
	for _, e := range req.Evidence {
		if e.SenderName == "" || len(e.SenderName) > 64 || e.Channel < 0 || e.Channel > 255 || e.SentAtUnix < 0 ||
			e.SentAtUnix > zones.MaxUnix ||
			utf8.RuneCountInString(e.Text) > maxChatText || strings.ContainsRune(e.Text, 0) ||
			strings.ContainsRune(e.SenderName, 0) {
			fields["evidence"] = "invalid"
			break
		}
	}
	return fields
}

// Report stores a report (§9.4): the reporter must hold a lease on the instance (otherwise 403);
// the target is resolved in the instance's world (404 if there is nobody; 400 if it is the
// account itself); 1 per target every 10 min and 10 per hour per account (429); it copies the
// evidence to report_evidence. It returns the report_id.
func (s *Service) Report(ctx context.Context, inst *zones.Instance, req ReportRequest) (int64, error) {
	now := s.clock.Now()
	var reportID int64
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		reporter := int64(req.ReporterCharacterID)
		account, _, ok, err := inside(ctx, tx, reporter, inst)
		if err != nil {
			return err
		}
		if !ok {
			return zones.ErrForbidden()
		}
		target, err := s.resolve(ctx, tx, inst.WorldID, req.TargetName)
		if err != nil {
			return err
		}
		if target == nil {
			return errTargetNotFound()
		}
		if target.AccountID == account {
			return zones.Validation(map[string]string{"target_name": "self"})
		}
		// The account row serializes the reports of the same account (the limits).
		if _, err := tx.Exec(ctx, `select 1 from accounts where account_id = $1 for no key update`, account); err != nil {
			return err
		}
		var hourCount int
		var oldest *time.Time
		if err := tx.QueryRow(ctx, `select count(*), min(created_at) from reports
			where reporter_account_id = $1 and created_at > $2`, account, now.Add(-time.Hour)).Scan(&hourCount, &oldest); err != nil {
			return err
		}
		if hourCount >= ReportsPerHour && oldest != nil {
			return errRateLimited(oldest.Add(time.Hour).Sub(now))
		}
		var last *time.Time
		if err := tx.QueryRow(ctx, `select max(created_at) from reports
			where reporter_account_id = $1 and target_character_id = $2 and created_at > $3`,
			account, target.ID, now.Add(-ReportTargetWindow)).Scan(&last); err != nil {
			return err
		}
		if last != nil {
			return errRateLimited(last.Add(ReportTargetWindow).Sub(now))
		}
		if err := tx.QueryRow(ctx, `insert into reports (world_id, reporter_account_id, reporter_character_id,
				target_account_id, target_character_id, target_name, category, comment, context, created_at)
			values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) returning report_id`,
			inst.WorldID, account, reporter, target.AccountID, target.ID, target.Name, req.Category, req.Comment,
			req.Context, now).Scan(&reportID); err != nil {
			return err
		}
		for i, e := range req.Evidence {
			if _, err := tx.Exec(ctx, `insert into report_evidence (report_id, seq, sender_name, channel, text, sent_at)
				values ($1, $2, $3, $4, $5, $6)`, reportID, i, e.SenderName, int(e.Channel), e.Text,
				time.Unix(int64(e.SentAtUnix), 0).UTC()); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	s.log.Info("reporte recibido", "report", reportID, "zone_instance", inst.IDString(), "category", req.Category)
	return reportID, nil
}

func (s *Service) report(w http.ResponseWriter, r *http.Request) {
	var req ReportRequest
	if e := zones.Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return
	}
	ctx := r.Context()
	inst, err := s.guard.Instance(ctx, zones.ScopeFrom(ctx), req.ZoneInstanceID, zones.OpModeration)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if fields := req.validate(); len(fields) > 0 {
		httpx.WriteError(w, zones.Validation(fields))
		return
	}
	id, err := s.Report(ctx, inst, req)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]jsonx.ID{"report_id": jsonx.ID(id)})
}
