// Package jsonx reads and writes the integers and ids of the two APIs' JSON (platform.md §4.1).
//
// Godot reads every JSON number as a float and, when re-serializing what it read, writes 820.0:
// that is why an integer field uses [Int], which accepts 4 and 4.0 and rejects 4.5 and anything that
// does not fit exactly in a float64. Every bigint id travels as a decimal string and uses [ID],
// which rejects an unquoted number: that way an error fails loudly instead of silently corrupting
// the id.
//
// [Decode] and [DecodeBytes] decode strictly: unknown fields, leftover data after the value and
// mismatched types are errors.
package jsonx

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
)

// MaxSafeInt is the largest integer that a float64 represents without losing precision relative to
// its neighbors (2^53 - 1): anything beyond that, Godot corrupts without warning.
const MaxSafeInt int64 = 1<<53 - 1

// maxNumberLen bounds the length of a JSON number before parsing it: none of the valid ones comes
// close, so an oversized exponent costs nothing.
const maxNumberLen = 64

// Int is an integer of the APIs that also accepts the form with null decimals that Godot writes
// (4.0, 4e0) and rejects the one with a fractional part (4.5), null, a string and anything beyond
// +/-[MaxSafeInt].
type Int int64

// ID is a bigint id of the APIs: a string with its decimal value, from 0 to 2^63 - 1, without sign,
// without spaces and without leading zeros. An unquoted number is an error.
type ID int64

// ErrInt and ErrID are the causes of the errors of [Int] and [ID] (errors.Is).
var (
	ErrInt = errors.New("se esperaba un número entero")
	ErrID  = errors.New("se esperaba un id: una cadena con un entero de 0 a 2^63 − 1")
)

// UnmarshalJSON reads an integer JSON number.
func (i *Int) UnmarshalJSON(b []byte) error {
	v, err := parseIntNumber(b)
	if err != nil {
		return err
	}
	*i = Int(v)
	return nil
}

// MarshalJSON writes the integer without decimals.
func (i Int) MarshalJSON() ([]byte, error) {
	if int64(i) > MaxSafeInt || int64(i) < -MaxSafeInt {
		return nil, fmt.Errorf("jsonx: %d no cabe exacto en un número JSON: %w", int64(i), ErrInt)
	}
	return strconv.AppendInt(nil, int64(i), 10), nil
}

// UnmarshalJSON reads a string with a decimal id.
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

// MarshalJSON writes the id as a decimal string.
func (id ID) MarshalJSON() ([]byte, error) {
	if id < 0 {
		return nil, fmt.Errorf("jsonx: id negativo %d: %w", int64(id), ErrID)
	}
	out := make([]byte, 0, 21)
	out = append(out, '"')
	out = strconv.AppendInt(out, int64(id), 10)
	return append(out, '"'), nil
}

// String returns the id in decimal, as it travels in the JSON and in routes.
func (id ID) String() string { return strconv.FormatInt(int64(id), 10) }

// ParseID reads a decimal id (from a route like /v1/characters/{id} or from a body): digits only,
// without sign or leading zeros, from 0 to 2^63 - 1.
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

// parseIntNumber parses an exact JSON number: integer part, decimals and exponent, without going
// through float64 (which would round 9007199254740993 to 9007199254740992).
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
	// JSON grammar: at least one digit and no leading zeros (except 0 itself).
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
			// With maxNumberLen the exponent does not exceed 62 digits; it saturates so as not to overflow.
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
	// Strip the leading zeros (from "0.5") and normalize the trailing ones into the exponent.
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
		// Significant digits remain after the decimal point: 4.5, 0.1.
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

// Decode reads a single JSON value from r into v, strictly: an unknown field, a mismatched type or
// anything after the value (except whitespace) are errors.
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

// DecodeBytes is [Decode] over a body that has already been read.
func DecodeBytes(b []byte, v any) error {
	return Decode(bytes.NewReader(b), v)
}
