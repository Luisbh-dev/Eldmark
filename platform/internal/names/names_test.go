package names_test

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/names"
)

// The cases it shares with test_name_rules.gd (platform.md §4.4). The Go tests run in the
// package's directory.
const sharedCases = "../../../tests/fixtures/names/name_rules_cases.json"

type nameCase struct {
	Name   string `json:"name"`
	Reason string `json:"reason"`
	Key    string `json:"key"`
}

func loadCases(t *testing.T) []nameCase {
	t.Helper()
	data, err := os.ReadFile(sharedCases)
	if err != nil {
		t.Fatal(err)
	}
	var cases []nameCase
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cases); err != nil {
		t.Fatal(err)
	}
	return cases
}

func TestSharedCasesWithGodot(t *testing.T) {
	cases := loadCases(t)
	if len(cases) < 100 {
		t.Fatalf("only %d cases", len(cases))
	}
	seen := map[string]bool{}
	for _, c := range cases {
		if _, ok := names.ParseReason(c.Reason); !ok {
			t.Errorf("%q: unknown reason %q", c.Name, c.Reason)
		}
		if got := names.Validate(c.Name).String(); got != c.Reason {
			t.Errorf("Validate(%q) = %s, expected %s", c.Name, got, c.Reason)
		}
		if got := names.NormalizeKey(c.Name); got != c.Key {
			t.Errorf("NormalizeKey(%q) = %q, expected %q", c.Name, got, c.Key)
		}
		seen[c.Reason] = true
	}
	for r := names.OK; r < names.Taken; r++ {
		if !seen[r.String()] {
			t.Errorf("no cases for %s", r)
		}
	}
}

func TestCollisionsByAccentAndCase(t *testing.T) {
	same := []string{"Aneira", "ANEIRA", "Anéira", "aneira", "ANÉIRA", "AnÉiRa"}
	for _, n := range same {
		if got := names.NormalizeKey(n); got != "aneira" {
			t.Errorf("NormalizeKey(%q) = %q", n, got)
		}
	}
	if names.NormalizeKey("Peña") != names.NormalizeKey("Pena") || names.NormalizeKey("Güenda") != names.NormalizeKey("Guenda") {
		t.Error("ñ and ü are folded")
	}
	if names.NormalizeKey("Álvaro") == names.NormalizeKey("Alvara") {
		t.Error("another letter does not collide")
	}
}

func TestReasons(t *testing.T) {
	r := names.Default()
	seen := map[string]bool{}
	for reason := names.OK; reason <= names.Taken; reason++ {
		code := reason.String()
		if seen[code] {
			t.Errorf("repeated code %s", code)
		}
		seen[code] = true
		back, ok := names.ParseReason(code)
		if !ok || back != reason {
			t.Errorf("ParseReason(%q) = %v, %v", code, back, ok)
		}
		if r.ReasonText(reason) == "" {
			t.Errorf("without text: %s", code)
		}
	}
	if _, ok := names.ParseReason("nada"); ok {
		t.Error("an unknown code is not valid")
	}
	if names.Reason(42).String() != "reason(42)" {
		t.Error("an unknown reason")
	}
	if !strings.Contains(r.ReasonText(names.TooShort), "3") || !strings.Contains(r.ReasonText(names.TooLong), "16") {
		t.Error("the texts state the lengths")
	}
	if r.MinLength() != 3 || r.MaxLength() != 16 {
		t.Error("lengths")
	}
}

// Each reserved name in the list, as written, is recognized; and the rules come from the data, not
// from the code: with other rules, other results.
func TestRulesComeFromTheData(t *testing.T) {
	sec := gamedata.MustLoad().Names
	for _, n := range sec.Reserved {
		if !names.Default().IsReserved(n) {
			t.Errorf("%q is not recognized as reserved", n)
		}
	}
	custom := sec
	custom.MinLength, custom.MaxLength = 2, 4
	custom.Reserved = []string{"Bo"}
	custom.Folded = map[string]string{}
	r, err := names.New(custom)
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]names.Reason{"Al": names.OK, "Bo": names.Reserved, "BÓ": names.OK,
		"Admin": names.TooLong, "A": names.TooShort} {
		if got := r.Validate(name); got != want {
			t.Errorf("with other rules, Validate(%q) = %s, expected %s", name, got, want)
		}
	}
	if r.NormalizeKey("Peña") != "peña" {
		t.Error("without folding, the ñ stays")
	}
	bad := sec
	bad.LowerLetters = "abc"
	if _, err := names.New(bad); err == nil {
		t.Error("mismatched uppercase and lowercase")
	}
	bad = sec
	bad.Folded = map[string]string{"ñ": "nn"}
	if _, err := names.New(bad); err == nil {
		t.Error("two-letter folding")
	}
}

// Text that is not valid UTF-8 (the name-check query arrives as is) is not a name.
func TestInvalidUTF8(t *testing.T) {
	if got := names.Validate("Ana\xff"); got != names.InvalidCharacter {
		t.Errorf("Validate with a stray byte = %s", got)
	}
	if got := names.Validate("\xc3\xb1ana"); got != names.NotCapitalized {
		t.Errorf("ñana = %s", got)
	}
}
