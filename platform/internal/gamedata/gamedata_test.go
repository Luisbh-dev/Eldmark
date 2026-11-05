package gamedata_test

import (
	"bytes"
	"encoding/json"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"eldmark/platform/internal/gamedata"
)

func TestEmbeddedRules(t *testing.T) {
	r, err := gamedata.Load()
	if err != nil {
		t.Fatal(err)
	}
	if r.ProtocolVersion < 5 {
		t.Errorf("protocol_version = %d; phase 5 starts at 5", r.ProtocolVersion)
	}
	n := r.Names
	if n.MinLength != 3 || n.MaxLength != 16 {
		t.Errorf("lengths %d-%d, expected 3-16", n.MinLength, n.MaxLength)
	}
	if !strings.Contains(n.UpperLetters, "Ñ") || !strings.Contains(n.LowerLetters, "ñ") || n.Folded["ñ"] != "n" {
		t.Errorf("the ñ or its folding is missing: %+v", n)
	}
	if len(n.Reserved) < 10 {
		t.Errorf("only %d reserved", len(n.Reserved))
	}
	if gamedata.MustLoad() != r {
		t.Error("Load does not always return the same rules")
	}
}

// The embedded file is Godot's: the protocol_version matches net_protocol.gd's.
func TestProtocolVersionMatchesGodot(t *testing.T) {
	src, err := os.ReadFile("../../../scripts/shared/net/net_protocol.gd")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^const PROTOCOL_VERSION: int = (\d+)$`).FindSubmatch(src)
	if m == nil {
		t.Fatal("PROTOCOL_VERSION not found in net_protocol.gd")
	}
	r := gamedata.MustLoad()
	if want := string(m[1]); want != strconv.Itoa(r.ProtocolVersion) {
		t.Errorf("progression_rules.json says protocol_version %d and net_protocol.gd %s: re-export the rules "+
			"(tools/progression/export_rules.gd)", r.ProtocolVersion, want)
	}
}

func TestRawIsTheEmbeddedFile(t *testing.T) {
	disk, err := os.ReadFile("progression_rules.json")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(disk, gamedata.Raw()) {
		t.Error("Raw is not the package's file")
	}
}

var protocolRe = regexp.MustCompile(`"protocol_version": \d+`)

func TestParseRejectsBrokenFiles(t *testing.T) {
	good := gamedata.Raw()
	cases := map[string]string{
		"no es JSON":            `{`,
		"sin names":             `{"protocol_version": 5}`,
		"sin protocol_version":  `{"names": {}}`,
		"protocolo cero":        protocolRe.ReplaceAllString(string(good), `"protocol_version": 0`),
		"letras desparejadas":   strings.Replace(string(good), `"upper_letters": "ABC`, `"upper_letters": "ABCX`, 1),
		"plegado de dos letras": strings.Replace(string(good), `"ñ": "n"`, `"ñ": "nn"`, 1),
		"longitudes al revés":   strings.Replace(string(good), `"min_length": 3`, `"min_length": 30`, 1),
	}
	for name, text := range cases {
		if text == string(good) {
			t.Fatalf("%s: the case does not change the file", name)
		}
		if _, err := gamedata.Parse([]byte(text)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	// Other sections (those of progression.md) do not interfere.
	var top map[string]json.RawMessage
	if err := json.Unmarshal(good, &top); err != nil {
		t.Fatal(err)
	}
	top["races"] = json.RawMessage(`[{"id": "race_vardheim"}]`)
	more, _ := json.Marshal(top)
	if _, err := gamedata.Parse(more); err != nil {
		t.Errorf("one more section should not break anything: %v", err)
	}
}
