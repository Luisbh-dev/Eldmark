package zones

import (
	"context"
	"log/slog"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
)

// Router is where the internal API's routes are mounted: *app.App.
type Router interface {
	HandleInternal(pattern string, h http.Handler)
}

// Guard performs the common checks of §6.1 in the fixed order: (1) the token, (2) the instance's
// scope and (3) its state according to the request. The rest (lease, seq, content) belong to each route.
type Guard struct {
	registry *Registry
	pool     *pgxpool.Pool
	log      *slog.Logger
}

// NewGuard prepares the checks with the configuration's tokens.
func NewGuard(registry *Registry, pool *pgxpool.Pool, log *slog.Logger) *Guard {
	if log == nil {
		log = logx.Discard()
	}
	return &Guard{registry: registry, pool: pool, log: log}
}

type scopeKey struct{}

// ScopeFrom returns the scope of the request's token (inside [Guard.Zone]).
func ScopeFrom(ctx context.Context) Scope {
	s, _ := ctx.Value(scopeKey{}).(Scope)
	return s
}

// Zone requires "Authorization: Bearer <zone token>" from a deployment in ELDMARK_ZONE_TOKENS
// (otherwise 401 bad_token) and leaves its scope in the context ([ScopeFrom]).
func (g *Guard) Zone(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		scheme, token, found := strings.Cut(r.Header.Get("Authorization"), " ")
		if !found || !strings.EqualFold(scheme, "Bearer") {
			httpx.WriteError(w, ErrBadToken())
			return
		}
		scope, ok := g.registry.Authenticate(strings.TrimSpace(token))
		if !ok {
			httpx.WriteError(w, ErrBadToken())
			return
		}
		h.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), scopeKey{}, scope)))
	})
}

// Instance reads the request's instance id and applies steps (2) and (3) of §6.1: an id that is
// not a canonical UUID is 400 validation; an instance that does not exist or is not in scope, 403
// forbidden; a state that does not admit the request, its 409.
func (g *Guard) Instance(ctx context.Context, scope Scope, id string, op Op) (*Instance, error) {
	u, ok := ParseUUID(id)
	if !ok {
		return nil, Validation(map[string]string{"zone_instance_id": "invalid"})
	}
	inst, err := LoadInstance(ctx, g.pool, u, false)
	if err != nil {
		return nil, err
	}
	if inst == nil || !inst.InScope(scope) {
		return nil, ErrForbidden()
	}
	if e := inst.Check(op); e != nil {
		return nil, e
	}
	return inst, nil
}

// Decode reads the internal API's JSON body (1 MB at most, strict): 413 or 400 bad_request.
func Decode(w http.ResponseWriter, r *http.Request, v any) *httpx.Error {
	return httpx.DecodeJSON(w, r, httpx.InternalBodyLimit, v)
}
