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

// EnterView is the response of POST /v1/characters/{id}/enter (§4.5).
type EnterView struct {
	Zone       ZoneView       `json:"zone"`
	Ticket     string         `json:"ticket"` // the 52 B in standard base64
	ExpiresInS int            `json:"expires_in_s"`
	Character  EnterCharacter `json:"character"`
}

// ZoneView is the zone instance to connect to. DTLS is null if the zone does not use DTLS (only in
// dev and test, §10.2).
type ZoneView struct {
	ZoneID  string    `json:"zone_id"`
	Channel int       `json:"channel"`
	Host    string    `json:"host"`
	Port    int       `json:"port"`
	DTLS    *DTLSView `json:"dtls"`
}

// DTLSView is the zone's certificate, which the client pins (§10.2).
type DTLSView struct {
	CertPEM string `json:"cert_pem"`
	Name    string `json:"name"`
}

// EnterCharacter is the character entering, with the realm in its text id.
type EnterCharacter struct {
	CharacterID jsonx.ID `json:"character_id"`
	Name        string   `json:"name"`
	Realm       string   `json:"realm"`
}

// instance is a candidate live zone instance.
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

// Enter issues the ticket to enter the world with a character (§4.5). It checks in order (the
// session, its sanctions and the privacy session were already checked by
// accounts.API.RequireSession): 10 per minute per account (429), maintenance of the character's
// world except for admin (503), pending deletion (403), texts to accept (403 terms_required),
// verified email if required (403), a living character of the account (404), forced rename (409
// rename_required) and no live lease of any character of the account in that world (409
// character_busy: a single character in the world per account; the claim checks it again, §5.3).
// Then it picks the zone ([Service.chooseInstance]), inserts the ticket in enter_tickets (10 s) and
// signs it.
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
	// A repeated ticket_id (2^63 possible) clashes with the primary key: another one is tried.
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

// chooseInstance picks the zone instance (§4.5): the character's last zone if it has a live
// instance that admits its realm and has room (in its last channel if still alive and with room);
// otherwise, its realm's entry zone (ELDMARK_ENTRY_ZONES). Within the zone, the channel with the
// fewest players under max_players (ties broken by the lowest). With none, 503 zone_unavailable.
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
				best = in // the list is sorted by players and channel
			}
		}
		if best != nil {
			return best, nil
		}
	}
	return nil, errZoneUnavailable()
}
