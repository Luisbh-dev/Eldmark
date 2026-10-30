// Package names es NameRules en Go (plataforma.md §4.4, SOC-13): las reglas de los nombres de
// personaje de scripts/shared/name_rules.gd, leídas de la sección names de progression_rules.json
// (internal/gamedata). La plataforma las aplica al crear y renombrar personajes, en name-check y al
// confirmar un borrado.
//
// Las dos implementaciones dan lo mismo con los mismos datos: los casos de
// tests/fixtures/names/name_rules_cases.json los leen test_name_rules.gd y las pruebas de este paquete.
package names

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"unicode"

	"eldmark/platform/internal/gamedata"
)

// Reason es el motivo por el que un nombre no vale, con los valores de NameRules.Reason. [OK] (0)
// es un nombre válido. [Taken] no lo devuelve [Rules.Validate]: lo decide quien mira la base.
type Reason int

// Motivos, en el orden de NameRules.Reason.
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

// Códigos de la API (el reason del 422 name_invalid y de name-check, §4.1), los de
// NameRules.REASON_CODES.
var codes = [...]string{"ok", "too_short", "too_long", "has_space", "has_digit", "invalid_character",
	"not_capitalized", "reserved", "taken"}

// String devuelve el código del motivo en la API («too_short»).
func (r Reason) String() string {
	if r >= 0 && int(r) < len(codes) {
		return codes[r]
	}
	return "reason(" + strconv.Itoa(int(r)) + ")"
}

// ParseReason lee el código de un motivo.
func ParseReason(code string) (Reason, bool) {
	for i, c := range codes {
		if c == code {
			return Reason(i), true
		}
	}
	return 0, false
}

// Rules son las reglas de los nombres. Son de solo lectura: valen entre gorrutinas.
type Rules struct {
	minLength, maxLength int
	upper, letters       map[rune]bool // mayúsculas; todas las letras admitidas
	folded               map[rune]rune
	reserved             map[string]bool // claves normalizadas
}

// New prepara las reglas de la sección names.
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

// Default devuelve las reglas de progression_rules.json incrustado en el binario. Entra en pánico
// si no valen: es un error del repositorio, que las pruebas detectan.
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

// MinLength devuelve las letras mínimas de un nombre.
func (r *Rules) MinLength() int { return r.minLength }

// MaxLength devuelve las letras máximas de un nombre.
func (r *Rules) MaxLength() int { return r.maxLength }

// Validate comprueba un nombre como NameRules.validate: devuelve [OK] o el primer motivo por el
// que no vale, en este orden: longitud (en caracteres), caracteres (en el orden en que aparecen:
// espacio, dígito ASCII u otro), mayúscula inicial y reservados.
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

// NormalizeKey es la clave con la que se comparan los nombres (NameRules.normalize_key): cada
// carácter en minúscula y sin tilde, diéresis ni eñe. Dos nombres son el mismo si tienen la misma
// clave. Con un texto que no es un nombre no falla: pasa a minúsculas lo que puede.
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

// IsReserved dice si el nombre, normalizado, es uno de los reservados.
func (r *Rules) IsReserved(name string) bool { return r.reserved[r.NormalizeKey(name)] }

// ReasonText es el texto en español del motivo (NameRules.reason_text; el de [Taken] es el de la
// plataforma, §4.1).
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

// Validate es [Rules.Validate] con las reglas por defecto ([Default]).
func Validate(name string) Reason { return Default().Validate(name) }

// NormalizeKey es [Rules.NormalizeKey] con las reglas por defecto ([Default]).
func NormalizeKey(name string) string { return Default().NormalizeKey(name) }
