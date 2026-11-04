// Package privacy implements the retention rules of platform.md §11.1 (TEC-43): the hourly
// privacy_retention job, which deletes from each table whatever has passed its deadline and
// empties the ledger of characters purged more than a year ago (ProgressStore.PurgeRetention,
// progression.md §3.5), along with deleting the tombstones that end up empty.
//
// The rest of §11 lives in other packages: chat retention (social.ChatRetentionJob, P7a),
// export (accounts.Service.Export, with ProgressStore.Export), account purging (accounts, P1)
// and character purging (characters.Purger, P2), and reapply-purges (admin, P9b).
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

// Deadlines from the table in platform.md §11.1. The sanctions of a live account and the
// ledger of a live character do not expire; the ledger of a purged one lasts progress.Retention
// (one year) from its purge.
const (
	AuthEventsRetention     = 30 * day  // auth_events
	SessionAccessRetention  = 30 * day  // the IP and agent of sessions, from when it was opened
	ExpiredSessionRetention = 7 * day   // sessions, from refresh_expires_at
	ExpiredTokenRetention   = 7 * day   // account_tokens, from expires_at
	TicketRetention         = day       // enter_tickets, from expires_at
	InstanceRetention       = 30 * day  // finished zone_instances, from ended_at
	MailRetention           = 7 * day   // outbound_mail
	ReportRetention         = 365 * day // closed reports and their evidence, from closing; an open one is closed at this deadline
	AuditRetention          = 365 * day // audit_log
	PurgedSanctionRetention = 365 * day // the sanctions of a purged account, from its purge
)

// Batch is the most that each statement deletes from the tables that can grow (§11.1: batches of 10 000).
const Batch = 10_000

// ExpiredReportResolution is the resolution of a report that closes itself after a year (§11.1).
const ExpiredReportResolution = "caducado"

// Steps of a pass, by the name under which they appear in [Result] and in the log.
const (
	StepReportsClosed    = "reports_closed"    // open reports from a year ago that move to dismissed
	StepReports          = "reports"           // reports closed more than a year ago (with their evidence)
	StepAudit            = "audit_log"         // audit entries from more than a year ago
	StepSanctions        = "sanctions"         // sanctions of accounts purged more than a year ago
	StepSanctionedEmails = "sanctioned_emails" // expired fingerprints of sanctioned emails
	StepAuthEvents       = "auth_events"       // logins from more than 30 days ago
	StepSessionAccess    = "session_access"    // sessions from more than 30 days ago that lose IP and agent
	StepSessions         = "sessions"          // sessions expired more than 7 days ago
	StepTokens           = "account_tokens"    // links expired more than 7 days ago
	StepTickets          = "enter_tickets"     // tickets expired more than a day ago
	StepInstances        = "zone_instances"    // instances finished more than 30 days ago (with their id blocks)
	StepMail             = "outbound_mail"     // test emails from more than 7 days ago
	StepNames            = "character_names"   // reserved names whose reservation expired
	StepLedger           = "ledger"            // ledger rows of characters purged more than a year ago
	StepLedgerTombstones = "ledger_tombstones" // tombstones of characters left without a ledger
)

// Steps are the steps of a pass, in order.
var Steps = []string{StepReportsClosed, StepReports, StepAudit, StepSanctions, StepSanctionedEmails, StepAuthEvents,
	StepSessionAccess, StepSessions, StepTokens, StepTickets, StepInstances, StepMail, StepNames, StepLedger,
	StepLedgerTombstones}

// Options are the service's dependencies.
type Options struct {
	Pool *pgxpool.Pool
	// Progress is the progress store (progress.Store in serve): its PurgeRetention empties the
	// ledger with its own clock.
	Progress persistence.ProgressStore
	Clock    clock.Clock // defaults to the system clock
	Log      *slog.Logger
}

// Service performs the retention jobs.
type Service struct {
	pool     *pgxpool.Pool
	progress persistence.ProgressStore
	clock    clock.Clock
	log      *slog.Logger
}

// New prepares the service.
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

// Result is what a pass has deleted (or changed) in each step.
type Result map[string]int64

// Total is the sum of all steps.
func (r Result) Total() int64 {
	var n int64
	for _, v := range r {
		n += v
	}
	return n
}

// step is a step of the pass: it deletes (or changes) with the given time and returns how many rows.
type step struct {
	name string
	run  func(ctx context.Context, now time.Time) (int64, error)
}

// Run performs one pass of the retention jobs with the clock's time: each step in its own
// statements (those of the large tables, in batches of [Batch]) and the ledger one with
// [Service.PurgeLedger]. A step that fails does not stop the others: the pass runs them all and
// returns the errors together (the next one, an hour later, retries it).
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

// Job is [Service.Run] as a periodic app job (privacy_retention, every hour): it logs what each
// step has deleted, without ids.
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
		// Open reports from a year ago are closed first: they count from now (§11.1).
		{StepReportsClosed, func(ctx context.Context, now time.Time) (int64, error) {
			return s.exec(ctx, `update reports set status = 'dismissed', closed_at = $1, resolution = $2
				where status in ('open', 'in_review') and created_at < $3`, now, ExpiredReportResolution, now.Add(-ReportRetention))
		}},
		// report_evidence and sanction_reports cascade with their report.
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
		// The registry only looks at active ones (until > now): an expired one is no longer of any use.
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
		// A session expires 12 h after opening (refresh_expires_at; revoking it does not extend it). Its
		// tickets cascade and the lease that holds it is left without a session (set null).
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
		// Finished: stopped, lost or replaced (all three set ended_at). Their id blocks and tickets
		// cascade; the leases, forts and war events that name them are left without it (set null).
		{StepInstances, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from zone_instances where zone_instance_id in (select zone_instance_id
				from zone_instances where status in ('stopped', 'lost', 'replaced') and ended_at < $1 limit $2)`,
				now.Add(-InstanceRetention))
		}},
		{StepMail, func(ctx context.Context, now time.Time) (int64, error) {
			return s.deleteBatched(ctx, `delete from outbound_mail where id in (select id from outbound_mail
				where created_at < $1 limit $2)`, now.Add(-MailRetention))
		}},
		// The name of a deleted character (or the old one of a renamed one) is reserved for a period
		// (§4.4); once expired, create and restore already treat it as free, and the row would only keep
		// the name.
		{StepNames, func(ctx context.Context, now time.Time) (int64, error) {
			return s.exec(ctx, `delete from character_names where status = 'reserved' and reserved_until <= $1`, now)
		}},
	}
}

// exec runs a statement and returns the rows it touches.
func (s *Service) exec(ctx context.Context, sql string, args ...any) (int64, error) {
	tag, err := s.pool.Exec(ctx, sql, args...)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// deleteBatched repeats a delete with "limit" (the last parameter, which it sets: [Batch]) until
// it deletes less than one batch. Each batch is its own statement: the whole table is not locked.
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

// PurgeLedger is the ledger retention (§11.1, progression.md §3.5): it calls
// ProgressStore.PurgeRetention in a transaction as long as it deletes anything and, in that same
// transaction, deletes the characters rows it returns as emptied (tombstones purged more than a
// year ago with no ledger), without looking at progress tables. It returns the ledger rows deleted
// and the tombstones deleted. The year is measured by the store's clock.
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
			// Tombstones only: a character that has not been purged is never deleted here, whatever the store says.
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
