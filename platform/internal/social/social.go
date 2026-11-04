// Package social is the part of the internal API for social features and moderation
// (plataforma.md §6, §9, SOC-14 to SOC-18): the zone's chat and audit batches (with per-entry
// rejection and validated against the instance that sends them), ignores, reports and the
// sanctions that a GM requests from the zone, which the platform authorizes.
//
// The world is always set by the instance: bodies carry no world_id (an unknown field, 400) and
// names are resolved in the instance's world, so a zone cannot reach anyone in another world.
package social

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/names"
	"eldmark/platform/internal/zones"
)

// Caps from §9.3 and §9.4.
const (
	MaxIgnores         = 100
	MaxEvidence        = 20
	MaxReportComment   = 500
	MaxReason          = 500
	MaxReportIDs       = 20
	ReportsPerHour     = 10
	ReportTargetWindow = 10 * time.Minute
	maxChatText        = 255
)

// Options are the service's dependencies.
type Options struct {
	Pool  *pgxpool.Pool
	Guard *zones.Guard
	Clock clock.Clock
	Log   *slog.Logger
	// Names are the name rules (the normalized key); nil: those from progression_rules.json.
	Names *names.Rules
}

// Service is the internal API's social service.
type Service struct {
	pool  *pgxpool.Pool
	guard *zones.Guard
	clock clock.Clock
	log   *slog.Logger
	names *names.Rules
}

// New prepares the service.
func New(o Options) (*Service, error) {
	if o.Pool == nil || o.Guard == nil {
		return nil, errors.New("social: faltan dependencias")
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	if o.Names == nil {
		o.Names = names.Default()
	}
	return &Service{pool: o.Pool, guard: o.Guard, clock: o.Clock, log: o.Log, names: o.Names}, nil
}

// Mount mounts the routes, all with the zone token.
func (s *Service) Mount(r zones.Router) {
	zone := func(pattern string, h http.HandlerFunc) { r.HandleInternal(pattern, s.guard.Zone(h)) }
	zone("POST /internal/v1/chat", s.chatBatch)
	zone("POST /internal/v1/audit", s.auditBatch)
	zone("POST /internal/v1/ignores", s.ignore)
	zone("DELETE /internal/v1/ignores", s.unignore)
	zone("POST /internal/v1/reports", s.report)
	zone("POST /internal/v1/sanctions", s.sanction)
}

func (s *Service) fail(w http.ResponseWriter, r *http.Request, err error) {
	zones.Fail(w, r, s.log, err)
}

// character is a character resolved by its name in a world.
type character struct {
	ID        int64
	AccountID int64
	Name      string
	Role      string
}

// resolve looks up the live character (neither deleted nor purged) with that name in the world,
// by the NameRules key; nil if there is none.
func (s *Service) resolve(ctx context.Context, q zones.Querier, worldID int16, name string) (*character, error) {
	key := s.names.NormalizeKey(name)
	if key == "" {
		return nil, nil
	}
	c := &character{}
	err := q.QueryRow(ctx, `select c.character_id, c.account_id, c.name, a.role from characters c
		join accounts a using (account_id)
		where c.world_id = $1 and c.name_key = $2 and c.deleted_at is null and c.purged_at is null`,
		worldID, key).Scan(&c.ID, &c.AccountID, &c.Name, &c.Role)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return c, nil
}

// inside returns the character's account and role if it has a lease on the instance
// (character_leases.zone_instance_id, §9.3–§9.5); otherwise, ok is false.
func inside(ctx context.Context, q zones.Querier, characterID int64, inst *zones.Instance) (accountID int64,
	role string, ok bool, err error) {
	err = q.QueryRow(ctx, `select c.account_id, a.role from character_leases l join characters c using (character_id)
		join accounts a on a.account_id = c.account_id
		where l.character_id = $1 and l.zone_instance_id = $2`, characterID, inst.ID).Scan(&accountID, &role)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, "", false, nil
	}
	return accountID, role, err == nil, err
}

func errTargetNotFound() *httpx.Error {
	return &httpx.Error{Status: http.StatusNotFound, Code: "not_found", Message: "No hay nadie con ese nombre"}
}

func errRateLimited(wait time.Duration) *httpx.Error {
	s := int(wait.Round(time.Second) / time.Second)
	if s < 1 {
		s = 1
	}
	return &httpx.Error{Status: http.StatusTooManyRequests, Code: "rate_limited",
		Message: "Demasiados reportes; espera un poco", RetryAfter: s}
}
