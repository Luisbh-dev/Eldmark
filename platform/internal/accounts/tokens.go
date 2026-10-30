package accounts

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	netmail "net/mail"
)

// TokenLen es la longitud de un token: 32 B de crypto/rand en base64url sin relleno (§4.2).
const TokenLen = 43

// newToken devuelve un token nuevo y su SHA-256, que es lo que se guarda.
func newToken() (string, []byte) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand no falla en los sistemas admitidos; sin aleatoriedad no se sigue.
		panic("accounts: crypto/rand: " + err.Error())
	}
	tok := base64.RawURLEncoding.EncodeToString(b[:])
	return tok, hashToken(tok)
}

func hashToken(tok string) []byte {
	sum := sha256.Sum256([]byte(tok))
	return sum[:]
}

// ValidToken dice si una cadena tiene la forma de un token: 43 caracteres base64url. Las páginas
// de los enlaces lo miran antes de pintar nada.
func ValidToken(tok string) bool {
	if len(tok) != TokenLen {
		return false
	}
	for i := 0; i < len(tok); i++ {
		c := tok[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	// La última letra solo lleva 4 bits de datos: las demás formas no salen de newToken.
	_, err := base64.RawURLEncoding.Strict().DecodeString(tok)
	return err == nil
}

// parseAddress devuelve la dirección que entiende net/mail, sin nombre visible.
func parseAddress(s string) (string, error) {
	a, err := netmail.ParseAddress(s)
	if err != nil {
		return "", err
	}
	if a.Name != "" {
		return "", errors.New("accounts: el correo lleva nombre visible")
	}
	return a.Address, nil
}
