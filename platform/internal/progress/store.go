package progress

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
)

// Store es el almacén del progreso en PostgreSQL (progresion.md §13.2, P7): implementa
// persistence.ProgressStore sobre las tablas de 0010_progress. Todo corre en la transacción o la conexión de
// quien llama; las reglas son de solo lectura, así que vale entre gorrutinas.
type Store struct {
	rules *Rules
	now   func() time.Time
}

// New prepara el almacén con las reglas exportadas y un reloj (nil: time.Now). El reloj da saved_at, la
// fecha de las operaciones y los apuntes, el «ahora» de S2 y S7 y el año de la retención.
func New(rules *Rules, now func() time.Time) *Store {
	if now == nil {
		now = time.Now
	}
	return &Store{rules: rules, now: now}
}

var _ persistence.ProgressStore = (*Store)(nil)

// Create implementa persistence.ProgressStore: el progreso de un personaje recién creado, con los valores
// por defecto de §3.3 y un saldo a 0 de cada moneda. worldID no se guarda (sale de characters).
func (s *Store) Create(ctx context.Context, tx pgx.Tx, _ int16, characterID int64, p persistence.CreateParams) error {
	if _, err := tx.Exec(ctx, `insert into character_progress (character_id, race_id, appearance, starter_template_id,
			bag_slots) values ($1, $2, $3, $4, $5)`, characterID, p.RaceID, p.Appearance[:], p.StarterTemplateID,
		s.rules.Containers.Bag.DefaultSlots); err != nil {
		return err
	}
	for _, c := range s.rules.Currencies {
		if _, err := tx.Exec(ctx, `insert into character_wallets (character_id, currency) values ($1, $2)`,
			characterID, c.Code); err != nil {
			return err
		}
	}
	return nil
}

// record es el ProgressRecord de la reclamación (progresion.md §3.4), con las claves en el orden de la zona
// (encoding/json las escribe en el del struct; el orden no importa a nadie, pero así el diff se lee).
type record struct {
	ActiveWeaponSlot  int            `json:"active_weapon_slot"`
	Appearance        string         `json:"appearance"`
	BagSlots          int            `json:"bag_slots"`
	Health            *int64         `json:"health"`
	Items             []recordItem   `json:"items"`
	Level             int            `json:"level"`
	Location          *recordPlace   `json:"location"`
	PlayedSeconds     int64          `json:"played_seconds"`
	ProgressFormat    int            `json:"progress_format"`
	RaceID            string         `json:"race_id"`
	RealmPoints       int64          `json:"realm_points"`
	StarterGranted    bool           `json:"starter_granted"`
	StarterTemplateID string         `json:"starter_template_id"`
	Timers            []recordTimer  `json:"timers"`
	Wallets           []recordWallet `json:"wallets"`
	XPTotal           int64          `json:"xp_total"`
}

type recordPlace struct {
	Channel     int     `json:"channel"`
	InCombat    bool    `json:"in_combat"`
	SavedAtUnix int64   `json:"saved_at_unix"`
	X           float32 `json:"x"`
	Y           float32 `json:"y"`
	Yaw         float32 `json:"yaw"`
	Z           float32 `json:"z"`
	ZoneID      string  `json:"zone_id"`
}

type recordItem struct {
	Affixes    []int32  `json:"affixes"`
	Bound      bool     `json:"bound"`
	Container  int16    `json:"container"`
	Count      int32    `json:"count"`
	DefID      string   `json:"def_id"`
	Durability *int16   `json:"durability"`
	Rarity     int16    `json:"rarity"`
	Seed       jsonx.ID `json:"seed"`
	Slot       int16    `json:"slot"`
	UID        jsonx.ID `json:"uid"`
}

type recordTimer struct {
	EndsAtUnix int64  `json:"ends_at_unix"`
	Key        string `json:"key"`
}

type recordWallet struct {
	Balance  int64 `json:"balance"`
	Currency int   `json:"currency"`
}

// Load implementa persistence.ProgressStore: el registro de §3.4 desde las tablas, con
// location.saved_at_unix de saved_at, un saldo por moneda de las reglas (0 sin fila), los objetos vivos por
// contenedor y ranura y los temporizadores por clave; persistence.ErrNotFound si el personaje no tiene
// progreso (no existe o está purgado).
func (s *Store) Load(ctx context.Context, q persistence.Querier, characterID int64) (json.RawMessage, error) {
	rec, err := s.loadRecord(ctx, q, characterID)
	if err != nil {
		return nil, err
	}
	return json.Marshal(rec)
}

func (s *Store) loadRecord(ctx context.Context, q persistence.Querier, characterID int64) (*record, error) {
	rec := &record{ProgressFormat: FormatVersion}
	var appearance []byte
	var health *int32
	var zoneID *string
	var channel *int16
	var x, y, z, yaw *float32
	var inCombat bool
	var savedAt *time.Time
	var level, bagSlots, activeSlot int16
	err := q.QueryRow(ctx, `select race_id, appearance, starter_template_id, starter_granted, level, xp_total,
			realm_points, played_seconds, bag_slots, health, active_weapon_slot, last_zone_id, last_channel, pos_x,
			pos_y, pos_z, yaw, last_in_combat, saved_at
		from character_progress where character_id = $1`, characterID).Scan(&rec.RaceID, &appearance,
		&rec.StarterTemplateID, &rec.StarterGranted, &level, &rec.XPTotal, &rec.RealmPoints, &rec.PlayedSeconds,
		&bagSlots, &health, &activeSlot, &zoneID, &channel, &x, &y, &z, &yaw, &inCombat, &savedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, persistence.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rec.Appearance = base64.StdEncoding.EncodeToString(appearance)
	rec.Level, rec.BagSlots, rec.ActiveWeaponSlot = int(level), int(bagSlots), int(activeSlot)
	if health != nil {
		h := int64(*health)
		rec.Health = &h
	}
	if zoneID != nil {
		place := &recordPlace{ZoneID: *zoneID, InCombat: inCombat}
		if channel != nil {
			place.Channel = int(*channel)
		}
		for _, f := range []struct {
			src *float32
			dst *float32
		}{{x, &place.X}, {y, &place.Y}, {z, &place.Z}, {yaw, &place.Yaw}} {
			if f.src != nil {
				*f.dst = *f.src
			}
		}
		if savedAt != nil {
			place.SavedAtUnix = savedAt.Unix()
		}
		rec.Location = place
	}
	balances := map[int]int64{}
	rows, err := q.Query(ctx, `select currency, balance from character_wallets where character_id = $1`, characterID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var currency int16
		var balance int64
		if err := rows.Scan(&currency, &balance); err != nil {
			rows.Close()
			return nil, err
		}
		balances[int(currency)] = balance
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rec.Wallets = make([]recordWallet, 0, len(s.rules.Currencies))
	for _, c := range s.rules.Currencies {
		rec.Wallets = append(rec.Wallets, recordWallet{Currency: c.Code, Balance: balances[c.Code]})
	}
	rows, err = q.Query(ctx, `select uid, def_id, container, slot, count, durability, rarity, bound, seed, affixes
		from item_instances where character_id = $1 and retired_at is null order by container, slot`, characterID)
	if err != nil {
		return nil, err
	}
	rec.Items, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (recordItem, error) {
		var it recordItem
		var uid, seed int64
		err := row.Scan(&uid, &it.DefID, &it.Container, &it.Slot, &it.Count, &it.Durability, &it.Rarity, &it.Bound,
			&seed, &it.Affixes)
		it.UID, it.Seed = jsonx.ID(uid), jsonx.ID(seed)
		if it.Affixes == nil {
			it.Affixes = []int32{}
		}
		return it, err
	})
	if err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `select key, ends_at from character_timers where character_id = $1 order by key`,
		characterID)
	if err != nil {
		return nil, err
	}
	rec.Timers, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (recordTimer, error) {
		var t recordTimer
		var endsAt time.Time
		err := row.Scan(&t.Key, &endsAt)
		t.EndsAtUnix = endsAt.Unix()
		return t, err
	})
	return rec, err
}

// Summaries implementa persistence.ProgressStore: raza, apariencia, nivel, última zona y canal y tiempo
// jugado de los personajes con progreso (los que no tienen fila no salen).
func (s *Store) Summaries(ctx context.Context, q persistence.Querier, characterIDs []int64) (map[int64]persistence.Summary, error) {
	out := make(map[int64]persistence.Summary, len(characterIDs))
	if len(characterIDs) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `select character_id, race_id, appearance, level, coalesce(last_zone_id, ''),
			coalesce(last_channel, 0), played_seconds
		from character_progress where character_id = any($1)`, characterIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var sum persistence.Summary
		var appearance []byte
		var level, channel int16
		if err := rows.Scan(&id, &sum.RaceID, &appearance, &level, &sum.LastZoneID, &channel,
			&sum.PlayedSeconds); err != nil {
			return nil, err
		}
		if len(appearance) != len(sum.Appearance) {
			return nil, fmt.Errorf("progress: la apariencia del personaje %d no tiene 8 B", id)
		}
		copy(sum.Appearance[:], appearance)
		sum.Level, sum.LastChannel = int(level), int(channel)
		out[id] = sum
	}
	return out, rows.Err()
}

// Purge implementa persistence.ProgressStore (progresion.md §3.5): borra el estado del progreso (progreso,
// saldos, objetos vivos y retirados, temporizadores) y deja lo de solo añadir, que se queda con la lápida de
// characters hasta la retención. La plataforma la llama con el arrendamiento y la fila del personaje
// bloqueados (plataforma.md §11.2).
func (s *Store) Purge(ctx context.Context, tx pgx.Tx, characterID int64) error {
	for _, table := range []string{"character_timers", "item_instances", "character_wallets", "character_progress"} {
		if _, err := tx.Exec(ctx, "delete from "+table+" where character_id = $1", characterID); err != nil {
			return err
		}
	}
	return nil
}
