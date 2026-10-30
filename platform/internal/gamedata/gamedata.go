// Package gamedata incrusta las reglas del juego que exporta Godot: progression_rules.json
// (progresion.md §13.4, plataforma.md §4.4). Lo genera ProgressionRulesExport.build() y lo escribe
// tools/progression/export_rules.gd; tests/test_progression_rules_export.gd comprueba que el archivo
// del repositorio coincide con las reglas del código. Aquí no se edita a mano.
//
// De plataforma.md son dos secciones: protocol_version ([Rules.ProtocolVersion], el
// ELDMARK_MIN_PROTOCOL por defecto en dev y test) y names ([Names], que lee internal/names). Las
// demás (razas, apariencia, plantillas, objetos…) las lee progress.LoadRules (progresion.md P7) de
// [Raw].
package gamedata

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
)

//go:embed progression_rules.json
var raw []byte

// Raw devuelve el archivo tal cual (progress.LoadRules lo lee entero). No se debe modificar.
func Raw() []byte { return raw }

// Names es la sección names: lo que NameRules necesita para validar y normalizar nombres.
type Names struct {
	MinLength    int               `json:"min_length"`
	MaxLength    int               `json:"max_length"`
	UpperLetters string            `json:"upper_letters"` // mismo orden que LowerLetters
	LowerLetters string            `json:"lower_letters"`
	Folded       map[string]string `json:"folded"`   // letra minúscula → la que cuenta en la clave
	Reserved     []string          `json:"reserved"` // tal como están escritos en NameRules
}

// Rules son las secciones de plataforma.md. El resto del archivo no se mira aquí.
type Rules struct {
	ProtocolVersion int   `json:"protocol_version"`
	Names           Names `json:"names"`
}

// Parse lee las secciones de plataforma.md de un progression_rules.json y comprueba que tienen
// sentido. Las claves de otras secciones no cuentan (son de progresion.md).
func Parse(b []byte) (*Rules, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(b, &top); err != nil {
		return nil, fmt.Errorf("gamedata: progression_rules.json no es JSON válido: %w", err)
	}
	r := &Rules{}
	for key, dst := range map[string]any{"protocol_version": &r.ProtocolVersion, "names": &r.Names} {
		v, ok := top[key]
		if !ok {
			return nil, fmt.Errorf("gamedata: falta la sección %q", key)
		}
		if err := json.Unmarshal(v, dst); err != nil {
			return nil, fmt.Errorf("gamedata: sección %q: %w", key, err)
		}
	}
	if err := r.check(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *Rules) check() error {
	n := r.Names
	switch {
	case r.ProtocolVersion < 1:
		return errors.New("gamedata: protocol_version tiene que ser mayor que 0")
	case n.MinLength < 1 || n.MaxLength < n.MinLength:
		return errors.New("gamedata: names: longitudes que no tienen sentido")
	case n.UpperLetters == "" || len([]rune(n.UpperLetters)) != len([]rune(n.LowerLetters)):
		return errors.New("gamedata: names: upper_letters y lower_letters tienen que tener las mismas letras")
	}
	for from, to := range n.Folded {
		if len([]rune(from)) != 1 || len([]rune(to)) != 1 {
			return fmt.Errorf("gamedata: names: folded %q → %q no es de una letra a una letra", from, to)
		}
	}
	return nil
}

var (
	once     sync.Once
	embedded *Rules
	errEmbed error
)

// Load devuelve las reglas incrustadas en el binario. Un archivo roto es un error del repositorio
// (la prueba de Godot y la de este paquete lo detectan antes): serve no arranca.
func Load() (*Rules, error) {
	once.Do(func() { embedded, errEmbed = Parse(raw) })
	return embedded, errEmbed
}

// MustLoad es [Load] para las pruebas y los valores por defecto: entra en pánico si el archivo
// incrustado no vale.
func MustLoad() *Rules {
	r, err := Load()
	if err != nil {
		panic(err)
	}
	return r
}
