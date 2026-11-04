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

// Rules for password failures (§4.2).
const (
	groupLockAfter     = 5                // consecutive failures from an IP group
	groupLock          = 15 * time.Minute // ...without attempts from that group
	groupLongLockAfter = 10
	groupLongLock      = time.Hour
	accountSlowAfter   = 5                // consecutive failures of the account, from any IP
	accountSlowEvery   = 30 * time.Second // ...one attempt every 30 s
	alertAfter         = 5                // on the 5th consecutive failure, login_failures email
	alertEvery         = 24 * time.Hour
	maxGroupsPerKey    = 256
)

// ErrThrottled is the cause of a [*ThrottledError]: too many password failures (429).
var ErrThrottled = errors.New("accounts: demasiados intentos de contraseña")

// ThrottledError says how long remains before another attempt can be made.
type ThrottledError struct{ RetryAfter time.Duration }

func (e *ThrottledError) Error() string {
	return "accounts: demasiados intentos de contraseña; espera " + e.RetryAfter.String()
}

// Is makes errors.Is(err, ErrThrottled) hold.
func (e *ThrottledError) Is(target error) bool { return target == ErrThrottled }

// failureTracker keeps the password failures in memory (a single instance in phase 5; LRU of
// 100,000 account keys).
type failureTracker struct {
	mu    sync.Mutex
	keys  *ratelimit.LRU[string, *keyFailures]
	turns map[string]*keyTurn // the keys with some attempt in progress (outside the LRU: they are not evicted)
}

// keyTurn is a key's turn: one attempt at a time per account (§4.2), so that checking the brake,
// looking at the password and recording the failure are a single section. Otherwise simultaneous
// attempts all passed the check before any failure was recorded.
type keyTurn struct {
	slot    chan struct{} // capacity 1
	waiting int           // attempts that hold it or are waiting for it; at 0 it is deleted
}

type keyFailures struct {
	consecutive int       // consecutive failures of the account, from any IP
	lastFail    time.Time // the last one
	lastAlert   time.Time // the last login_failures email
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

// turn waits for the key's turn (or for ctx to expire) and returns the function that releases it.
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

// check says how long remains before the key can attempt from the group (0: now).
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

// fail records a failure and says whether the owner should be notified.
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

// success resets the key's failures (the account's and those of all its groups); the last notice is
// kept.
func (f *failureTracker) success(key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if k, ok := f.keys.Get(key); ok {
		k.consecutive = 0
		k.groups = map[string]*groupFailures{}
	}
}

// CheckPassword is the only function that checks passwords (§4.2): login and the routes with a
// session that ask for a password use it, with the same counters. accountID is 0 for an email
// without an account and email is the normalized one (in the routes with a session, the account's
// current one).
//
// The attempts of the same key go one at a time: the brake is checked with the turn taken and the
// failure is recorded before releasing it, so N simultaneous attempts count as N consecutive ones
// (without the turn, they all passed the check before the first failure was recorded). Those of
// different keys do not wait for each other.
//
// The failures' key is the accountID or, if it is 0, the SHA-256 of the email: each email without
// an account has its own counter and braking one does not reveal the others. With an email without
// an account, or an account without a password (null password_hash after reverting the email), it
// is checked against the padding hash: the time reveals nothing. With too many failures it returns
// a [*ThrottledError] (429), whether or not the account exists. If the stored string does not use
// the current parameters, it rewrites it.
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
			// Only if nobody has changed it in the meantime.
			if _, err := s.pool.Exec(ctx, `update accounts set password_hash = $2 where account_id = $1 and password_hash = $3`,
				accountID, fresh, phc); err != nil {
				s.log.LogAttrs(ctx, slog.LevelWarn, "no se ha podido reescribir el hash", slog.String("req", logx.RequestID(ctx)),
					slog.String("err", err.Error()))
			}
		}
	}
	return true, nil
}

// checkInTurn is the part of [Service.CheckPassword] that goes with the key's turn: the brake, the
// query, argon2 and recording the failure or the success. alert says whether the login_failures
// email is due.
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
	// The same query also without an account (with id 0, which does not exist): the time does not
	// change.
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
		// A corrupted string in the database: it is logged and counts as a failure, with the padding time.
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

// resetFailures forgets an account's failures (after recovering the password).
func (s *Service) resetFailures(accountID int64) { s.failures.success(accountKey(accountID, "")) }

// passwordError turns CheckPassword's result into the response of a route with a session: 429 with
// the brake, 401 invalid_credentials with a bad password (and the password_fail row).
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
