package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/sanctions"
)

// Estados de un reporte (reports.status).
var reportStatuses = []string{"open", "in_review", "actioned", "dismissed"}

// ReportSummary es un reporte en la lista.
type ReportSummary struct {
	ID                  int64
	WorldID             int16
	CreatedAt           time.Time
	Category            string
	Status              string
	ReporterAccountID   *int64
	ReporterCharacterID *int64
	ReporterName        *string // el nombre de ahora del personaje que reporta (null si se purgó)
	TargetAccountID     *int64
	TargetCharacterID   *int64
	TargetName          string // el nombre que se reportó
	Comment             string
	Evidence            int
}

// ReportFilter son los filtros de reports list.
type ReportFilter struct {
	Status string // open (por defecto), in_review, actioned, dismissed o all
	Limit  int
}

// Reports es reports list (lectura, moderator): los reportes de ese estado, del más viejo al más
// nuevo (la cola). Deja la fila reports list (args {status, limit, os_user}).
func (s *Service) Reports(ctx context.Context, actor *Actor, f ReportFilter) ([]ReportSummary, error) {
	if f.Status == "" {
		f.Status = "open"
	}
	if f.Status != "all" && !slices.Contains(reportStatuses, f.Status) {
		return nil, fmt.Errorf("estado desconocido %q: open, in_review, actioned, dismissed o all", f.Status)
	}
	n := limit(f.Limit)
	var out []ReportSummary
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		out = nil
		rows, err := tx.Query(ctx, reportSelect+` where ($1 = 'all' or r.status = $1)
			order by r.created_at, r.report_id limit $2`, f.Status, n)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, scanSummary)
		if err != nil {
			return err
		}
		return s.audit(ctx, tx, actor, entry{command: "reports list",
			args: map[string]any{"status": f.Status, "limit": n}}, s.clock.Now())
	})
	return out, err
}

const reportSelect = `select r.report_id, r.world_id, r.created_at, r.category, r.status, r.reporter_account_id,
		r.reporter_character_id, c.name, r.target_account_id, r.target_character_id, r.target_name, r.comment,
		(select count(*) from report_evidence e where e.report_id = r.report_id)
	from reports r left join characters c on c.character_id = r.reporter_character_id`

func scanSummary(row pgx.CollectableRow) (ReportSummary, error) {
	var r ReportSummary
	err := row.Scan(&r.ID, &r.WorldID, &r.CreatedAt, &r.Category, &r.Status, &r.ReporterAccountID,
		&r.ReporterCharacterID, &r.ReporterName, &r.TargetAccountID, &r.TargetCharacterID, &r.TargetName, &r.Comment,
		&r.Evidence)
	return r, err
}

// Evidence es un mensaje copiado al reporte (report_evidence).
type Evidence struct {
	Seq        int16
	SenderName string
	Channel    int16
	Text       string
	SentAt     time.Time
}

// ReportDetail es reports show: el reporte con su prueba y sus sanciones.
type ReportDetail struct {
	ReportSummary
	Context    json.RawMessage
	HandledBy  *int64
	Resolution *string
	ClosedAt   *time.Time
	Evidence   []Evidence
	Sanctions  []int64 // sanciones enlazadas (sanction_reports)
}

// Report es reports show (lectura, moderator). Deja la fila reports show con el objetivo del
// reporte en target_account_id y target_character_id y args {report_id, os_user}.
func (s *Service) Report(ctx context.Context, actor *Actor, id int64) (*ReportDetail, error) {
	var out *ReportDetail
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		out = nil
		rows, err := tx.Query(ctx, reportSelect+` where r.report_id = $1`, id)
		if err != nil {
			return err
		}
		list, err := pgx.CollectRows(rows, scanSummary)
		if err != nil {
			return err
		}
		if len(list) == 0 {
			return ErrReportNotFound
		}
		d := &ReportDetail{ReportSummary: list[0]}
		if err := tx.QueryRow(ctx, `select context, handled_by, resolution, closed_at from reports where report_id = $1`,
			id).Scan(&d.Context, &d.HandledBy, &d.Resolution, &d.ClosedAt); err != nil {
			return err
		}
		rows, err = tx.Query(ctx, `select seq, sender_name, channel, text, sent_at from report_evidence
			where report_id = $1 order by seq`, id)
		if err != nil {
			return err
		}
		if d.Evidence, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Evidence, error) {
			var e Evidence
			err := row.Scan(&e.Seq, &e.SenderName, &e.Channel, &e.Text, &e.SentAt)
			return e, err
		}); err != nil {
			return err
		}
		rows, err = tx.Query(ctx, `select sanction_id from sanction_reports where report_id = $1 order by sanction_id`, id)
		if err != nil {
			return err
		}
		if d.Sanctions, err = pgx.CollectRows(rows, pgx.RowTo[int64]); err != nil {
			return err
		}
		out = d
		return s.audit(ctx, tx, actor, entry{world: d.WorldID, command: "reports show", targetAccount: deref(d.TargetAccountID),
			targetCharacter: deref(d.TargetCharacterID), args: map[string]any{"report_id": idString(id)}}, s.clock.Now())
	})
	return out, err
}

// CloseReport es reports close (admin): cierra un reporte abierto o en revisión como actioned o
// dismissed, con handled_by del --actor, la resolución y closed_at (la retención de un año cuenta
// desde ahí, §11.1). Deja la fila reports close (args {report_id, status, os_user}; la resolución
// queda en reports.resolution, no en la auditoría).
func (s *Service) CloseReport(ctx context.Context, actor *Actor, id int64, status, resolution string) error {
	if status != "actioned" && status != "dismissed" {
		return errors.New("un reporte se cierra como actioned o dismissed")
	}
	return s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockActor(ctx, tx, actor, sanctions.RoleAdmin); err != nil {
			return err
		}
		var current string
		var world int16
		var targetAccount, targetCharacter *int64
		err := tx.QueryRow(ctx, `select status, world_id, target_account_id, target_character_id from reports
			where report_id = $1 for update`, id).Scan(&current, &world, &targetAccount, &targetCharacter)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrReportNotFound
		}
		if err != nil {
			return err
		}
		if current == "actioned" || current == "dismissed" {
			return ErrReportClosed
		}
		now := s.clock.Now()
		if _, err := tx.Exec(ctx, `update reports set status = $2, handled_by = $3, resolution = $4, closed_at = $5
			where report_id = $1`, id, status, actor.AccountID, resolution, now); err != nil {
			return err
		}
		return s.audit(ctx, tx, actor, entry{world: world, command: "reports close", targetAccount: deref(targetAccount),
			targetCharacter: deref(targetCharacter), args: map[string]any{"report_id": idString(id), "status": status}}, now)
	})
}

func deref(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}
