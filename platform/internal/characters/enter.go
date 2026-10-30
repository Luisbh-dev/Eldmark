package characters

import (
	"context"
	"encoding/base64"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/tickets"
)

// EnterView es la respuesta de POST /v1/characters/{id}/enter (§4.5).
type EnterView struct {
	Zone       ZoneView       `json:"zone"`
	Ticket     string         `json:"ticket"` // los 52 B en base64 estándar
	ExpiresInS int            `json:"expires_in_s"`
	Character  EnterCharacter `json:"character"`
}

// ZoneView es la instancia de zona a la que conectar. DTLS es null si la zona no usa DTLS (solo en
// dev y test, §10.2).
type ZoneView struct {
	ZoneID  string    `json:"zone_id"`
	Channel int       `json:"channel"`
	Host    string    `json:"host"`
	Port    int       `json:"port"`
	DTLS    *DTLSView `json:"dtls"`
}

// DTLSView es el certificado de la zona, que el cliente ancla (§10.2).
type DTLSView struct {
	CertPEM string `json:"cert_pem"`
	Name    string `json:"name"`
}

// EnterCharacter es el personaje que entra, con el reino en su id de texto.
type EnterCharacter struct {
	CharacterID jsonx.ID `json:"character_id"`
	Name        string   `json:"name"`
	Realm       string   `json:"realm"`
}

// instance es una instancia de zona viva candidata.
type instance struct {
	ID         [16]byte
	ZoneID     string
	Channel    int
	Host       string
	Port       int
	CertPEM    *string
	DTLSName   *string
	Players    int
	MaxPlayers int
}

// Enter emite el billete para entrar al mundo con un personaje (§4.5). Comprueba en orden (la
// sesión, sus sanciones y la sesión de privacidad ya las miró accounts.API.RequireSession):
// 10 por minuto y cuenta (429), mantenimiento del mundo del personaje salvo para admin (503),
// borrado pendiente (403), textos por aceptar (403 terms_required), correo verificado si se exige
// (403), personaje vivo de la cuenta (404), renombrado forzado (409 rename_required) y ningún
// arrendamiento vivo de ningún personaje de la cuenta en ese mundo (409 character_busy: un solo
// personaje en el mundo por cuenta; la reclamación lo vuelve a mirar, §5.3). Después elige la zona
// ([Service.chooseInstance]), inserta el billete en enter_tickets (10 s) y lo firma.
func (s *Service) Enter(ctx context.Context, sess *accounts.Session, characterID int64) (*EnterView, error) {
	now := s.clock.Now()
	if ok, wait := s.limits.enter.Allow("a:"+itoa(sess.AccountID), now); !ok {
		return nil, errRateLimited(wait)
	}
	var status string
	var purgeAfter *time.Time
	var verified bool
	if err := s.pool.QueryRow(ctx, `select status, purge_after, email_verified_at is not null from accounts
		where account_id = $1`, sess.AccountID).Scan(&status, &purgeAfter, &verified); err != nil {
		return nil, err
	}
	c, err := scanCharacter(s.pool.QueryRow(ctx, `select `+characterColumns+` from characters
		where character_id = $1 and account_id = $2 and deleted_at is null and purged_at is null`, characterID, sess.AccountID))
	if errors.Is(err, pgx.ErrNoRows) {
		c, err = nil, nil
	}
	if err != nil {
		return nil, err
	}
	if c != nil && sess.Role != "admin" {
		worldStatus, err := s.checkWorld(ctx, s.pool, c.WorldID)
		if err != nil {
			return nil, err
		}
		if worldStatus == "maintenance" {
			return nil, errMaintenance()
		}
	}
	if status == "pending_deletion" {
		return nil, errPendingDeletion(purgeAfter)
	}
	missing, err := s.accounts.MissingAcceptances(ctx, s.pool, sess.AccountID)
	if err != nil {
		return nil, err
	}
	if len(missing) > 0 {
		return nil, errTermsRequired(missing)
	}
	if s.cfg.RequireVerifiedEmail && !verified {
		return nil, errEmailUnverified()
	}
	if c == nil {
		return nil, httpx.ErrNotFound
	}
	if c.MustRename {
		return nil, errRenameRequired()
	}
	var busy bool
	if err := s.pool.QueryRow(ctx, `select exists (select 1 from character_leases l join characters c using (character_id)
		where c.account_id = $1 and c.world_id = $2 and `+leaseAlive+`$3)`, sess.AccountID, c.WorldID, now).Scan(&busy); err != nil {
		return nil, err
	}
	if busy {
		return nil, errCharacterBusy()
	}
	sums, err := s.summaries(ctx, s.pool, []int64{c.ID})
	if err != nil {
		return nil, err
	}
	sum := sums[c.ID]
	inst, err := s.chooseInstance(ctx, c, sum.LastZoneID, sum.LastChannel)
	if err != nil {
		return nil, err
	}
	issued := now.Truncate(time.Second)
	t := tickets.Ticket{Version: tickets.Version, KeyID: s.cfg.TicketSignKey, WorldID: uint16(c.WorldID),
		CharacterID: uint64(c.ID), ZoneKey: tickets.ZoneKey(inst.ZoneID), Channel: uint8(inst.Channel),
		Realm: uint8(c.Realm), Arrival: 0, Flags: tickets.FlagFromMenu, IssuedAt: uint32(issued.Unix()),
		ExpiresAt: uint32(issued.Unix() + tickets.Lifetime)}
	// Un ticket_id repetido (2^63 posibles) choca con la clave primaria: se prueba con otro.
	for attempt := 0; ; attempt++ {
		if t.TicketID, err = tickets.NewID(); err != nil {
			return nil, err
		}
		_, err = s.pool.Exec(ctx, `insert into enter_tickets (ticket_id, world_id, character_id, session_id,
			zone_instance_id, issued_at, expires_at) values ($1, $2, $3, $4, $5, $6, $7)`,
			int64(t.TicketID), c.WorldID, c.ID, sess.ID, inst.ID, issued, issued.Add(tickets.Lifetime*time.Second))
		if err == nil || db.Constraint(err) != "enter_tickets_pkey" || attempt == 2 {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	signed := t.Sign(s.signKey)
	v := &EnterView{
		Zone:       ZoneView{ZoneID: inst.ZoneID, Channel: inst.Channel, Host: inst.Host, Port: inst.Port},
		Ticket:     base64.StdEncoding.EncodeToString(signed[:]),
		ExpiresInS: tickets.Lifetime,
		Character:  EnterCharacter{CharacterID: jsonx.ID(c.ID), Name: c.Name, Realm: c.Realm.String()},
	}
	if inst.CertPEM != nil {
		v.Zone.DTLS = &DTLSView{CertPEM: *inst.CertPEM}
		if inst.DTLSName != nil {
			v.Zone.DTLS.Name = *inst.DTLSName
		}
	}
	return v, nil
}

// chooseInstance elige la instancia de zona (§4.5): la última zona del personaje si tiene una
// instancia live que admite su reino y con sitio (en su último canal si sigue vivo y con sitio); si
// no, la zona de entrada de su reino (ELDMARK_ENTRY_ZONES). Dentro de la zona, el canal con menos
// jugadores bajo max_players (a igualdad, el menor). Sin ninguna, 503 zone_unavailable.
func (s *Service) chooseInstance(ctx context.Context, c *characterRow, lastZone string, lastChannel int) (*instance, error) {
	zones := []string{}
	if lastZone != "" {
		zones = append(zones, lastZone)
	}
	if entry := s.cfg.EntryZones[c.Realm]; entry != "" && entry != lastZone {
		zones = append(zones, entry)
	}
	if len(zones) == 0 {
		return nil, errZoneUnavailable()
	}
	rows, err := s.pool.Query(ctx, `select zone_instance_id, zone_id, channel, public_host, public_port, dtls_cert_pem,
		dtls_name, players, max_players from zone_instances
		where world_id = $1 and status = 'live' and $2 = any(realms) and zone_id = any($3)
		  and channel between 0 and 255 and players < max_players
		order by players, channel`, c.WorldID, int16(c.Realm), zones)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (instance, error) {
		var i instance
		err := r.Scan(&i.ID, &i.ZoneID, &i.Channel, &i.Host, &i.Port, &i.CertPEM, &i.DTLSName, &i.Players, &i.MaxPlayers)
		return i, err
	})
	if err != nil {
		return nil, err
	}
	for _, zone := range zones {
		var best *instance
		for i := range list {
			in := &list[i]
			if in.ZoneID != zone {
				continue
			}
			if zone == lastZone && in.Channel == lastChannel {
				return in, nil
			}
			if best == nil {
				best = in // la lista viene ordenada por jugadores y canal
			}
		}
		if best != nil {
			return best, nil
		}
	}
	return nil, errZoneUnavailable()
}
