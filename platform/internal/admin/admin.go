// Package admin es la orden admin de la plataforma (plataforma.md §9, §11.2 y §12; SOC-13 a
// SOC-18): lo que hacen a mano los moderadores y los administradores, siempre con identidad.
//
// Toda orden lleva --actor <correo> de una cuenta admin (o moderator para las de lectura: reports
// list|show, audit, chat y sanction list); sin él, o con otra cuenta, no se ejecuta ([ActorError],
// código 2 en la CLI). Cada orden deja su fila en audit_log con source = 'cli', en command su nombre
// («set-role», «reports show»…), en actor_account_id la cuenta del --actor, en args.os_user quien
// la corrió en la máquina ($SUDO_USER o $USER) y el objetivo en target_account_id y
// target_character_id: args nunca lleva un correo ni el nombre de un personaje (§9.1; los nombres
// y los correos se resuelven a ids antes de escribir). Las lecturas también se auditan, en la misma
// transacción que la consulta: si la fila no se escribe, no se lee nada.
//
// Las órdenes que cambian algo vuelven a mirar el rol del --actor con su fila bloqueada, dentro de
// su transacción: un administrador al que le quitan el rol a mitad no termina la orden.
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

// Plazos de purge-now (§11.2): espera hasta 30 s a que el latido expulse a los personajes de la
// cuenta con su guardado final.
const (
	DefaultPurgeWait = 30 * time.Second
	purgePoll        = 500 * time.Millisecond
)

// Topes de las consultas.
const (
	DefaultLimit = 200
	MaxLimit     = 5000
)

// Options son las dependencias del servicio.
type Options struct {
	Pool     *pgxpool.Pool
	Accounts *accounts.Service
	// Characters vuelve a purgar personajes en reapply-purges (characters.Purger); nil: la orden se
	// niega (staging y production mientras no exista el almacén del progreso, como purge-now).
	Characters CharacterReapplier
	// Legal son los textos vigentes: create-account y bootstrap los publican en legal_documents si
	// faltan (como serve al arrancar) antes de dar la cuenta por aceptada. StrictLegal (staging y
	// production) se niega si un texto ya publicado ha cambiado.
	Legal       *legal.Set
	StrictLegal bool
	Names       *names.Rules // nil: las de progression_rules.json
	Clock       clock.Clock  // nil: el del sistema
	Log         *slog.Logger
	// OSUser es quien corre la orden en la máquina ($SUDO_USER o $USER): va en args.os_user.
	OSUser string
	// PurgePoll es cada cuánto mira purge-now si se han liberado los arrendamientos (0: 500 ms).
	PurgePoll time.Duration
}

// Service es la orden admin.
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

// New prepara el servicio.
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

// Errores de las órdenes (el texto es el que ve quien la corre).
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

// ActorError es un --actor que falta o que no puede usar la orden: no se ejecuta (código 2).
type ActorError struct{ Reason string }

func (e *ActorError) Error() string { return e.Reason }

// DeniedError es una sanción que la plataforma no autoriza (§9.5): queda la fila sanction_denied.
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

// Actor es la cuenta del --actor.
type Actor struct {
	AccountID int64
	Role      string
}

// Authorize comprueba el --actor: una cuenta activa (sin borrado pedido ni suspensión o expulsión
// vigente) con al menos el rol need (sanctions.RoleModerator para las lecturas, RoleAdmin para lo
// demás). Si no, [ActorError].
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

// lockActor vuelve a mirar el rol del --actor con su fila bloqueada (for share), dentro de la
// transacción de una orden que cambia algo.
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

// entry es una fila de audit_log de la CLI: el objetivo por id y en args nada personal.
type entry struct {
	world           int16
	command         string
	targetAccount   int64
	targetCharacter int64
	args            map[string]any
}

// audit escribe la fila de una orden (source = 'cli', at = la hora de la orden, args con os_user).
// actor nil: bootstrap, que no tiene --actor.
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

// Character es un personaje resuelto por su nombre (o por «#id»).
type Character struct {
	ID        int64
	AccountID int64
	WorldID   int16
	Name      string
	Deleted   bool
}

// character resuelve un personaje no purgado: «#123» por su id (en cualquier mundo) o un nombre por
// la clave de NameRules en el mundo dado, primero el vivo y si no el borrado que aún se puede
// restaurar. Si no hay ninguno, [ErrCharacterNotFound].
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

// inTx corre fn en una transacción con los reintentos de db.InTx.
func (s *Service) inTx(ctx context.Context, fn func(pgx.Tx) error) error {
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, fn)
}

// limit acota el tope de una consulta.
func limit(n int) int {
	switch {
	case n <= 0:
		return DefaultLimit
	case n > MaxLimit:
		return MaxLimit
	}
	return n
}
