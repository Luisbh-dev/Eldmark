package httpx

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/logx"
)

// Only X-Real-IP and only from a trusted proxy; never X-Forwarded-For (platform.md §4.2).
func TestClientIP(t *testing.T) {
	trusted := []netip.Prefix{netip.MustParsePrefix("172.18.0.5/32")}
	cases := []struct {
		remote, realIP, forwarded, want string
	}{
		{"203.0.113.7:5000", "", "", "203.0.113.7"},
		{"203.0.113.7:5000", "1.2.3.4", "", "203.0.113.7"},              // X-Real-IP from an untrusted origin
		{"203.0.113.7:5000", "", "1.2.3.4", "203.0.113.7"},              // X-Forwarded-For never
		{"172.18.0.5:41000", "198.51.100.9", "1.2.3.4", "198.51.100.9"}, // Caddy
		{"172.18.0.5:41000", "no-es-ip", "", "172.18.0.5"},
		{"[::ffff:203.0.113.7]:5000", "", "", "203.0.113.7"},
		{"[2001:db8::1%eth0]:5000", "", "", "2001:db8::1"},
	}
	for _, c := range cases {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.RemoteAddr = c.remote
		if c.realIP != "" {
			r.Header.Set("X-Real-IP", c.realIP)
		}
		if c.forwarded != "" {
			r.Header.Set("X-Forwarded-For", c.forwarded)
		}
		if got := ClientIP(r, trusted).String(); got != c.want {
			t.Errorf("%+v: %s", c, got)
		}
	}
}

func TestAddrGroup(t *testing.T) {
	for in, want := range map[string]string{
		"203.0.113.7":             "203.0.113.7",
		"::ffff:203.0.113.7":      "203.0.113.7",
		"2001:db8:1:2:3:4:5:6":    "2001:db8:1:2::/64",
		"2001:db8:1:2:ffff::9999": "2001:db8:1:2::/64",
	} {
		if got := AddrGroup(netip.MustParseAddr(in)); got != want {
			t.Errorf("%s: %s", in, got)
		}
	}
	if AddrGroup(netip.Addr{}) != "?" {
		t.Error("IP vacía")
	}
}

// Without X-Eldmark-Protocol or below the minimum: 426 client_outdated with min_protocol (§4.1).
func TestRequireProtocol(t *testing.T) {
	h := RequireProtocol(7, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) }))
	for header, want := range map[string]int{"": 426, "6": 426, "x": 426, "7": 204, "8": 204} {
		r := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
		if header != "" {
			r.Header.Set(ProtocolHeader, header)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		if rec.Code != want {
			t.Errorf("%q: %d", header, rec.Code)
		}
		if want == 426 {
			body := decodeBody(t, rec)["error"].(map[string]any)
			if body["code"] != "client_outdated" || body["min_protocol"] != 7.0 {
				t.Errorf("%q: %v", header, body)
			}
		}
	}
	any := RequireProtocol(0, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) }))
	rec := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	r.Header.Set(ProtocolHeader, "1")
	any.ServeHTTP(rec, r)
	if rec.Code != 204 {
		t.Fatalf("con mínimo 0 vale cualquiera: %d", rec.Code)
	}
}

func TestFail(t *testing.T) {
	cases := []struct {
		err  error
		code string
	}{
		{&Error{Status: 409, Code: "name_taken", Message: "x"}, "name_taken"},
		{fmt.Errorf("envuelto: %w", &Error{Status: 404, Code: "not_found", Message: "x"}), "not_found"},
		{&pgconn.PgError{Code: "08006"}, "unavailable"},
		{fmt.Errorf("%w: %w", db.ErrConflict, &pgconn.PgError{Code: "40001"}), "unavailable"},
		{errors.New("otro"), "internal"},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		Fail(rec, httptest.NewRequest(http.MethodGet, "/", nil), logx.Discard(), c.err)
		if got := decodeBody(t, rec)["error"].(map[string]any)["code"]; got != c.code {
			t.Errorf("%v: %v", c.err, got)
		}
	}
}
