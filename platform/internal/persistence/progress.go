// Package persistence es la persistencia del personaje en la plataforma (plataforma.md §7, TEC-25).
//
// Este archivo es la frontera con docs/progresion.md (plataforma.md §7.5, progresion.md §13.2): la
// interfaz [ProgressStore] con sus tipos y errores, y la validación de la creación
// ([CreateValidator], [ValidationError]) con su implementación provisional
// ([ProvisionalValidator]). Las implementa internal/progress (progresion.md P7), que importa este
// paquete (nunca al revés: no hay ciclo), y serve las usa en todos los entornos; el falso
// ([MemoryProgressStore]) y la provisional quedan para las pruebas.
package persistence

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/config"
)

// InvalidSaveError es un guardado que no pasa S1–S7 (progresion.md §13.3): la respuesta es 400
// invalid_save con fields.check y fields.detail. Se devuelve siempre como puntero (errors.As con
// *InvalidSaveError).
type InvalidSaveError struct{ Check, Detail string }

func (e *InvalidSaveError) Error() string { return "invalid_save " + e.Check + ": " + e.Detail }

// ErrNotFound es lo que no existe o no se puede ver (Op y Ledger): 404 not_found.
var ErrNotFound = errors.New("not_found")

// CreateParams es lo que el personaje recibe al crearlo, ya validado (plataforma.md §4.4 paso 5).
type CreateParams struct {
	RaceID            string
	Appearance        [8]byte
	StarterTemplateID string
}

// SaveKey identifica un guardado: el mundo y la zona salen de la instancia que reclamó
// (InstanceID es character_leases.claimed_by).
type SaveKey struct {
	WorldID     int16
	CharacterID int64
	InstanceID  [16]byte
	ZoneID      string
}

// Summary es lo que la plataforma lee del progreso fuera del guardado: la lista de personajes,
// enter y la excepción de la reserva del nombre (plataforma.md §4.4 y §4.5). LastZoneID vacío:
// nunca ha entrado.
type Summary struct {
	RaceID        string
	Appearance    [8]byte
	Level         int
	LastZoneID    string
	LastChannel   int
	PlayedSeconds int64
}

// Querier es una consulta dentro de la transacción o la conexión de quien llama: lo cumplen
// pgx.Tx y *pgxpool.Pool.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ProgressStore es el almacén del progreso (progresion.md §13.2). Todo va dentro de la transacción
// o la conexión de quien llama; en la frontera viaja JSON crudo.
type ProgressStore interface {
	// Create guarda el progreso inicial de un personaje recién creado (§4.4 paso 6).
	Create(ctx context.Context, tx pgx.Tx, worldID int16, characterID int64, p CreateParams) error
	// Load devuelve el ProgressRecord de la reclamación (progresion.md §3.4).
	Load(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)
	// Apply aplica la sección progress de un guardado con S1–S8 y devuelve el save_version nuevo.
	Apply(ctx context.Context, tx pgx.Tx, key SaveKey, progress json.RawMessage) (saveVersion int64, err error)
	// Summaries devuelve el resumen de cada personaje que tenga progreso.
	Summaries(ctx context.Context, q Querier, characterIDs []int64) (map[int64]Summary, error)
	// Purge borra el estado del progreso y deja lo de solo añadir (progresion.md §3.5).
	Purge(ctx context.Context, tx pgx.Tx, characterID int64) error
	// PurgeRetention borra el libro retenido más de un año; emptied son las lápidas que se han
	// quedado sin libro, que la plataforma borra (progresion.md §3.5).
	PurgeRetention(ctx context.Context, tx pgx.Tx) (deleted int64, emptied []int64, err error)
	// Export da el progreso de un personaje para la exportación de datos (progresion.md §3.5).
	Export(ctx context.Context, q Querier, characterID int64) (json.RawMessage, error)
	// Op devuelve una operación si alguno de sus participantes tiene arrendamiento en instance;
	// si no, [ErrNotFound].
	Op(ctx context.Context, q Querier, opID int64, instance [16]byte) (json.RawMessage, error)
	// Ledger devuelve los apuntes de un personaje, los más recientes primero (limit de 1 a 100).
	Ledger(ctx context.Context, q Querier, characterID int64, limit int, beforeEntryID int64) (json.RawMessage, error)
}

// CreateValidator valida la raza, la apariencia y la plantilla de inicio de un personaje nuevo
// (plataforma.md §4.4 paso 5, progresion.md §13.2). realm es el código de NetProtocol.Realm.
// Devuelve nil o un *[ValidationError].
type CreateValidator interface {
	ValidateCreate(realm int16, raceID string, appearance [8]byte, templateID string) error
}

// ValidationError es una creación que no vale: la respuesta es 400 validation con estos fields tal
// cual ({"race_id": "wrong_realm"}, {"appearance": "invalid"},
// {"starter_template_id": "not_selectable"}). Se devuelve siempre como puntero.
type ValidationError struct{ Fields map[string]string }

func (e *ValidationError) Error() string {
	keys := make([]string, 0, len(e.Fields))
	for k := range e.Fields {
		keys = append(keys, k+"="+e.Fields[k])
	}
	sort.Strings(keys)
	return "validation: " + strings.Join(keys, ", ")
}

// templatePattern es la plantilla que admite la validación provisional.
var templatePattern = regexp.MustCompile(`^[a-z0-9_]{1,32}$`)

// ProvisionalValidator es la validación de la creación de antes de progresion.md P7 (plataforma.md
// §4.4 paso 5): race_id = "race_" + el id de texto del reino, 8 B de apariencia cualesquiera (la
// zona corrige al cargar una que no valga, progresion.md §7.2) y una plantilla que cumple
// ^[a-z0-9_]{1,32}$. serve usa *progress.Rules; esta queda para las pruebas que crean personajes
// sin las reglas exportadas.
type ProvisionalValidator struct{}

// ValidateCreate implementa [CreateValidator]. Una raza de otro reino es wrong_realm; un id que
// no es de ninguna raza, unknown.
func (ProvisionalValidator) ValidateCreate(realm int16, raceID string, _ [8]byte, templateID string) error {
	fields := map[string]string{}
	if raceID != "race_"+config.Realm(realm).String() {
		fields["race_id"] = "unknown"
		for _, r := range []config.Realm{config.RealmVardheim, config.RealmSolmarch, config.RealmAskarra} {
			if raceID == "race_"+r.String() {
				fields["race_id"] = "wrong_realm"
			}
		}
	}
	if !templatePattern.MatchString(templateID) {
		fields["starter_template_id"] = "not_selectable"
	}
	if len(fields) > 0 {
		return &ValidationError{Fields: fields}
	}
	return nil
}
