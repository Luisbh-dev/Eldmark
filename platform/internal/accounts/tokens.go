package accounts

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	netmail "net/mail"
)

// TokenLen is the length of a token: 32 B from crypto/rand in unpadded base64url (§4.2).
const TokenLen = 43

// newToken returns a new token and its SHA-256, which is what gets stored.
func newToken() (string, []byte) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand does not fail on the supported systems; without randomness we do not continue.
		panic("accounts: crypto/rand: " + err.Error())
	}
	tok := base64.RawURLEncoding.EncodeToString(b[:])
	return tok, hashToken(tok)
}

func hashToken(tok string) []byte {
	sum := sha256.Sum256([]byte(tok))
	return sum[:]
}

// ValidToken says whether a string has the shape of a token: 43 base64url characters. The link
// pages check it before rendering anything.
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
	// The last letter carries only 4 bits of data: the other forms do not come out of newToken.
	_, err := base64.RawURLEncoding.Strict().DecodeString(tok)
	return err == nil
}

// parseAddress returns the address that net/mail understands, without a display name.
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
