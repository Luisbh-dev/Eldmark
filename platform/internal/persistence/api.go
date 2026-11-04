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

// API is the routes of the character's internal API (§6): the claim, the save (one or a batch), the
// release and the operation and ledger queries over [ProgressStore].
type API struct {
	store *Store
	guard *zones.Guard
	log   *slog.Logger
}

// NewAPI prepares the routes with the store and the checks from zones.
func NewAPI(store *Store, guard *zones.Guard) *API {
	return &API{store: store, guard: guard, log: store.log}
}

// Mount mounts the routes, all with the zone token.
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

// routeID reads the route's {id} and leaves it in the request log; 0 if it is not valid.
func routeID(r *http.Request) int64 {
	id, err := jsonx.ParseID(r.PathValue("id"))
	if err != nil || id < 1 {
		return 0
	}
	logx.SetCharacter(r.Context(), int64(id))
	return int64(id)
}

// ClaimRequest is the claim's body.
type ClaimRequest struct {
	ZoneInstanceID string   `json:"zone_instance_id"`
	TicketID       jsonx.ID `json:"ticket_id"`
	CharacterID    jsonx.ID `json:"character_id"`
}

// ClaimView is the claim's response (§6): string ids and the realm in its code (§4.1).
type ClaimView struct {
	LeaseID        string          `json:"lease_id"`
	InstanceStatus string          `json:"instance_status"`
	Account        ClaimAccount    `json:"account"`
	Character      ClaimCharacter  `json:"character"`
	Progress       json.RawMessage `json:"progress"`
	PvP            PvP             `json:"pvp"`
}

// ClaimAccount is the account in the claim.
type ClaimAccount struct {
	AccountID         jsonx.ID   `json:"account_id"`
	Role              string     `json:"role"`
	MutedUntilUnix    int64      `json:"muted_until_unix"`
	IgnoredAccountIDs []jsonx.ID `json:"ignored_account_ids"`
	// Warnings are the notices the account has not yet seen (§9.5: on entering, NOTICE with the
	// reason), with the text composed by the platform; empty list if there are none.
	Warnings []ClaimWarning `json:"warnings"`
}

// ClaimWarning is a pending notice in the claim.
type ClaimWarning struct {
	SanctionID jsonx.ID `json:"sanction_id"`
	Text       string   `json:"text"`
	AtUnix     int64    `json:"at_unix"`
}

// ClaimCharacter is the character in the claim.
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
	warnings := make([]ClaimWarning, len(res.Warnings))
	for i, w := range res.Warnings {
		warnings[i] = ClaimWarning{SanctionID: jsonx.ID(w.SanctionID), Text: w.Text(), AtUnix: w.At.Unix()}
	}
	httpx.WriteJSON(w, http.StatusOK, ClaimView{
		LeaseID:        zones.FormatUUID(res.LeaseID),
		InstanceStatus: res.InstanceStatus,
		Account: ClaimAccount{AccountID: jsonx.ID(res.AccountID), Role: res.Role, MutedUntilUnix: res.MutedUntilUnix,
			IgnoredAccountIDs: ignored, Warnings: warnings},
		Character: ClaimCharacter{CharacterID: jsonx.ID(res.CharacterID), WorldID: int(res.WorldID), Realm: int(res.Realm),
			Name: res.Name},
		Progress: res.Progress,
		PvP:      res.PvP,
	})
}

// readBody reads the whole body (1 MB at most): the save needs the bytes as is for its fingerprint.
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

// writeSaveError writes a save's error with the §7.3 rule ([SaveError]).
func (a *API) writeSaveError(w http.ResponseWriter, r *http.Request, err error) {
	resp := SaveError(err)
	if resp == nil {
		a.fail(w, r, err)
		return
	}
	switch resp.Code {
	case "invalid_save", "seq_conflict", "stale_seq":
		// Our own errors (from the zone or the platform): the zone kicks out and releases (§7.3).
		a.log.Warn("guardado rechazado", "req", logx.RequestID(r.Context()), "code", resp.Code,
			"check", resp.Fields["check"], "detail", resp.Fields["detail"])
	}
	httpx.WriteError(w, resp)
}

// save is PUT /internal/v1/characters/{id}/state: the envelope is read strictly before touching the
// database (400 invalid_save with check envelope); then, the scope of its zone_instance_id (403) and
// [Store.Save]'s save, in any state of the instance (§6.1: the final saves of a lost or replaced
// instance are valid if the lease matches).
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

// SaveManyView is the response of POST /internal/v1/saves: one result per save, in the batch's
// order.
type SaveManyView struct {
	InstanceStatus string           `json:"instance_status"`
	Saves          []SaveResultView `json:"saves"`
}

// SaveResultView is the result of one save in a batch.
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

// op is GET /internal/v1/ops/{op_id}?zone_instance_id=: ProgressStore.Op with the instance, which
// returns ErrNotFound if no participant has a lease on it (404).
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

// ledger is GET /internal/v1/characters/{id}/ledger: only if the character has a lease on the
// instance (character_leases.zone_instance_id, §6); otherwise, 404.
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

// writeRaw writes the store's JSON as is (the bodies of progresion.md §13.2).
func writeRaw(w http.ResponseWriter, body json.RawMessage) {
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(append(body, '\n'))
}
