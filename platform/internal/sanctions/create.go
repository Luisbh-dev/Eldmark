package sanctions

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

// Sources of the audit_log rows the platform writes (§9.1): sanctions requested by a GM from the
// zone (through the internal API) and the admin CLI's commands.
const (
	SourcePlatform = "platform"
	SourceCLI      = "cli"
)

// audit_log commands for a sanction (§9.5): created or denied. Both are written only by the
// platform; a zone cannot send them in its batch.
const (
	CommandSanction       = "sanction"
	CommandSanctionDenied = "sanction_denied"
)

// Denial is why the platform does not let a sanction be created (it goes in args.denied of sanction_denied).
type Denial string

const (
	DeniedNoLease    Denial = "no_lease"    // the author has no lease on the instance
	DeniedRole       Denial = "role"        // their role is not enough for that type and duration
	DeniedTargetRole Denial = "target_role" // the target does not have a lower role
)

// [Create] errors that are not authorization errors.
var (
	// ErrUnknownReports: some report_id is not a report of the sanction's world (400).
	ErrUnknownReports = errors.New("sanctions: hay reportes que no son de ese mundo")
	// ErrBadRequest: the type, duration or reason is not valid.
	ErrBadRequest = errors.New("sanctions: tipo, duración o motivo que no valen")
)

// Request is a requested sanction (§9.5), from the zone (/gm …, through the internal API) or from
// the CLI (admin --actor <email> sanction …). The target is already resolved (by name in the
// world, in the caller's transaction); its role is read here with its row locked.
type Request struct {
	WorldID int16
	ZoneID  string // the instance's zone; "" from the CLI
	Source  string // SourcePlatform (the zone) or SourceCLI

	// AuthorCharacterID is the GM's character (from the zone): their account comes from characters
	// in the sanction's world, and they must hold a lease on Instance.
	AuthorCharacterID int64
	Instance          *[16]byte
	// AuthorAccountID is the --actor's account (from the CLI), with no character or instance.
	AuthorAccountID int64
	// RequireRole is a minimum role for the author besides the one in the §9.1 table ("admin" in the
	// CLI, which requires admin for any command that changes something); "" if none.
	RequireRole string

	TargetAccountID   int64
	TargetCharacterID int64

	Kind      string
	Duration  time.Duration // mute and suspension; 0 for the others
	Reason    string
	ReportIDs []int64
	// Args are additional arguments for the audit_log rows (the CLI's os_user). Never an email or a
	// name (§9.1).
	Args map[string]any
	Now  time.Time
}

// Created is a created sanction.
type Created struct {
	SanctionID int64
	EndsAt     *time.Time // nil: no end
}

// Timed says whether the type carries a duration: mute and suspension. Warning, rename and ban
// (permanent) do not.
func Timed(kind string) bool { return kind == KindMute || kind == KindSuspension }

// Create creates the sanction if the platform authorizes it (§9.5), inside the caller's
// transaction tx, which must commit it also when it denies it (the sanction_denied row):
//
//  1. from the zone, the author holds a lease on the instance;
//  2. the author's account has the minimum role from §9.1 for that type and duration (and RequireRole);
//  3. the target account has a lower role than the author's.
//
// The rows of both accounts are locked in id order (for no key update): the role being checked
// does not change midway (set-role locks the same rows). If a check fails it returns the reason
// and leaves a sanction_denied row in audit_log, with the target by id (no names or emails).
// Otherwise, it inserts the sanction with its reports (from that world; if not, [ErrUnknownReports]),
// sets must_rename on a rename and leaves a sanction row.
func Create(ctx context.Context, tx pgx.Tx, req Request) (*Created, Denial, error) {
	if MinRole(req.Kind, req.Duration) == "" || req.Reason == "" || Timed(req.Kind) != (req.Duration > 0) {
		return nil, "", ErrBadRequest
	}
	authorAccount := req.AuthorAccountID
	if req.AuthorCharacterID != 0 {
		authorAccount = 0
		err := tx.QueryRow(ctx, `select account_id from characters where character_id = $1 and world_id = $2`,
			req.AuthorCharacterID, req.WorldID).Scan(&authorAccount)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, "", err
		}
	}
	accounts := []int64{req.TargetAccountID}
	if authorAccount != 0 && authorAccount != req.TargetAccountID {
		accounts = append(accounts, authorAccount)
	}
	slices.Sort(accounts)
	roles, err := lockRoles(ctx, tx, accounts)
	if err != nil {
		return nil, "", err
	}
	authorRole := roles[authorAccount]
	hasLease := true
	if req.Instance != nil {
		err := tx.QueryRow(ctx, `select exists (select 1 from character_leases
			where character_id = $1 and zone_instance_id = $2)`, req.AuthorCharacterID, *req.Instance).Scan(&hasLease)
		if err != nil {
			return nil, "", err
		}
	}
	need := MinRole(req.Kind, req.Duration)
	if Rank(req.RequireRole) > Rank(need) {
		need = req.RequireRole
	}
	var denied Denial
	switch {
	case authorAccount == 0 || !hasLease:
		denied = DeniedNoLease
	case Rank(authorRole) < Rank(need):
		denied = DeniedRole
	case Rank(roles[req.TargetAccountID]) >= Rank(authorRole):
		denied = DeniedTargetRole
	}
	args := map[string]any{"kind": req.Kind, "minutes": int64(req.Duration / time.Minute)}
	for k, v := range req.Args {
		args[k] = v
	}
	row := auditRow{world: req.WorldID, zone: req.ZoneID, source: req.Source, targetAccount: req.TargetAccountID,
		targetCharacter: req.TargetCharacterID, at: req.Now}
	if authorAccount != 0 {
		row.actorAccount = authorAccount
		row.actorCharacter = req.AuthorCharacterID
	}
	if denied != "" {
		args["denied"] = string(denied)
		row.command, row.args = CommandSanctionDenied, args
		return nil, denied, row.insert(ctx, tx)
	}
	if len(req.ReportIDs) > 0 {
		var found int
		if err := tx.QueryRow(ctx, `select count(*) from reports where report_id = any($1) and world_id = $2`,
			req.ReportIDs, req.WorldID).Scan(&found); err != nil {
			return nil, "", err
		}
		if found != len(req.ReportIDs) {
			return nil, "", ErrUnknownReports
		}
	}
	var ends *time.Time
	if Timed(req.Kind) {
		t := req.Now.Add(req.Duration)
		ends = &t
	}
	created := &Created{EndsAt: ends}
	if err := tx.QueryRow(ctx, `insert into sanctions (account_id, world_id, character_id, kind, reason,
			author_account_id, starts_at, ends_at, created_at)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $7) returning sanction_id`,
		req.TargetAccountID, req.WorldID, nullID(req.TargetCharacterID), req.Kind, req.Reason, nullID(authorAccount),
		req.Now, ends).Scan(&created.SanctionID); err != nil {
		return nil, "", err
	}
	for _, id := range req.ReportIDs {
		if _, err := tx.Exec(ctx, `insert into sanction_reports (sanction_id, report_id) values ($1, $2)`,
			created.SanctionID, id); err != nil {
			return nil, "", err
		}
	}
	if req.Kind == KindRename && req.TargetCharacterID != 0 {
		if _, err := tx.Exec(ctx, `update characters set must_rename = true where character_id = $1`,
			req.TargetCharacterID); err != nil {
			return nil, "", err
		}
	}
	args["sanction_id"] = strconv.FormatInt(created.SanctionID, 10)
	if len(req.ReportIDs) > 0 {
		ids := make([]string, len(req.ReportIDs))
		for i, id := range req.ReportIDs {
			ids[i] = strconv.FormatInt(id, 10)
		}
		args["report_ids"] = ids
	}
	row.command, row.args = CommandSanction, args
	if err := row.insert(ctx, tx); err != nil {
		return nil, "", err
	}
	return created, "", nil
}

// lockRoles locks the account rows in id order (for no key update) and returns their role.
func lockRoles(ctx context.Context, tx pgx.Tx, accounts []int64) (map[int64]string, error) {
	rows, err := tx.Query(ctx, `select account_id, role from accounts where account_id = any($1)
		order by account_id for no key update`, accounts)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	roles := map[int64]string{}
	for rows.Next() {
		var id int64
		var role string
		if err := rows.Scan(&id, &role); err != nil {
			return nil, err
		}
		roles[id] = role
	}
	return roles, rows.Err()
}

// auditRow is an audit_log row written by the platform (§9.1): the target by id, with no names or
// emails in args.
type auditRow struct {
	world           int16
	zone            string
	source          string
	actorAccount    int64
	actorCharacter  int64
	command         string
	targetAccount   int64
	targetCharacter int64
	args            map[string]any
	at              time.Time
}

func (r auditRow) insert(ctx context.Context, tx pgx.Tx) error {
	data, err := json.Marshal(r.args)
	if err != nil {
		return err
	}
	var world, zone any
	if r.world != 0 {
		world = r.world
	}
	if r.zone != "" {
		zone = r.zone
	}
	_, err = tx.Exec(ctx, `insert into audit_log (world_id, source, actor_account_id, actor_character_id, zone_id,
			command, target_account_id, target_character_id, args, at)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
		world, r.source, nullID(r.actorAccount), nullID(r.actorCharacter), zone, r.command, nullID(r.targetAccount),
		nullID(r.targetCharacter), data, r.at)
	return err
}

func nullID(id int64) any {
	if id == 0 {
		return nil
	}
	return id
}
