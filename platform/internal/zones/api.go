package zones

import (
	"net/http"

	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
)

// API son las rutas de las instancias de zona y de los bloques de ids (§6).
type API struct {
	s *Service
}

// NewAPI prepara las rutas del servicio.
func NewAPI(s *Service) *API { return &API{s: s} }

// Mount monta las rutas, todas con el token de zona.
func (a *API) Mount(r Router) {
	zone := func(pattern string, h http.HandlerFunc) { r.HandleInternal(pattern, a.s.guard.Zone(h)) }
	zone("POST /internal/v1/zone-instances", a.register)
	zone("POST /internal/v1/zone-instances/{id}/live", a.live)
	zone("POST /internal/v1/zone-instances/{id}/heartbeat", a.heartbeat)
	zone("DELETE /internal/v1/zone-instances/{id}", a.stop)
	zone("POST /internal/v1/id-blocks", a.idBlock)
}

func (a *API) fail(w http.ResponseWriter, r *http.Request, err error) { Fail(w, r, a.s.log, err) }

func (a *API) register(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if e := Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return
	}
	res, err := a.s.Register(r.Context(), ScopeFrom(r.Context()), req)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

// instance lee la instancia {id} de la ruta para op (los pasos 2 y 3 de §6.1).
func (a *API) instance(w http.ResponseWriter, r *http.Request, op Op) (*Instance, bool) {
	inst, err := a.s.guard.Instance(r.Context(), ScopeFrom(r.Context()), r.PathValue("id"), op)
	if err != nil {
		a.fail(w, r, err)
		return nil, false
	}
	return inst, true
}

func (a *API) live(w http.ResponseWriter, r *http.Request) {
	inst, ok := a.instance(w, r, OpAny)
	if !ok {
		return
	}
	if err := a.s.Live(r.Context(), inst); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) heartbeat(w http.ResponseWriter, r *http.Request) {
	inst, ok := a.instance(w, r, OpHeartbeat)
	if !ok {
		return
	}
	var req HeartbeatRequest
	if e := Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return
	}
	res, err := a.s.Heartbeat(r.Context(), inst, req)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (a *API) stop(w http.ResponseWriter, r *http.Request) {
	inst, ok := a.instance(w, r, OpAny)
	if !ok {
		return
	}
	if err := a.s.Stop(r.Context(), inst); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// IDBlockView es la respuesta de POST /internal/v1/id-blocks: el primero en cadena (§4.1).
type IDBlockView struct {
	First jsonx.ID `json:"first"`
	Count int      `json:"count"`
}

func (a *API) idBlock(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ZoneInstanceID string `json:"zone_instance_id"`
	}
	if e := Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return
	}
	inst, err := a.s.guard.Instance(r.Context(), ScopeFrom(r.Context()), req.ZoneInstanceID, OpIDBlock)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	first, err := a.s.IDBlock(r.Context(), inst)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, IDBlockView{First: jsonx.ID(first), Count: BlockSize})
}
