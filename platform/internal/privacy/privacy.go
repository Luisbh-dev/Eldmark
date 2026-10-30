// Package privacy son las retenciones de plataforma.md §11.1 (TEC-43): el trabajo horario
// privacy_retention, que borra de cada tabla lo que ha pasado su plazo y vacía el libro de los
// personajes purgados hace más de un año (ProgressStore.PurgeRetention, progresion.md §3.5), con el
// borrado de las lápidas que se quedan vacías.
//
// Lo demás de §11 está en otros paquetes: la retención del chat (social.ChatRetentionJob, P7a), la
// exportación (accounts.Service.Export, con ProgressStore.Export), la purga de cuentas (accounts, P1) y
// de personajes (characters.Purger, P2), y reapply-purges (admin, P9b).
package privacy

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/persistence"
)

const day = 24 * time.Hour

// Plazos de la tabla de plataforma.md §11.1. Las sanciones de una cuenta viva y el libro de un personaje
// vivo no caducan; el libro de uno purgado dura progress.Retention (un año) desde su purga.
const (
	AuthEventsRetention     = 30 * day  // auth_events
	SessionAccessRetention  = 30 * day  // la IP y el agente de sessions, desde que se abrió
	ExpiredSessionRetention = 7 * day   // sessions, desde refresh_expires_at
	ExpiredTokenRetention   = 7 * day   // account_tokens, desde expires_at
	TicketRetention         = day       // enter_tickets, desde expires_at
	InstanceRetention       = 30 * day  // zone_instances terminadas, desde ended_at
	MailRetention           = 7 * day   // outbound_mail
	ReportRetention         = 365 * day // reportes cerrados y su prueba, desde el cierre; uno abierto se cierra a este plazo
	AuditRetention          = 365 * day // audit_log
	PurgedSanctionRetention = 365 * day // las sanciones de una cuenta purgada, desde su purga
)

// Batch es lo que borra como mucho cada sentencia de las tablas que pueden crecer (§11.1: lotes de 10 000).
const Batch = 10_000

// ExpiredReportResolution es la resolución de un reporte que se cierra solo al año (§11.1).
const ExpiredReportResolution = "caducado"

// Pasos de una vuelta, por el nombre con el que salen en [Result] y en el registro.
const (
	StepReportsClosed    = "reports_closed"    // reportes abiertos de hace un año que pasan a dismissed
	StepReports          = "reports"           // reportes cerrados hace más de un año (con su prueba)
	StepAudit            = "audit_log"         // auditoría de hace más de un año
	StepSanctions        = "sanctions"         // sanciones de cuentas purgadas hace más de un año
	StepSanctionedEmails = "sanctioned_emails" // huellas de correos sancionados vencidas
	StepAuthEvents       = "auth_events"       // accesos de hace más de 30 días
	StepSessionAccess    = "session_access"    // sesiones de hace más de 30 días que pierden IP y agente
	StepSessions         = "sessions"          // sesiones caducadas hace más de 7 días
	StepTokens           = "account_tokens"    // enlaces caducados hace más de 7 días
	StepTickets          = "enter_tickets"     // billetes caducados hace más de un día
	StepInstances        = "zone_instances"    // instancias terminadas hace más de 30 días (con sus bloques de ids)
	StepMail             = "outbound_mail"     // correos de prueba de hace más de 7 días
	StepNames            = "character_names"   // nombres reservados cuya reserva venció
	StepLedger           = "ledger"            // filas del libro de los purgados hace más de un año
	StepLedgerTombstones = "ledger_tombstones" // lápidas de personajes que se quedan sin libro
)

// Steps son los pasos de una vuelta, en su orden.
var Steps = []string{StepReportsClosed, StepReports, StepAudit, StepSanctions, StepSanctionedEmails, StepAuthEvents,
	StepSessionAccess, StepSessions, StepTokens, StepTickets, StepInstances, StepMail, StepNames, StepLedger,
	StepLedgerTombstones}

// Options son las dependencias del servicio.
type Options struct {
	Pool *pgxpool.Pool
	// Progress es el almacén del progreso (progress.Store en serve): su PurgeRetention vacía el libro
	// con su propio reloj.
	Progress persistence.ProgressStore
	Clock    clock.Clock // por defecto, el del sistema
	Log      *slog.Logger
}

// Service hace las retenciones.
type Service struct {
	pool     *pgxpool.Pool
	progress persistence.ProgressStore
	clock    clock.Clock
	log      *slog.Logger
}

// New prepara el servicio.
func New(o Options) (*Service, error) {
	if o.Pool == nil || o.Progress == nil {
		return nil, errors.New("privacy: faltan dependencias")
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	return &Service{pool: o.Pool, progress: o.Progress, clock: o.Clock, log: o.Log}, nil
}

// Result es lo que ha borrado (o cambiado) una vuelta en cada paso.
type Result map[string]int64

// Total es la suma de todos los pasos.
func (r Result) Total() int64 {
	var n int64
	for _, v := range r {
		n += v
	}
	return n
}

// step es un paso de la vuelta: borra (o cambia) con la hora dada y devuelve cuántas filas.
type step struct {
	name string
	run  func(ctx context.Context, now time.Time) (int64, error)
}

// Run hace una vuelta de las retenciones con la hora del reloj: cada paso en sus propias sentencias (los
// de las tablas grandes, en lotes de [Batch]) y la del libro con [Service.PurgeLedger]. Un paso que falla
// no para a los demás: la vuelta los hace todos y devuelve los errores juntos (la siguiente, dentro de
// una hora, lo reintenta).
func (s *Service) Run(ctx context.Context) (Result, error) {
	now := s.clock.Now()
	res := make(Result, len(Steps))
	var errs []error
	for _, st := range s.steps() {
		if err := ctx.Err(); err != nil {
			return res, errors.Join(append(errs, err)...)
		}
		n, err := st.run(ctx, now)
		res[st.name] = n
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", st.name, err))
		}
	}
	if err := ctx.Err(); err != nil {
		return res, errors.Join(append(errs, err)...)
	}
	deleted, tombstones, err := s.PurgeLedger(ctx)
	res[StepLedger], res[StepLedgerTombstones] = deleted, tombstones
	if err != nil {
		errs = append(errs, fmt.Errorf("%s: %w", StepLedger, err))
	}
	return res, errors.Join(errs...)
}

// Job es [Service.Run] como trabajo periódico de app (privacy_retention, cada hora): registra lo que
// ha borrado cada paso, sin ids.
func (s *Service) Job(ctx context.Context) error {
	res, err := s.Run(ctx)
	if res.Total() > 0 {
		attrs := make([]any, 0, 2*len(res))
		for _, name := range Steps {
			if n := res[name]; n > 0 {
				attrs = append(attrs, name, n)
			}
		}
		s.log.Info("retenciones: borrado lo caducado", attrs...)
	}
	return err
}

func (s *Service) steps() []step {
	return []step{
		// Primero se cierran los reportes abiertos de hace un año: cuentan desde ahora (§11.1).
		{StepReportsClosed, func(ctx context.Context, now time.Time) (int64, error) {
			return s.exec(ctx, `update reports set status = 'dismissed', closed_at = $1, resolution = $2
				where status in ('open', 'in_review') and created_at < $3`, now, ExpiredReportResolution, now.Add(-ReportRetention))
		}},
		// report_evidence y sanction_reports caen en cascada con su reporte.
		{StepReports, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from reports where report_id in (select report_id from reports
				where status in ('actioned', 'dismissed') and coalesce(closed_at, created_at) < $1 limit $2)`,
				now.Add(-ReportRetention))
		}},
		{StepAudit, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from audit_log where id in (select id from audit_log where at < $1
				order by at limit $2)`, now.Add(-AuditRetention))
		}},
		{StepSanctions, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from sanctions where sanction_id in (select s.sanction_id from sanctions s
				join accounts a on a.account_id = s.account_id where a.status = 'purged' and a.purged_at < $1 limit $2)`,
				now.Add(-PurgedSanctionRetention))
		}},
		// El registro solo mira las vigentes (until > ahora): una vencida ya no sirve de nada.
		{StepSanctionedEmails, func(ctx context.Context, now time.Time) (int64, error) {
			return s.exec(ctx, `delete from sanctioned_email_hashes where until <= $1`, now)
		}},
		{StepAuthEvents, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from auth_events where id in (select id from auth_events where at < $1
				order by at limit $2)`, now.Add(-AuthEventsRetention))
		}},
		{StepSessionAccess, func(ctx context.Context, now time.Time) (int64, error) {
			return s.exec(ctx, `update sessions set ip = null, user_agent = null
				where created_at < $1 and (ip is not null or user_agent is not null)`, now.Add(-SessionAccessRetention))
		}},
		// Una sesión caduca a las 12 h de abrirse (refresh_expires_at; revocarla no la alarga). Sus
		// billetes caen en cascada y el arrendamiento que la tenga se queda sin sesión (set null).
		{StepSessions, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from sessions where session_id in (select session_id from sessions
				where refresh_expires_at < $1 limit $2)`, now.Add(-ExpiredSessionRetention))
		}},
		{StepTokens, func(ctx context.Context, now time.Time) (int64, error) {
			return s.exec(ctx, `delete from account_tokens where expires_at < $1`, now.Add(-ExpiredTokenRetention))
		}},
		{StepTickets, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from enter_tickets where ticket_id in (select ticket_id from enter_tickets
				where expires_at < $1 limit $2)`, now.Add(-TicketRetention))
		}},
		// Terminadas: paradas, perdidas o sustituidas (las tres ponen ended_at). Sus bloques de ids y
		// billetes caen en cascada; los arrendamientos, fortalezas y eventos de guerra que las nombran se
		// quedan sin ella (set null).
		{StepInstances, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from zone_instances where zone_instance_id in (select zone_instance_id
				from zone_instances where status in ('stopped', 'lost', 'replaced') and ended_at < $1 limit $2)`,
				now.Add(-InstanceRetention))
		}},
		{StepMail, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from outbound_mail where id in (select id from outbound_mail
				where created_at < $1 limit $2)`, now.Add(-MailRetention))
		}},
		// El nombre de un personaje borrado (o el viejo de un renombrado) se reserva un plazo (§4.4); vencido,
		// crear y restaurar ya lo tratan como libre, y la fila solo guardaría el nombre.
		{StepNames, func(ctx context.Context, now time.Time) (int64, error) {
			return s.exec(ctx, `delete from character_names where status = 'reserved' and reserved_until <= $1`, now)
		}},
	}
}

// exec corre una sentencia y devuelve las filas que toca.
func (s *Service) exec(ctx context.Context, sql string, args ...any) (int64, error) {
	tag, err := s.pool.Exec(ctx, sql, args...)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// deleteBatched repite un borrado con «limit» (el último parámetro, que pone ella: [Batch]) hasta que
// borra menos de un lote. Cada lote es su propia sentencia: no se bloquea la tabla entera.
func (s *Service) deleteBatched(ctx context.Context, sql string, args ...any) (int64, error) {
	args = append(args, Batch)
	var total int64
	for {
		tag, err := s.pool.Exec(ctx, sql, args...)
		if err != nil {
			return total, err
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < Batch {
			return total, nil
		}
		if err := ctx.Err(); err != nil {
			return total, err
		}
	}
}

// PurgeLedger es la retención del libro (§11.1, progresion.md §3.5): llama a ProgressStore.PurgeRetention
// en una transacción mientras borre algo y, en esa misma transacción, borra las filas de characters que
// devuelve vacías (lápidas purgadas hace más de un año sin libro), sin mirar tablas del progreso. Devuelve
// las filas del libro borradas y las lápidas borradas. El año lo mide el reloj del almacén.
func (s *Service) PurgeLedger(ctx context.Context) (deleted, tombstones int64, err error) {
	for {
		var n, gone int64
		err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
			var emptied []int64
			var err error
			n, emptied, err = s.progress.PurgeRetention(ctx, tx)
			if err != nil {
				return err
			}
			gone = 0
			if len(emptied) == 0 {
				return nil
			}
			// Solo lápidas: un personaje sin purgar nunca se borra aquí, diga lo que diga el almacén.
			tag, err := tx.Exec(ctx, `delete from characters where character_id = any($1) and purged_at is not null`,
				emptied)
			if err != nil {
				return err
			}
			gone = tag.RowsAffected()
			return nil
		})
		if err != nil {
			return deleted, tombstones, err
		}
		deleted += n
		tombstones += gone
		if n == 0 {
			return deleted, tombstones, nil
		}
		if err := ctx.Err(); err != nil {
			return deleted, tombstones, err
		}
	}
}
