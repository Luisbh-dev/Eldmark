// Package httpx gathers what the two HTTP APIs have in common (plataforma.md §4.1 and §6): the error
// body, the logging of each request with its id, the body limits, /health and /ready.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/logx"
)

// Body limits: 16 KB on the public API (§4.1) and 1 MB on the internal one (§6).
const (
	PublicBodyLimit   int64 = 16 << 10
	InternalBodyLimit int64 = 1 << 20
)

// Error is an error response with the §4.1 body:
// {"error": {"code": ..., "message": ..., "retry_after_s": ..., "fields": {...}}}. Extra adds
// fields to the error object (account_blocked's kind, until_unix and reason, §6.1).
type Error struct {
	Status     int
	Code       string
	Message    string
	RetryAfter int
	Fields     map[string]string
	Extra      map[string]any
}

func (e *Error) Error() string { return strconv.Itoa(e.Status) + " " + e.Code + ": " + e.Message }

// MarshalJSON writes the whole error body.
func (e *Error) MarshalJSON() ([]byte, error) {
	inner := make(map[string]any, 4+len(e.Extra))
	for k, v := range e.Extra {
		inner[k] = v
	}
	inner["code"] = e.Code
	inner["message"] = e.Message
	inner["retry_after_s"] = e.RetryAfter
	if len(e.Fields) > 0 {
		inner["fields"] = e.Fields
	}
	return json.Marshal(map[string]any{"error": inner})
}

// General-purpose errors.
var (
	ErrNotFound = &Error{Status: http.StatusNotFound, Code: "not_found", Message: "No encontrado"}
	ErrInternal = &Error{Status: http.StatusInternalServerError, Code: "internal", Message: "Error del servidor"}
)

// BadRequest is the 400 for broken JSON or JSON with unknown fields.
func BadRequest() *Error {
	return &Error{Status: http.StatusBadRequest, Code: "bad_request", Message: "Datos no válidos"}
}

// TooLarge is the 413 for a body that exceeds the limit.
func TooLarge() *Error {
	return &Error{Status: http.StatusRequestEntityTooLarge, Code: "too_large", Message: "La petición es demasiado grande"}
}

// WriteJSON writes v as JSON with the given status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		status, body = http.StatusInternalServerError, []byte(`{"error":{"code":"internal","message":"Error del servidor","retry_after_s":0}}`)
	}
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(append(body, '\n'))
}

// WriteError writes the error body; with 429 and 503 it adds Retry-After.
func WriteError(w http.ResponseWriter, e *Error) {
	if e.Status == http.StatusTooManyRequests || e.Status == http.StatusServiceUnavailable {
		retry := e.RetryAfter
		if retry < 1 {
			retry = 1
		}
		w.Header().Set("Retry-After", strconv.Itoa(retry))
	}
	WriteJSON(w, e.Status, e)
}

// NotFound answers 404 not_found to every route that does not exist.
func NotFound() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { WriteError(w, ErrNotFound) })
}

// DecodeJSON reads the request body into v, strictly (jsonx.Decode), with the given limit. A body
// that exceeds the limit is 413; a broken one, with unknown fields or with mismatched types, 400
// bad_request.
func DecodeJSON(w http.ResponseWriter, r *http.Request, limit int64, v any) *Error {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	if err := jsonx.Decode(r.Body, v); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return TooLarge()
		}
		return BadRequest()
	}
	return nil
}

// statusWriter remembers the response's status for the log.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) {
	if s.status == 0 {
		s.status = code
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusWriter) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

func (s *statusWriter) Unwrap() http.ResponseWriter { return s.ResponseWriter }

// Middleware gives each request an id (the log's req field and the X-Request-Id header), writes a
// log line when it finishes (route, status, ms and, if known, account and character; never the
// body) and turns a panic into a 500 internal. Successful /health and /ready requests are logged
// only at the debug level, and those that fail, as a warning.
func Middleware(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		info := &logx.Request{ID: logx.NewRequestID()}
		w.Header().Set("X-Request-Id", info.ID)
		sw := &statusWriter{ResponseWriter: w}
		req := r.WithContext(logx.WithRequest(r.Context(), info))
		defer func() {
			if p := recover(); p != nil {
				if p == http.ErrAbortHandler {
					panic(p)
				}
				log.LogAttrs(req.Context(), slog.LevelError, "pánico en una petición",
					append(info.Attrs(), slog.String("route", req.Pattern), slog.Any("panic", p),
						slog.String("stack", string(debug.Stack())))...)
				if sw.status == 0 {
					WriteError(sw, ErrInternal)
				}
			}
			status := sw.status
			if status == 0 {
				status = http.StatusOK
			}
			level := slog.LevelInfo
			probe := req.Pattern == "GET /health" || req.Pattern == "GET /ready"
			switch {
			case probe && status < 400:
				level = slog.LevelDebug
			case probe:
				// A /ready at 503 while the database or the schema are not there: the startup already logs the
				// reason, and the probes repeat every few seconds.
				level = slog.LevelWarn
			case status >= 500:
				level = slog.LevelError
			}
			attrs := append(info.Attrs(),
				slog.String("route", routeOf(req)),
				slog.Int("status", status),
				slog.Float64("ms", float64(time.Since(start).Microseconds())/1000))
			log.LogAttrs(req.Context(), level, "petición", attrs...)
		}()
		next.ServeHTTP(sw, req)
	})
}

// routeOf returns the route's pattern ("GET /v1/characters/{id}"), never the route with ids or the
// query. Without a pattern (404), the method and "?".
func routeOf(r *http.Request) string {
	if r.Pattern != "" && r.Pattern != "/" {
		return r.Pattern
	}
	return r.Method + " ?"
}

// Health answers 200 while the process lives, without touching the database.
func Health() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

// Ready answers 200 if check gives no error and, otherwise, 503 with the reason, which check writes
// for anyone: /ready is public, so the reason carries no database details.
func Ready(timeout time.Duration, check func(ctx context.Context) error) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), timeout)
		defer cancel()
		if err := check(ctx); err != nil {
			w.Header().Set("Retry-After", "5")
			WriteJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "not_ready",
				"reason": strings.TrimSpace(err.Error()),
			})
			return
		}
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}
