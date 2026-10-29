// Package sanctions reúne las reglas de las sanciones y de los roles que comparten la API pública,
// la interna y la CLI admin (plataforma.md §6.1, §9.1 y §9.5): la restricción vigente de una cuenta
// (suspensión o expulsión), los silencios, los avisos pendientes, los textos para el jugador que
// compone la plataforma, el rango de los roles, qué rol puede crear cada sanción, la creación de
// una sanción con su autorización ([Create], la misma para la zona y para la CLI) y el rol que tenía
// una cuenta en un instante ([RoleAt], para la comprobación S2 del guardado).
//
// Es una hoja: no importa ningún otro paquete de la plataforma salvo mail (la fecha de los
// textos), así que la usan accounts, zones, persistence y social sin ciclos.
package sanctions

import (
	"context"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/mail"
)

// Tipos de sanción (sanctions.kind).
const (
	KindWarning    = "warning"
	KindMute       = "mute"
	KindSuspension = "suspension"
	KindBan        = "ban"
	KindRename     = "rename"
)

// Roles de las cuentas (accounts.role), de menor a mayor.
const (
	RolePlayer    = "player"
	RoleModerator = "moderator"
	RoleGM        = "gm"
	RoleAdmin     = "admin"
)

// ShortLimit es lo que pueden durar el silencio de un moderador y la suspensión de un GM (§9.1).
const ShortLimit = 7 * 24 * time.Hour

// MaxTextBytes es el tope de un texto para el jugador: el text_len del REJECT (§6.1).
const MaxTextBytes = 255

// NoEndUnix es la fecha Unix que va en until_unix de un silencio sin fin (9999-12-31 23:59:59
// UTC): la zona compara números y un null la obligaría a otro caso. Ni la zona ni la CLI crean
// silencios sin fin en la fase 5 (los dos exigen duración).
const NoEndUnix int64 = 253402300799

// Querier es una consulta dentro de la transacción o la conexión de quien llama.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// Restriction es una suspensión o expulsión vigente.
type Restriction struct {
	Kind   string     // KindSuspension o KindBan
	Until  *time.Time // nil: sin fin
	Reason string
}

// Message es el texto para el jugador: «Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC:
// motivo» o «Tu cuenta está expulsada: motivo», cortado a [MaxTextBytes].
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

// PendingDeletionMessage es el texto de una cuenta con el borrado pedido: «Tu cuenta se borrará el
// …».
func PendingDeletionMessage(purgeAfter *time.Time) string {
	if purgeAfter == nil {
		return "Tu cuenta se va a borrar"
	}
	return "Tu cuenta se borrará el " + mail.FormatDate(*purgeAfter)
}

// Truncate corta s a max bytes como mucho sin partir un carácter.
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

// restrictionSQL elige, por cuenta, la restricción que manda: una expulsión sobre una suspensión
// y, entre suspensiones, la que acaba más tarde.
const restrictionSQL = `select distinct on (account_id) account_id, kind, ends_at, reason from sanctions
	where account_id = any($1) and revoked_at is null and kind in ('suspension', 'ban')
	  and starts_at <= $2 and (ends_at is null or ends_at > $2)
	order by account_id, (kind = 'ban') desc, ends_at desc nulls first`

// Active devuelve la suspensión o expulsión vigente de la cuenta a la hora now, o nil.
func Active(ctx context.Context, q Querier, accountID int64, now time.Time) (*Restriction, error) {
	all, err := ActiveMany(ctx, q, []int64{accountID}, now)
	if err != nil {
		return nil, err
	}
	return all[accountID], nil
}

// ActiveMany es [Active] de varias cuentas a la vez; las que no tienen restricción no salen.
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

// Mutes devuelve, por cuenta, hasta cuándo dura su silencio vigente a la hora now (el que acaba más
// tarde), en Unix; uno sin fin da [NoEndUnix]. Las cuentas sin silencio no salen.
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

// Rank es el rango de un rol (player 0, moderator 1, gm 2, admin 3); uno desconocido, -1.
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

// MinRole es el rol mínimo que puede crear una sanción de ese tipo y esa duración (§9.1): el aviso
// y el silencio de hasta 7 días, moderator; la suspensión de hasta 7 días y el renombrado, gm; la
// suspensión más larga, la expulsión y el silencio de más de 7 días, admin («Todo»). Un tipo
// desconocido, "" (nadie).
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
