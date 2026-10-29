package sanctions

import (
	"context"
	"time"
)

// CommandSetRole es el command de la fila fija de set-role (§9.1): source cli, actor_account_id
// del --actor, target_account_id la cuenta y args {from, to, os_user}.
const CommandSetRole = "set-role"

// Roles son los roles válidos, de menor a mayor.
var Roles = []string{RolePlayer, RoleModerator, RoleGM, RoleAdmin}

// RoleAt es el rol que tenía la cuenta en el instante at, para la comprobación S2 del guardado
// (progresion.md §13.3: el actor de una operación GM o REVERSAL con el rol que tenía en
// detail.at_unix). Lo da la primera fila set-role de la CLI posterior a at, con su args.from: el
// rol de antes de ese cambio; sin ninguna, el rol actual. Solo cuentan las filas con source = 'cli'
// (las que escribe la orden admin): una zona no las puede escribir (§6, «Lotes»), así que no puede
// darle a nadie un rol pasado. "" si la cuenta no existe.
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

// Warning es un aviso (§9.5: «al entrar, NOTICE con el motivo»).
type Warning struct {
	SanctionID int64
	Reason     string
	At         time.Time
}

// Text es el texto para el jugador, compuesto por la plataforma como los demás (§6.1): «Has
// recibido un aviso de la moderación: motivo», cortado a [MaxTextBytes].
func (w Warning) Text() string {
	msg := "Has recibido un aviso de la moderación"
	if w.Reason != "" {
		msg += ": " + w.Reason
	}
	return Truncate(msg, MaxTextBytes)
}

// MaxWarnings es cuántos avisos pendientes trae una reclamación como mucho (los más recientes).
const MaxWarnings = 5

// PendingWarnings devuelve los avisos de la cuenta que aún no ha visto en ese mundo: sin revocar,
// de ese mundo o de todos, puestos hasta now y después de since (la última entrada al mundo de
// cualquiera de sus personajes, antes de esta; nil si nunca entró). Así cada aviso sale en la
// primera entrada que le sigue y, después, solo queda en la cuenta (cuenta para la reincidencia,
// social.md §9). Los más recientes, [MaxWarnings] como mucho, del más viejo al más nuevo.
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
