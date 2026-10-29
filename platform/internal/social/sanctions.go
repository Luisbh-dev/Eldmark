package social

import (
	"context"
	"encoding/json"
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

// maxSanctionMinutes acota la duración de una sanción con fin (10 años).
const maxSanctionMinutes = 10 * 365 * 24 * 60

// SanctionRequest es el cuerpo de POST /internal/v1/sanctions (§9.5). No lleva world_id: el nombre
// se resuelve en el mundo de la instancia.
type SanctionRequest struct {
	ZoneInstanceID    string     `json:"zone_instance_id"`
	AuthorCharacterID jsonx.ID   `json:"author_character_id"`
	TargetName        string     `json:"target_name"`
	Kind              string     `json:"kind"`
	Minutes           jsonx.Int  `json:"minutes"`
	Reason            string     `json:"reason"`
	ReportIDs         []jsonx.ID `json:"report_ids"`
}

// SanctionView es la respuesta: el id y el fin (null: sin fin).
type SanctionView struct {
	SanctionID jsonx.ID `json:"sanction_id"`
	EndsAtUnix *int64   `json:"ends_at_unix"`
}

// timed dice si el tipo lleva duración: el silencio y la suspensión. El aviso, el renombrado y la
// expulsión (permanente) no.
func timed(kind string) bool { return kind == sanctions.KindMute || kind == sanctions.KindSuspension }

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
	case timed(req.Kind) && (req.Minutes < 1 || req.Minutes > maxSanctionMinutes):
		fields["minutes"] = "invalid"
	case !timed(req.Kind) && req.Minutes != 0:
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

// denial es por qué la plataforma no deja crear una sanción (va en args de sanction_denied).
type denial string

const (
	deniedNoLease    denial = "no_lease"    // el autor no tiene arrendamiento en la instancia
	deniedRole       denial = "role"        // su rol no llega para ese tipo y esa duración
	deniedTargetRole denial = "target_role" // el objetivo no tiene un rol menor
)

// Sanction crea una sanción pedida desde la zona (/gm …) si la plataforma la autoriza (§9.5), en la
// transacción de la sanción: (1) el autor tiene arrendamiento en la instancia, (2) su cuenta tiene
// el rol mínimo para ese tipo y esa duración (§9.1) y (3) la cuenta objetivo (el nombre en el mundo
// de la instancia; 404 si no hay nadie) tiene un rol menor. Si falla alguna, 403 forbidden y una
// fila sanction_denied en audit_log (el objetivo por id, sin nombres). Si no, la sanción con sus
// reportes (de ese mundo; si no, 400), must_rename en un renombrado y una fila sanction en
// audit_log.
func (s *Service) Sanction(ctx context.Context, inst *zones.Instance, req SanctionRequest) (*SanctionView, error) {
	now := s.clock.Now()
	author := int64(req.AuthorCharacterID)
	duration := time.Duration(req.Minutes) * time.Minute
	reason := strings.TrimSpace(req.Reason)
	reports := make([]int64, 0, len(req.ReportIDs))
	for _, id := range req.ReportIDs {
		if !slices.Contains(reports, int64(id)) {
			reports = append(reports, int64(id))
		}
	}
	var view *SanctionView
	var denied denial
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		view, denied = nil, ""
		target, err := s.resolve(ctx, tx, inst.WorldID, req.TargetName)
		if err != nil {
			return err
		}
		if target == nil {
			return errTargetNotFound()
		}
		var authorAccount int64
		var authorRole string
		err = tx.QueryRow(ctx, `select c.account_id, a.role from characters c join accounts a using (account_id)
			where c.character_id = $1 and c.world_id = $2`, author, inst.WorldID).Scan(&authorAccount, &authorRole)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		// Las filas de las dos cuentas, en orden de id: el rol que se mira no cambia a mitad.
		accounts := []int64{target.AccountID}
		if authorAccount != 0 && authorAccount != target.AccountID {
			accounts = append(accounts, authorAccount)
		}
		slices.Sort(accounts)
		rows, err := tx.Query(ctx, `select account_id, role from accounts where account_id = any($1)
			order by account_id for no key update`, accounts)
		if err != nil {
			return err
		}
		roles := map[int64]string{}
		for rows.Next() {
			var id int64
			var role string
			if err := rows.Scan(&id, &role); err != nil {
				rows.Close()
				return err
			}
			roles[id] = role
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		authorRole = roles[authorAccount]
		_, _, hasLease, err := inside(ctx, tx, author, inst)
		if err != nil {
			return err
		}
		switch {
		case !hasLease:
			denied = deniedNoLease
		case sanctions.Rank(authorRole) < sanctions.Rank(sanctions.MinRole(req.Kind, duration)):
			denied = deniedRole
		case sanctions.Rank(roles[target.AccountID]) >= sanctions.Rank(authorRole):
			denied = deniedTargetRole
		}
		args := map[string]any{"kind": req.Kind, "minutes": int64(req.Minutes)}
		var actorAccount, actorCharacter *int64
		if authorAccount != 0 {
			actorAccount, actorCharacter = &authorAccount, &author
		}
		if denied != "" {
			args["denied"] = string(denied)
			return s.audit(ctx, tx, inst, "sanction_denied", actorAccount, actorCharacter, target, args, now)
		}
		if len(reports) > 0 {
			var found int
			if err := tx.QueryRow(ctx, `select count(*) from reports where report_id = any($1) and world_id = $2`,
				reports, inst.WorldID).Scan(&found); err != nil {
				return err
			}
			if found != len(reports) {
				return zones.Validation(map[string]string{"report_ids": "unknown"})
			}
		}
		var ends *time.Time
		if timed(req.Kind) {
			t := now.Add(duration)
			ends = &t
		}
		var sanctionID int64
		if err := tx.QueryRow(ctx, `insert into sanctions (account_id, world_id, character_id, kind, reason,
				author_account_id, starts_at, ends_at, created_at)
			values ($1, $2, $3, $4, $5, $6, $7, $8, $7) returning sanction_id`,
			target.AccountID, inst.WorldID, target.ID, req.Kind, reason, authorAccount, now, ends).Scan(&sanctionID); err != nil {
			return err
		}
		for _, id := range reports {
			if _, err := tx.Exec(ctx, `insert into sanction_reports (sanction_id, report_id) values ($1, $2)`,
				sanctionID, id); err != nil {
				return err
			}
		}
		if req.Kind == sanctions.KindRename {
			if _, err := tx.Exec(ctx, `update characters set must_rename = true where character_id = $1`, target.ID); err != nil {
				return err
			}
		}
		args["sanction_id"] = jsonx.ID(sanctionID)
		if len(reports) > 0 {
			ids := make([]jsonx.ID, len(reports))
			for i, id := range reports {
				ids[i] = jsonx.ID(id)
			}
			args["report_ids"] = ids
		}
		if err := s.audit(ctx, tx, inst, "sanction", actorAccount, actorCharacter, target, args, now); err != nil {
			return err
		}
		view = &SanctionView{SanctionID: jsonx.ID(sanctionID)}
		if ends != nil {
			u := ends.Unix()
			view.EndsAtUnix = &u
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if denied != "" {
		s.log.Warn("sanción denegada", "zone_instance", inst.IDString(), "author", author, "kind", req.Kind,
			"denied", string(denied))
		return nil, zones.ErrForbidden()
	}
	s.log.Info("sanción creada", "sanction", int64(view.SanctionID), "kind", req.Kind, "author", author)
	return view, nil
}

// audit escribe una fila de la plataforma en audit_log (§9.1): el objetivo por id, sin nombres ni
// correos en args.
func (s *Service) audit(ctx context.Context, tx pgx.Tx, inst *zones.Instance, command string, actorAccount,
	actorCharacter *int64, target *character, args map[string]any, now time.Time) error {
	data, err := json.Marshal(args)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `insert into audit_log (world_id, source, actor_account_id, actor_character_id, zone_id,
			command, target_account_id, target_character_id, args, at)
		values ($1, 'platform', $2, $3, $4, $5, $6, $7, $8, $9)`,
		inst.WorldID, actorAccount, actorCharacter, inst.ZoneID, command, target.AccountID, target.ID, data, now)
	return err
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
