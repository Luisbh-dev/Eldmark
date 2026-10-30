// Package tickets es el billete de entrada en la zona (plataforma.md §5.1, TEC-24): 52 B en
// little-endian con solo la identidad del personaje y su destino, firmados con HMAC-SHA256 truncado
// a 16 B. La plataforma lo emite en enter (§4.5); la zona lo comprueba sin red (HandoffTicket y
// TicketAuthProvider, §5.2) y la reclamación (§5.3) garantiza el un solo uso.
//
// Los vectores de tests/fixtures/tickets/handoff_ticket_vectors.json los comprueban las pruebas de
// este paquete y, con el mismo archivo, las de HandoffTicket en GDScript (plataforma.md P4).
package tickets

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

// Tamaños y valores del formato (§5.1).
const (
	Size     = 52 // bytes del billete
	Version  = 1  // único formato
	MACSize  = 16 // HMAC-SHA256 truncado
	bodySize = Size - MACSize
	// Lifetime es lo que vale un billete, en segundos: expires_at = issued_at + Lifetime.
	Lifetime = 10
)

// Bits de Flags.
const (
	FlagFromMenu uint8 = 1 << 0 // entrada desde el menú
	FlagHandoff  uint8 = 1 << 1 // traspaso entre zonas (fase 6)
)

// Errores de [Parse] (errors.Is).
var (
	ErrSize    = errors.New("tickets: el billete no mide 52 B")
	ErrVersion = errors.New("tickets: versión de billete desconocida")
	ErrKey     = errors.New("tickets: clave de billete desconocida")
	ErrMAC     = errors.New("tickets: la firma del billete no vale")
)

// Ticket son los campos de un billete, en el orden del formato.
type Ticket struct {
	Version, KeyID uint8
	WorldID        uint16
	// TicketID es aleatorio, con el bit 63 a 0 ([NewID]); es la clave de enter_tickets.
	TicketID, CharacterID uint64
	ZoneKey               uint32 // [ZoneKey] del id de la zona
	Channel, Realm        uint8  // Realm: código de NetProtocol.Realm, informativo
	Arrival, Flags        uint8
	IssuedAt, ExpiresAt   uint32 // Unix, s
}

// ZoneKey es la huella de una zona en el billete: los 4 primeros bytes del SHA-256 de su id ASCII,
// leídos como u32 little-endian («vado_gris» → 0x19efc013).
func ZoneKey(zoneID string) uint32 {
	sum := sha256.Sum256([]byte(zoneID))
	return binary.LittleEndian.Uint32(sum[:4])
}

func (t Ticket) body() [bodySize]byte {
	var b [bodySize]byte
	b[0], b[1] = t.Version, t.KeyID
	binary.LittleEndian.PutUint16(b[2:], t.WorldID)
	binary.LittleEndian.PutUint64(b[4:], t.TicketID)
	binary.LittleEndian.PutUint64(b[12:], t.CharacterID)
	binary.LittleEndian.PutUint32(b[20:], t.ZoneKey)
	b[24], b[25], b[26], b[27] = t.Channel, t.Realm, t.Arrival, t.Flags
	binary.LittleEndian.PutUint32(b[28:], t.IssuedAt)
	binary.LittleEndian.PutUint32(b[32:], t.ExpiresAt)
	return b
}

func mac(key, body []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(body)
	return m.Sum(nil)[:MACSize]
}

// Sign codifica el billete y lo firma con la clave de su KeyID.
func (t Ticket) Sign(key []byte) [Size]byte {
	var out [Size]byte
	body := t.body()
	copy(out[:], body[:])
	copy(out[bodySize:], mac(key, body[:]))
	return out
}

// Parse decodifica un billete y comprueba, en este orden, el tamaño ([ErrSize]), la versión
// ([ErrVersion]), que su key_id esté en keys ([ErrKey]) y la firma en tiempo constante
// ([ErrMAC]). No mira la zona, el reloj ni el un solo uso: eso es de quien lo recibe (§5.2, §5.3).
func Parse(b []byte, keys map[uint8][]byte) (Ticket, error) {
	if len(b) != Size {
		return Ticket{}, ErrSize
	}
	if b[0] != Version {
		return Ticket{}, ErrVersion
	}
	key, ok := keys[b[1]]
	if !ok || len(key) == 0 {
		return Ticket{}, ErrKey
	}
	if !hmac.Equal(mac(key, b[:bodySize]), b[bodySize:]) {
		return Ticket{}, ErrMAC
	}
	return Ticket{
		Version: b[0], KeyID: b[1],
		WorldID:     binary.LittleEndian.Uint16(b[2:]),
		TicketID:    binary.LittleEndian.Uint64(b[4:]),
		CharacterID: binary.LittleEndian.Uint64(b[12:]),
		ZoneKey:     binary.LittleEndian.Uint32(b[20:]),
		Channel:     b[24], Realm: b[25], Arrival: b[26], Flags: b[27],
		IssuedAt:  binary.LittleEndian.Uint32(b[28:]),
		ExpiresAt: binary.LittleEndian.Uint32(b[32:]),
	}, nil
}

// NewID devuelve un ticket_id aleatorio de crypto/rand: de 1 a 2^63 − 1 (el bit 63 a 0, para que
// quepa en un bigint y en el int64 de GDScript).
func NewID() (uint64, error) {
	var b [8]byte
	for {
		if _, err := rand.Read(b[:]); err != nil {
			return 0, err
		}
		id := binary.LittleEndian.Uint64(b[:]) &^ (1 << 63)
		if id != 0 {
			return id, nil
		}
	}
}
