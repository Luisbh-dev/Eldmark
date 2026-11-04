// Package characters is the platform's characters API (plataforma.md §4.4 and §4.5, TEC-24, SOC-13,
// PRG-41): an account's list in a world, the name check, create (the account's realm, slots with
// entitlements, unique name and validation of race, appearance and template), delete with a
// restore window and the reserved name, restore, the forced rename and entering the world, which
// picks the zone and issues the 52 B ticket (internal/tickets).
//
// It also purges characters ([Purger]): deleted ones whose window expired (hourly job) and those of
// an account being purged (accounts.CharacterPurger), leaving the §11.2 tombstone.
//
// The platform does not read progression columns: race, appearance, level, last zone and play time
// come from persistence.ProgressStore.Summaries (§7.5).
package characters

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/names"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/ratelimit"
)

// Deadlines and caps from plataforma.md §0, §4.2 and §4.4.
const (
	RestoreWindow      = 7 * 24 * time.Hour  // a deleted character can be restored for 7 days
	NameReservation    = 30 * 24 * time.Hour // its name stays reserved restore_until + 30 days
	RenameReservation  = 30 * 24 * time.Hour // the old name of a rename
	RealmUnlockDelay   = 30 * 24 * time.Hour // the realm is freed 30 days after deleting the last one
	TrialAge           = 24 * time.Hour      // test character: less than 24 h of life...
	TrialPlayedSeconds = 3600                // ...and less than 1 h played
	DailyLimit         = 5                   // creations and deletions per account per day
	dailyWindow        = 24 * time.Hour
	busyRetrySeconds   = 3 // character_busy: the client retries every 3 s
)

// Options are the service's dependencies.
type Options struct {
	Config   *config.Config
	Pool     *pgxpool.Pool
	Log      *slog.Logger
	Clock    clock.Clock // by default, the system's
	Accounts *accounts.Service
	Progress persistence.ProgressStore
	// Validator validates race, appearance and template on creation (serve: *progress.Rules, from
	// progresion.md P7); nil: persistence.ProvisionalValidator, the tests' one.
	Validator persistence.CreateValidator
	// Names are the name rules; nil: those from progression_rules.json.
	Names *names.Rules
	// Purger is the character purge; nil: a new one. serve creates it earlier to give it to accounts
	// too (accounts.Options.Characters).
	Purger *Purger
	// MinProtocol is the client's minimum protocol for the 426 rule.
	MinProtocol int
}

// Service is the characters service.
type Service struct {
	cfg         *config.Config
	pool        *pgxpool.Pool
	log         *slog.Logger
	clock       clock.Clock
	accounts    *accounts.Service
	progress    persistence.ProgressStore
	validator   persistence.CreateValidator
	names       *names.Rules
	purger      *Purger
	minProtocol int
	signKey     []byte
	limits      limits
}

type limits struct {
	nameCheck *ratelimit.Limiter // 30/min per session
	enter     *ratelimit.Limiter // 10/min per account
}

// New prepares the service.
func New(o Options) (*Service, error) {
	if o.Config == nil || o.Pool == nil || o.Accounts == nil || o.Progress == nil {
		return nil, errors.New("characters: faltan dependencias")
	}
	key := o.Config.TicketKeys[o.Config.TicketSignKey]
	if len(key) == 0 {
		return nil, errors.New("characters: no hay clave para firmar billetes")
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	if o.Validator == nil {
		o.Validator = persistence.ProvisionalValidator{}
	}
	if o.Names == nil {
		o.Names = names.Default()
	}
	if o.Purger == nil {
		o.Purger = NewPurger(o.Pool, o.Progress, o.Clock, o.Log)
	}
	capacity := ratelimit.DefaultCapacity
	return &Service{cfg: o.Config, pool: o.Pool, log: o.Log, clock: o.Clock, accounts: o.Accounts, progress: o.Progress,
		validator: o.Validator, names: o.Names, purger: o.Purger,
		minProtocol: o.MinProtocol, signKey: key,
		limits: limits{
			nameCheck: ratelimit.New(30, time.Minute, 30, capacity),
			enter:     ratelimit.New(10, time.Minute, 10, capacity),
		}}, nil
}

// Public API errors (§4.1).

func errValidation(fields map[string]string) *httpx.Error {
	return &httpx.Error{Status: http.StatusBadRequest, Code: "validation", Message: "Datos no válidos", Fields: fields}
}

func (s *Service) errNameInvalid(reason names.Reason) *httpx.Error {
	return &httpx.Error{Status: http.StatusUnprocessableEntity, Code: "name_invalid", Message: s.names.ReasonText(reason),
		Extra: map[string]any{"reason": reason.String()}}
}

func errNameTaken() *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "name_taken", Message: "Ese nombre ya está en uso"}
}

// realmTitles are the realm names in the texts.
var realmTitles = map[config.Realm]string{config.RealmVardheim: "Vardheim", config.RealmSolmarch: "Solmarch",
	config.RealmAskarra: "Askarra"}

func errRealmLocked(realm config.Realm, unlockAt *time.Time) *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "realm_locked", Message: "Tu cuenta es de " + realmTitles[realm],
		Extra: map[string]any{"realm": realm.String(), "unlock_at": unix(unlockAt)}}
}

func errRealmClosed() *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "realm_closed", Message: "Ese reino abre más adelante"}
}

func errSlotsFull() *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "slots_full", Message: "No te quedan huecos"}
}

func errRenameRequired() *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "rename_required",
		Message: "Tu personaje tiene que cambiar de nombre antes de entrar"}
}

func errRenameNotRequired() *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "rename_not_required",
		Message: "Tu personaje no tiene que cambiar de nombre"}
}

func errCharacterBusy() *httpx.Error {
	return &httpx.Error{Status: http.StatusConflict, Code: "character_busy",
		Message: "Tu personaje está saliendo del mundo…", RetryAfter: busyRetrySeconds}
}

func errZoneUnavailable() *httpx.Error {
	return &httpx.Error{Status: http.StatusServiceUnavailable, Code: "zone_unavailable",
		Message: "La zona no está disponible", RetryAfter: 5}
}

func errMaintenance() *httpx.Error {
	return &httpx.Error{Status: http.StatusServiceUnavailable, Code: "maintenance",
		Message: "El mundo está en mantenimiento", RetryAfter: 60, Extra: map[string]any{"until": nil}}
}

func errPendingDeletion(purgeAt *time.Time) *httpx.Error {
	msg := "Tu cuenta se va a borrar"
	if purgeAt != nil {
		msg = "Tu cuenta se borrará el " + mail.FormatDate(*purgeAt)
	}
	return &httpx.Error{Status: http.StatusForbidden, Code: "account_pending_deletion", Message: msg,
		Extra: map[string]any{"deletion_at": unix(purgeAt)}}
}

func errTermsRequired(documents []string) *httpx.Error {
	return &httpx.Error{Status: http.StatusForbidden, Code: "terms_required",
		Message: "Hay textos nuevos que aceptar", Extra: map[string]any{"documents": documents}}
}

func errEmailUnverified() *httpx.Error {
	return &httpx.Error{Status: http.StatusForbidden, Code: "email_unverified", Message: "Verifica tu correo para entrar"}
}

func errRateLimited(wait time.Duration) *httpx.Error {
	s := ratelimit.RetryAfterSeconds(wait)
	return &httpx.Error{Status: http.StatusTooManyRequests, Code: "rate_limited",
		Message: "Demasiados intentos; espera " + strconv.Itoa(s) + " s", RetryAfter: s}
}

// Helpers.

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func unix(t *time.Time) *int64 {
	if t == nil {
		return nil
	}
	v := t.Unix()
	return &v
}

// leaseAlive is the condition of a live lease in character_leases l (§5.3) at time $now.
const leaseAlive = `l.zone_instance_id is not null and l.expires_at > `

// dailyLimit checks how many kind rows the account has in auth_events in the last 24 h; with
// [DailyLimit] or more, it returns the 429 with how long remains for the oldest in the window to
// drop out.
func dailyLimit(ctx context.Context, tx pgx.Tx, accountID int64, kind string, now time.Time) error {
	rows, err := tx.Query(ctx, `select at from auth_events where account_id = $1 and kind = $2 and at > $3
		order by at desc limit $4`, accountID, kind, now.Add(-dailyWindow), DailyLimit)
	if err != nil {
		return err
	}
	times, err := pgx.CollectRows(rows, pgx.RowTo[time.Time])
	if err != nil {
		return err
	}
	if len(times) < DailyLimit {
		return nil
	}
	return errRateLimited(times[len(times)-1].Add(dailyWindow).Sub(now))
}

// lockAccount locks the account's row (the order of the claim, §5.3, and of the purge, §11.2) and
// returns its status and its purge_after.
func lockAccount(ctx context.Context, tx pgx.Tx, accountID int64) (status string, purgeAfter *time.Time, err error) {
	err = tx.QueryRow(ctx, `select status, purge_after from accounts where account_id = $1 for no key update`,
		accountID).Scan(&status, &purgeAfter)
	return status, purgeAfter, err
}

// summaries reads the progression summaries; a store failure is a request error.
func (s *Service) summaries(ctx context.Context, q persistence.Querier, ids []int64) (map[int64]persistence.Summary, error) {
	if len(ids) == 0 {
		return map[int64]persistence.Summary{}, nil
	}
	sums, err := s.progress.Summaries(ctx, q, ids)
	if err != nil {
		return nil, fmt.Errorf("characters: resúmenes del progreso: %w", err)
	}
	return sums, nil
}

// checkWorld returns 404 if the world does not exist, and its status if it does.
func (s *Service) checkWorld(ctx context.Context, q persistence.Querier, worldID int16) (string, error) {
	var status string
	err := q.QueryRow(ctx, `select status from worlds where world_id = $1`, worldID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", httpx.ErrNotFound
	}
	return status, err
}

// openRealm says whether characters can be created in the realm (ELDMARK_OPEN_REALMS).
func (s *Service) openRealm(r config.Realm) bool {
	for _, open := range s.cfg.OpenRealms {
		if open == r {
			return true
		}
	}
	return false
}
