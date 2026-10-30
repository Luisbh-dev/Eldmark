package characters

import (
	"net/http"
	"strconv"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/logx"
)

// Router es donde se montan las rutas: *app.App.
type Router interface {
	HandlePublic(pattern string, h http.Handler)
}

// API son las rutas de personajes de la API pública (§4.4 y §4.5).
type API struct {
	s *Service
}

// NewAPI prepara las rutas del servicio.
func NewAPI(s *Service) *API { return &API{s: s} }

// Mount monta las rutas, todas con la regla del 426 y la sesión de juego de auth
// (accounts.API.RequireSession sin la sesión de privacidad: una cuenta sancionada recibe 403 con
// el motivo, también en enter).
func (a *API) Mount(r Router, auth *accounts.API) {
	game := func(pattern string, h http.HandlerFunc) {
		r.HandlePublic(pattern, httpx.RequireProtocol(a.s.minProtocol, auth.RequireSession(false, h)))
	}
	game("GET /v1/worlds/{w}/characters", a.list)
	game("GET /v1/worlds/{w}/name-check", a.nameCheck)
	game("POST /v1/worlds/{w}/characters", a.create)
	game("DELETE /v1/characters/{id}", a.delete)
	game("POST /v1/characters/{id}/restore", a.restore)
	game("POST /v1/characters/{id}/rename", a.rename)
	game("POST /v1/characters/{id}/enter", a.enter)
}

func (a *API) fail(w http.ResponseWriter, r *http.Request, err error) { httpx.Fail(w, r, a.s.log, err) }

// world lee el {w} de la ruta: un mundo que no se entiende es 404, como uno que no existe.
func world(r *http.Request) (int16, bool) {
	n, err := strconv.ParseInt(r.PathValue("w"), 10, 16)
	if err != nil || n < 1 {
		return 0, false
	}
	return int16(n), true
}

// character lee el {id} de la ruta y lo deja en el registro de la petición.
func character(r *http.Request) (int64, bool) {
	id, err := jsonx.ParseID(r.PathValue("id"))
	if err != nil || id < 1 {
		return 0, false
	}
	logx.SetCharacter(r.Context(), int64(id))
	return int64(id), true
}

func (a *API) meta(r *http.Request) accounts.ClientMeta {
	return accounts.ClientMeta{IP: httpx.ClientIP(r, a.s.cfg.TrustedProxies), UserAgent: r.UserAgent(),
		Protocol: httpx.ClientProtocol(r)}
}

// decode lee el cuerpo JSON (16 KB, estricto); si falla, escribe el error y devuelve false.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if e := httpx.DecodeJSON(w, r, httpx.PublicBodyLimit, v); e != nil {
		httpx.WriteError(w, e)
		return false
	}
	return true
}

func (a *API) list(w http.ResponseWriter, r *http.Request) {
	worldID, ok := world(r)
	if !ok {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	v, err := a.s.List(r.Context(), accounts.SessionFrom(r.Context()), worldID)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, v)
}

func (a *API) nameCheck(w http.ResponseWriter, r *http.Request) {
	worldID, ok := world(r)
	if !ok {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	q := r.URL.Query()
	if len(q["name"]) != 1 {
		httpx.WriteError(w, errValidation(map[string]string{"name": "required"}))
		return
	}
	v, err := a.s.NameCheck(r.Context(), accounts.SessionFrom(r.Context()), worldID, q.Get("name"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, v)
}

func (a *API) create(w http.ResponseWriter, r *http.Request) {
	worldID, ok := world(r)
	if !ok {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	var req CreateRequest
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s.Create(r.Context(), accounts.SessionFrom(r.Context()), worldID, req, a.meta(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	logx.SetCharacter(r.Context(), int64(v.CharacterID))
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"character": v})
}

func (a *API) delete(w http.ResponseWriter, r *http.Request) {
	id, ok := character(r)
	if !ok {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	var req struct {
		ConfirmName *string `json:"confirm_name"`
	}
	if !decode(w, r, &req) {
		return
	}
	until, err := a.s.Delete(r.Context(), accounts.SessionFrom(r.Context()), id, req.ConfirmName, a.meta(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]int64{"restore_until": until.Unix()})
}

func (a *API) restore(w http.ResponseWriter, r *http.Request) {
	id, ok := character(r)
	if !ok {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	v, err := a.s.Restore(r.Context(), accounts.SessionFrom(r.Context()), id)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"character": v})
}

func (a *API) rename(w http.ResponseWriter, r *http.Request) {
	id, ok := character(r)
	if !ok {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	var req struct {
		Name *string `json:"name"`
	}
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s.Rename(r.Context(), accounts.SessionFrom(r.Context()), id, req.Name)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"character": v})
}

func (a *API) enter(w http.ResponseWriter, r *http.Request) {
	id, ok := character(r)
	if !ok {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	v, err := a.s.Enter(r.Context(), accounts.SessionFrom(r.Context()), id)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, v)
}
