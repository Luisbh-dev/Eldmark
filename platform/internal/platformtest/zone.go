package platformtest

import (
	"encoding/json"
	"net/http"
	"strconv"

	"eldmark/platform/internal/zones"
)

// Zone es una zona de prueba que habla con la API interna con el token de su alcance.
type Zone struct {
	P     *Platform
	Scope zones.Scope
	Token string
	ID    string // zone_instance_id tras registrarse
}

// NewZone prepara una zona de ese alcance (sin registrarla).
func (p *Platform) NewZone(world int16, zoneID string, channel int16) *Zone {
	s := zones.Scope{WorldID: world, ZoneID: zoneID, Channel: channel}
	return &Zone{P: p, Scope: s, Token: Token(s)}
}

// Do hace una petición a la API interna con el token de la zona.
func (z *Zone) Do(method, path string, body any) *Response {
	z.P.T.Helper()
	return do(z.P.T, z.P.Internal, method, path, body, map[string]string{"Authorization": "Bearer " + z.Token})
}

// RegisterBody es el cuerpo del registro de la zona; overrides cambia o quita (nil) campos.
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

// Register registra la zona; con 200 apunta su zone_instance_id.
func (z *Zone) Register(overrides map[string]any) *Response {
	z.P.T.Helper()
	res := z.Do("POST", "/internal/v1/zone-instances", z.RegisterBody(overrides))
	if res.Status == http.StatusOK {
		z.ID = res.String("zone_instance_id")
	}
	return res
}

// Live pasa la zona a live.
func (z *Zone) Live() *Response {
	z.P.T.Helper()
	return z.Do("POST", "/internal/v1/zone-instances/"+z.ID+"/live", nil)
}

// Start registra la zona y la pasa a live, o falla.
func (z *Zone) Start() *Zone {
	z.P.T.Helper()
	Expect(z.P.T, z.Register(nil), http.StatusOK, "")
	Expect(z.P.T, z.Live(), http.StatusNoContent, "")
	return z
}

// Lease es un personaje del conjunto del latido.
type Lease struct {
	CharacterID int64
	LeaseID     string
}

// Heartbeat manda un latido con los personajes dados.
func (z *Zone) Heartbeat(players int, leases ...Lease) *Response {
	z.P.T.Helper()
	chars := make([]map[string]any, 0, len(leases))
	for _, l := range leases {
		chars = append(chars, map[string]any{"character_id": strconv.FormatInt(l.CharacterID, 10), "lease_id": l.LeaseID})
	}
	return z.Do("POST", "/internal/v1/zone-instances/"+z.ID+"/heartbeat", map[string]any{"players": players,
		"characters": chars})
}

// Claim reclama al personaje con el billete.
func (z *Zone) Claim(ticketID, characterID int64) *Response {
	z.P.T.Helper()
	return z.Do("POST", "/internal/v1/claims", map[string]any{"zone_instance_id": z.ID,
		"ticket_id": strconv.FormatInt(ticketID, 10), "character_id": strconv.FormatInt(characterID, 10)})
}

// MustClaim reclama y devuelve el lease_id.
func (z *Zone) MustClaim(ticketID, characterID int64) string {
	z.P.T.Helper()
	res := z.Claim(ticketID, characterID)
	Expect(z.P.T, res, http.StatusOK, "")
	return res.String("lease_id")
}

// Join hace entrar al personaje en esta zona: enter (que tiene que elegir esta instancia) y la
// reclamación. Devuelve el lease_id.
func (z *Zone) Join(pl *Player, characterID int64) string {
	z.P.T.Helper()
	ticket, instance := z.P.MustEnter(pl, characterID)
	if instance != z.ID {
		z.P.T.Fatalf("enter eligió la instancia %s y no %s", instance, z.ID)
	}
	return z.MustClaim(ticket, characterID)
}

// SaveBody es un sobre de guardado de §7.3 con una sección progress mínima; el que llama puede
// cambiar lo que quiera antes de mandarlo.
func (z *Zone) SaveBody(characterID int64, leaseID string, seq int) map[string]any {
	return map[string]any{"save_format": 1, "character_id": strconv.FormatInt(characterID, 10),
		"zone_instance_id": z.ID, "lease_id": leaseID, "seq": seq, "reason": 1, "release_lease": false,
		"progress": map[string]any{"progress_format": 1, "level": 2, "played_seconds": 60 * seq,
			"location": map[string]any{"zone_id": z.Scope.ZoneID, "channel": z.Scope.Channel}}}
}

// Save manda un guardado (body: un mapa, que se serializa, o los bytes tal cual).
func (z *Zone) Save(characterID int64, body any) *Response {
	z.P.T.Helper()
	return z.Do("PUT", "/internal/v1/characters/"+strconv.FormatInt(characterID, 10)+"/state", body)
}

// Release libera al personaje sin guardar.
func (z *Zone) Release(characterID int64, leaseID string) *Response {
	z.P.T.Helper()
	return z.Do("POST", "/internal/v1/characters/"+strconv.FormatInt(characterID, 10)+"/release",
		map[string]any{"zone_instance_id": z.ID, "lease_id": leaseID})
}

// Marshal serializa un cuerpo una vez (los reintentos mandan los mismos bytes).
func Marshal(v any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return data
}

// Int lee un número del cuerpo (json.Number).
func (r *Response) Int(name string) int64 {
	n, _ := r.Body[name].(json.Number)
	v, _ := n.Int64()
	return v
}
