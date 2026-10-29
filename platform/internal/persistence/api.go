package persistence

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"

	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/zones"
)

// API son las rutas de la API interna del personaje (§6): la reclamación, el guardado (uno o un
// lote), la liberación y las consultas de operación y libro sobre [ProgressStore].
type API struct {
	store *Store
	guard *zones.Guard
	log   *slog.Logger
}

// NewAPI prepara las rutas con el almacén y las comprobaciones de zones.
func NewAPI(store *Store, guard *zones.Guard) *API {
	return &API{store: store, guard: guard, log: store.log}
}

// Mount monta las rutas, todas con el token de zona.
func (a *API) Mount(r zones.Router) {
	zone := func(pattern string, h http.HandlerFunc) { r.HandleInternal(pattern, a.guard.Zone(h)) }
	zone("POST /internal/v1/claims", a.claim)
	zone("PUT /internal/v1/characters/{id}/state", a.save)
	zone("POST /internal/v1/saves", a.saveMany)
	zone("POST /internal/v1/characters/{id}/release", a.release)
	zone("GET /internal/v1/ops/{op_id}", a.op)
	zone("GET /internal/v1/characters/{id}/ledger", a.ledger)
}

func (a *API) fail(w http.ResponseWriter, r *http.Request, err error) { zones.Fail(w, r, a.log, err) }

// routeID lee el {id} de la ruta y lo deja en el registro de la petición; 0 si no vale.
func routeID(r *http.Request) int64 {
	id, err := jsonx.ParseID(r.PathValue("id"))
	if err != nil || id < 1 {
		return 0
	}
	logx.SetCharacter(r.Context(), int64(id))
	return int64(id)
}

// ClaimRequest es el cuerpo de la reclamación.
type ClaimRequest struct {
	ZoneInstanceID string   `json:"zone_instance_id"`
	TicketID       jsonx.ID `json:"ticket_id"`
	CharacterID    jsonx.ID `json:"character_id"`
}

// ClaimView es la respuesta de la reclamación (§6): ids en cadena y el reino en su código (§4.1).
type ClaimView struct {
	LeaseID        string          `json:"lease_id"`
	InstanceStatus string          `json:"instance_status"`
	Account        ClaimAccount    `json:"account"`
	Character      ClaimCharacter  `json:"character"`
	Progress       json.RawMessage `json:"progress"`
	PvP            PvP             `json:"pvp"`
}

// ClaimAccount es la cuenta en la reclamación.
type ClaimAccount struct {
	AccountID         jsonx.ID   `json:"account_id"`
	Role              string     `json:"role"`
	MutedUntilUnix    int64      `json:"muted_until_unix"`
	IgnoredAccountIDs []jsonx.ID `json:"ignored_account_ids"`
}

// ClaimCharacter es el personaje en la reclamación.
type ClaimCharacter struct {
	CharacterID jsonx.ID `json:"character_id"`
	WorldID     int      `json:"world_id"`
	Realm       int      `json:"realm"`
	Name        string   `json:"name"`
}

func (a *API) claim(w http.ResponseWriter, r *http.Request) {
	var req ClaimRequest
	if e := zones.Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return
	}
	ctx := r.Context()
	logx.SetCharacter(ctx, int64(req.CharacterID))
	inst, err := a.guard.Instance(ctx, zones.ScopeFrom(ctx), req.ZoneInstanceID, zones.OpClaim)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	if req.TicketID < 1 || req.CharacterID < 1 {
		httpx.WriteError(w, errTicketInvalid())
		return
	}
	res, err := a.store.Claim(ctx, inst.ID, int64(req.TicketID), int64(req.CharacterID))
	if err != nil {
		var e *httpx.Error
		if errors.As(err, &e) && e.Code == "account_blocked" {
			a.log.Info("reclamación de una cuenta bloqueada", "character", int64(req.CharacterID), "kind", e.Extra["kind"])
		}
		a.fail(w, r, err)
		return
	}
	logx.SetAccount(ctx, res.AccountID)
	ignored := make([]jsonx.ID, len(res.IgnoredAccounts))
	for i, id := range res.IgnoredAccounts {
		ignored[i] = jsonx.ID(id)
	}
	httpx.WriteJSON(w, http.StatusOK, ClaimView{
		LeaseID:        zones.FormatUUID(res.LeaseID),
		InstanceStatus: res.InstanceStatus,
		Account: ClaimAccount{AccountID: jsonx.ID(res.AccountID), Role: res.Role, MutedUntilUnix: res.MutedUntilUnix,
			IgnoredAccountIDs: ignored},
		Character: ClaimCharacter{CharacterID: jsonx.ID(res.CharacterID), WorldID: int(res.WorldID), Realm: int(res.Realm),
			Name: res.Name},
		Progress: res.Progress,
		PvP:      res.PvP,
	})
}

// readBody lee el cuerpo entero (1 MB como mucho): el guardado necesita los bytes tal cual para su
// huella.
func readBody(w http.ResponseWriter, r *http.Request) ([]byte, *httpx.Error) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, httpx.InternalBodyLimit))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return nil, httpx.TooLarge()
		}
		return nil, httpx.BadRequest()
	}
	return body, nil
}

// writeSaveError escribe el error de un guardado con la regla de §7.3 ([SaveError]).
func (a *API) writeSaveError(w http.ResponseWriter, r *http.Request, err error) {
	resp := SaveError(err)
	if resp == nil {
		a.fail(w, r, err)
		return
	}
	switch resp.Code {
	case "invalid_save", "seq_conflict", "stale_seq":
		// Errores nuestros (de la zona o de la plataforma): la zona expulsa y libera (§7.3).
		a.log.Warn("guardado rechazado", "req", logx.RequestID(r.Context()), "code", resp.Code,
			"check", resp.Fields["check"], "detail", resp.Fields["detail"])
	}
	httpx.WriteError(w, resp)
}

// save es PUT /internal/v1/characters/{id}/state: el sobre se lee estricto antes de tocar la base
// (400 invalid_save con check envelope); después, el alcance de su zone_instance_id (403) y el
// guardado de [Store.Save], en cualquier estado de la instancia (§6.1: los guardados finales de una
// instancia perdida o sustituida valen si el arrendamiento casa).
func (a *API) save(w http.ResponseWriter, r *http.Request) {
	raw, e := readBody(w, r)
	if e != nil {
		httpx.WriteError(w, e)
		return
	}
	id := routeID(r)
	var req SaveRequest
	var err error
	if id == 0 {
		err = envelopeError("character_id distinto del de la ruta")
	} else {
		req, err = ParseEnvelope(raw, id)
	}
	if err != nil {
		a.writeSaveError(w, r, err)
		return
	}
	ctx := r.Context()
	if _, err := a.guard.Instance(ctx, zones.ScopeFrom(ctx), zones.FormatUUID(req.InstanceID), zones.OpAny); err != nil {
		a.fail(w, r, err)
		return
	}
	res, err := a.store.Save(ctx, id, raw, req)
	if err != nil {
		a.writeSaveError(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

// SaveManyView es la respuesta de POST /internal/v1/saves: un resultado por guardado, en el orden
// del lote.
type SaveManyView struct {
	InstanceStatus string           `json:"instance_status"`
	Saves          []SaveResultView `json:"saves"`
}

// SaveResultView es el resultado de un guardado de un lote.
type SaveResultView struct {
	CharacterID jsonx.ID `json:"character_id"`
	Applied     bool     `json:"applied"`
	Duplicate   bool     `json:"duplicate"`
	SaveVersion int64    `json:"save_version"`
}

func (a *API) saveMany(w http.ResponseWriter, r *http.Request) {
	raw, e := readBody(w, r)
	if e != nil {
		httpx.WriteError(w, e)
		return
	}
	var body struct {
		ZoneInstanceID string            `json:"zone_instance_id"`
		Saves          []json.RawMessage `json:"saves"`
	}
	if err := jsonx.DecodeBytes(raw, &body); err != nil || len(body.Saves) == 0 {
		a.writeSaveError(w, r, envelopeError("el lote no se entiende o no tiene guardados"))
		return
	}
	ctx := r.Context()
	inst, err := a.guard.Instance(ctx, zones.ScopeFrom(ctx), body.ZoneInstanceID, zones.OpAny)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	raws := make([][]byte, len(body.Saves))
	reqs := make([]SaveRequest, len(body.Saves))
	for i, s := range body.Saves {
		raws[i] = s
		if reqs[i], err = ParseEnvelope(s, 0); err != nil {
			a.writeSaveError(w, r, err)
			return
		}
	}
	results, err := a.store.SaveMany(ctx, inst.ID, raws, reqs)
	if err != nil {
		a.writeSaveError(w, r, err)
		return
	}
	view := SaveManyView{InstanceStatus: results[0].InstanceStatus, Saves: make([]SaveResultView, len(results))}
	for i, res := range results {
		view.Saves[i] = SaveResultView{CharacterID: jsonx.ID(res.CharacterID), Applied: res.Applied,
			Duplicate: res.Duplicate, SaveVersion: res.SaveVersion}
	}
	httpx.WriteJSON(w, http.StatusOK, view)
}

func (a *API) release(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ZoneInstanceID string `json:"zone_instance_id"`
		LeaseID        string `json:"lease_id"`
	}
	if e := zones.Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return
	}
	ctx := r.Context()
	id := routeID(r)
	inst, err := a.guard.Instance(ctx, zones.ScopeFrom(ctx), req.ZoneInstanceID, zones.OpAny)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	leaseID, ok := zones.ParseUUID(req.LeaseID)
	if id == 0 || !ok {
		httpx.WriteError(w, zones.Validation(map[string]string{"lease_id": "invalid"}))
		return
	}
	if err := a.store.Release(ctx, id, inst.ID, leaseID); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// op es GET /internal/v1/ops/{op_id}?zone_instance_id=: ProgressStore.Op con la instancia, que
// devuelve ErrNotFound si ningún participante tiene arrendamiento en ella (404).
func (a *API) op(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	inst, err := a.guard.Instance(ctx, zones.ScopeFrom(ctx), r.URL.Query().Get("zone_instance_id"), zones.OpProgress)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	opID, err := jsonx.ParseID(r.PathValue("op_id"))
	if err != nil || opID < 1 {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	body, err := a.store.progress.Op(ctx, a.store.pool, int64(opID), inst.ID)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeRaw(w, body)
}

// ledger es GET /internal/v1/characters/{id}/ledger: solo si el personaje tiene arrendamiento en la
// instancia (character_leases.zone_instance_id, §6); si no, 404.
func (a *API) ledger(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	q := r.URL.Query()
	inst, err := a.guard.Instance(ctx, zones.ScopeFrom(ctx), q.Get("zone_instance_id"), zones.OpProgress)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	id := routeID(r)
	if id == 0 {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	limit := 20
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 100 {
			httpx.WriteError(w, zones.Validation(map[string]string{"limit": "out_of_range"}))
			return
		}
		limit = n
	}
	var before int64
	if v := q.Get("before_entry_id"); v != "" {
		entry, err := jsonx.ParseID(v)
		if err != nil {
			httpx.WriteError(w, zones.Validation(map[string]string{"before_entry_id": "invalid"}))
			return
		}
		before = int64(entry)
	}
	var inside bool
	if err := a.store.pool.QueryRow(ctx, `select exists (select 1 from character_leases
		where character_id = $1 and zone_instance_id = $2)`, id, inst.ID).Scan(&inside); err != nil {
		a.fail(w, r, err)
		return
	}
	if !inside {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	body, err := a.store.progress.Ledger(ctx, a.store.pool, id, limit, before)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeRaw(w, body)
}

// writeRaw escribe el JSON del almacén tal cual (los cuerpos de progresion.md §13.2).
func writeRaw(w http.ResponseWriter, body json.RawMessage) {
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(append(body, '\n'))
}
