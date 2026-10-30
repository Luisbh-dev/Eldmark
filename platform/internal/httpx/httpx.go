// Package httpx reúne lo común de las dos API HTTP (plataforma.md §4.1 y §6): el cuerpo de error,
// el registro de cada petición con su id, los límites del cuerpo, /health y /ready.
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

// Límites del cuerpo: 16 KB en la API pública (§4.1) y 1 MB en la interna (§6).
const (
	PublicBodyLimit   int64 = 16 << 10
	InternalBodyLimit int64 = 1 << 20
)

// Error es una respuesta de error con el cuerpo de §4.1:
// {"error": {"code": …, "message": …, "retry_after_s": …, "fields": {…}}}. Extra añade campos al
// objeto error (el kind, until_unix y reason de account_blocked, §6.1).
type Error struct {
	Status     int
	Code       string
	Message    string
	RetryAfter int
	Fields     map[string]string
	Extra      map[string]any
}

func (e *Error) Error() string { return strconv.Itoa(e.Status) + " " + e.Code + ": " + e.Message }

// MarshalJSON escribe el cuerpo de error entero.
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

// Errores de uso general.
var (
	ErrNotFound = &Error{Status: http.StatusNotFound, Code: "not_found", Message: "No encontrado"}
	ErrInternal = &Error{Status: http.StatusInternalServerError, Code: "internal", Message: "Error del servidor"}
)

// BadRequest es el 400 de un JSON roto o con campos desconocidos.
func BadRequest() *Error {
	return &Error{Status: http.StatusBadRequest, Code: "bad_request", Message: "Datos no válidos"}
}

// TooLarge es el 413 de un cuerpo que pasa del límite.
func TooLarge() *Error {
	return &Error{Status: http.StatusRequestEntityTooLarge, Code: "too_large", Message: "La petición es demasiado grande"}
}

// WriteJSON escribe v como JSON con el estado dado.
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

// WriteError escribe el cuerpo de error; con 429 y 503 añade Retry-After.
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

// NotFound responde 404 not_found a toda ruta que no existe.
func NotFound() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { WriteError(w, ErrNotFound) })
}

// DecodeJSON lee el cuerpo de la petición en v, estricto (jsonx.Decode), con el límite dado. Un
// cuerpo que pasa del límite es 413; uno roto, con campos desconocidos o con tipos que no casan,
// 400 bad_request.
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

// statusWriter recuerda el estado de la respuesta para el registro.
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

// Middleware da a cada petición un id (campo req del registro y cabecera X-Request-Id), escribe
// una línea de registro al terminarla (route, status, ms y, si se conocen, account y character;
// nunca el cuerpo) y convierte un pánico en 500 internal. Las de /health y /ready que van bien se
// registran solo en el nivel de depuración, y las que no, como aviso.
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
				// Un /ready en 503 mientras la base o el esquema no están: el motivo ya lo registra
				// el arranque, y los sondeos se repiten cada pocos segundos.
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

// routeOf devuelve el patrón de la ruta («GET /v1/characters/{id}»), nunca la ruta con ids ni la
// consulta. Sin patrón (404), el método y «?».
func routeOf(r *http.Request) string {
	if r.Pattern != "" && r.Pattern != "/" {
		return r.Pattern
	}
	return r.Method + " ?"
}

// Health responde 200 mientras el proceso vive, sin tocar la base.
func Health() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

// Ready responde 200 si check no da error y, si no, 503 con el motivo, que check escribe para
// cualquiera: /ready es público, así que el motivo no lleva detalles de la base.
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
