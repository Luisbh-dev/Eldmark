package social

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/internal/zones"
)

// maxSanctionMinutes bounds the duration of a sanction with an end (10 years).
const maxSanctionMinutes = 10 * 365 * 24 * 60

// SanctionRequest is the body of POST /internal/v1/sanctions (§9.5). It has no world_id: the name
// is resolved in the instance's world.
type SanctionRequest struct {
	ZoneInstanceID    string     `json:"zone_instance_id"`
	AuthorCharacterID jsonx.ID   `json:"author_character_id"`
	TargetName        string     `json:"target_name"`
	Kind              string     `json:"kind"`
	Minutes           jsonx.Int  `json:"minutes"`
	Reason            string     `json:"reason"`
	ReportIDs         []jsonx.ID `json:"report_ids"`
}

// SanctionView is the response: the id and the end (null: no end).
type SanctionView struct {
	SanctionID jsonx.ID `json:"sanction_id"`
	EndsAtUnix *int64   `json:"ends_at_unix"`
}

func (req *SanctionRequest) validate() map[string]string {
	fields := map[string]string{}
	if req.AuthorCharacterID < 1 {
		fields["author_character_id"] = "invalid"
	}
	if req.TargetName == "" || len(req.TargetName) > 64 {
		fields["target_name"] = "invalid"
	}
	if sanctions.MinRole(req.Kind, 0) == "" {
		fields["kind"] = "invalid"
	}
	switch {
	case sanctions.Timed(req.Kind) && (req.Minutes < 1 || req.Minutes > maxSanctionMinutes):
		fields["minutes"] = "invalid"
	case !sanctions.Timed(req.Kind) && req.Minutes != 0:
		fields["minutes"] = "invalid"
	}
	reason := strings.TrimSpace(req.Reason)
	if reason == "" || utf8.RuneCountInString(reason) > MaxReason || strings.ContainsRune(reason, 0) {
		fields["reason"] = "invalid"
	}
	if len(req.ReportIDs) > MaxReportIDs {
		fields["report_ids"] = "too_many"
	}
	return fields
}

// Sanction creates a sanction requested from the zone (/gm …) if the platform authorizes it
// (§9.5), in the sanction's transaction ([sanctions.Create], the same as the CLI's): (1) the
// author holds a lease on the instance, (2) their account has the minimum role for that type and
// duration (§9.1) and (3) the target account (the name in the instance's world; 404 if there is
// nobody) has a lower role. If any fails, 403 forbidden and a sanction_denied row in audit_log
// (the target by id, without names). Otherwise, the sanction with its reports (from that world;
// if not, 400), must_rename on a rename and a sanction row in audit_log.
func (s *Service) Sanction(ctx context.Context, inst *zones.Instance, req SanctionRequest) (*SanctionView, error) {
	now := s.clock.Now()
	author := int64(req.AuthorCharacterID)
	reports := make([]int64, 0, len(req.ReportIDs))
	for _, id := range req.ReportIDs {
		if !slices.Contains(reports, int64(id)) {
			reports = append(reports, int64(id))
		}
	}
	instance := inst.ID
	var created *sanctions.Created
	var denied sanctions.Denial
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		created, denied = nil, ""
		target, err := s.resolve(ctx, tx, inst.WorldID, req.TargetName)
		if err != nil {
			return err
		}
		if target == nil {
			return errTargetNotFound()
		}
		created, denied, err = sanctions.Create(ctx, tx, sanctions.Request{WorldID: inst.WorldID, ZoneID: inst.ZoneID,
			Source: sanctions.SourcePlatform, AuthorCharacterID: author, Instance: &instance,
			TargetAccountID: target.AccountID, TargetCharacterID: target.ID, Kind: req.Kind,
			Duration: time.Duration(req.Minutes) * time.Minute, Reason: strings.TrimSpace(req.Reason),
			ReportIDs: reports, Now: now})
		switch {
		case errors.Is(err, sanctions.ErrUnknownReports):
			return zones.Validation(map[string]string{"report_ids": "unknown"})
		case errors.Is(err, sanctions.ErrBadRequest):
			return zones.Validation(map[string]string{"kind": "invalid"})
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	if denied != "" {
		s.log.Warn("sanción denegada", "zone_instance", inst.IDString(), "author", author, "kind", req.Kind,
			"denied", string(denied))
		return nil, zones.ErrForbidden()
	}
	s.log.Info("sanción creada", "sanction", created.SanctionID, "kind", req.Kind, "author", author)
	view := &SanctionView{SanctionID: jsonx.ID(created.SanctionID)}
	if created.EndsAt != nil {
		u := created.EndsAt.Unix()
		view.EndsAtUnix = &u
	}
	return view, nil
}

func (s *Service) sanction(w http.ResponseWriter, r *http.Request) {
	var req SanctionRequest
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
	view, err := s.Sanction(ctx, inst, req)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, view)
}
