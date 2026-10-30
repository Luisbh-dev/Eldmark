package social

import (
	"context"
	"net/http"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/zones"
)

// IgnoreRequest es el cuerpo de POST y DELETE /internal/v1/ignores (§9.3). No lleva world_id: el
// nombre se resuelve en el mundo de la instancia.
type IgnoreRequest struct {
	ZoneInstanceID string   `json:"zone_instance_id"`
	CharacterID    jsonx.ID `json:"character_id"`
	TargetName     string   `json:"target_name"`
}

// IgnoreView es la respuesta de POST /internal/v1/ignores.
type IgnoreView struct {
	IgnoredAccountID jsonx.ID `json:"ignored_account_id"`
	Name             string   `json:"name"`
}

func errIgnoreListFull() *httpx.Error {
	return zones.Conflict("ignore_list_full", "Tu lista de ignorados está llena")
}

// Ignore guarda que la cuenta del personaje (con arrendamiento en la instancia; si no, 403) ignora
// a la cuenta del personaje llamado name en el mundo de la instancia (404 si no hay nadie; 400 si
// es la propia cuenta). Hasta [MaxIgnores] cuentas (409 ignore_list_full); volver a ignorar a la
// misma cuenta actualiza el nombre.
func (s *Service) Ignore(ctx context.Context, inst *zones.Instance, characterID int64, name string) (*IgnoreView, error) {
	var view *IgnoreView
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		account, _, ok, err := inside(ctx, tx, characterID, inst)
		if err != nil {
			return err
		}
		if !ok {
			return zones.ErrForbidden()
		}
		target, err := s.resolve(ctx, tx, inst.WorldID, name)
		if err != nil {
			return err
		}
		if target == nil {
			return errTargetNotFound()
		}
		if target.AccountID == account {
			return zones.Validation(map[string]string{"target_name": "self"})
		}
		// La fila de la cuenta pone en serie las altas de la misma lista (el tope de 100).
		if _, err := tx.Exec(ctx, `select 1 from accounts where account_id = $1 for no key update`, account); err != nil {
			return err
		}
		var count int
		var already bool
		if err := tx.QueryRow(ctx, `select count(*), coalesce(bool_or(ignored_account_id = $2), false) from ignores
			where account_id = $1`, account, target.AccountID).Scan(&count, &already); err != nil {
			return err
		}
		if !already && count >= MaxIgnores {
			return errIgnoreListFull()
		}
		if _, err := tx.Exec(ctx, `insert into ignores (account_id, ignored_account_id, ignored_character_id,
				ignored_name, created_at) values ($1, $2, $3, $4, $5)
			on conflict (account_id, ignored_account_id) do update set ignored_character_id = excluded.ignored_character_id,
				ignored_name = excluded.ignored_name`, account, target.AccountID, target.ID, target.Name, s.clock.Now()); err != nil {
			return err
		}
		view = &IgnoreView{IgnoredAccountID: jsonx.ID(target.AccountID), Name: target.Name}
		return nil
	})
	return view, err
}

// Unignore deja de ignorar: borra la fila de la cuenta del personaje llamado name en el mundo de la
// instancia y la que guardó ese nombre (puede haber cambiado de nombre o de dueño). Sin ninguna,
// nada (204).
func (s *Service) Unignore(ctx context.Context, inst *zones.Instance, characterID int64, name string) error {
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		account, _, ok, err := inside(ctx, tx, characterID, inst)
		if err != nil {
			return err
		}
		if !ok {
			return zones.ErrForbidden()
		}
		rows, err := tx.Query(ctx, `select ignored_account_id, ignored_name from ignores where account_id = $1`, account)
		if err != nil {
			return err
		}
		type ignored struct {
			account int64
			name    string
		}
		list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (ignored, error) {
			var i ignored
			err := r.Scan(&i.account, &i.name)
			return i, err
		})
		if err != nil {
			return err
		}
		key := s.names.NormalizeKey(name)
		target, err := s.resolve(ctx, tx, inst.WorldID, name)
		if err != nil {
			return err
		}
		var drop []int64
		for _, i := range list {
			if (target != nil && i.account == target.AccountID) || (key != "" && s.names.NormalizeKey(i.name) == key) {
				drop = append(drop, i.account)
			}
		}
		if len(drop) == 0 {
			return nil
		}
		_, err = tx.Exec(ctx, `delete from ignores where account_id = $1 and ignored_account_id = any($2)`, account, drop)
		return err
	})
}

func (s *Service) decodeIgnore(w http.ResponseWriter, r *http.Request) (*zones.Instance, *IgnoreRequest, bool) {
	var req IgnoreRequest
	if e := zones.Decode(w, r, &req); e != nil {
		httpx.WriteError(w, e)
		return nil, nil, false
	}
	ctx := r.Context()
	inst, err := s.guard.Instance(ctx, zones.ScopeFrom(ctx), req.ZoneInstanceID, zones.OpModeration)
	if err != nil {
		s.fail(w, r, err)
		return nil, nil, false
	}
	if req.CharacterID < 1 || req.TargetName == "" || len(req.TargetName) > 64 {
		httpx.WriteError(w, zones.Validation(map[string]string{"target_name": "invalid"}))
		return nil, nil, false
	}
	return inst, &req, true
}

func (s *Service) ignore(w http.ResponseWriter, r *http.Request) {
	inst, req, ok := s.decodeIgnore(w, r)
	if !ok {
		return
	}
	view, err := s.Ignore(r.Context(), inst, int64(req.CharacterID), req.TargetName)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, view)
}

func (s *Service) unignore(w http.ResponseWriter, r *http.Request) {
	inst, req, ok := s.decodeIgnore(w, r)
	if !ok {
		return
	}
	if err := s.Unignore(r.Context(), inst, int64(req.CharacterID), req.TargetName); err != nil {
		s.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
