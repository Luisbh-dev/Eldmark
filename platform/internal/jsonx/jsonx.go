// Package jsonx lee y escribe los enteros y los ids del JSON de las dos API (plataforma.md §4.1).
//
// Godot lee todo número JSON como float y, al volver a serializar lo que leyó, escribe 820.0: por
// eso un campo entero usa [Int], que acepta 4 y 4.0 y rechaza 4.5 y lo que no cabe exacto en un
// float64. Todo id bigint viaja como cadena decimal y usa [ID], que rechaza un número sin
// comillas: así un error falla en voz alta en lugar de corromper el id en silencio.
//
// [Decode] y [DecodeBytes] decodifican estricto: campos desconocidos, datos sobrantes tras el
// valor y tipos que no casan son errores.
package jsonx

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
)

// MaxSafeInt es el mayor entero que un float64 representa sin perder precisión junto a sus
// vecinos (2^53 − 1): lo que pasa de ahí, Godot lo corrompe sin avisar.
const MaxSafeInt int64 = 1<<53 - 1

// maxNumberLen acota la longitud de un número JSON antes de analizarlo: ninguno de los que valen
// se acerca y así un exponente desmesurado no cuesta nada.
const maxNumberLen = 64

// Int es un entero de las API que acepta también la forma con decimales nulos que escribe Godot
// (4.0, 4e0) y rechaza la que tiene parte fraccionaria (4.5), null, una cadena y lo que pasa de
// ±[MaxSafeInt].
type Int int64

// ID es un id bigint de las API: una cadena con su valor decimal, de 0 a 2^63 − 1, sin signo, sin
// espacios y sin ceros a la izquierda. Un número sin comillas es un error.
type ID int64

// ErrInt y ErrID son las causas de los errores de [Int] y de [ID] (errors.Is).
var (
	ErrInt = errors.New("se esperaba un número entero")
	ErrID  = errors.New("se esperaba un id: una cadena con un entero de 0 a 2^63 − 1")
)

// UnmarshalJSON lee un número JSON entero.
func (i *Int) UnmarshalJSON(b []byte) error {
	v, err := parseIntNumber(b)
	if err != nil {
		return err
	}
	*i = Int(v)
	return nil
}

// MarshalJSON escribe el entero sin decimales.
func (i Int) MarshalJSON() ([]byte, error) {
	if int64(i) > MaxSafeInt || int64(i) < -MaxSafeInt {
		return nil, fmt.Errorf("jsonx: %d no cabe exacto en un número JSON: %w", int64(i), ErrInt)
	}
	return strconv.AppendInt(nil, int64(i), 10), nil
}

// UnmarshalJSON lee una cadena con un id decimal.
func (id *ID) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || b[0] != '"' {
		return ErrID
	}
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return ErrID
	}
	v, err := ParseID(s)
	if err != nil {
		return err
	}
	*id = v
	return nil
}

// MarshalJSON escribe el id como cadena decimal.
func (id ID) MarshalJSON() ([]byte, error) {
	if id < 0 {
		return nil, fmt.Errorf("jsonx: id negativo %d: %w", int64(id), ErrID)
	}
	out := make([]byte, 0, 21)
	out = append(out, '"')
	out = strconv.AppendInt(out, int64(id), 10)
	return append(out, '"'), nil
}

// String devuelve el id en decimal, como viaja en el JSON y en las rutas.
func (id ID) String() string { return strconv.FormatInt(int64(id), 10) }

// ParseID lee un id decimal (el de una ruta como /v1/characters/{id} o el de un cuerpo): solo
// dígitos, sin signo ni ceros a la izquierda, de 0 a 2^63 − 1.
func ParseID(s string) (ID, error) {
	if len(s) == 0 || len(s) > 19 || (len(s) > 1 && s[0] == '0') {
		return 0, ErrID
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, ErrID
		}
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, ErrID
	}
	return ID(v), nil
}

// parseIntNumber analiza un número JSON exacto: parte entera, decimales y exponente, sin pasar por
// float64 (que redondearía 9007199254740993 a 9007199254740992).
func parseIntNumber(b []byte) (int64, error) {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || len(b) > maxNumberLen {
		return 0, ErrInt
	}
	s := b
	neg := false
	if s[0] == '-' {
		neg = true
		s = s[1:]
	}
	intEnd := 0
	for intEnd < len(s) && isDigit(s[intEnd]) {
		intEnd++
	}
	// Gramática de JSON: al menos un dígito y sin ceros a la izquierda (salvo el propio 0).
	if intEnd == 0 || (intEnd > 1 && s[0] == '0') {
		return 0, ErrInt
	}
	digits := append([]byte(nil), s[:intEnd]...)
	rest := s[intEnd:]
	exp := 0
	if len(rest) > 0 && rest[0] == '.' {
		fracEnd := 1
		for fracEnd < len(rest) && isDigit(rest[fracEnd]) {
			fracEnd++
		}
		if fracEnd == 1 {
			return 0, ErrInt
		}
		digits = append(digits, rest[1:fracEnd]...)
		exp -= fracEnd - 1
		rest = rest[fracEnd:]
	}
	if len(rest) > 0 && (rest[0] == 'e' || rest[0] == 'E') {
		rest = rest[1:]
		expNeg := false
		if len(rest) > 0 && (rest[0] == '+' || rest[0] == '-') {
			expNeg = rest[0] == '-'
			rest = rest[1:]
		}
		if len(rest) == 0 {
			return 0, ErrInt
		}
		e := 0
		for _, c := range rest {
			if !isDigit(c) {
				return 0, ErrInt
			}
			// Con maxNumberLen el exponente no pasa de 62 dígitos; se satura para no desbordar.
			if e < 1_000_000 {
				e = e*10 + int(c-'0')
			}
		}
		if expNeg {
			e = -e
		}
		exp += e
		rest = nil
	}
	if len(rest) != 0 {
		return 0, ErrInt
	}
	// Quita los ceros a la izquierda (de «0.5») y normaliza los de la derecha al exponente.
	for len(digits) > 1 && digits[0] == '0' {
		digits = digits[1:]
	}
	if len(digits) == 1 && digits[0] == '0' {
		return 0, nil
	}
	for len(digits) > 0 && digits[len(digits)-1] == '0' {
		digits = digits[:len(digits)-1]
		exp++
	}
	if exp < 0 {
		// Quedan cifras significativas detrás de la coma: 4.5, 0.1.
		return 0, ErrInt
	}
	if len(digits)+exp > 16 {
		return 0, ErrInt
	}
	var v int64
	for _, c := range digits {
		v = v*10 + int64(c-'0')
	}
	for ; exp > 0; exp-- {
		v *= 10
	}
	if v > MaxSafeInt {
		return 0, ErrInt
	}
	if neg {
		v = -v
	}
	return v, nil
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// Decode lee de r un único valor JSON en v, estricto: un campo desconocido, un tipo que no casa o
// algo detrás del valor (salvo espacios) son errores.
func Decode(r io.Reader, v any) error {
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return errors.New("jsonx: hay datos detrás del valor JSON")
		}
		return err
	}
	return nil
}

// DecodeBytes es [Decode] sobre un cuerpo ya leído.
func DecodeBytes(b []byte, v any) error {
	return Decode(bytes.NewReader(b), v)
}
