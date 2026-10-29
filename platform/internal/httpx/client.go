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

// ClientIP devuelve la IP del cliente (plataforma.md §4.2): la de X-Real-IP solo si la conexión
// llega de un proxy de confianza (ELDMARK_TRUSTED_PROXIES, el contenedor de Caddy) y, si no, la
// de la conexión. Nunca X-Forwarded-For. Las IPv4 dentro de IPv6 salen como IPv4.
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

// AddrGroup es el grupo de una IP para los límites: la propia IPv4, o el prefijo /64 de una IPv6
// (como ServerAuth.address_group en la zona).
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

// ProtocolHeader es la cabecera con el PROTOCOL_VERSION del cliente (§4.1).
const ProtocolHeader = "X-Eldmark-Protocol"

// ClientProtocol devuelve el protocolo de la cabecera, o 0 si falta o no es un entero positivo.
func ClientProtocol(r *http.Request) int {
	v := strings.TrimSpace(r.Header.Get(ProtocolHeader))
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > 65535 {
		return 0
	}
	return n
}

// Outdated es el 426 client_outdated, con el protocolo mínimo.
func Outdated(min int) *Error {
	return &Error{Status: http.StatusUpgradeRequired, Code: "client_outdated", Message: "Actualiza el cliente",
		Extra: map[string]any{"min_protocol": min}}
}

// RequireProtocol responde 426 si la petición no trae X-Eldmark-Protocol o trae uno por debajo de
// min (toda ruta de /v1, §4.1). Con min 0 basta con que la cabecera traiga un entero positivo.
func RequireProtocol(min int, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if p := ClientProtocol(r); p == 0 || p < min {
			WriteError(w, Outdated(min))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Unavailable es el 503 de la API pública cuando la base no responde o una transacción chocó con
// otras demasiadas veces.
func Unavailable() *Error {
	return &Error{Status: http.StatusServiceUnavailable, Code: "unavailable",
		Message: "El servicio de cuentas no responde; inténtalo más tarde", RetryAfter: 5}
}

// Fail escribe la respuesta de un error: un *Error tal cual; uno de la base que no está
// disponible (o que agotó los reintentos), 503 unavailable; cualquier otro, 500 internal. Los dos
// últimos se registran con el id de la petición (el mensaje de pgx no lleva valores de las filas).
func Fail(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	var e *Error
	if errors.As(err, &e) {
		WriteError(w, e)
		return
	}
	if errors.Is(err, context.Canceled) && r.Context().Err() != nil {
		// El cliente se fue: no hay a quién responder.
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
