// Package war es la parte de la API interna de la guerra persistente (plataforma.md §6 y §8,
// GUE-19): los registros de las fortalezas, que solo puede leer y escribir la zona a la que
// pertenecen, con versión para no pisarse, y el lote de eventos de guerra (fortress_events).
package war

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/zones"
)

var fortressIDPattern = regexp.MustCompile(`^[a-z0-9_]{1,64}$`)

// Service es el servicio de las fortalezas y los eventos de guerra.
type Service struct {
	pool  *pgxpool.Pool
	guard *zones.Guard
	clock clock.Clock
	log   *slog.Logger
}

// Options son las dependencias del servicio.
type Options struct {
	Pool  *pgxpool.Pool
	Guard *zones.Guard
	Clock clock.Clock
	Log   *slog.Logger
}

// New prepara el servicio.
func New(o Options) (*Service, error) {
	if o.Pool == nil || o.Guard == nil {
		return nil, errors.New("war: faltan dependencias")
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	return &Service{pool: o.Pool, guard: o.Guard, clock: o.Clock, log: o.Log}, nil
}

// Mount monta las rutas, todas con el token de zona.
func (s *Service) Mount(r zones.Router) {
	zone := func(pattern string, h http.HandlerFunc) { r.HandleInternal(pattern, s.guard.Zone(h)) }
	zone("GET /internal/v1/fortresses", s.list)
	zone("PUT /internal/v1/fortresses/{id}", s.put)
	zone("POST /internal/v1/war-events", s.events)
}

func (s *Service) fail(w http.ResponseWriter, r *http.Request, err error) {
	zones.Fail(w, r, s.log, err)
}

// FortressView es una fortaleza en el GET.
type FortressView struct {
	FortressID string          `json:"fortress_id"`
	Record     json.RawMessage `json:"record"`
	Version    int64           `json:"version"`
}

// Fortresses devuelve los registros de las fortalezas de la zona de la instancia en su mundo
// (lista vacía: ninguno, el primer arranque).
func (s *Service) Fortresses(ctx context.Context, inst *zones.Instance) ([]FortressView, error) {
	rows, err := s.pool.Query(ctx, `select fortress_id, record, version from fortresses
		where world_id = $1 and zone_id = $2 order by fortress_id`, inst.WorldID, inst.ZoneID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (FortressView, error) {
		var f FortressView
		err := r.Scan(&f.FortressID, &f.Record, &f.Version)
		return f, err
	})
}

func (s *Service) list(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	inst, err := s.guard.Instance(ctx, zones.ScopeFrom(ctx), r.URL.Query().Get("zone_instance_id"), zones.OpFortressGet)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	list, err := s.Fortresses(ctx, inst)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"fortresses": list})
}

// PutRequest es el cuerpo del PUT de una fortaleza.
type PutRequest struct {
	ZoneInstanceID  string          `json:"zone_instance_id"`
	ExpectedVersion jsonx.Int       `json:"expected_version"`
	Record          json.RawMessage `json:"record"`
}

func errVersionConflict(version int64) *httpx.Error {
	e := zones.Conflict("version_conflict", "El registro de la fortaleza ha cambiado")
	e.Extra = map[string]any{"version": version}
	return e
}

// Put escribe el registro de una fortaleza (§8) si su versión es la esperada, y devuelve la nueva.
// El primer PUT de un fortress_id (expected_version 0) crea su fila con la zona de la instancia; uno
// de una fortaleza de otra zona es 403 forbidden; una versión que no casa, 409 version_conflict con
// la versión actual (la zona reenvía su registro con ella).
func (s *Service) Put(ctx context.Context, inst *zones.Instance, fortressID string, expected int64,
	record json.RawMessage) (int64, error) {
	now := s.clock.Now()
	var version int64
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		for attempt := 0; attempt < 2; attempt++ {
			var zoneID string
			var current int64
			err := tx.QueryRow(ctx, `select zone_id, version from fortresses where world_id = $1 and fortress_id = $2
				for update`, inst.WorldID, fortressID).Scan(&zoneID, &current)
			if errors.Is(err, pgx.ErrNoRows) {
				if expected != 0 {
					return errVersionConflict(0)
				}
				err = tx.QueryRow(ctx, `insert into fortresses (world_id, fortress_id, zone_id, record, version, updated_at,
						updated_by)
					values ($1, $2, $3, $4, 1, $5, $6) on conflict (world_id, fortress_id) do nothing returning version`,
					inst.WorldID, fortressID, inst.ZoneID, record, now, inst.ID).Scan(&version)
				if errors.Is(err, pgx.ErrNoRows) {
					continue // otra la creó a la vez: se mira la suya
				}
				return err
			}
			if err != nil {
				return err
			}
			if zoneID != inst.ZoneID {
				return zones.ErrForbidden()
			}
			if current != expected {
				return errVersionConflict(current)
			}
			return tx.QueryRow(ctx, `update fortresses set record = $3, version = version + 1, updated_at = $4,
					updated_by = $5
				where world_id = $1 and fortress_id = $2 returning version`,
				inst.WorldID, fortressID, record, now, inst.ID).Scan(&version)
		}
		return errVersionConflict(0)
	})
	return version, err
}

func (s *Service) put(w http.ResponseWriter, r *http.Request) {
	var req PutRequest
	if e := zones.Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return
	}
	ctx := r.Context()
	inst, err := s.guard.Instance(ctx, zones.ScopeFrom(ctx), req.ZoneInstanceID, zones.OpFortressPut)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	fortressID := r.PathValue("id")
	fields := map[string]string{}
	if !fortressIDPattern.MatchString(fortressID) {
		fields["fortress_id"] = "invalid"
	}
	if req.ExpectedVersion < 0 {
		fields["expected_version"] = "invalid"
	}
	if !zones.IsJSONObject(req.Record) {
		fields["record"] = "invalid"
	}
	if len(fields) > 0 {
		httpx.WriteError(w, zones.Validation(fields))
		return
	}
	version, err := s.Put(ctx, inst, fortressID, int64(req.ExpectedVersion), req.Record)
	if err != nil {
		var e *httpx.Error
		if errors.As(err, &e) && e.Code == "forbidden" {
			s.log.Warn("PUT de una fortaleza de otra zona", "zone_instance", inst.IDString(), "fortress", fortressID)
		}
		s.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]int64{"version": version})
}

// event es un evento de guerra válido del lote.
type event struct {
	key        string
	fortressID string
	event      int16
	realm      int16
	at         time.Time
}

// Events inserta los eventos de guerra de un lote (§8: {key, fortress_id, event, realm, at_unix})
// en fortress_events con on conflict do nothing (reenviar no duplica) y devuelve las claves
// rechazadas: una entrada sin algún campo o con uno que no vale, con una key que no es de la
// instancia, o de una fortaleza que ya existe con otra zona.
func (s *Service) Events(ctx context.Context, inst *zones.Instance, entries []json.RawMessage) ([]string, error) {
	keys := zones.NewKeyChecker(inst, s.pool)
	rejected := []string{}
	var valid []event
	zoneOf := map[string]string{}
	for _, raw := range entries {
		ev, ok, err := s.parseEvent(ctx, keys, raw)
		if err != nil {
			return nil, err
		}
		if ok {
			zone, seen := zoneOf[ev.fortressID]
			if !seen {
				err := s.pool.QueryRow(ctx, `select zone_id from fortresses where world_id = $1 and fortress_id = $2`,
					inst.WorldID, ev.fortressID).Scan(&zone)
				if err != nil && !errors.Is(err, pgx.ErrNoRows) {
					return nil, err
				}
				zoneOf[ev.fortressID] = zone
			}
			// Una fortaleza que aún no tiene registro vale: el evento puede llegar antes que su
			// primer PUT, que va por otra cola (§6).
			ok = zone == "" || zone == inst.ZoneID
		}
		if !ok {
			key := zones.EntryKey(raw)
			s.log.Warn("evento de guerra rechazado", "zone_instance", inst.IDString(), "key", key)
			rejected = append(rejected, key)
			continue
		}
		valid = append(valid, ev)
	}
	rows := make([][]any, len(valid))
	validKeys := make([]string, len(valid))
	for i, ev := range valid {
		rows[i] = []any{inst.WorldID, ev.fortressID, ev.event, ev.realm, ev.at, inst.ID, ev.key}
		validKeys[i] = ev.key
	}
	failed, err := zones.InsertEach(ctx, s.pool, `insert into fortress_events (world_id, fortress_id, event, realm, at,
		zone_instance_id, event_key) values ($1, $2, $3, $4, $5, $6, $7) on conflict (event_key) do nothing`, rows, validKeys)
	if err != nil {
		return nil, err
	}
	for _, key := range failed {
		s.log.Warn("evento de guerra rechazado por la base", "zone_instance", inst.IDString(), "key", key)
	}
	return append(rejected, failed...), nil
}

func (s *Service) parseEvent(ctx context.Context, keys *zones.KeyChecker, raw json.RawMessage) (event, bool, error) {
	e, ok := zones.ParseEntry(raw, "key", "fortress_id", "event", "realm", "at_unix")
	if !ok {
		return event{}, false, nil
	}
	var ev event
	key, okKey := e.String("key")
	fortress, okFortress := e.String("fortress_id")
	kind, okEvent := e.Int("event")
	realm, okRealm := e.Int("realm")
	at, okAt := e.Int("at_unix")
	if !okKey || !okFortress || !okEvent || !okRealm || !okAt || !fortressIDPattern.MatchString(fortress) ||
		kind < 1 || kind > 7 || realm < 0 || realm > 3 || at < 0 || at > zones.MaxUnix {
		return event{}, false, nil
	}
	valid, err := keys.Valid(ctx, key, false)
	if err != nil || !valid {
		return event{}, false, err
	}
	ev = event{key: key, fortressID: fortress, event: int16(kind), realm: int16(realm), at: time.Unix(at, 0).UTC()}
	return ev, true, nil
}

func (s *Service) events(w http.ResponseWriter, r *http.Request) {
	batch, e := zones.DecodeBatch(w, r, "events")
	if e != nil {
		httpx.WriteError(w, e)
		return
	}
	ctx := r.Context()
	inst, err := s.guard.Instance(ctx, zones.ScopeFrom(ctx), batch.InstanceID, zones.OpAny)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	rejected, err := s.Events(ctx, inst, batch.Entries)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	zones.BatchResponse(w, rejected)
}
