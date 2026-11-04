// Package zones is the part of the internal API (plataforma.md §6, TEC-24) that handles zone
// instances: per-deployment tokens and their scope, registration (with replacement and the
// silent instance that is considered lost), live, the heartbeat (it renews leases and says whom
// to remove and whom to mute), deregistration, the lost-instances job and id blocks.
//
// It also gives the other internal API packages (persistence, war, social) what is common from
// §6.1: [Guard] checks the token (401 bad_token), the instance's scope (403 forbidden) and its
// state according to the request (the §6.1 table), and [Fail] writes errors with the internal
// rule (503 db_unavailable). Batches are read with [DecodeBatch] and their keys are validated
// with [KeyChecker].
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

// Scope is the scope of a zone token: the deployment (world, zone, channel) it belongs to.
type Scope struct {
	WorldID int16
	ZoneID  string
	Channel int16
}

// Registry holds the zone tokens (ELDMARK_ZONE_TOKENS): only their SHA-256 with their scope.
type Registry struct {
	tokens []config.ZoneToken
}

// NewRegistry prepares the configuration's tokens.
func NewRegistry(tokens []config.ZoneToken) *Registry {
	return &Registry{tokens: append([]config.ZoneToken(nil), tokens...)}
}

// Authenticate computes the token's SHA-256 and compares it in constant time with every entry
// (with all of them, even after finding it); the one that matches gives its scope.
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

// NewUUID returns a version 4 UUID from crypto/rand (§2.2: own format, no dependencies).
func NewUUID() [16]byte {
	var u [16]byte
	if _, err := rand.Read(u[:]); err != nil {
		panic("zones: crypto/rand no responde: " + err.Error())
	}
	u[6] = u[6]&0x0f | 0x40
	u[8] = u[8]&0x3f | 0x80
	return u
}

// FormatUUID writes the UUID in its canonical form, in lowercase.
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

// ParseUUID reads a UUID in its canonical form (36 characters with hyphens, in lowercase, as
// [FormatUUID] writes it); any other form is invalid.
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

// Instance states (zone_instances.status).
const (
	StatusStarting = "starting"
	StatusLive     = "live"
	StatusStopped  = "stopped"
	StatusLost     = "lost"
	StatusReplaced = "replaced"
)

// Instance is a zone instance.
type Instance struct {
	ID      [16]byte
	WorldID int16
	ZoneID  string
	Channel int16
	Status  string
}

// IDString is the zone_instance_id in its canonical form.
func (i *Instance) IDString() string { return FormatUUID(i.ID) }

// Op is the request type for the §6.1 state table.
type Op int

// Requests in the §6.1 table. live, deregistration, save and release have their own rules and do
// not go through [Instance.Check].
const (
	OpHeartbeat   Op = iota // starting and live: 200
	OpIDBlock               // starting and live: 200 (the first one belongs to startup, §8)
	OpFortressGet           // starting and live: 200
	OpClaim                 // live only; starting: instance_not_live
	OpProgress              // operation and ledger: live only
	OpFortressPut           // live only
	OpModeration            // reports, ignores and sanctions: live only
	OpAny                   // batches, saves and release: any state
)

// Check applies the §6.1 table: nil if the request goes on, or its error (409 instance_not_live,
// instance_lost, instance_replaced or instance_stopped).
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

// StatusError is the 409 for an instance that is no longer valid: instance_lost,
// instance_replaced or instance_stopped (nil with starting and live).
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

// Internal API errors (§6.1). The body is the one from §4.1.

func conflict(code, message string) *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: code, Message: message}
}

// Conflict is a 409 with its code and its text.
func Conflict(code, message string) *httpx.Error { return conflict(code, message) }

// ErrBadToken is the 401 for a zone token that is missing or matches none.
func ErrBadToken() *httpx.Error {
	return &httpx.Error{Status: http.StatusUnauthorized, Code: "bad_token", Message: "Token de zona no válido"}
}

// ErrForbidden is the 403 for what is outside the token's or the instance's scope.
func ErrForbidden() *httpx.Error {
	return &httpx.Error{Status: http.StatusForbidden, Code: "forbidden", Message: "No permitido"}
}

// ErrInstanceNotLive is the 409 for a request that is only valid with the instance live.
func ErrInstanceNotLive() *httpx.Error {
	return conflict("instance_not_live", "La instancia aún no está en marcha")
}

// Validation is the 400 for invalid fields, with fields.
func Validation(fields map[string]string) *httpx.Error {
	return &httpx.Error{Status: http.StatusBadRequest, Code: "validation", Message: "Datos no válidos", Fields: fields}
}

// ErrDBUnavailable is the 503 for a database that does not respond or a transaction that
// collided with others more times than it is retried (§7.3).
func ErrDBUnavailable() *httpx.Error {
	return &httpx.Error{Status: http.StatusServiceUnavailable, Code: "db_unavailable",
		Message: "La base de datos no responde", RetryAfter: 1}
}

// Fail writes the response for an internal API error: an *httpx.Error as is; one from an
// unavailable database or that exhausted its retries, 503 db_unavailable; data the database
// rejects (class 22: a NUL in jsonb, an out-of-range date), 400 validation, because retrying
// does not fix it and the zone retries a 5xx; any other, 500 internal. The last three are logged
// with the request id.
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

// Querier is a query inside the caller's transaction or connection.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// LoadInstance reads an instance, or nil if it does not exist. lock adds "for share" (the claim:
// the lost-instances job and the heartbeat wait for it to finish).
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

// InScope says whether the instance is within the token's scope.
func (i *Instance) InScope(s Scope) bool {
	return i.WorldID == s.WorldID && i.ZoneID == s.ZoneID && i.Channel == s.Channel
}
