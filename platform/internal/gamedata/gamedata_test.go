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
		t.Errorf("protocol_version = %d; la fase 5 empieza en la 5", r.ProtocolVersion)
	}
	n := r.Names
	if n.MinLength != 3 || n.MaxLength != 16 {
		t.Errorf("longitudes %d–%d, se esperaban 3–16", n.MinLength, n.MaxLength)
	}
	if !strings.Contains(n.UpperLetters, "Ñ") || !strings.Contains(n.LowerLetters, "ñ") || n.Folded["ñ"] != "n" {
		t.Errorf("faltan la ñ o su plegado: %+v", n)
	}
	if len(n.Reserved) < 10 {
		t.Errorf("solo %d reservados", len(n.Reserved))
	}
	if gamedata.MustLoad() != r {
		t.Error("Load no devuelve siempre las mismas reglas")
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
		t.Fatal("no se encuentra PROTOCOL_VERSION en net_protocol.gd")
	}
	r := gamedata.MustLoad()
	if want := string(m[1]); want != strconv.Itoa(r.ProtocolVersion) {
		t.Errorf("progression_rules.json dice protocol_version %d y net_protocol.gd %s: vuelve a exportar las reglas "+
			"(tools/progression/export_rules.gd)", r.ProtocolVersion, want)
	}
}

func TestRawIsTheEmbeddedFile(t *testing.T) {
	disk, err := os.ReadFile("progression_rules.json")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(disk, gamedata.Raw()) {
		t.Error("Raw no es el archivo del paquete")
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
			t.Fatalf("%s: el caso no cambia el archivo", name)
		}
		if _, err := gamedata.Parse([]byte(text)); err == nil {
			t.Errorf("%s: se esperaba un error", name)
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
		t.Errorf("una sección más no debería romper nada: %v", err)
	}
}
