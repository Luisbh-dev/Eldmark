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

// Router es donde se montan las rutas de la API interna: *app.App.
type Router interface {
	HandleInternal(pattern string, h http.Handler)
}

// Guard hace las comprobaciones comunes de §6.1 en el orden fijo: (1) el token, (2) el alcance de
// la instancia y (3) su estado según la petición. Las demás (arrendamiento, seq, contenido) son de
// cada ruta.
type Guard struct {
	registry *Registry
	pool     *pgxpool.Pool
	log      *slog.Logger
}

// NewGuard prepara las comprobaciones con los tokens de la configuración.
func NewGuard(registry *Registry, pool *pgxpool.Pool, log *slog.Logger) *Guard {
	if log == nil {
		log = logx.Discard()
	}
	return &Guard{registry: registry, pool: pool, log: log}
}

type scopeKey struct{}

// ScopeFrom devuelve el alcance del token de la petición (dentro de [Guard.Zone]).
func ScopeFrom(ctx context.Context) Scope {
	s, _ := ctx.Value(scopeKey{}).(Scope)
	return s
}

// Zone exige «Authorization: Bearer <token de zona>» de un despliegue de ELDMARK_ZONE_TOKENS (si
// no, 401 bad_token) y deja su alcance en el contexto ([ScopeFrom]).
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

// Instance lee la instancia id de la petición y aplica los pasos (2) y (3) de §6.1: un id que no
// es un UUID canónico es 400 validation; una instancia que no existe o no es del alcance, 403
// forbidden; un estado que no admite la petición, su 409.
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

// Decode lee el cuerpo JSON de la API interna (1 MB como mucho, estricto): 413 o 400
// bad_request.
func Decode(w http.ResponseWriter, r *http.Request, v any) *httpx.Error {
	return httpx.DecodeJSON(w, r, httpx.InternalBodyLimit, v)
}
