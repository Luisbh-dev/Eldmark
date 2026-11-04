package platformtest

import (
	"encoding/json"
	"net/http"
	"strconv"

	"eldmark/platform/internal/zones"
)

// Zone is a test zone that talks to the internal API with its scope's token.
type Zone struct {
	P     *Platform
	Scope zones.Scope
	Token string
	ID    string // zone_instance_id after registering
}

// NewZone prepares a zone of that scope (without registering it).
func (p *Platform) NewZone(world int16, zoneID string, channel int16) *Zone {
	s := zones.Scope{WorldID: world, ZoneID: zoneID, Channel: channel}
	return &Zone{P: p, Scope: s, Token: Token(s)}
}

// Do makes a request to the internal API with the zone's token.
func (z *Zone) Do(method, path string, body any) *Response {
	z.P.T.Helper()
	return do(z.P.T, z.P.Internal, method, path, body, map[string]string{"Authorization": "Bearer " + z.Token})
}

// RegisterBody is the zone's registration body; overrides changes or removes (nil) fields.
func (z *Zone) RegisterBody(overrides map[string]any) map[string]any {
	body := map[string]any{"world_id": z.Scope.WorldID, "zone_id": z.Scope.ZoneID, "channel": z.Scope.Channel,
		"public_host": "203.0.113.5", "public_port": 24600 + int(z.Scope.Channel), "realms": []int{1, 2},
		"build_id": "build-1", "protocol_version": Protocol, "record_format": 1, "max_players": 64,
		"dtls_cert_pem": nil, "dtls_name": nil, "replace": false}
	for k, v := range overrides {
		if v == nil {
			delete(body, k)
			continue
		}
		body[k] = v
	}
	return body
}

// Register registers the zone; on 200 it records its zone_instance_id.
func (z *Zone) Register(overrides map[string]any) *Response {
	z.P.T.Helper()
	res := z.Do("POST", "/internal/v1/zone-instances", z.RegisterBody(overrides))
	if res.Status == http.StatusOK {
		z.ID = res.String("zone_instance_id")
	}
	return res
}

// Live moves the zone to live.
func (z *Zone) Live() *Response {
	z.P.T.Helper()
	return z.Do("POST", "/internal/v1/zone-instances/"+z.ID+"/live", nil)
}

// Start registers the zone and moves it to live, or fails.
func (z *Zone) Start() *Zone {
	z.P.T.Helper()
	Expect(z.P.T, z.Register(nil), http.StatusOK, "")
	Expect(z.P.T, z.Live(), http.StatusNoContent, "")
	return z
}

// Lease is a character in the heartbeat set.
type Lease struct {
	CharacterID int64
	LeaseID     string
}

// Heartbeat sends a heartbeat with the given characters.
func (z *Zone) Heartbeat(players int, leases ...Lease) *Response {
	z.P.T.Helper()
	chars := make([]map[string]any, 0, len(leases))
	for _, l := range leases {
		chars = append(chars, map[string]any{"character_id": strconv.FormatInt(l.CharacterID, 10), "lease_id": l.LeaseID})
	}
	return z.Do("POST", "/internal/v1/zone-instances/"+z.ID+"/heartbeat", map[string]any{"players": players,
		"characters": chars})
}

// Claim claims the character with the ticket.
func (z *Zone) Claim(ticketID, characterID int64) *Response {
	z.P.T.Helper()
	return z.Do("POST", "/internal/v1/claims", map[string]any{"zone_instance_id": z.ID,
		"ticket_id": strconv.FormatInt(ticketID, 10), "character_id": strconv.FormatInt(characterID, 10)})
}

// MustClaim claims and returns the lease_id.
func (z *Zone) MustClaim(ticketID, characterID int64) string {
	z.P.T.Helper()
	res := z.Claim(ticketID, characterID)
	Expect(z.P.T, res, http.StatusOK, "")
	return res.String("lease_id")
}

// Join makes the character enter this zone: enter (which must pick this instance) and the
// claim. It returns the lease_id.
func (z *Zone) Join(pl *Player, characterID int64) string {
	z.P.T.Helper()
	ticket, instance := z.P.MustEnter(pl, characterID)
	if instance != z.ID {
		z.P.T.Fatalf("enter eligió la instancia %s y no %s", instance, z.ID)
	}
	return z.MustClaim(ticket, characterID)
}

// SaveBody is a save envelope from §7.3 with a minimal progress section; the caller can change
// whatever they want before sending it.
func (z *Zone) SaveBody(characterID int64, leaseID string, seq int) map[string]any {
	return map[string]any{"save_format": 1, "character_id": strconv.FormatInt(characterID, 10),
		"zone_instance_id": z.ID, "lease_id": leaseID, "seq": seq, "reason": 1, "release_lease": false,
		"progress": map[string]any{"progress_format": 1, "level": 2, "played_seconds": 60 * seq,
			"location": map[string]any{"zone_id": z.Scope.ZoneID, "channel": z.Scope.Channel}}}
}

// Save sends a save (body: a map, which is serialized, or the bytes as they are).
func (z *Zone) Save(characterID int64, body any) *Response {
	z.P.T.Helper()
	return z.Do("PUT", "/internal/v1/characters/"+strconv.FormatInt(characterID, 10)+"/state", body)
}

// Release releases the character without saving.
func (z *Zone) Release(characterID int64, leaseID string) *Response {
	z.P.T.Helper()
	return z.Do("POST", "/internal/v1/characters/"+strconv.FormatInt(characterID, 10)+"/release",
		map[string]any{"zone_instance_id": z.ID, "lease_id": leaseID})
}

// Marshal serializes a body once (retries send the same bytes).
func Marshal(v any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return data
}

// Int reads a number from the body (json.Number).
func (r *Response) Int(name string) int64 {
	n, _ := r.Body[name].(json.Number)
	v, _ := n.Int64()
	return v
}
