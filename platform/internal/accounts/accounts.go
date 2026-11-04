// Package accounts is the platform's accounts and sessions service (platform.md §4.1 to §4.3,
// TEC-23 and TEC-41): registration that does not reveal accounts, login with argon2id and a single
// function that checks passwords ([Service.CheckPassword], with failures per account and IP group),
// sessions with the refresh that rotates in the same row, a privacy session for sanctioned
// accounts, rate limits, the account lifecycle with single-use links (verify, recover, change and
// revert the email, delete), data export, the purge of unverified and deleted accounts, and the
// HTML pages for the email links.
//
// The /v1 routes are mounted by [API.Mount]; [API.RequireSession] also protects those of the
// following packages (characters, entering the world).
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

// Timeouts from platform.md §0, §4.2, §4.3 and §11.1.
const (
	AccessTTL      = 15 * time.Minute    // access token
	SessionTTL     = 12 * time.Hour      // the session, from login; rotating does not extend it
	VerifyTTL      = 24 * time.Hour      // verify_email
	ChangeEmailTTL = 24 * time.Hour      // change_email
	ResetTTL       = time.Hour           // reset_password
	RevertTTL      = 7 * 24 * time.Hour  // revert_email
	DeletionGrace  = 14 * 24 * time.Hour // from the requested deletion to the purge
	UnverifiedTTL  = 7 * 24 * time.Hour  // unverified account (staging and production)
	ExportEvery    = 24 * time.Hour      // one export per day
	BaseSlots      = 6                   // character slots per account and world, without entitlements
)

// Rate limits from §4.2.
const (
	maxPasswordBytes = 512
	maxUserAgent     = 256
)

// Scopes of a session (sessions.scope).
const (
	ScopeGame    = "game"
	ScopePrivacy = "privacy"
)

// CharacterPurger purges an account's characters inside its purge transaction (platform.md §11.2:
// tombstone, ProgressStore.Purge...). It is provided by characters.Purger (P2); without it, an
// account with unpurged characters is not purged and is logged. With a character in the world it
// returns an error that wraps [ErrCharactersBusy] and purges nothing.
type CharacterPurger interface {
	PurgeAccountCharacters(ctx context.Context, tx pgx.Tx, accountID int64, at time.Time) error
}

// Options are the service's dependencies.
type Options struct {
	Config     *config.Config
	Pool       *pgxpool.Pool
	Log        *slog.Logger
	Mail       mail.Sender
	Clock      clock.Clock // by default, the system's
	Legal      *legal.Set
	Characters CharacterPurger // characters.Purger (P2); nil: accounts with characters are not purged
	// Progress gives each character's progression in the export (ProgressStore.Export, §11.2); nil: the
	// export does not include it (this package's tests).
	Progress ProgressExporter
	// MinProtocol is the client's minimum protocol for the 426 rule (already resolved with
	// config.ResolveMinProtocol; 0 while there is no progression_rules.json: the header is enough).
	MinProtocol int
}

// Service is the accounts service.
type Service struct {
	cfg         *config.Config
	pool        *pgxpool.Pool
	log         *slog.Logger
	mail        mail.Sender
	clock       clock.Clock
	legal       *legal.Set
	characters  CharacterPurger
	progress    ProgressExporter
	params      passwords.Params
	filler      string
	failures    *failureTracker
	limits      limits
	minProtocol int
	background  sync.WaitGroup // what continues after responding (Wait)
}

type limits struct {
	login       *ratelimit.Limiter // 10/min, burst 10, per IP group
	register    *ratelimit.Limiter // 3 per hour per IP group
	mailAccount *ratelimit.Limiter // 3 per hour per recipient
	mailIP      *ratelimit.Limiter // 10 per hour per IP group
}

// New prepares the service. It computes the padding hash with the current parameters.
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
		characters: o.Characters, progress: o.Progress, params: params, filler: filler, failures: newFailureTracker(capacity),
		minProtocol: o.MinProtocol,
		limits: limits{
			login:       ratelimit.New(10, time.Minute, 10, capacity),
			register:    ratelimit.New(3, time.Hour, 3, capacity),
			mailAccount: ratelimit.New(3, time.Hour, 3, capacity),
			mailIP:      ratelimit.New(10, time.Hour, 10, capacity),
		},
	}, nil
}

// Public API errors (§4.1).

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

// Email and password (§4.2).

// NormalizeEmail lowercases the email and strips the surrounding whitespace (spaces only: a line
// break is not stripped and makes the email invalid).
func NormalizeEmail(s string) string { return strings.ToLower(strings.Trim(s, " ")) }

// ValidEmail says whether an already normalized email is valid: 3-254 B, printable ASCII only with
// no spaces, a single @, net/mail.ParseAddress returns it unchanged and without a display name, and
// a domain with at least one dot, [a-z0-9-] labels and none starting with xn-- (IDNs are rejected
// in phase 5).
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

// PasswordProblem says why a new password is not valid ("" if it is): too_short (fewer than 10
// characters), too_long (more than 128 characters or 512 B) or same_as_email.
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

// emailHash is an email's key in the limits and in the password failures.
func emailHash(email string) string {
	sum := sha256.Sum256([]byte(email))
	return hex.EncodeToString(sum[:])
}

// accountKey is an account's key in the password failures (§4.2): the account_id if it is not 0
// or, if the email has no account, the SHA-256 of the normalized email.
func accountKey(accountID int64, email string) string {
	if accountID != 0 {
		return "a:" + strconv.FormatInt(accountID, 10)
	}
	return "e:" + emailHash(email)
}

// sanctionedHMAC is an email's fingerprint in sanctioned_email_hashes (§11.2).
func (s *Service) sanctionedHMAC(email string) []byte {
	m := hmac.New(sha256.New, s.cfg.EmailHMACKey)
	m.Write([]byte(email))
	return m.Sum(nil)
}

// link builds an email's link: ELDMARK_PUBLIC_URL/<page>?token=....
func (s *Service) link(page, token string) string {
	return s.cfg.PublicURL.String() + "/" + page + "?token=" + token
}

// sendMail composes and sends an email. A failure is logged and does not change the response: the
// API does not reveal whether an email went out.
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

// allowMail spends a token from the recipient's and the IP's email limit (§4.2: 3 per account per
// hour and 10 per IP per hour).
func (s *Service) allowMail(recipient string, ip netip.Addr, now time.Time) error {
	ok, wait := ratelimit.AllowAll(now,
		ratelimit.Key{Limiter: s.limits.mailAccount, Key: emailHash(recipient)},
		ratelimit.Key{Limiter: s.limits.mailIP, Key: httpx.AddrGroup(ip)})
	if !ok {
		return errRateLimited(wait)
	}
	return nil
}

// Database access.

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

type querier interface {
	execer
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ClientMeta is the connection data stored with the session and in auth_events.
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

// event writes a row in auth_events (kind: §4.2).
func (s *Service) event(ctx context.Context, q execer, accountID int64, kind string, meta ClientMeta, at time.Time) error {
	_, err := q.Exec(ctx, `insert into auth_events (account_id, kind, ip, user_agent, at) values ($1, $2, $3, $4, $5)`,
		nullID(accountID), kind, nullIP(meta.IP), nullString(cleanUserAgent(meta.UserAgent)), at)
	return err
}

// Event writes a row in auth_events inside the caller's transaction: characters (P2) record
// character_create and character_delete this way, which count toward their daily limits (§4.2).
func (s *Service) Event(ctx context.Context, tx pgx.Tx, accountID int64, kind string, meta ClientMeta, at time.Time) error {
	return s.event(ctx, tx, accountID, kind, meta, at)
}

// eventLogged writes the row outside the request's transaction; a failure is only logged.
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

// unix returns the Unix date of an instant, or nil.
func unix(t *time.Time) *int64 {
	if t == nil {
		return nil
	}
	v := t.Unix()
	return &v
}
