// Package tickets is the zone entry ticket (plataforma.md §5.1, TEC-24): 52 B in little-endian
// with only the character's identity and its destination, signed with HMAC-SHA256 truncated to
// 16 B. The platform issues it in enter (§4.5); the zone checks it without a network (HandoffTicket
// and TicketAuthProvider, §5.2) and the claim (§5.3) guarantees single use.
//
// The vectors in tests/fixtures/tickets/handoff_ticket_vectors.json are checked by this
// package's tests and, with the same file, by those of HandoffTicket in GDScript (plataforma.md P4).
package tickets

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

// Sizes and values of the format (§5.1).
const (
	Size     = 52 // ticket bytes
	Version  = 1  // only format
	MACSize  = 16 // truncated HMAC-SHA256
	bodySize = Size - MACSize
	// Lifetime is how long a ticket is valid, in seconds: expires_at = issued_at + Lifetime.
	Lifetime = 10
)

// Bits of Flags.
const (
	FlagFromMenu uint8 = 1 << 0 // entry from the menu
	FlagHandoff  uint8 = 1 << 1 // handoff between zones (phase 6)
)

// [Parse] errors (errors.Is).
var (
	ErrSize    = errors.New("tickets: el billete no mide 52 B")
	ErrVersion = errors.New("tickets: versión de billete desconocida")
	ErrKey     = errors.New("tickets: clave de billete desconocida")
	ErrMAC     = errors.New("tickets: la firma del billete no vale")
)

// Ticket holds the fields of a ticket, in the format's order.
type Ticket struct {
	Version, KeyID uint8
	WorldID        uint16
	// TicketID is random, with bit 63 at 0 ([NewID]); it is the key of enter_tickets.
	TicketID, CharacterID uint64
	ZoneKey               uint32 // [ZoneKey] of the zone's id
	Channel, Realm        uint8  // Realm: NetProtocol.Realm code, informational
	Arrival, Flags        uint8
	IssuedAt, ExpiresAt   uint32 // Unix, s
}

// ZoneKey is a zone's fingerprint in the ticket: the first 4 bytes of the SHA-256 of its ASCII
// id, read as a little-endian u32 ("vado_gris" → 0x19efc013).
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

// Sign encodes the ticket and signs it with the key for its KeyID.
func (t Ticket) Sign(key []byte) [Size]byte {
	var out [Size]byte
	body := t.body()
	copy(out[:], body[:])
	copy(out[bodySize:], mac(key, body[:]))
	return out
}

// Parse decodes a ticket and checks, in this order, the size ([ErrSize]), the version
// ([ErrVersion]), that its key_id is in keys ([ErrKey]) and the signature in constant time
// ([ErrMAC]). It does not check the zone, the clock or single use: that is up to whoever receives
// it (§5.2, §5.3).
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

// NewID returns a random ticket_id from crypto/rand: from 1 to 2^63 − 1 (bit 63 at 0, so that it
// fits in a bigint and in GDScript's int64).
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
