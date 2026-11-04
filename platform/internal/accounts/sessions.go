package accounts

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/sanctions"
)

// Session is the session of an authenticated request.
type Session struct {
	ID        int64
	AccountID int64
	Scope     string // ScopeGame or ScopePrivacy
	Email     string
	Role      string
	Status    string // active or pending_deletion
}

type sessionKey struct{}

// WithSession stores the session in the context.
func WithSession(ctx context.Context, s *Session) context.Context {
	return context.WithValue(ctx, sessionKey{}, s)
}

// SessionFrom returns the request's session, or nil (outside [API.RequireSession]).
func SessionFrom(ctx context.Context) *Session {
	s, _ := ctx.Value(sessionKey{}).(*Session)
	return s
}

// Restriction is the sanction that restricts an account: a current suspension or ban.
type Restriction struct {
	Code   string     // account_suspended or account_banned
	Until  *time.Time // nil: no end
	Reason string
}

// Message is the text for the player (§4.1 and §6.1): "Tu cuenta está suspendida hasta el
// 3/11/2026 18:00 UTC: motivo" (your account is suspended until...) or "Tu cuenta está expulsada:
// motivo" (your account is banned), truncated to 255 B (sanctions.Restriction.Message, the same
// text as the claim and the heartbeat).
func (r *Restriction) Message() string {
	kind := sanctions.KindSuspension
	if r.Code == "account_banned" {
		kind = sanctions.KindBan
	}
	return (&sanctions.Restriction{Kind: kind, Until: r.Until, Reason: r.Reason}).Message()
}

// Error is the restriction's 403, with until (Unix date or null) and reason.
func (r *Restriction) Error() *httpx.Error {
	return &httpx.Error{Status: http.StatusForbidden, Code: r.Code, Message: r.Message(),
		Extra: map[string]any{"until": unix(r.Until), "reason": r.Reason}}
}

// RestrictionView is the restriction in JSON: {code, until, reason}.
type RestrictionView struct {
	Code   string `json:"code"`
	Until  *int64 `json:"until"`
	Reason string `json:"reason"`
}

func (r *Restriction) view() *RestrictionView {
	if r == nil {
		return nil
	}
	return &RestrictionView{Code: r.Code, Until: unix(r.Until), Reason: r.Reason}
}

// ActiveRestriction returns the account's current suspension or ban, or nil. A ban takes precedence
// over a suspension; among suspensions, the one that ends later.
func ActiveRestriction(ctx context.Context, q querier, accountID int64, now time.Time) (*Restriction, error) {
	active, err := sanctions.Active(ctx, q, accountID, now)
	if err != nil || active == nil {
		return nil, err
	}
	r := &Restriction{Code: "account_suspended", Until: active.Until, Reason: active.Reason}
	if active.Kind == sanctions.KindBan {
		r.Code = "account_banned"
	}
	return r, nil
}

// Tokens is a session's token pair.
type Tokens struct {
	AccessToken      string `json:"access_token"`
	AccessExpiresIn  int64  `json:"access_expires_in"`
	RefreshToken     string `json:"refresh_token"`
	RefreshExpiresIn int64  `json:"refresh_expires_in"`
	Scope            string `json:"scope"`
}

// LoginResult is the response of POST /v1/sessions.
type LoginResult struct {
	Tokens
	Restriction *RestrictionView `json:"restriction"`
	Account     *AccountView     `json:"account"`
}

func seconds(d time.Duration) int64 { return int64(d.Round(time.Second) / time.Second) }

// Login logs in (§4.2). With a bad password, invalid_credentials whether or not the account is
// sanctioned (and whether or not it exists); with a good one, a suspended or banned account gets the
// privacy session. Logging in revokes the account's other sessions (replaced).
func (s *Service) Login(ctx context.Context, email, password string, meta ClientMeta) (*LoginResult, error) {
	email = NormalizeEmail(email)
	fields := map[string]string{}
	if !ValidEmail(email) {
		fields["email"] = "invalid"
	}
	if password == "" || len(password) > maxPasswordBytes {
		fields["password"] = "invalid"
	}
	if len(fields) > 0 {
		return nil, errValidation(fields)
	}
	now := s.clock.Now()
	if ok, wait := s.limits.login.Allow(groupOf(meta), now); !ok {
		s.eventLogged(ctx, 0, "login_throttled", meta, now)
		return nil, errRateLimited(wait)
	}
	var accountID int64
	err := s.pool.QueryRow(ctx, `select account_id from accounts where email = $1`, email).Scan(&accountID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	ok, err := s.CheckPassword(ctx, accountID, email, password, meta.IP)
	var throttled *ThrottledError
	switch {
	case errors.As(err, &throttled):
		s.eventLogged(ctx, accountID, "login_throttled", meta, now)
		return nil, errRateLimited(throttled.RetryAfter)
	case err != nil:
		return nil, err
	case !ok:
		s.eventLogged(ctx, accountID, "login_fail", meta, now)
		return nil, errInvalidCredentials()
	}
	var res *LoginResult
	err = db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		var status string
		err := tx.QueryRow(ctx, `select status from accounts where account_id = $1 for no key update`, accountID).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) || status == "purged" {
			return errInvalidCredentials()
		}
		if err != nil {
			return err
		}
		restriction, err := ActiveRestriction(ctx, tx, accountID, now)
		if err != nil {
			return err
		}
		scope := ScopeGame
		if restriction != nil {
			scope = ScopePrivacy
		}
		tokens, sessionID, err := s.createSession(ctx, tx, accountID, scope, meta, now)
		if err != nil {
			return err
		}
		if err := revokeSessions(ctx, tx, accountID, sessionID, "replaced", now); err != nil {
			return err
		}
		if err := s.event(ctx, tx, accountID, "login_ok", meta, now); err != nil {
			return err
		}
		view, err := s.accountView(ctx, tx, accountID, now)
		if err != nil {
			return err
		}
		res = &LoginResult{Tokens: tokens, Restriction: restriction.view(), Account: view}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return res, nil
}

// createSession inserts the row of a new session: 12 h from now, 15 min access.
func (s *Service) createSession(ctx context.Context, tx pgx.Tx, accountID int64, scope string, meta ClientMeta,
	now time.Time) (Tokens, int64, error) {
	access, accessHash := newToken()
	refresh, refreshHash := newToken()
	refreshExp := now.Add(SessionTTL)
	accessExp := now.Add(AccessTTL)
	var id int64
	err := tx.QueryRow(ctx, `insert into sessions (account_id, access_hash, access_expires_at, refresh_hash,
		refresh_expires_at, scope, ip, user_agent, client_protocol, created_at)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) returning session_id`,
		accountID, accessHash, accessExp, refreshHash, refreshExp, scope, nullIP(meta.IP),
		nullString(cleanUserAgent(meta.UserAgent)), nullID(int64(meta.Protocol)), now).Scan(&id)
	if err != nil {
		return Tokens{}, 0, err
	}
	return Tokens{AccessToken: access, AccessExpiresIn: seconds(AccessTTL), RefreshToken: refresh,
		RefreshExpiresIn: seconds(SessionTTL), Scope: scope}, id, nil
}

// revokeSessions revokes the account's live sessions except except (0: all).
func revokeSessions(ctx context.Context, q execer, accountID, except int64, reason string, now time.Time) error {
	_, err := q.Exec(ctx, `update sessions set revoked_at = $3, revoke_reason = $4
		where account_id = $1 and session_id <> $2 and revoked_at is null`, accountID, except, now, reason)
	return err
}

// Refresh rotates the token pair in the same row (§4.2). The previous refresh (prev_refresh_hash)
// on a live session is a reuse: it revokes the session (refresh_reuse) and gives 401. One from two
// rotations ago gives 401 without revoking. The session is not extended: the new access does not go
// past refresh_expires_at, and the scope (game or privacy) is kept.
func (s *Service) Refresh(ctx context.Context, refreshToken string, meta ClientMeta) (*Tokens, error) {
	if !ValidToken(refreshToken) {
		return nil, errUnauthorized()
	}
	given := hashToken(refreshToken)
	access, accessHash := newToken()
	refresh, refreshHash := newToken()
	now := s.clock.Now()
	var res *Tokens
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		res = nil
		var scope string
		var accessExp, refreshExp time.Time
		err := tx.QueryRow(ctx, `update sessions set prev_refresh_hash = refresh_hash, refresh_hash = $2,
			access_hash = $3, access_expires_at = least($4::timestamptz, refresh_expires_at), rotated_at = $5
			where refresh_hash = $1 and revoked_at is null and refresh_expires_at > $5
			returning scope, access_expires_at, refresh_expires_at`,
			given, refreshHash, accessHash, now.Add(AccessTTL), now).Scan(&scope, &accessExp, &refreshExp)
		if err == nil {
			res = &Tokens{AccessToken: access, AccessExpiresIn: seconds(accessExp.Sub(now)), RefreshToken: refresh,
				RefreshExpiresIn: seconds(refreshExp.Sub(now)), Scope: scope}
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var accountID int64
		err = tx.QueryRow(ctx, `update sessions set revoked_at = $2, revoke_reason = 'refresh_reuse'
			where prev_refresh_hash = $1 and revoked_at is null and refresh_expires_at > $2
			returning account_id`, given, now).Scan(&accountID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		// The revocation is committed and the response is 401 (res stays nil).
		return s.event(ctx, tx, accountID, "refresh_reuse", meta, now)
	})
	if err != nil {
		return nil, err
	}
	if res == nil {
		return nil, errUnauthorized()
	}
	return res, nil
}

// Logout revokes the session (logout).
func (s *Service) Logout(ctx context.Context, sess *Session) error {
	_, err := s.pool.Exec(ctx, `update sessions set revoked_at = $2, revoke_reason = 'logout'
		where session_id = $1 and revoked_at is null`, sess.ID, s.clock.Now())
	return err
}

// Authenticate returns the session of a live access token, or nil.
func (s *Service) Authenticate(ctx context.Context, accessToken string) (*Session, error) {
	if !ValidToken(accessToken) {
		return nil, nil
	}
	sess := &Session{}
	err := s.pool.QueryRow(ctx, `select s.session_id, s.account_id, s.scope, a.email, a.role, a.status
		from sessions s join accounts a using (account_id)
		where s.access_hash = $1 and s.revoked_at is null and s.access_expires_at > $2
		  and a.status <> 'purged' and a.email is not null`, hashToken(accessToken), s.clock.Now()).
		Scan(&sess.ID, &sess.AccountID, &sess.Scope, &sess.Email, &sess.Role, &sess.Status)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return sess, nil
}

func groupOf(meta ClientMeta) string { return httpx.AddrGroup(meta.IP) }
