// Package characters es la API de personajes de la plataforma (plataforma.md §4.4 y §4.5, TEC-24,
// SOC-13, PRG-41): la lista de una cuenta en un mundo, la comprobación de nombres, crear (reino de
// la cuenta, huecos con derechos, nombre único y validación de raza, apariencia y plantilla), borrar
// con plazo para restaurar y el nombre reservado, restaurar, el renombrado forzado y entrar al mundo,
// que elige la zona y emite el billete de 52 B (internal/tickets).
//
// También purga los personajes ([Purger]): los borrados cuyo plazo venció (trabajo horario) y los
// de una cuenta que se purga (accounts.CharacterPurger), dejando la lápida de §11.2.
//
// La plataforma no lee columnas del progreso: raza, apariencia, nivel, última zona y tiempo jugado
// salen de persistence.ProgressStore.Summaries (§7.5).
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

// Plazos y topes de plataforma.md §0, §4.2 y §4.4.
const (
	RestoreWindow      = 7 * 24 * time.Hour  // un personaje borrado se puede restaurar 7 días
	NameReservation    = 30 * 24 * time.Hour // su nombre queda reservado restore_until + 30 días
	RenameReservation  = 30 * 24 * time.Hour // el nombre viejo de un renombrado
	RealmUnlockDelay   = 30 * 24 * time.Hour // el reino se libera 30 días después de borrar el último
	TrialAge           = 24 * time.Hour      // personaje de prueba: menos de 24 h de vida…
	TrialPlayedSeconds = 3600                // …y menos de 1 h jugada
	DailyLimit         = 5                   // creaciones y borrados por cuenta y día
	dailyWindow        = 24 * time.Hour
	busyRetrySeconds   = 3 // character_busy: el cliente reintenta cada 3 s
)

// Options son las dependencias del servicio.
type Options struct {
	Config   *config.Config
	Pool     *pgxpool.Pool
	Log      *slog.Logger
	Clock    clock.Clock // por defecto, el del sistema
	Accounts *accounts.Service
	Progress persistence.ProgressStore
	// Validator valida raza, apariencia y plantilla al crear; nil: persistence.ProvisionalValidator
	// (hasta progresion.md P7, que aporta *progress.Rules).
	Validator persistence.CreateValidator
	// Names son las reglas de los nombres; nil: las de progression_rules.json.
	Names *names.Rules
	// Purger es la purga de personajes; nil: una nueva. serve la crea antes para dársela también a
	// accounts (accounts.Options.Characters).
	Purger *Purger
	// MinProtocol es el protocolo mínimo del cliente para la regla del 426.
	MinProtocol int
}

// Service es el servicio de personajes.
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
	nameCheck *ratelimit.Limiter // 30/min por sesión
	enter     *ratelimit.Limiter // 10/min por cuenta
}

// New prepara el servicio.
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

// Errores de la API pública (§4.1).

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

// realmTitles son los nombres de los reinos en los textos.
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

// Ayudas.

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func unix(t *time.Time) *int64 {
	if t == nil {
		return nil
	}
	v := t.Unix()
	return &v
}

// leaseAlive es la condición de un arrendamiento vivo de character_leases l (§5.3) a la hora $now.
const leaseAlive = `l.zone_instance_id is not null and l.expires_at > `

// dailyLimit mira cuántas filas kind tiene la cuenta en auth_events en las últimas 24 h; con
// [DailyLimit] o más, devuelve el 429 con lo que falta para que salga la más vieja de la ventana.
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

// lockAccount bloquea la fila de la cuenta (el orden de la reclamación, §5.3, y de la purga,
// §11.2) y devuelve su estado y su purge_after.
func lockAccount(ctx context.Context, tx pgx.Tx, accountID int64) (status string, purgeAfter *time.Time, err error) {
	err = tx.QueryRow(ctx, `select status, purge_after from accounts where account_id = $1 for no key update`,
		accountID).Scan(&status, &purgeAfter)
	return status, purgeAfter, err
}

// summaries lee los resúmenes del progreso; un fallo del almacén es un error de la petición.
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

// checkWorld devuelve 404 si el mundo no existe, y su estado si existe.
func (s *Service) checkWorld(ctx context.Context, q persistence.Querier, worldID int16) (string, error) {
	var status string
	err := q.QueryRow(ctx, `select status from worlds where world_id = $1`, worldID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", httpx.ErrNotFound
	}
	return status, err
}

// openRealm dice si se pueden crear personajes en el reino (ELDMARK_OPEN_REALMS).
func (s *Service) openRealm(r config.Realm) bool {
	for _, open := range s.cfg.OpenRealms {
		if open == r {
			return true
		}
	}
	return false
}
