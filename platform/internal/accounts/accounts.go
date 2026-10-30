// Package accounts es el servicio de cuentas y sesiones de la plataforma (plataforma.md §4.1 a
// §4.3, TEC-23 y TEC-41): registro sin delatar cuentas, inicio de sesión con argon2id y una sola
// función que comprueba contraseñas ([Service.CheckPassword], con fallos por cuenta y grupo de
// IP), sesiones con el refresco que rota en la misma fila, sesión de privacidad para las cuentas
// sancionadas, límites de ritmo, el ciclo de vida de la cuenta con enlaces de un solo uso
// (verificar, recuperar, cambiar y revertir el correo, borrar), la exportación de datos, la purga
// de las cuentas sin verificar y de las borradas, y las páginas HTML de los enlaces de los correos.
//
// Las rutas de /v1 las monta [API.Mount]; [API.RequireSession] protege también las de los paquetes
// siguientes (personajes, entrar al mundo).
package accounts

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/passwords"
	"eldmark/platform/internal/ratelimit"
	"eldmark/platform/legal"
)

// Plazos de plataforma.md §0, §4.2, §4.3 y §11.1.
const (
	AccessTTL      = 15 * time.Minute    // token de acceso
	SessionTTL     = 12 * time.Hour      // la sesión, desde el inicio de sesión; rotar no la alarga
	VerifyTTL      = 24 * time.Hour      // verify_email
	ChangeEmailTTL = 24 * time.Hour      // change_email
	ResetTTL       = time.Hour           // reset_password
	RevertTTL      = 7 * 24 * time.Hour  // revert_email
	DeletionGrace  = 14 * 24 * time.Hour // del borrado pedido a la purga
	UnverifiedTTL  = 7 * 24 * time.Hour  // cuenta sin verificar (staging y production)
	ExportEvery    = 24 * time.Hour      // una exportación al día
	BaseSlots      = 6                   // huecos de personaje por cuenta y mundo, sin derechos
)

// Límites de ritmo de §4.2.
const (
	maxPasswordBytes = 512
	maxUserAgent     = 256
)

// Ámbitos de una sesión (sessions.scope).
const (
	ScopeGame    = "game"
	ScopePrivacy = "privacy"
)

// CharacterPurger purga los personajes de una cuenta dentro de la transacción de su purga
// (plataforma.md §11.2: lápida, ProgressStore.Purge…). Lo aporta characters.Purger (P2); sin él,
// una cuenta con personajes sin purgar no se purga y se registra. Con un personaje en el mundo
// devuelve un error que envuelve [ErrCharactersBusy] y no purga nada.
type CharacterPurger interface {
	PurgeAccountCharacters(ctx context.Context, tx pgx.Tx, accountID int64, at time.Time) error
}

// Options son las dependencias del servicio.
type Options struct {
	Config     *config.Config
	Pool       *pgxpool.Pool
	Log        *slog.Logger
	Mail       mail.Sender
	Clock      clock.Clock // por defecto, el del sistema
	Legal      *legal.Set
	Characters CharacterPurger // characters.Purger (P2); nil: las cuentas con personajes no se purgan
	// MinProtocol es el protocolo mínimo del cliente para la regla del 426 (ya resuelto con
	// config.ResolveMinProtocol; 0 mientras no haya progression_rules.json: basta la cabecera).
	MinProtocol int
}

// Service es el servicio de cuentas.
type Service struct {
	cfg         *config.Config
	pool        *pgxpool.Pool
	log         *slog.Logger
	mail        mail.Sender
	clock       clock.Clock
	legal       *legal.Set
	characters  CharacterPurger
	params      passwords.Params
	filler      string
	failures    *failureTracker
	limits      limits
	minProtocol int
	background  sync.WaitGroup // lo que sigue tras responder (Wait)
}

type limits struct {
	login       *ratelimit.Limiter // 10/min, ráfaga 10, por grupo de IP
	register    *ratelimit.Limiter // 3 por hora por grupo de IP
	mailAccount *ratelimit.Limiter // 3 por hora por destinatario
	mailIP      *ratelimit.Limiter // 10 por hora por grupo de IP
}

// New prepara el servicio. Calcula el hash de relleno con los parámetros actuales.
func New(o Options) (*Service, error) {
	if o.Config == nil || o.Pool == nil || o.Mail == nil || o.Legal == nil {
		return nil, errors.New("accounts: faltan dependencias")
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	params := passwords.Params{MemoryKiB: o.Config.Argon2.MemoryKiB, Time: o.Config.Argon2.Time, Threads: o.Config.Argon2.Threads}
	filler, err := passwords.Filler(params)
	if err != nil {
		return nil, fmt.Errorf("accounts: hash de relleno: %w", err)
	}
	capacity := ratelimit.DefaultCapacity
	return &Service{
		cfg: o.Config, pool: o.Pool, log: o.Log, mail: o.Mail, clock: o.Clock, legal: o.Legal,
		characters: o.Characters, params: params, filler: filler, failures: newFailureTracker(capacity),
		minProtocol: o.MinProtocol,
		limits: limits{
			login:       ratelimit.New(10, time.Minute, 10, capacity),
			register:    ratelimit.New(3, time.Hour, 3, capacity),
			mailAccount: ratelimit.New(3, time.Hour, 3, capacity),
			mailIP:      ratelimit.New(10, time.Hour, 10, capacity),
		},
	}, nil
}

// Errores de la API pública (§4.1).

func errValidation(fields map[string]string) *httpx.Error {
	return &httpx.Error{Status: http.StatusBadRequest, Code: "validation", Message: "Datos no válidos", Fields: fields}
}

func errLink(reason string) *httpx.Error { return errValidation(map[string]string{"token": reason}) }

func errInvalidCredentials() *httpx.Error {
	return &httpx.Error{Status: http.StatusUnauthorized, Code: "invalid_credentials", Message: "Correo o contraseña incorrectos"}
}

func errUnauthorized() *httpx.Error {
	return &httpx.Error{Status: http.StatusUnauthorized, Code: "unauthorized", Message: "Tu sesión ha caducado"}
}

func errDeletionExpired() *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "deletion_expired",
		Message: "El plazo para cancelar el borrado ha terminado"}
}

func errRateLimited(wait time.Duration) *httpx.Error {
	s := ratelimit.RetryAfterSeconds(wait)
	return &httpx.Error{Status: http.StatusTooManyRequests, Code: "rate_limited",
		Message: "Demasiados intentos; espera " + strconv.Itoa(s) + " s", RetryAfter: s}
}

// Correo y contraseña (§4.2).

// NormalizeEmail pone el correo en minúsculas y le quita los espacios de alrededor (solo
// espacios: un salto de línea no se quita y hace que el correo no valga).
func NormalizeEmail(s string) string { return strings.ToLower(strings.Trim(s, " ")) }

// ValidEmail dice si un correo ya normalizado vale: 3–254 B, solo ASCII imprimible sin espacios,
// una sola @, net/mail.ParseAddress lo devuelve igual y sin nombre visible, y un dominio con al
// menos un punto, etiquetas [a-z0-9-] y ninguna xn-- (los IDN se rechazan en la fase 5).
func ValidEmail(email string) bool {
	if len(email) < 3 || len(email) > 254 || strings.Count(email, "@") != 1 {
		return false
	}
	for i := 0; i < len(email); i++ {
		if email[i] < 0x21 || email[i] > 0x7e {
			return false
		}
	}
	local, domain, _ := strings.Cut(email, "@")
	if local == "" || !strings.Contains(domain, ".") {
		return false
	}
	for _, label := range strings.Split(domain, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "xn--") || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for i := 0; i < len(label); i++ {
			c := label[i]
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	addr, err := parseAddress(email)
	return err == nil && addr == email
}

// PasswordProblem dice por qué no vale una contraseña nueva ("" si vale): too_short (menos de 10
// caracteres), too_long (más de 128 o de 512 B) o same_as_email.
func PasswordProblem(password, email string) string {
	switch n := utf8.RuneCountInString(password); {
	case len(password) > maxPasswordBytes || n > 128:
		return "too_long"
	case n < 10:
		return "too_short"
	case email != "" && strings.EqualFold(password, email):
		return "same_as_email"
	}
	return ""
}

// emailHash es la clave de un correo en los límites y en los fallos de contraseña.
func emailHash(email string) string {
	sum := sha256.Sum256([]byte(email))
	return hex.EncodeToString(sum[:])
}

// accountKey es la clave de una cuenta en los fallos de contraseña (§4.2): el account_id si no es
// 0 o, si el correo no tiene cuenta, el SHA-256 del correo normalizado.
func accountKey(accountID int64, email string) string {
	if accountID != 0 {
		return "a:" + strconv.FormatInt(accountID, 10)
	}
	return "e:" + emailHash(email)
}

// sanctionedHMAC es la huella de un correo en sanctioned_email_hashes (§11.2).
func (s *Service) sanctionedHMAC(email string) []byte {
	m := hmac.New(sha256.New, s.cfg.EmailHMACKey)
	m.Write([]byte(email))
	return m.Sum(nil)
}

// link arma el enlace de un correo: ELDMARK_PUBLIC_URL/<página>?token=….
func (s *Service) link(page, token string) string {
	return s.cfg.PublicURL.String() + "/" + page + "?token=" + token
}

// sendMail compone y envía un correo. Un fallo se registra y no cambia la respuesta: la API no
// delata si un correo salió.
func (s *Service) sendMail(ctx context.Context, tpl mail.Template, to string, data mail.Data) {
	m, err := mail.Compose(tpl, to, data)
	if err == nil {
		err = s.mail.Send(context.WithoutCancel(ctx), m)
	}
	if err != nil {
		s.log.LogAttrs(ctx, slog.LevelError, "no se ha podido enviar un correo", slog.String("req", logx.RequestID(ctx)),
			slog.String("to", logx.MaskEmail(to)), slog.String("template", string(tpl)), slog.String("err", err.Error()))
	}
}

// allowMail gasta una ficha del límite de correos del destinatario y de la IP (§4.2: 3 por
// cuenta y hora y 10 por IP y hora).
func (s *Service) allowMail(recipient string, ip netip.Addr, now time.Time) error {
	ok, wait := ratelimit.AllowAll(now,
		ratelimit.Key{Limiter: s.limits.mailAccount, Key: emailHash(recipient)},
		ratelimit.Key{Limiter: s.limits.mailIP, Key: httpx.AddrGroup(ip)})
	if !ok {
		return errRateLimited(wait)
	}
	return nil
}

// Acceso a la base.

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

type querier interface {
	execer
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ClientMeta son los datos de la conexión que se guardan con la sesión y en auth_events.
type ClientMeta struct {
	IP        netip.Addr
	UserAgent string
	Protocol  int
}

func cleanUserAgent(ua string) string {
	ua = strings.ToValidUTF8(ua, "")
	if len(ua) > maxUserAgent {
		ua = ua[:maxUserAgent]
		for !utf8.ValidString(ua) {
			ua = ua[:len(ua)-1]
		}
	}
	return ua
}

func nullIP(ip netip.Addr) any {
	if !ip.IsValid() {
		return nil
	}
	return ip
}

func nullID(id int64) any {
	if id == 0 {
		return nil
	}
	return id
}

// event escribe una fila en auth_events (kind: §4.2).
func (s *Service) event(ctx context.Context, q execer, accountID int64, kind string, meta ClientMeta, at time.Time) error {
	_, err := q.Exec(ctx, `insert into auth_events (account_id, kind, ip, user_agent, at) values ($1, $2, $3, $4, $5)`,
		nullID(accountID), kind, nullIP(meta.IP), nullString(cleanUserAgent(meta.UserAgent)), at)
	return err
}

// Event escribe una fila en auth_events dentro de la transacción de quien llama: los personajes
// (P2) anotan así character_create y character_delete, que cuentan en sus límites diarios (§4.2).
func (s *Service) Event(ctx context.Context, tx pgx.Tx, accountID int64, kind string, meta ClientMeta, at time.Time) error {
	return s.event(ctx, tx, accountID, kind, meta, at)
}

// eventLogged escribe la fila fuera de la transacción de la petición; un fallo solo se registra.
func (s *Service) eventLogged(ctx context.Context, accountID int64, kind string, meta ClientMeta, at time.Time) {
	if err := s.event(context.WithoutCancel(ctx), s.pool, accountID, kind, meta, at); err != nil {
		s.log.LogAttrs(ctx, slog.LevelError, "auth_events", slog.String("req", logx.RequestID(ctx)),
			slog.String("kind", kind), slog.String("err", err.Error()))
	}
}

func nullString(v string) any {
	if v == "" {
		return nil
	}
	return v
}

// unix devuelve la fecha Unix de un instante, o nil.
func unix(t *time.Time) *int64 {
	if t == nil {
		return nil
	}
	v := t.Unix()
	return &v
}
