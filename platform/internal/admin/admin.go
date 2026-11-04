// Package admin is the platform's admin command (plataforma.md §9, §11.2 and §12; SOC-13 to
// SOC-18): what moderators and administrators do by hand, always with identity.
//
// Every command carries --actor <email> of an admin account (or moderator for the read ones:
// reports list|show, audit, chat and sanction list); without it, or with another account, it is not
// executed ([ActorError], code 2 in the CLI). Each command leaves its row in audit_log with source =
// 'cli', its name in command ("set-role", "reports show"...), the --actor's account in
// actor_account_id, whoever ran it on the machine in args.os_user ($SUDO_USER or $USER) and the
// target in target_account_id and target_character_id: args never carries an email or a character's
// name (§9.1; names and emails are resolved to ids before writing). Reads are also audited, in the
// same transaction as the query: if the row is not written, nothing is read.
//
// Commands that change something check the --actor's role again with its row locked, inside their
// transaction: an administrator who loses the role midway does not finish the command.
package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/names"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/legal"
)

// Timeouts of purge-now (§11.2): it waits up to 30 s for the heartbeat to kick out the account's
// characters with their final save.
const (
	DefaultPurgeWait = 30 * time.Second
	purgePoll        = 500 * time.Millisecond
)

// Query caps.
const (
	DefaultLimit = 200
	MaxLimit     = 5000
)

// Options are the service's dependencies.
type Options struct {
	Pool     *pgxpool.Pool
	Accounts *accounts.Service
	// Characters purges characters again in reapply-purges (characters.Purger); nil: the command
	// refuses (staging and production while the progression store does not exist, like purge-now).
	Characters CharacterReapplier
	// Legal are the current texts: create-account and bootstrap publish them in legal_documents if they
	// are missing (like serve at startup) before considering the account as having accepted. StrictLegal
	// (staging and production) refuses if an already published text has changed.
	Legal       *legal.Set
	StrictLegal bool
	Names       *names.Rules // nil: those from progression_rules.json
	Clock       clock.Clock  // nil: the system's
	Log         *slog.Logger
	// OSUser is whoever runs the command on the machine ($SUDO_USER or $USER): it goes in args.os_user.
	OSUser string
	// PurgePoll is how often purge-now checks whether the leases have been released (0: 500 ms).
	PurgePoll time.Duration
}

// Service is the admin command.
type Service struct {
	pool        *pgxpool.Pool
	accounts    *accounts.Service
	characters  CharacterReapplier
	legal       *legal.Set
	strictLegal bool
	names       *names.Rules
	clock       clock.Clock
	log         *slog.Logger
	osUser      string
	purgePoll   time.Duration
}

// New prepares the service.
func New(o Options) (*Service, error) {
	if o.Pool == nil || o.Accounts == nil || o.Legal == nil {
		return nil, errors.New("admin: faltan dependencias")
	}
	if o.Names == nil {
		o.Names = names.Default()
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	if o.OSUser == "" {
		o.OSUser = "desconocido"
	}
	if o.PurgePoll <= 0 {
		o.PurgePoll = purgePoll
	}
	return &Service{pool: o.Pool, accounts: o.Accounts, characters: o.Characters, legal: o.Legal, strictLegal: o.StrictLegal, names: o.Names,
		clock: o.Clock, log: o.Log, osUser: o.OSUser, purgePoll: o.PurgePoll}, nil
}

// Command errors (the text is what the person who runs it sees).
var (
	ErrAccountNotFound   = errors.New("no hay ninguna cuenta con ese correo")
	ErrCharacterNotFound = errors.New("no hay ningún personaje con ese nombre en ese mundo")
	ErrReportNotFound    = errors.New("no hay ningún reporte con ese número")
	ErrSanctionNotFound  = errors.New("no hay ninguna sanción con ese número")
	ErrSelf              = errors.New("esa orden no se puede usar sobre la propia cuenta del --actor")
	ErrReportClosed      = errors.New("ese reporte ya está cerrado")
	ErrAlreadyRevoked    = errors.New("esa sanción ya estaba revocada")
	ErrUnknownReports    = errors.New("hay reportes que no existen o son de otro mundo")
	ErrBusy              = errors.New("character_busy: un personaje de la cuenta sigue en el mundo; no se ha purgado nada")
	ErrHasAdmin          = errors.New("ya hay una cuenta admin: crea las demás con «admin --actor <correo> create-account»")
	ErrInvalidName       = errors.New("ese término no vale: solo letras, como un nombre de personaje")
)

// ActorError is an --actor that is missing or that cannot use the command: it is not executed (code
// 2).
type ActorError struct{ Reason string }

func (e *ActorError) Error() string { return e.Reason }

// DeniedError is a sanction that the platform does not authorize (§9.5): the sanction_denied row is
// left.
type DeniedError struct{ Denial sanctions.Denial }

func (e *DeniedError) Error() string {
	switch e.Denial {
	case sanctions.DeniedTargetRole:
		return "no autorizada: la cuenta objetivo no tiene un rol menor que el tuyo"
	case sanctions.DeniedRole:
		return "no autorizada: tu rol no llega para ese tipo y esa duración"
	}
	return "no autorizada (" + string(e.Denial) + ")"
}

// Actor is the --actor's account.
type Actor struct {
	AccountID int64
	Role      string
}

// Authorize checks the --actor: an active account (without a requested deletion or a current
// suspension or ban) with at least the role need (sanctions.RoleModerator for reads, RoleAdmin for
// the rest). Otherwise, [ActorError].
func (s *Service) Authorize(ctx context.Context, email, need string) (*Actor, error) {
	if strings.TrimSpace(email) == "" {
		return nil, &ActorError{Reason: "toda orden admin necesita --actor <correo> de una cuenta " + need}
	}
	id, role, status, err := s.accounts.LookupAccount(ctx, email)
	if err != nil {
		return nil, err
	}
	if id == 0 {
		return nil, &ActorError{Reason: "--actor no es el correo de ninguna cuenta"}
	}
	if status != "active" {
		return nil, &ActorError{Reason: "la cuenta de --actor no está activa (" + status + ")"}
	}
	if sanctions.Rank(role) < sanctions.Rank(need) {
		return nil, &ActorError{Reason: fmt.Sprintf("la cuenta de --actor tiene el rol %s y esta orden pide %s", role, need)}
	}
	restriction, err := sanctions.Active(ctx, s.pool, id, s.clock.Now())
	if err != nil {
		return nil, err
	}
	if restriction != nil {
		return nil, &ActorError{Reason: "la cuenta de --actor está sancionada (" + restriction.Kind + ")"}
	}
	return &Actor{AccountID: id, Role: role}, nil
}

// lockActor checks the --actor's role again with its row locked (for share), inside the transaction
// of a command that changes something.
func lockActor(ctx context.Context, tx pgx.Tx, actor *Actor, need string) error {
	var role, status string
	err := tx.QueryRow(ctx, `select role, status from accounts where account_id = $1 for share`, actor.AccountID).
		Scan(&role, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return &ActorError{Reason: "la cuenta de --actor ya no existe"}
	}
	if err != nil {
		return err
	}
	if status != "active" || sanctions.Rank(role) < sanctions.Rank(need) {
		return &ActorError{Reason: "la cuenta de --actor ha dejado de poder usar esta orden"}
	}
	actor.Role = role
	return nil
}

// entry is a CLI audit_log row: the target by id and nothing personal in args.
type entry struct {
	world           int16
	command         string
	targetAccount   int64
	targetCharacter int64
	args            map[string]any
}

// audit writes a command's row (source = 'cli', at = the command's time, args with os_user). actor
// nil: bootstrap, which has no --actor.
func (s *Service) audit(ctx context.Context, tx pgx.Tx, actor *Actor, e entry, at time.Time) error {
	args := map[string]any{"os_user": s.osUser}
	for k, v := range e.args {
		args[k] = v
	}
	data, err := json.Marshal(args)
	if err != nil {
		return err
	}
	var actorID any
	if actor != nil {
		actorID = actor.AccountID
	}
	_, err = tx.Exec(ctx, `insert into audit_log (world_id, source, actor_account_id, command, target_account_id,
			target_character_id, args, at)
		values ($1, 'cli', $2, $3, $4, $5, $6, $7)`,
		nullWorld(e.world), actorID, e.command, nullID(e.targetAccount), nullID(e.targetCharacter), data, at)
	return err
}

func nullID(id int64) any {
	if id == 0 {
		return nil
	}
	return id
}

func nullWorld(w int16) any {
	if w == 0 {
		return nil
	}
	return w
}

func idString(id int64) string { return strconv.FormatInt(id, 10) }

// Character is a character resolved by its name (or by "#id").
type Character struct {
	ID        int64
	AccountID int64
	WorldID   int16
	Name      string
	Deleted   bool
}

// character resolves an unpurged character: "#123" by its id (in any world) or a name by its
// NameRules key in the given world, first the living one and otherwise the deleted one that can
// still be restored. If there is none, [ErrCharacterNotFound].
func (s *Service) character(ctx context.Context, q interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}, world int16, ref string) (*Character, error) {
	c := &Character{}
	var err error
	if id, ok := strings.CutPrefix(ref, "#"); ok {
		n, perr := strconv.ParseInt(id, 10, 64)
		if perr != nil || n < 1 {
			return nil, ErrCharacterNotFound
		}
		err = q.QueryRow(ctx, `select character_id, account_id, world_id, name, deleted_at is not null from characters
			where character_id = $1 and purged_at is null`, n).Scan(&c.ID, &c.AccountID, &c.WorldID, &c.Name, &c.Deleted)
	} else {
		key := s.names.NormalizeKey(ref)
		if key == "" {
			return nil, ErrCharacterNotFound
		}
		err = q.QueryRow(ctx, `select character_id, account_id, world_id, name, deleted_at is not null from characters
			where world_id = $1 and name_key = $2 and purged_at is null
			order by deleted_at desc nulls first, character_id desc limit 1`, world, key).
			Scan(&c.ID, &c.AccountID, &c.WorldID, &c.Name, &c.Deleted)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrCharacterNotFound
	}
	if err != nil {
		return nil, err
	}
	return c, nil
}

// inTx runs fn in a transaction with db.InTx's retries.
func (s *Service) inTx(ctx context.Context, fn func(pgx.Tx) error) error {
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, fn)
}

// limit bounds a query's cap.
func limit(n int) int {
	switch {
	case n <= 0:
		return DefaultLimit
	case n > MaxLimit:
		return MaxLimit
	}
	return n
}
