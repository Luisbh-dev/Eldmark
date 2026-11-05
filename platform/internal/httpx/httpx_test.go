package httpx

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/logx"
)

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("JSON body: %v (%s)", err, rec.Body.String())
	}
	return body
}

func TestErrorBody(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteError(rec, &Error{Status: 409, Code: "name_taken", Message: "Ese nombre ya está en uso",
		Fields: map[string]string{"name": "taken"}})
	if rec.Code != 409 || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("status and type: %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}
	got := decodeBody(t, rec)["error"].(map[string]any)
	if got["code"] != "name_taken" || got["message"] != "Ese nombre ya está en uso" || got["retry_after_s"] != 0.0 ||
		got["fields"].(map[string]any)["name"] != "taken" {
		t.Fatalf("§4.1 body: %v", got)
	}
	if rec.Header().Get("Retry-After") != "" {
		t.Fatal("only 429 and 503 carry Retry-After")
	}

	rec = httptest.NewRecorder()
	WriteError(rec, &Error{Status: 403, Code: "account_blocked", Message: "Tu cuenta está suspendida",
		Extra: map[string]any{"kind": "suspension", "until_unix": 1800000000, "reason": "motivo"}})
	got = decodeBody(t, rec)["error"].(map[string]any)
	if got["kind"] != "suspension" || got["until_unix"] != 1800000000.0 || got["code"] != "account_blocked" {
		t.Fatalf("extra fields: %v", got)
	}
	if _, ok := got["fields"]; ok {
		t.Fatal("without fields, the key is omitted")
	}

	for _, status := range []int{429, 503} {
		rec = httptest.NewRecorder()
		WriteError(rec, &Error{Status: status, Code: "rate_limited", Message: "Espera", RetryAfter: 30})
		if rec.Header().Get("Retry-After") != "30" {
			t.Fatalf("%d carries Retry-After: %q", status, rec.Header().Get("Retry-After"))
		}
	}
}

func TestDecodeJSONLimitsAndStrictness(t *testing.T) {
	type body struct {
		CharacterID jsonx.ID  `json:"character_id"`
		Seq         jsonx.Int `json:"seq"`
	}
	post := func(payload string, limit int64) *Error {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(payload))
		var b body
		return DecodeJSON(httptest.NewRecorder(), req, limit, &b)
	}
	if err := post(`{"character_id": "42", "seq": 3.0}`, PublicBodyLimit); err != nil {
		t.Fatalf("valid body: %v", err)
	}
	if err := post(`{"character_id": "42", "seq": 3, "otro": 1}`, PublicBodyLimit); err == nil || err.Code != "bad_request" || err.Status != 400 {
		t.Fatalf("unknown field -> 400: %v", err)
	}
	if err := post(`{"character_id": 42, "seq": 3}`, PublicBodyLimit); err == nil || err.Status != 400 {
		t.Fatalf("unquoted id -> 400: %v", err)
	}
	big := `{"character_id": "42", "seq": 3` + strings.Repeat(" ", int(PublicBodyLimit)) + `}`
	if err := post(big, PublicBodyLimit); err == nil || err.Status != 413 {
		t.Fatalf("more than 16 KB -> 413: %v", err)
	}
	if err := post(big, InternalBodyLimit); err != nil {
		t.Fatalf("the internal API allows 1 MB: %v", err)
	}
}

func TestMiddlewareLogsWithoutBodies(t *testing.T) {
	var logs bytes.Buffer
	log := logx.New(&logs, slog.LevelDebug)
	mux := http.NewServeMux()
	mux.Handle("GET /health", Health())
	mux.HandleFunc("POST /v1/characters/{id}/enter", func(w http.ResponseWriter, r *http.Request) {
		logx.SetAccount(r.Context(), 7)
		logx.SetCharacter(r.Context(), 42)
		WriteJSON(w, 200, map[string]string{"ticket": "secreto"})
	})
	mux.HandleFunc("GET /boom", func(http.ResponseWriter, *http.Request) { panic("roto") })
	mux.Handle("/", NotFound())
	h := Middleware(log, mux)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/characters/42/enter?x=1", strings.NewReader(`{"password":"hunter22"}`)))
	id := rec.Header().Get("X-Request-Id")
	if rec.Code != 200 || len(id) != 16 {
		t.Fatalf("response with X-Request-Id: %d %q", rec.Code, id)
	}
	var line map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(logs.Bytes()), &line); err != nil {
		t.Fatalf("a JSON line: %v %s", err, logs.String())
	}
	want := map[string]any{"msg": "petición", "req": id, "route": "POST /v1/characters/{id}/enter",
		"status": 200.0, "account": 7.0, "character": 42.0, "level": "INFO"}
	for k, v := range want {
		if line[k] != v {
			t.Errorf("field %s: %v, expected %v", k, line[k], v)
		}
	}
	if _, ok := line["ms"]; !ok {
		t.Error("ms is missing")
	}
	for _, secret := range []string{"hunter22", "secreto", "x=1"} {
		if strings.Contains(logs.String(), secret) {
			t.Errorf("the log carries %q: %s", secret, logs.String())
		}
	}

	logs.Reset()
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/no/existe", nil))
	if rec.Code != 404 || decodeBody(t, rec)["error"].(map[string]any)["code"] != "not_found" {
		t.Fatalf("404 in JSON: %d %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(logs.String(), `"route":"GET ?"`) {
		t.Errorf("an unknown route is not logged verbatim: %s", logs.String())
	}

	logs.Reset()
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/boom", nil))
	if rec.Code != 500 || decodeBody(t, rec)["error"].(map[string]any)["code"] != "internal" {
		t.Fatalf("a panic is a 500 internal: %d", rec.Code)
	}
	if !strings.Contains(logs.String(), "pánico") || !strings.Contains(logs.String(), `"level":"ERROR"`) {
		t.Errorf("the panic is logged as an error: %s", logs.String())
	}

	logs.Reset()
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != 200 || !strings.Contains(logs.String(), `"level":"DEBUG"`) {
		t.Errorf("a successful /health goes at debug level: %d %s", rec.Code, logs.String())
	}
}

func TestReady(t *testing.T) {
	var gotDeadline bool
	ok := Ready(time.Second, func(ctx context.Context) error {
		_, gotDeadline = ctx.Deadline()
		return nil
	})
	rec := httptest.NewRecorder()
	ok.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ready", nil))
	if rec.Code != 200 || !gotDeadline {
		t.Fatalf("ready: %d, deadline %v", rec.Code, gotDeadline)
	}
	bad := Ready(time.Second, func(context.Context) error { return errors.New("La base de datos no responde") })
	rec = httptest.NewRecorder()
	bad.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ready", nil))
	body := decodeBody(t, rec)
	if rec.Code != 503 || body["reason"] != "La base de datos no responde" || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("not ready: %d %v", rec.Code, body)
	}
}
