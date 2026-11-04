package sanctions

import (
	"context"
	"time"
)

// CommandSetRole is the command of the fixed set-role row (§9.1): source cli, actor_account_id
// of the --actor, target_account_id the account and args {from, to, os_user}.
const CommandSetRole = "set-role"

// Roles are the valid roles, from lowest to highest.
var Roles = []string{RolePlayer, RoleModerator, RoleGM, RoleAdmin}

// RoleAt is the role the account had at instant at, for the save's S2 check (progresion.md
// §13.3: the actor of a GM or REVERSAL operation with the role they had at detail.at_unix). It is
// given by the first CLI set-role row after at, with its args.from: the role from before that
// change; with none, the current role. Only rows with source = 'cli' count (those written by the
// admin command): a zone cannot write them (§6, "Batches"), so it cannot give anyone a past role.
// "" if the account does not exist.
func RoleAt(ctx context.Context, q Querier, accountID int64, at time.Time) (string, error) {
	var role *string
	err := q.QueryRow(ctx, `select coalesce(
			(select args->>'from' from audit_log
			 where target_account_id = $1 and command = 'set-role' and source = 'cli' and at > $2
			 order by at, id limit 1),
			(select role from accounts where account_id = $1))`, accountID, at).Scan(&role)
	if err != nil || role == nil {
		return "", err
	}
	return *role, nil
}

// Warning is a warning (§9.5: "on entering, NOTICE with the reason").
type Warning struct {
	SanctionID int64
	Reason     string
	At         time.Time
}

// Text is the player-facing text, composed by the platform like the others (§6.1): "Has recibido
// un aviso de la moderación: motivo" (you have received a warning from moderation: reason), cut to [MaxTextBytes].
func (w Warning) Text() string {
	msg := "Has recibido un aviso de la moderación"
	if w.Reason != "" {
		msg += ": " + w.Reason
	}
	return Truncate(msg, MaxTextBytes)
}

// MaxWarnings is how many pending warnings a claim brings at most (the most recent ones).
const MaxWarnings = 5

// PendingWarnings returns the account's warnings that it has not yet seen in that world: not
// revoked, from that world or all of them, issued up to now and after since (the last world entry
// of any of its characters, before this one; nil if it never entered). This way each warning
// appears on the first entry that follows it and, afterwards, only remains on the account (it
// counts toward recidivism, social.md §9). The most recent ones, [MaxWarnings] at most, from
// oldest to newest.
func PendingWarnings(ctx context.Context, q Querier, accountID int64, worldID int16, since *time.Time,
	now time.Time) ([]Warning, error) {
	rows, err := q.Query(ctx, `select sanction_id, reason, starts_at from (
			select sanction_id, reason, starts_at from sanctions
			where account_id = $1 and kind = 'warning' and revoked_at is null and (world_id is null or world_id = $2)
			  and starts_at <= $4 and ($3::timestamptz is null or starts_at > $3)
			order by starts_at desc, sanction_id desc limit $5) w
		order by starts_at, sanction_id`, accountID, worldID, since, now, MaxWarnings)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Warning{}
	for rows.Next() {
		var w Warning
		if err := rows.Scan(&w.SanctionID, &w.Reason, &w.At); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}
