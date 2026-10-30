package accounts

import (
	"context"
	"errors"
	"log/slog"
	"net/netip"
	"strconv"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/passwords"
	"eldmark/platform/internal/ratelimit"
)

// Reglas de los fallos de contraseña (§4.2).
const (
	groupLockAfter     = 5                // fallos seguidos desde un grupo de IP
	groupLock          = 15 * time.Minute // …sin intentos desde ese grupo
	groupLongLockAfter = 10
	groupLongLock      = time.Hour
	accountSlowAfter   = 5                // fallos seguidos de la cuenta, desde cualquier IP
	accountSlowEvery   = 30 * time.Second // …un intento cada 30 s
	alertAfter         = 5                // al 5.º fallo seguido, correo login_failures
	alertEvery         = 24 * time.Hour
	maxGroupsPerKey    = 256
)

// ErrThrottled es la causa de un [*ThrottledError]: demasiados fallos de contraseña (429).
var ErrThrottled = errors.New("accounts: demasiados intentos de contraseña")

// ThrottledError dice cuánto falta para poder volver a intentarlo.
type ThrottledError struct{ RetryAfter time.Duration }

func (e *ThrottledError) Error() string {
	return "accounts: demasiados intentos de contraseña; espera " + e.RetryAfter.String()
}

// Is hace que errors.Is(err, ErrThrottled) valga.
func (e *ThrottledError) Is(target error) bool { return target == ErrThrottled }

// failureTracker lleva los fallos de contraseña en memoria (una sola instancia en la fase 5; LRU
// de 100 000 claves de cuenta).
type failureTracker struct {
	mu    sync.Mutex
	keys  *ratelimit.LRU[string, *keyFailures]
	turns map[string]*keyTurn // las claves con algún intento en curso (fuera del LRU: no se expulsan)
}

// keyTurn es el turno de una clave: un intento a la vez por cuenta (§4.2), para que comprobar el
// freno, mirar la contraseña y anotar el fallo sean una sola sección. Si no, los intentos
// simultáneos pasaban todos la comprobación antes de que se anotara ningún fallo.
type keyTurn struct {
	slot    chan struct{} // capacidad 1
	waiting int           // intentos que lo tienen o lo esperan; con 0 se borra
}

type keyFailures struct {
	consecutive int       // fallos seguidos de la cuenta, desde cualquier IP
	lastFail    time.Time // el último
	lastAlert   time.Time // el último correo login_failures
	groups      map[string]*groupFailures
}

type groupFailures struct {
	consecutive int
	lockedUntil time.Time
	last        time.Time
}

func newFailureTracker(capacity int) *failureTracker {
	return &failureTracker{keys: ratelimit.NewLRU[string, *keyFailures](capacity), turns: map[string]*keyTurn{}}
}

// turn espera el turno de la clave (o a que venza ctx) y devuelve la función que lo suelta.
func (f *failureTracker) turn(ctx context.Context, key string) (func(), error) {
	f.mu.Lock()
	t := f.turns[key]
	if t == nil {
		t = &keyTurn{slot: make(chan struct{}, 1)}
		f.turns[key] = t
	}
	t.waiting++
	f.mu.Unlock()
	leave := func() {
		f.mu.Lock()
		if t.waiting--; t.waiting == 0 {
			delete(f.turns, key)
		}
		f.mu.Unlock()
	}
	select {
	case t.slot <- struct{}{}:
		return func() { <-t.slot; leave() }, nil
	case <-ctx.Done():
		leave()
		return nil, ctx.Err()
	}
}

// check dice cuánto falta para que la clave pueda intentarlo desde el grupo (0: ya).
func (f *failureTracker) check(key, group string, now time.Time) time.Duration {
	f.mu.Lock()
	defer f.mu.Unlock()
	k, ok := f.keys.Get(key)
	if !ok {
		return 0
	}
	var wait time.Duration
	if g := k.groups[group]; g != nil && now.Before(g.lockedUntil) {
		wait = g.lockedUntil.Sub(now)
	}
	if k.consecutive >= accountSlowAfter {
		if next := k.lastFail.Add(accountSlowEvery); now.Before(next) {
			wait = max(wait, next.Sub(now))
		}
	}
	return wait
}

// fail anota un fallo y dice si toca avisar al dueño.
func (f *failureTracker) fail(key, group string, now time.Time) (alert bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	k, ok := f.keys.Get(key)
	if !ok {
		k = &keyFailures{groups: map[string]*groupFailures{}}
		f.keys.Put(key, k)
	}
	k.consecutive++
	k.lastFail = now
	g := k.groups[group]
	if g == nil {
		if len(k.groups) >= maxGroupsPerKey {
			var oldest string
			for name, other := range k.groups {
				if oldest == "" || other.last.Before(k.groups[oldest].last) {
					oldest = name
				}
			}
			delete(k.groups, oldest)
		}
		g = &groupFailures{}
		k.groups[group] = g
	}
	g.consecutive++
	g.last = now
	switch {
	case g.consecutive >= groupLongLockAfter:
		g.lockedUntil = now.Add(groupLongLock)
	case g.consecutive >= groupLockAfter:
		g.lockedUntil = now.Add(groupLock)
	}
	if k.consecutive == alertAfter && (k.lastAlert.IsZero() || now.Sub(k.lastAlert) >= alertEvery) {
		k.lastAlert = now
		return true
	}
	return false
}

// success reinicia los fallos de la clave (los de la cuenta y los de todos sus grupos); el último
// aviso se conserva.
func (f *failureTracker) success(key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if k, ok := f.keys.Get(key); ok {
		k.consecutive = 0
		k.groups = map[string]*groupFailures{}
	}
}

// CheckPassword es la única función que comprueba contraseñas (§4.2): la usan el inicio de sesión
// y las rutas con sesión que piden contraseña, con los mismos contadores. accountID es 0 para un
// correo sin cuenta y email es el normalizado (en las rutas con sesión, el actual de la cuenta).
//
// Los intentos de una misma clave van de uno en uno: el freno se comprueba con el turno tomado y el
// fallo se anota antes de soltarlo, así que N intentos a la vez cuentan como N seguidos (sin el
// turno, todos pasaban la comprobación antes de que se anotara el primer fallo). Los de claves
// distintas no se esperan.
//
// La clave de los fallos es el accountID o, si es 0, el SHA-256 del correo: cada correo sin cuenta
// tiene su propio contador y frenar uno no delata a los demás. Con un correo sin cuenta, o una
// cuenta sin contraseña (password_hash nulo tras revertir el correo), se comprueba contra el hash
// de relleno: el tiempo no delata nada. Con demasiados fallos devuelve un [*ThrottledError]
// (429), exista o no la cuenta. Si la cadena guardada no usa los parámetros actuales, la reescribe.
func (s *Service) CheckPassword(ctx context.Context, accountID int64, email string, password string, ip netip.Addr) (bool, error) {
	key := accountKey(accountID, email)
	ok, rehash, phc, alert, err := s.checkInTurn(ctx, key, accountID, password, httpx.AddrGroup(ip))
	if err != nil || !ok {
		if alert && accountID != 0 {
			s.sendMail(ctx, mail.LoginFailures, email, mail.Data{})
		}
		return false, err
	}
	if rehash {
		if fresh, err := passwords.HashContext(ctx, password, s.params); err == nil {
			// Solo si nadie la ha cambiado entre medias.
			if _, err := s.pool.Exec(ctx, `update accounts set password_hash = $2 where account_id = $1 and password_hash = $3`,
				accountID, fresh, phc); err != nil {
				s.log.LogAttrs(ctx, slog.LevelWarn, "no se ha podido reescribir el hash", slog.String("req", logx.RequestID(ctx)),
					slog.String("err", err.Error()))
			}
		}
	}
	return true, nil
}

// checkInTurn es lo de [Service.CheckPassword] que va con el turno de la clave: el freno, la
// consulta, argon2 y anotar el fallo o el acierto. alert dice si toca el correo login_failures.
func (s *Service) checkInTurn(ctx context.Context, key string, accountID int64, password, group string) (
	ok, rehash bool, phc string, alert bool, err error) {
	release, err := s.failures.turn(ctx, key)
	if err != nil {
		return false, false, "", false, err
	}
	defer release()
	now := s.clock.Now()
	if wait := s.failures.check(key, group, now); wait > 0 {
		return false, false, "", false, &ThrottledError{RetryAfter: wait}
	}
	// La misma consulta también sin cuenta (con el id 0, que no existe): el tiempo no cambia.
	phc = s.filler
	var stored *string
	err = s.pool.QueryRow(ctx, `select password_hash from accounts where account_id = $1 and status <> 'purged'`,
		accountID).Scan(&stored)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, false, "", false, err
	}
	if stored != nil && accountID != 0 {
		phc = *stored
	}
	ok, rehash, err = passwords.VerifyContext(ctx, password, phc, s.params)
	if errors.Is(err, passwords.ErrFormat) {
		// Una cadena dañada en la base: se registra y cuenta como fallo, con el tiempo del relleno.
		s.log.LogAttrs(ctx, slog.LevelError, "hash de contraseña no válido", slog.String("req", logx.RequestID(ctx)),
			slog.String("account", strconv.FormatInt(accountID, 10)))
		_, _, err = passwords.VerifyContext(ctx, password, s.filler, s.params)
		ok, rehash = false, false
	}
	if err != nil {
		return false, false, "", false, err
	}
	if phc == s.filler {
		ok = false
	}
	if !ok {
		return false, false, phc, s.failures.fail(key, group, now), nil
	}
	s.failures.success(key)
	return true, rehash, phc, false, nil
}

// resetFailures olvida los fallos de una cuenta (tras recuperar la contraseña).
func (s *Service) resetFailures(accountID int64) { s.failures.success(accountKey(accountID, "")) }

// passwordError convierte el resultado de CheckPassword en la respuesta de una ruta con sesión:
// 429 con el freno, 401 invalid_credentials con una contraseña mala (y la fila password_fail).
func (s *Service) passwordError(ctx context.Context, sess *Session, ok bool, err error, meta ClientMeta) error {
	var throttled *ThrottledError
	switch {
	case errors.As(err, &throttled):
		s.eventLogged(ctx, sess.AccountID, "login_throttled", meta, s.clock.Now())
		return errRateLimited(throttled.RetryAfter)
	case err != nil:
		return err
	case !ok:
		s.eventLogged(ctx, sess.AccountID, "password_fail", meta, s.clock.Now())
		return errInvalidCredentials()
	}
	return nil
}
