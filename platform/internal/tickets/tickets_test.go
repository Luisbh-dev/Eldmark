package tickets_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"math/rand/v2"
	"os"
	"strconv"
	"testing"

	"eldmark/platform/internal/tickets"
)

// update rewrites the shared vectors: go test ./internal/tickets -run TestSharedVectors -update
var update = flag.Bool("update", false, "reescribe tests/fixtures/tickets/handoff_ticket_vectors.json")

// The vectors shared with HandoffTicket in GDScript (platform.md P4).
const vectorsPath = "../../../tests/fixtures/tickets/handoff_ticket_vectors.json"

// The vector from platform.md §5.1 and the ticket from the enter response in §4.5.
const (
	specHex    = "0101010008070605040302012a0000000000000013c0ef190001000100d2496b0ad2496b7061e2f54ab1a096f66024437123d9d1"
	specBase64 = "AQEBAAgHBgUEAwIBKgAAAAAAAAATwO8ZAAEAAQDSSWsK0klrcGHi9UqxoJb2YCRDcSPZ0Q=="
)

// Key 1: the vector's (00 01 … 1f), valid only in tests. Key 2: another fixed test key.
var (
	key1 = func() []byte {
		k := make([]byte, 32)
		for i := range k {
			k[i] = byte(i)
		}
		return k
	}()
	key2 = func() []byte { s := sha256.Sum256([]byte("eldmark: segunda clave de billete de prueba")); return s[:] }()
	keys = map[uint8][]byte{1: key1, 2: key2}
)

func specTicket() tickets.Ticket {
	return tickets.Ticket{Version: 1, KeyID: 1, WorldID: 1, TicketID: 0x0102030405060708, CharacterID: 42,
		ZoneKey: tickets.ZoneKey("vado_gris"), Channel: 0, Realm: 1, Arrival: 0, Flags: tickets.FlagFromMenu,
		IssuedAt: 1800000000, ExpiresAt: 1800000010}
}

func TestSpecVector(t *testing.T) {
	if got := tickets.ZoneKey("vado_gris"); got != 0x19efc013 {
		t.Fatalf("ZoneKey(vado_gris) = %#x", got)
	}
	signed := specTicket().Sign(key1)
	if got := hex.EncodeToString(signed[:]); got != specHex {
		t.Fatalf("vector from §5.1:\n got %s\nwant %s", got, specHex)
	}
	if got := base64.StdEncoding.EncodeToString(signed[:]); got != specBase64 {
		t.Errorf("base64 from §4.5: %s", got)
	}
	parsed, err := tickets.Parse(signed[:], keys)
	if err != nil {
		t.Fatal(err)
	}
	if parsed != specTicket() {
		t.Errorf("Parse = %+v", parsed)
	}
}

func TestParseErrors(t *testing.T) {
	good := specTicket().Sign(key1)
	flip := func(i int) []byte {
		b := bytes.Clone(good[:])
		b[i] ^= 0x01
		return b
	}
	cases := []struct {
		name string
		b    []byte
		want error
	}{
		{"vacío", nil, tickets.ErrSize},
		{"51 B", good[:51], tickets.ErrSize},
		{"53 B", append(bytes.Clone(good[:]), 0), tickets.ErrSize},
		{"versión", flip(0), tickets.ErrVersion},
		{"clave desconocida", flip(1), tickets.ErrKey}, // key_id 0
		{"mundo", flip(2), tickets.ErrMAC},
		{"personaje", flip(12), tickets.ErrMAC},
		{"caducidad", flip(32), tickets.ErrMAC},
		{"firma", flip(tickets.Size - 1), tickets.ErrMAC},
	}
	for _, c := range cases {
		if _, err := tickets.Parse(c.b, keys); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, expected %v", c.name, err, c.want)
		}
	}
	// Signed with a different key than the one for its key_id.
	other := specTicket().Sign(key2)
	if _, err := tickets.Parse(other[:], keys); !errors.Is(err, tickets.ErrMAC) {
		t.Errorf("another key: %v", err)
	}
	if _, err := tickets.Parse(good[:], map[uint8][]byte{2: key2}); !errors.Is(err, tickets.ErrKey) {
		t.Errorf("without key 1: %v", err)
	}
}

func TestRoundTrip(t *testing.T) {
	r := rand.New(rand.NewPCG(1, 2))
	for range 1000 {
		tk := tickets.Ticket{Version: 1, KeyID: 2, WorldID: uint16(r.Uint32()), TicketID: r.Uint64() >> 1,
			CharacterID: r.Uint64() >> 1, ZoneKey: r.Uint32(), Channel: uint8(r.Uint32()), Realm: uint8(r.Uint32()),
			Arrival: uint8(r.Uint32()), Flags: uint8(r.Uint32()), IssuedAt: r.Uint32(), ExpiresAt: r.Uint32()}
		b := tk.Sign(key2)
		got, err := tickets.Parse(b[:], keys)
		if err != nil || got != tk {
			t.Fatalf("%+v → %+v, %v", tk, got, err)
		}
	}
}

func TestNewID(t *testing.T) {
	seen := map[uint64]bool{}
	for range 1000 {
		id, err := tickets.NewID()
		if err != nil {
			t.Fatal(err)
		}
		if id == 0 || id>>63 != 0 {
			t.Fatalf("id out of range: %d", id)
		}
		if seen[id] {
			t.Fatalf("repeated id: %d", id)
		}
		seen[id] = true
	}
}

// Vectors shared with GDScript. Ids are strings (platform.md §4.1): in GDScript they are read
// with String.to_int(); the other numbers fit in a float.
type vectorFile struct {
	Comment  string        `json:"comment"`
	Keys     []vectorKey   `json:"keys"`
	ZoneKeys []zoneKeyCase `json:"zone_keys"`
	Valid    []validCase   `json:"valid"`
	Invalid  []invalidCase `json:"invalid"`
}

type vectorKey struct {
	KeyID uint8  `json:"key_id"`
	Hex   string `json:"hex"`
}

type zoneKeyCase struct {
	ZoneID  string `json:"zone_id"`
	ZoneKey uint32 `json:"zone_key"`
}

type validCase struct {
	Name        string `json:"name"`
	KeyID       uint8  `json:"key_id"`
	WorldID     uint16 `json:"world_id"`
	TicketID    string `json:"ticket_id"`
	CharacterID string `json:"character_id"`
	ZoneID      string `json:"zone_id"`
	ZoneKey     uint32 `json:"zone_key"`
	Channel     uint8  `json:"channel"`
	Realm       uint8  `json:"realm"`
	Arrival     uint8  `json:"arrival"`
	Flags       uint8  `json:"flags"`
	IssuedAt    uint32 `json:"issued_at"`
	ExpiresAt   uint32 `json:"expires_at"`
	Hex         string `json:"hex"`
	Base64      string `json:"base64"`
}

type invalidCase struct {
	Name  string `json:"name"`
	Hex   string `json:"hex"`
	Error string `json:"error"` // size, version, key or mac
}

func (c validCase) ticket(t *testing.T) tickets.Ticket {
	t.Helper()
	ticketID, err1 := strconv.ParseUint(c.TicketID, 10, 64)
	characterID, err2 := strconv.ParseUint(c.CharacterID, 10, 64)
	if err1 != nil || err2 != nil {
		t.Fatalf("%s: ids that cannot be read", c.Name)
	}
	return tickets.Ticket{Version: tickets.Version, KeyID: c.KeyID, WorldID: c.WorldID, TicketID: ticketID,
		CharacterID: characterID, ZoneKey: c.ZoneKey, Channel: c.Channel, Realm: c.Realm, Arrival: c.Arrival,
		Flags: c.Flags, IssuedAt: c.IssuedAt, ExpiresAt: c.ExpiresAt}
}

func valid(name string, keyID uint8, tk tickets.Ticket, zoneID string) validCase {
	tk.Version, tk.KeyID, tk.ZoneKey = tickets.Version, keyID, tickets.ZoneKey(zoneID)
	b := tk.Sign(keys[keyID])
	return validCase{Name: name, KeyID: keyID, WorldID: tk.WorldID, TicketID: strconv.FormatUint(tk.TicketID, 10),
		CharacterID: strconv.FormatUint(tk.CharacterID, 10), ZoneID: zoneID, ZoneKey: tk.ZoneKey, Channel: tk.Channel,
		Realm: tk.Realm, Arrival: tk.Arrival, Flags: tk.Flags, IssuedAt: tk.IssuedAt, ExpiresAt: tk.ExpiresAt,
		Hex: hex.EncodeToString(b[:]), Base64: base64.StdEncoding.EncodeToString(b[:])}
}

// buildVectors builds the vectors file; the one in the repository must be exactly this one.
func buildVectors() vectorFile {
	spec := specTicket()
	good := spec.Sign(key1)
	altered := func(i int, x byte) string {
		b := bytes.Clone(good[:])
		b[i] ^= x
		return hex.EncodeToString(b)
	}
	resigned := func(tk tickets.Ticket, key []byte) string {
		b := tk.Sign(key)
		return hex.EncodeToString(b[:])
	}
	unknownKey := spec
	unknownKey.KeyID = 9
	version2 := spec
	version2.Version = 2
	f := vectorFile{
		Comment: "Billete de 52 B de docs/platform.md §5.1. Generado por platform/internal/tickets " +
			"(go test ./internal/tickets -run TestSharedVectors -update); lo leen las pruebas de Go y de HandoffTicket.",
		Keys: []vectorKey{{1, hex.EncodeToString(key1)}, {2, hex.EncodeToString(key2)}},
	}
	for _, z := range []string{"vado_gris", "test_world", "eldrun", "a", ""} {
		f.ZoneKeys = append(f.ZoneKeys, zoneKeyCase{z, tickets.ZoneKey(z)})
	}
	f.Valid = []validCase{
		valid("vector de platform.md §5.1", 1, spec, "vado_gris"),
		valid("ids de 63 bits, por encima de 2^53", 2, tickets.Ticket{WorldID: 1, TicketID: 1<<63 - 1,
			CharacterID: 1<<53 + 1, Channel: 3, Realm: 2, Flags: tickets.FlagFromMenu, IssuedAt: 1800000100,
			ExpiresAt: 1800000110}, "test_world"),
		valid("traspaso: mundo de dos bytes, canal 255 y fechas al final del u32", 1, tickets.Ticket{WorldID: 513,
			TicketID: 1, CharacterID: 1, Channel: 255, Realm: 3, Arrival: 2, Flags: tickets.FlagHandoff,
			IssuedAt: 1<<32 - 11, ExpiresAt: 1<<32 - 1}, "eldrun"),
	}
	f.Invalid = []invalidCase{
		{"firma alterada (último byte)", altered(tickets.Size-1, 0x01), "mac"},
		{"cuerpo alterado (personaje 43 con la firma del 42)", altered(12, 0x01), "mac"},
		{"cuerpo alterado (caduca 1 s después)", altered(32, 0x01), "mac"},
		{"firmado con la clave 2 pero con key_id 1", resigned(spec, key2), "mac"},
		{"clave desconocida (key_id 9)", resigned(unknownKey, key1), "key"},
		{"versión 2", resigned(version2, key1), "version"},
		{"51 B", hex.EncodeToString(good[:51]), "size"},
		{"53 B", hex.EncodeToString(append(bytes.Clone(good[:]), 0)), "size"},
		{"vacío", "", "size"},
	}
	return f
}

func TestSharedVectors(t *testing.T) {
	want, err := json.MarshalIndent(buildVectors(), "", "\t")
	if err != nil {
		t.Fatal(err)
	}
	want = append(want, '\n')
	if *update {
		if err := os.MkdirAll("../../../tests/fixtures/tickets", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(vectorsPath, want, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := os.ReadFile(vectorsPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("%s is not up to date: go test ./internal/tickets -run TestSharedVectors -update", vectorsPath)
	}
	var f vectorFile
	if err := json.Unmarshal(got, &f); err != nil {
		t.Fatal(err)
	}
	if f.Valid[0].Hex != specHex {
		t.Errorf("the first vector is not the one from §5.1")
	}
	for _, z := range f.ZoneKeys {
		if tickets.ZoneKey(z.ZoneID) != z.ZoneKey {
			t.Errorf("ZoneKey(%q)", z.ZoneID)
		}
	}
	for _, c := range f.Valid {
		b, _ := hex.DecodeString(c.Hex)
		parsed, err := tickets.Parse(b, keys)
		if err != nil || parsed != c.ticket(t) {
			t.Errorf("%s: %+v, %v", c.Name, parsed, err)
		}
	}
	errs := map[string]error{"size": tickets.ErrSize, "version": tickets.ErrVersion, "key": tickets.ErrKey,
		"mac": tickets.ErrMAC}
	for _, c := range f.Invalid {
		b, _ := hex.DecodeString(c.Hex)
		if _, err := tickets.Parse(b, keys); !errors.Is(err, errs[c.Error]) {
			t.Errorf("%s: %v, expected %s", c.Name, err, c.Error)
		}
	}
}
