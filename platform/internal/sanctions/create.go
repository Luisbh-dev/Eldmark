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

// Orígenes de las filas de audit_log que escribe la plataforma (§9.1): las sanciones que pide un
// GM desde la zona (por la API interna) y las órdenes de la CLI admin.
const (
	SourcePlatform = "platform"
	SourceCLI      = "cli"
)

// Commands de audit_log de una sanción (§9.5): creada o denegada. Los dos los escribe solo la
// plataforma; una zona no los puede mandar en su lote.
const (
	CommandSanction       = "sanction"
	CommandSanctionDenied = "sanction_denied"
)

// Denial es por qué la plataforma no deja crear una sanción (va en args.denied de
// sanction_denied).
type Denial string

const (
	DeniedNoLease    Denial = "no_lease"    // el autor no tiene arrendamiento en la instancia
	DeniedRole       Denial = "role"        // su rol no llega para ese tipo y esa duración
	DeniedTargetRole Denial = "target_role" // el objetivo no tiene un rol menor
)

// Errores de [Create] que no son de autorización.
var (
	// ErrUnknownReports: algún report_id no es un reporte del mundo de la sanción (400).
	ErrUnknownReports = errors.New("sanctions: hay reportes que no son de ese mundo")
	// ErrBadRequest: el tipo, la duración o el motivo no valen.
	ErrBadRequest = errors.New("sanctions: tipo, duración o motivo que no valen")
)

// Request es una sanción pedida (§9.5), desde la zona (/gm …, por la API interna) o desde la CLI
// (admin --actor <correo> sanction …). El objetivo ya viene resuelto (por su nombre en el mundo, en
// la transacción de quien llama); su rol se lee aquí con su fila bloqueada.
type Request struct {
	WorldID int16
	ZoneID  string // la zona de la instancia; "" desde la CLI
	Source  string // SourcePlatform (la zona) o SourceCLI

	// AuthorCharacterID es el personaje del GM (desde la zona): su cuenta sale de characters en el
	// mundo de la sanción, y tiene que tener arrendamiento en Instance.
	AuthorCharacterID int64
	Instance          *[16]byte
	// AuthorAccountID es la cuenta del --actor (desde la CLI), sin personaje ni instancia.
	AuthorAccountID int64
	// RequireRole es un rol mínimo del autor aparte del de la tabla de §9.1 («admin» en la CLI,
	// que exige admin para toda orden que cambia algo); "" si no hay.
	RequireRole string

	TargetAccountID   int64
	TargetCharacterID int64

	Kind      string
	Duration  time.Duration // silencio y suspensión; 0 en los demás
	Reason    string
	ReportIDs []int64
	// Args son más argumentos para las filas de audit_log (os_user de la CLI). Nunca un correo ni
	// un nombre (§9.1).
	Args map[string]any
	Now  time.Time
}

// Created es una sanción creada.
type Created struct {
	SanctionID int64
	EndsAt     *time.Time // nil: sin fin
}

// Timed dice si el tipo lleva duración: el silencio y la suspensión. El aviso, el renombrado y la
// expulsión (permanente) no.
func Timed(kind string) bool { return kind == KindMute || kind == KindSuspension }

// Create crea la sanción si la plataforma la autoriza (§9.5), dentro de la transacción tx de quien
// llama, que tiene que confirmarla también cuando la deniega (la fila sanction_denied):
//
//  1. desde la zona, el autor tiene arrendamiento en la instancia;
//  2. la cuenta del autor tiene el rol mínimo de §9.1 para ese tipo y esa duración (y RequireRole);
//  3. la cuenta objetivo tiene un rol menor que la del autor.
//
// Las filas de las dos cuentas se bloquean en orden de id (for no key update): el rol que se mira
// no cambia a mitad (set-role bloquea las mismas filas). Si falla alguna comprobación devuelve el
// motivo y deja una fila sanction_denied en audit_log, con el objetivo por id (sin nombres ni
// correos). Si no, inserta la sanción con sus reportes (de ese mundo; si no, [ErrUnknownReports]),
// pone must_rename en un renombrado y deja una fila sanction.
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

// lockRoles bloquea las filas de las cuentas en orden de id (for no key update) y devuelve su rol.
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

// auditRow es una fila de audit_log escrita por la plataforma (§9.1): el objetivo por id, sin
// nombres ni correos en args.
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
