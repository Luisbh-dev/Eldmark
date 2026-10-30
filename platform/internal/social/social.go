// Package social es la parte de la API interna de lo social y la moderación (plataforma.md §6,
// §9, SOC-14 a SOC-18): los lotes de chat y de auditoría de la zona (con rechazo por entrada y
// validados contra la instancia que los manda), los ignorados, los reportes y las sanciones que
// pide un GM desde la zona, que la plataforma autoriza.
//
// El mundo lo pone siempre la instancia: los cuerpos no traen world_id (un campo desconocido, 400)
// y los nombres se resuelven en el mundo de la instancia, así que una zona no alcanza a nadie de
// otro mundo.
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

// Topes de §9.3 y §9.4.
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

// Options son las dependencias del servicio.
type Options struct {
	Pool  *pgxpool.Pool
	Guard *zones.Guard
	Clock clock.Clock
	Log   *slog.Logger
	// Names son las reglas de los nombres (la clave normalizada); nil: las de progression_rules.json.
	Names *names.Rules
}

// Service es el servicio de lo social de la API interna.
type Service struct {
	pool  *pgxpool.Pool
	guard *zones.Guard
	clock clock.Clock
	log   *slog.Logger
	names *names.Rules
}

// New prepara el servicio.
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

// Mount monta las rutas, todas con el token de zona.
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

// character es un personaje resuelto por su nombre en un mundo.
type character struct {
	ID        int64
	AccountID int64
	Name      string
	Role      string
}

// resolve busca el personaje vivo (ni borrado ni purgado) con ese nombre en el mundo, por la clave
// de NameRules; nil si no hay ninguno.
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

// inside devuelve la cuenta y el rol del personaje si tiene arrendamiento en la instancia
// (character_leases.zone_instance_id, §9.3–§9.5); si no, ok es false.
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
