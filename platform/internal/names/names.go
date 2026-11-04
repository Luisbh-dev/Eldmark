// Package names is NameRules in Go (plataforma.md §4.4, SOC-13): the character name rules of
// scripts/shared/name_rules.gd, read from the names section of progression_rules.json
// (internal/gamedata). The platform applies them when creating and renaming characters, in
// name-check and when confirming a deletion.
//
// The two implementations give the same results with the same data: the cases in
// tests/fixtures/names/name_rules_cases.json are read by test_name_rules.gd and this package's
// tests.
package names

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"unicode"

	"eldmark/platform/internal/gamedata"
)

// Reason is the reason a name is not valid, with the values of NameRules.Reason. [OK] (0) is a valid
// name. [Taken] is not returned by [Rules.Validate]: whoever looks at the database decides it.
type Reason int

// Reasons, in the order of NameRules.Reason.
const (
	OK Reason = iota
	TooShort
	TooLong
	HasSpace
	HasDigit
	InvalidCharacter
	NotCapitalized
	Reserved
	Taken
)

// API codes (the reason of the 422 name_invalid and of name-check, §4.1), those of
// NameRules.REASON_CODES.
var codes = [...]string{"ok", "too_short", "too_long", "has_space", "has_digit", "invalid_character",
	"not_capitalized", "reserved", "taken"}

// String returns the reason's API code ("too_short").
func (r Reason) String() string {
	if r >= 0 && int(r) < len(codes) {
		return codes[r]
	}
	return "reason(" + strconv.Itoa(int(r)) + ")"
}

// ParseReason reads a reason's code.
func ParseReason(code string) (Reason, bool) {
	for i, c := range codes {
		if c == code {
			return Reason(i), true
		}
	}
	return 0, false
}

// Rules are the name rules. They are read-only: safe across goroutines.
type Rules struct {
	minLength, maxLength int
	upper, letters       map[rune]bool // uppercase; all the admitted letters
	folded               map[rune]rune
	reserved             map[string]bool // normalized keys
}

// New prepares the rules from the names section.
func New(sec gamedata.Names) (*Rules, error) {
	upper, lower := []rune(sec.UpperLetters), []rune(sec.LowerLetters)
	if sec.MinLength < 1 || sec.MaxLength < sec.MinLength || len(upper) == 0 || len(upper) != len(lower) {
		return nil, fmt.Errorf("names: reglas que no tienen sentido (%d–%d letras, %d mayúsculas, %d minúsculas)",
			sec.MinLength, sec.MaxLength, len(upper), len(lower))
	}
	r := &Rules{minLength: sec.MinLength, maxLength: sec.MaxLength, upper: map[rune]bool{},
		letters: map[rune]bool{}, folded: map[rune]rune{}, reserved: map[string]bool{}}
	for i := range upper {
		r.upper[upper[i]] = true
		r.letters[upper[i]] = true
		r.letters[lower[i]] = true
	}
	for from, to := range sec.Folded {
		f, t := []rune(from), []rune(to)
		if len(f) != 1 || len(t) != 1 {
			return nil, fmt.Errorf("names: el plegado %q → %q no es de una letra a una letra", from, to)
		}
		r.folded[f[0]] = t[0]
	}
	for _, name := range sec.Reserved {
		r.reserved[r.NormalizeKey(name)] = true
	}
	return r, nil
}

var (
	defaultOnce  sync.Once
	defaultRules *Rules
)

// Default returns the rules from the progression_rules.json embedded in the binary. It panics if
// they are not valid: it is a repository error, which the tests catch.
func Default() *Rules {
	defaultOnce.Do(func() {
		r, err := New(gamedata.MustLoad().Names)
		if err != nil {
			panic(err)
		}
		defaultRules = r
	})
	return defaultRules
}

// MinLength returns the minimum letters of a name.
func (r *Rules) MinLength() int { return r.minLength }

// MaxLength returns the maximum letters of a name.
func (r *Rules) MaxLength() int { return r.maxLength }

// Validate checks a name like NameRules.validate: it returns [OK] or the first reason it is not
// valid, in this order: length (in characters), characters (in the order they appear: space, ASCII
// digit or other), initial capital and reserved.
func (r *Rules) Validate(name string) Reason {
	runes := []rune(name)
	switch {
	case len(runes) < r.minLength:
		return TooShort
	case len(runes) > r.maxLength:
		return TooLong
	}
	for _, c := range runes {
		switch {
		case r.letters[c]:
			continue
		case c == ' ':
			return HasSpace
		case c >= '0' && c <= '9':
			return HasDigit
		default:
			return InvalidCharacter
		}
	}
	if !r.upper[runes[0]] {
		return NotCapitalized
	}
	if r.IsReserved(name) {
		return Reserved
	}
	return OK
}

// NormalizeKey is the key names are compared by (NameRules.normalize_key): each character
// lowercased and without accent, diaeresis or tilde on the n. Two names are the same if they have
// the same key. With text that is not a name it does not fail: it lowercases what it can.
func (r *Rules) NormalizeKey(name string) string {
	var b strings.Builder
	b.Grow(len(name))
	for _, c := range name {
		c = unicode.ToLower(c)
		if f, ok := r.folded[c]; ok {
			c = f
		}
		b.WriteRune(c)
	}
	return b.String()
}

// IsReserved says whether the name, normalized, is one of the reserved ones.
func (r *Rules) IsReserved(name string) bool { return r.reserved[r.NormalizeKey(name)] }

// ReasonText is the reason's text in Spanish (NameRules.reason_text; [Taken]'s is the platform's,
// §4.1).
func (r *Rules) ReasonText(reason Reason) string {
	switch reason {
	case OK:
		return "Nombre válido"
	case TooShort:
		return fmt.Sprintf("El nombre debe tener al menos %d letras", r.minLength)
	case TooLong:
		return fmt.Sprintf("El nombre puede tener %d letras como máximo", r.maxLength)
	case HasSpace:
		return "El nombre no puede llevar espacios"
	case HasDigit:
		return "El nombre no puede llevar números"
	case InvalidCharacter:
		return "El nombre solo puede llevar letras (con tildes y ñ)"
	case NotCapitalized:
		return "El nombre debe empezar por mayúscula"
	case Reserved:
		return "Ese nombre está reservado"
	case Taken:
		return "Ese nombre ya está en uso"
	}
	return "Nombre no válido"
}

// Validate is [Rules.Validate] with the default rules ([Default]).
func Validate(name string) Reason { return Default().Validate(name) }

// NormalizeKey is [Rules.NormalizeKey] with the default rules ([Default]).
func NormalizeKey(name string) string { return Default().NormalizeKey(name) }
