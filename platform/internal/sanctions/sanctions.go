// Package sanctions gathers the rules for sanctions and roles shared by the public API, the
// internal one and the admin CLI (platform.md §6.1, §9.1 and §9.5): an account's active
// restriction (suspension or ban), mutes, pending warnings, the player-facing texts that the
// platform composes, the role ranking, which role can create each sanction, creating a sanction
// with its authorization ([Create], the same for the zone and for the CLI) and the role an
// account had at a given instant ([RoleAt], for the save's S2 check).
//
// It is a leaf: it imports no other platform package except mail (the date in the texts), so
// accounts, zones, persistence and social use it without cycles.
package sanctions

import (
	"context"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/mail"
)

// Sanction types (sanctions.kind).
const (
	KindWarning    = "warning"
	KindMute       = "mute"
	KindSuspension = "suspension"
	KindBan        = "ban"
	KindRename     = "rename"
)

// Account roles (accounts.role), from lowest to highest.
const (
	RolePlayer    = "player"
	RoleModerator = "moderator"
	RoleGM        = "gm"
	RoleAdmin     = "admin"
)

// ShortLimit is how long a moderator's mute and a GM's suspension can last (§9.1).
const ShortLimit = 7 * 24 * time.Hour

// MaxTextBytes is the cap of a player-facing text: the REJECT's text_len (§6.1).
const MaxTextBytes = 255

// NoEndUnix is the Unix date that goes in until_unix of an open-ended mute (9999-12-31 23:59:59
// UTC): the zone compares numbers and a null would force it into another case. Neither the zone
// nor the CLI creates open-ended mutes in phase 5 (both require a duration).
const NoEndUnix int64 = 253402300799

// Querier is a query inside the caller's transaction or connection.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// Restriction is an active suspension or ban.
type Restriction struct {
	Kind   string     // KindSuspension or KindBan
	Until  *time.Time // nil: no end
	Reason string
}

// Message is the player-facing text: "Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC:
// motivo" (your account is suspended until …: reason) or "Tu cuenta está expulsada: motivo" (your
// account is banned: reason), cut to [MaxTextBytes].
func (r *Restriction) Message() string {
	var msg string
	switch {
	case r.Kind == KindBan:
		msg = "Tu cuenta está expulsada"
	case r.Until != nil:
		msg = "Tu cuenta está suspendida hasta el " + mail.FormatDate(*r.Until)
	default:
		msg = "Tu cuenta está suspendida"
	}
	if r.Reason != "" {
		msg += ": " + r.Reason
	}
	return Truncate(msg, MaxTextBytes)
}

// PendingDeletionMessage is the text for an account with deletion requested: "Tu cuenta se
// borrará el …" (your account will be deleted on …).
func PendingDeletionMessage(purgeAfter *time.Time) string {
	if purgeAfter == nil {
		return "Tu cuenta se va a borrar"
	}
	return "Tu cuenta se borrará el " + mail.FormatDate(*purgeAfter)
}

// Truncate cuts s to at most max bytes without splitting a character.
func Truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	s = s[:max]
	for len(s) > 0 && !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

// restrictionSQL picks, per account, the restriction that prevails: a ban over a suspension and,
// among suspensions, the one that ends latest.
const restrictionSQL = `select distinct on (account_id) account_id, kind, ends_at, reason from sanctions
	where account_id = any($1) and revoked_at is null and kind in ('suspension', 'ban')
	  and starts_at <= $2 and (ends_at is null or ends_at > $2)
	order by account_id, (kind = 'ban') desc, ends_at desc nulls first`

// Active returns the account's active suspension or ban at time now, or nil.
func Active(ctx context.Context, q Querier, accountID int64, now time.Time) (*Restriction, error) {
	all, err := ActiveMany(ctx, q, []int64{accountID}, now)
	if err != nil {
		return nil, err
	}
	return all[accountID], nil
}

// ActiveMany is [Active] for several accounts at once; those without a restriction are not returned.
func ActiveMany(ctx context.Context, q Querier, accountIDs []int64, now time.Time) (map[int64]*Restriction, error) {
	out := map[int64]*Restriction{}
	if len(accountIDs) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, restrictionSQL, accountIDs, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		r := &Restriction{}
		if err := rows.Scan(&id, &r.Kind, &r.Until, &r.Reason); err != nil {
			return nil, err
		}
		out[id] = r
	}
	return out, rows.Err()
}

// Mutes returns, per account, until when its active mute lasts at time now (the one that ends
// latest), in Unix time; an open-ended one gives [NoEndUnix]. Accounts without a mute are not returned.
func Mutes(ctx context.Context, q Querier, accountIDs []int64, now time.Time) (map[int64]int64, error) {
	out := map[int64]int64{}
	if len(accountIDs) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `select distinct on (account_id) account_id, ends_at from sanctions
		where account_id = any($1) and revoked_at is null and kind = 'mute'
		  and starts_at <= $2 and (ends_at is null or ends_at > $2)
		order by account_id, ends_at desc nulls first`, accountIDs, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var ends *time.Time
		if err := rows.Scan(&id, &ends); err != nil {
			return nil, err
		}
		out[id] = NoEndUnix
		if ends != nil {
			out[id] = ends.Unix()
		}
	}
	return out, rows.Err()
}

// Rank is the rank of a role (player 0, moderator 1, gm 2, admin 3); an unknown one, -1.
func Rank(role string) int {
	switch role {
	case RolePlayer:
		return 0
	case RoleModerator:
		return 1
	case RoleGM:
		return 2
	case RoleAdmin:
		return 3
	}
	return -1
}

// MinRole is the minimum role that can create a sanction of that type and duration (§9.1):
// warning and mute of up to 7 days, moderator; suspension of up to 7 days and rename, gm; longer
// suspension, ban and mute of more than 7 days, admin ("All"). An unknown type, "" (nobody).
func MinRole(kind string, d time.Duration) string {
	switch kind {
	case KindWarning:
		return RoleModerator
	case KindMute:
		if d <= ShortLimit {
			return RoleModerator
		}
		return RoleAdmin
	case KindSuspension:
		if d <= ShortLimit {
			return RoleGM
		}
		return RoleAdmin
	case KindRename:
		return RoleGM
	case KindBan:
		return RoleAdmin
	}
	return ""
}
