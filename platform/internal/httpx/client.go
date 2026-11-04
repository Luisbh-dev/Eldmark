package httpx

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/logx"
)

// ClientIP returns the client's IP (plataforma.md §4.2): the one from X-Real-IP only if the
// connection comes from a trusted proxy (ELDMARK_TRUSTED_PROXIES, the Caddy container) and,
// otherwise, the connection's. Never X-Forwarded-For. IPv4 addresses inside IPv6 come out as IPv4.
func ClientIP(r *http.Request, trusted []netip.Prefix) netip.Addr {
	remote := remoteAddr(r.RemoteAddr)
	if remote.IsValid() && contains(trusted, remote) {
		if v := strings.TrimSpace(r.Header.Get("X-Real-IP")); v != "" {
			if a, err := netip.ParseAddr(v); err == nil {
				return a.Unmap().WithZone("")
			}
		}
	}
	return remote
}

func remoteAddr(s string) netip.Addr {
	if ap, err := netip.ParseAddrPort(s); err == nil {
		return ap.Addr().Unmap().WithZone("")
	}
	host, _, err := net.SplitHostPort(s)
	if err != nil {
		host = s
	}
	a, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}
	}
	return a.Unmap().WithZone("")
}

func contains(prefixes []netip.Prefix, a netip.Addr) bool {
	for _, p := range prefixes {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

// AddrGroup is an IP's group for the limits: the IPv4 itself, or the /64 prefix of an IPv6 (like
// ServerAuth.address_group in the zone).
func AddrGroup(a netip.Addr) string {
	if !a.IsValid() {
		return "?"
	}
	a = a.Unmap().WithZone("")
	if a.Is4() {
		return a.String()
	}
	p, err := a.Prefix(64)
	if err != nil {
		return a.String()
	}
	return p.String()
}

// ProtocolHeader is the header carrying the client's PROTOCOL_VERSION (§4.1).
const ProtocolHeader = "X-Eldmark-Protocol"

// ClientProtocol returns the header's protocol, or 0 if it is missing or not a positive integer.
func ClientProtocol(r *http.Request) int {
	v := strings.TrimSpace(r.Header.Get(ProtocolHeader))
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > 65535 {
		return 0
	}
	return n
}

// Outdated is the 426 client_outdated, with the minimum protocol.
func Outdated(min int) *Error {
	return &Error{Status: http.StatusUpgradeRequired, Code: "client_outdated", Message: "Actualiza el cliente",
		Extra: map[string]any{"min_protocol": min}}
}

// RequireProtocol answers 426 if the request does not carry X-Eldmark-Protocol or carries one below
// min (every /v1 route, §4.1). With min 0 it is enough for the header to carry a positive integer.
func RequireProtocol(min int, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if p := ClientProtocol(r); p == 0 || p < min {
			WriteError(w, Outdated(min))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Unavailable is the public API's 503 when the database does not respond or a transaction clashed
// with others too many times.
func Unavailable() *Error {
	return &Error{Status: http.StatusServiceUnavailable, Code: "unavailable",
		Message: "El servicio de cuentas no responde; inténtalo más tarde", RetryAfter: 5}
}

// Fail writes an error's response: an *Error as is; a database one that is unavailable (or that
// exhausted the retries), 503 unavailable; any other, 500 internal. The last two are logged with the
// request id (pgx's message carries no row values).
func Fail(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	var e *Error
	if errors.As(err, &e) {
		WriteError(w, e)
		return
	}
	if errors.Is(err, context.Canceled) && r.Context().Err() != nil {
		// The client left: there is nobody to respond to.
		return
	}
	resp := ErrInternal
	if kind := db.Classify(err); kind == db.KindUnavailable || kind == db.KindRetryable {
		resp = Unavailable()
	}
	if log != nil {
		log.LogAttrs(r.Context(), slog.LevelError, "error en una petición", slog.String("req", logx.RequestID(r.Context())),
			slog.String("route", routeOf(r)), slog.String("err", err.Error()))
	}
	WriteError(w, resp)
}
