package jsonx

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestIntAcceptsIntegersAndGodotFloats(t *testing.T) {
	cases := map[string]int64{
		`4`:                 4,
		`4.0`:               4,
		`820.0`:             820,
		`-3`:                -3,
		`-3.000`:            -3,
		`0`:                 0,
		`-0`:                0,
		`0.0`:               0,
		`4e0`:               4,
		`4E+2`:              400,
		`1.5e1`:             15,
		`9007199254740991`:  MaxSafeInt,
		`-9007199254740991`: -MaxSafeInt,
		` 7 `:               7,
		`0e999`:             0,
	}
	for in, want := range cases {
		var got Int
		if err := json.Unmarshal([]byte(in), &got); err != nil {
			t.Errorf("%s: unexpected error: %v", in, err)
			continue
		}
		if int64(got) != want {
			t.Errorf("%s: %d, expected %d", in, got, want)
		}
	}
}

func TestIntRejectsFractionsStringsAndUnsafeValues(t *testing.T) {
	for _, in := range []string{
		`4.5`, `45e-1`, `0.1`, `-0.5`, `"4"`, `null`, `true`, `[]`, `{}`,
		`9007199254740992`, `9007199254740993`, `-9007199254740992`, `1e16`, `1e300`,
		`9223372036854775807`, `04`, `4.`, `.5`, `+4`, `4e`, `4e+`, `0x10`, `NaN`,
		`1` + strings.Repeat("0", 70),
	} {
		var got Int
		err := json.Unmarshal([]byte(in), &got)
		if err == nil {
			t.Errorf("%s: accepted as %d", in, got)
		}
	}
}

func TestIntInsideAStructAndAsPointer(t *testing.T) {
	var body struct {
		Kills Int  `json:"kills"`
		Level *Int `json:"level"`
	}
	if err := DecodeBytes([]byte(`{"kills": 4.0, "level": null}`), &body); err != nil {
		t.Fatalf("Godot rewrites 4 as 4.0 and it has to be accepted: %v", err)
	}
	if body.Kills != 4 || body.Level != nil {
		t.Fatalf("kills %d, level %v", body.Kills, body.Level)
	}
	if err := DecodeBytes([]byte(`{"kills": 4.5}`), &body); !errors.Is(err, ErrInt) {
		t.Fatalf("4.5 had to fail with ErrInt: %v", err)
	}
	out, err := json.Marshal(Int(820))
	if err != nil || string(out) != "820" {
		t.Fatalf("Int is written without decimals: %s %v", out, err)
	}
	if _, err := json.Marshal(Int(MaxSafeInt + 1)); err == nil {
		t.Fatal("an integer that does not fit exactly in JSON is not written")
	}
}

func TestIDRoundTripsTheFull63Bits(t *testing.T) {
	var id ID
	if err := json.Unmarshal([]byte(`"9223372036854775807"`), &id); err != nil {
		t.Fatalf("2^63 - 1 as a string is accepted: %v", err)
	}
	if int64(id) != 1<<63-1 {
		t.Fatalf("read %d", id)
	}
	out, err := json.Marshal(id)
	if err != nil || string(out) != `"9223372036854775807"` {
		t.Fatalf("it is written as a string: %s %v", out, err)
	}
	// The vector's ticket_id from §5.1 and an id above 2^53, without losing anything.
	for in, want := range map[string]int64{
		`"72623859790382856"`: 0x0102030405060708,
		`"9007199254740993"`:  1<<53 + 1,
		`"0"`:                 0,
		`"42"`:                42,
		`"\u0034\u0032"`:      42, // JSON escapes inside the string
	} {
		var got ID
		if err := json.Unmarshal([]byte(in), &got); err != nil || int64(got) != want {
			t.Errorf("%s: %d %v, expected %d", in, got, err, want)
		}
	}
}

func TestIDRejectsNumbersAndMalformedStrings(t *testing.T) {
	for _, in := range []string{
		`42`, `42.0`, `null`, `"9223372036854775808"`, `"18446744073709551615"`, `"-1"`, `"+1"`,
		`""`, `" 42"`, `"42 "`, `"042"`, `"4e2"`, `"0x2a"`, `"4_2"`, `true`, `["42"]`,
	} {
		var got ID
		if err := json.Unmarshal([]byte(in), &got); err == nil {
			t.Errorf("%s: accepted as %d", in, got)
		} else if !errors.Is(err, ErrID) {
			t.Errorf("%s: the error is not ErrID: %v", in, err)
		}
	}
	if _, err := ParseID("12a"); err == nil {
		t.Error("ParseID accepts only digits")
	}
	if id, err := ParseID("8152839359930207727"); err != nil || id.String() != "8152839359930207727" {
		t.Errorf("ParseID with the id that Godot corrupts: %v %v", id, err)
	}
}

func TestDecodeIsStrict(t *testing.T) {
	type body struct {
		CharacterID ID  `json:"character_id"`
		Seq         Int `json:"seq"`
	}
	var b body
	if err := DecodeBytes([]byte(`{"character_id": "41", "seq": 17.0}`), &b); err != nil {
		t.Fatalf("valid body: %v", err)
	}
	if b.CharacterID != 41 || b.Seq != 17 {
		t.Fatalf("read %+v", b)
	}
	bad := map[string]string{
		"campo desconocido":      `{"character_id": "41", "seq": 1, "world_id": 1}`,
		"id sin comillas":        `{"character_id": 41, "seq": 1}`,
		"datos sobrantes":        `{"character_id": "41", "seq": 1} {}`,
		"basura detrás":          `{"character_id": "41", "seq": 1}x`,
		"JSON roto":              `{"character_id": "41",`,
		"vacío":                  ``,
		"tipo que no casa":       `[]`,
		"seq con decimales":      `{"character_id": "41", "seq": 1.5}`,
		"id mayor que 2^63 − 1":  `{"character_id": "9223372036854775808", "seq": 1}`,
		"entero mayor que 2^53":  `{"character_id": "41", "seq": 9007199254740993}`,
		"clave repetida rara":    `{"character_id": "41", "seq": 1, "Seq": 2, "x": 1}`,
		"cadena en lugar de int": `{"character_id": "41", "seq": "1"}`,
	}
	for name, in := range bad {
		var b body
		if err := DecodeBytes([]byte(in), &b); err == nil {
			t.Errorf("%s: accepted %s", name, in)
		}
	}
	// Trailing spaces and line breaks are valid.
	if err := DecodeBytes([]byte("{\"character_id\": \"1\", \"seq\": 1}\n\n"), &b); err != nil {
		t.Fatalf("trailing whitespace: %v", err)
	}
}
