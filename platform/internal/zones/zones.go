// Package zones es la parte de la API interna (plataforma.md §6, TEC-24) que lleva las instancias
// de zona: los tokens por despliegue y su alcance, el registro (con la sustitución y la instancia
// sin latido que se da por perdida), live, el latido (renueva los arrendamientos y dice a quién
// expulsar y a quién silenciar), la baja, el trabajo de instancias perdidas y los bloques de ids.
//
// También da a los demás paquetes de la API interna (persistence, war, social) lo común de §6.1:
// [Guard] comprueba el token (401 bad_token), el alcance de la instancia (403 forbidden) y su
// estado según la petición (tabla de §6.1), y [Fail] escribe los errores con la regla interna (503
// db_unavailable). Los lotes se leen con [DecodeBatch] y sus claves se validan con [KeyChecker].
package zones

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
)

// Scope es el alcance de un token de zona: el despliegue (mundo, zona, canal) al que pertenece.
type Scope struct {
	WorldID int16
	ZoneID  string
	Channel int16
}

// Registry son los tokens de las zonas (ELDMARK_ZONE_TOKENS): solo sus SHA-256 con su alcance.
type Registry struct {
	tokens []config.ZoneToken
}

// NewRegistry prepara los tokens de la configuración.
func NewRegistry(tokens []config.ZoneToken) *Registry {
	return &Registry{tokens: append([]config.ZoneToken(nil), tokens...)}
}

// Authenticate calcula el SHA-256 del token y lo compara en tiempo constante con cada entrada (con
// todas, también tras encontrarlo); la que casa da su alcance.
func (r *Registry) Authenticate(bearer string) (Scope, bool) {
	if bearer == "" {
		return Scope{}, false
	}
	sum := sha256.Sum256([]byte(bearer))
	var found Scope
	ok := false
	for _, t := range r.tokens {
		if subtle.ConstantTimeCompare(sum[:], t.Hash[:]) == 1 && !ok {
			found, ok = Scope{WorldID: t.WorldID, ZoneID: t.ZoneID, Channel: t.Channel}, true
		}
	}
	return found, ok
}

// UUID.

// NewUUID devuelve un UUID versión 4 de crypto/rand (§2.2: formato propio, sin dependencias).
func NewUUID() [16]byte {
	var u [16]byte
	if _, err := rand.Read(u[:]); err != nil {
		panic("zones: crypto/rand no responde: " + err.Error())
	}
	u[6] = u[6]&0x0f | 0x40
	u[8] = u[8]&0x3f | 0x80
	return u
}

// FormatUUID escribe el UUID en su forma canónica, en minúsculas.
func FormatUUID(u [16]byte) string {
	var b [36]byte
	hex.Encode(b[0:8], u[0:4])
	b[8] = '-'
	hex.Encode(b[9:13], u[4:6])
	b[13] = '-'
	hex.Encode(b[14:18], u[6:8])
	b[18] = '-'
	hex.Encode(b[19:23], u[8:10])
	b[23] = '-'
	hex.Encode(b[24:36], u[10:16])
	return string(b[:])
}

// ParseUUID lee un UUID en su forma canónica (36 caracteres con guiones, en minúsculas, como lo
// escribe [FormatUUID]); cualquier otra forma no vale.
func ParseUUID(s string) ([16]byte, bool) {
	var u [16]byte
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return u, false
	}
	hexPart := s[0:8] + s[9:13] + s[14:18] + s[19:23] + s[24:36]
	for i := 0; i < len(hexPart); i++ {
		if c := hexPart[i]; (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return u, false
		}
	}
	if _, err := hex.Decode(u[:], []byte(hexPart)); err != nil {
		return u, false
	}
	return u, true
}

// Estados de una instancia (zone_instances.status).
const (
	StatusStarting = "starting"
	StatusLive     = "live"
	StatusStopped  = "stopped"
	StatusLost     = "lost"
	StatusReplaced = "replaced"
)

// Instance es una instancia de zona.
type Instance struct {
	ID      [16]byte
	WorldID int16
	ZoneID  string
	Channel int16
	Status  string
}

// IDString es el zone_instance_id en su forma canónica.
func (i *Instance) IDString() string { return FormatUUID(i.ID) }

// Op es el tipo de petición para la tabla de estados de §6.1.
type Op int

// Peticiones de la tabla de §6.1. live, la baja, el guardado y la liberación tienen sus propias
// reglas y no pasan por [Instance.Check].
const (
	OpHeartbeat   Op = iota // starting y live: 200
	OpIDBlock               // starting y live: 200 (el primero es del arranque, §8)
	OpFortressGet           // starting y live: 200
	OpClaim                 // solo live; starting: instance_not_live
	OpProgress              // operación y libro: solo live
	OpFortressPut           // solo live
	OpModeration            // reportes, ignorados y sanciones: solo live
	OpAny                   // lotes, guardados y liberación: cualquier estado
)

// Check aplica la tabla de §6.1: nil si la petición sigue, o su error (409 instance_not_live,
// instance_lost, instance_replaced o instance_stopped).
func (i *Instance) Check(op Op) *httpx.Error {
	if op == OpAny {
		return nil
	}
	switch i.Status {
	case StatusLive:
		return nil
	case StatusStarting:
		switch op {
		case OpHeartbeat, OpIDBlock, OpFortressGet:
			return nil
		}
		return ErrInstanceNotLive()
	}
	return StatusError(i.Status)
}

// StatusError es el 409 de una instancia que ya no vale: instance_lost, instance_replaced o
// instance_stopped (nil con starting y live).
func StatusError(status string) *httpx.Error {
	switch status {
	case StatusLost:
		return conflict("instance_lost", "La instancia se ha dado por perdida")
	case StatusReplaced:
		return conflict("instance_replaced", "La instancia ha sido sustituida por otra")
	case StatusStopped:
		return conflict("instance_stopped", "La instancia está parada")
	}
	return nil
}

// Errores de la API interna (§6.1). El cuerpo es el de §4.1.

func conflict(code, message string) *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: code, Message: message}
}

// Conflict es un 409 con su código y su texto.
func Conflict(code, message string) *httpx.Error { return conflict(code, message) }

// ErrBadToken es el 401 de un token de zona que falta o no casa con ninguno.
func ErrBadToken() *httpx.Error {
	return &httpx.Error{Status: http.StatusUnauthorized, Code: "bad_token", Message: "Token de zona no válido"}
}

// ErrForbidden es el 403 de lo que no es del alcance del token o de la instancia.
func ErrForbidden() *httpx.Error {
	return &httpx.Error{Status: http.StatusForbidden, Code: "forbidden", Message: "No permitido"}
}

// ErrInstanceNotLive es el 409 de una petición que solo vale con la instancia live.
func ErrInstanceNotLive() *httpx.Error {
	return conflict("instance_not_live", "La instancia aún no está en marcha")
}

// Validation es el 400 de campos que no valen, con fields.
func Validation(fields map[string]string) *httpx.Error {
	return &httpx.Error{Status: http.StatusBadRequest, Code: "validation", Message: "Datos no válidos", Fields: fields}
}

// ErrDBUnavailable es el 503 de la base que no responde o de una transacción que chocó con otras
// más veces de las que se reintenta (§7.3).
func ErrDBUnavailable() *httpx.Error {
	return &httpx.Error{Status: http.StatusServiceUnavailable, Code: "db_unavailable",
		Message: "La base de datos no responde", RetryAfter: 1}
}

// Fail escribe la respuesta de un error de la API interna: un *httpx.Error tal cual; uno de la
// base no disponible o que agotó los reintentos, 503 db_unavailable; un dato que la base rechaza
// (clase 22: un NUL en jsonb, una fecha fuera de rango), 400 validation, porque reintentarlo no lo
// arregla y la zona reintenta un 5xx; cualquier otro, 500 internal. Los tres últimos se registran
// con el id de la petición.
func Fail(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	var e *httpx.Error
	if errors.As(err, &e) {
		httpx.WriteError(w, e)
		return
	}
	if errors.Is(err, context.Canceled) && r.Context().Err() != nil {
		return
	}
	resp := httpx.ErrInternal
	switch db.Classify(err) {
	case db.KindUnavailable, db.KindRetryable:
		resp = ErrDBUnavailable()
	case db.KindData:
		resp = Validation(map[string]string{"body": "invalid"})
	}
	if log != nil {
		log.LogAttrs(r.Context(), slog.LevelError, "error en una petición interna",
			slog.String("req", logx.RequestID(r.Context())), slog.String("route", r.Pattern), slog.String("err", err.Error()))
	}
	httpx.WriteError(w, resp)
}

// Querier es una consulta dentro de la transacción o la conexión de quien llama.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// LoadInstance lee una instancia, o nil si no existe. lock añade «for share» (la reclamación: el
// trabajo de perdidas y el latido esperan a que termine).
func LoadInstance(ctx context.Context, q Querier, id [16]byte, lock bool) (*Instance, error) {
	sql := `select world_id, zone_id, channel, status from zone_instances where zone_instance_id = $1`
	if lock {
		sql += ` for share`
	}
	i := &Instance{ID: id}
	err := q.QueryRow(ctx, sql, id).Scan(&i.WorldID, &i.ZoneID, &i.Channel, &i.Status)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return i, nil
}

// InScope dice si la instancia es del alcance del token.
func (i *Instance) InScope(s Scope) bool {
	return i.WorldID == s.WorldID && i.ZoneID == s.ZoneID && i.Channel == s.Channel
}
