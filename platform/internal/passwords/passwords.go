// Package passwords computes and checks the accounts' password hashes (plataforma.md §0 and §4.2):
// argon2id in a PHC string
//
//	$argon2id$v=19$m=19456,t=2,p=1$<salt in unpadded base64>$<hash in unpadded base64>
//
// with a 16 B salt and a 32 B hash. The password is not normalized. At most runtime.NumCPU()
// computations at once across the whole process (each one reserves m KiB of memory): the others
// wait their turn.
package passwords

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Params are the argon2id parameters: memory in KiB, passes and threads.
type Params struct {
	MemoryKiB, Time uint32
	Threads         uint8
}

// String returns the parameters as in the PHC string: m=19456,t=2,p=1.
func (p Params) String() string {
	return "m=" + strconv.FormatUint(uint64(p.MemoryKiB), 10) + ",t=" + strconv.FormatUint(uint64(p.Time), 10) +
		",p=" + strconv.FormatUint(uint64(p.Threads), 10)
}

// Sizes of the salt and the hash that Hash writes.
const (
	SaltLen = 16
	KeyLen  = 32
)

// Caps on what is accepted when reading a PHC string: a corrupted or malicious string in the
// database cannot ask for gigabytes of memory or hours of computation.
const (
	maxMemoryKiB = 1 << 20 // 1 GiB
	maxTime      = 64
	minSaltLen   = 8
	maxSaltLen   = 64
	minKeyLen    = 16
	maxKeyLen    = 64
)

// ErrFormat is the error of a PHC string that is not understood or that asks for parameters outside
// the caps.
var ErrFormat = errors.New("passwords: la cadena PHC no es un argon2id válido")

var slots = make(chan struct{}, max(1, runtime.NumCPU()))

func acquire(ctx context.Context) error {
	select {
	case slots <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func release() { <-slots }

func (p Params) valid() bool {
	return p.Time >= 1 && p.Time <= maxTime && p.Threads >= 1 && p.MemoryKiB >= 8*uint32(p.Threads) &&
		p.MemoryKiB <= maxMemoryKiB
}

// Hash computes a password's hash with a fresh crypto/rand salt.
func Hash(password string, p Params) (string, error) {
	return HashContext(context.Background(), password, p)
}

// HashContext is [Hash] with a context for the wait for a turn.
func HashContext(ctx context.Context, password string, p Params) (string, error) {
	if !p.valid() {
		return "", fmt.Errorf("passwords: parámetros no válidos %s", p)
	}
	salt := make([]byte, SaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	if err := acquire(ctx); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, p.Time, p.MemoryKiB, p.Threads, KeyLen)
	release()
	enc := base64.RawStdEncoding
	return "$argon2id$v=19$" + p.String() + "$" + enc.EncodeToString(salt) + "$" + enc.EncodeToString(key), nil
}

// Verify checks a password against its PHC string in constant time. needsRehash says that the
// string does not use the current parameters (or Hash's salt and hash size): login rewrites it.
func Verify(password, phc string, current Params) (ok, needsRehash bool, err error) {
	return VerifyContext(context.Background(), password, phc, current)
}

// VerifyContext is [Verify] with a context for the wait for a turn.
func VerifyContext(ctx context.Context, password, phc string, current Params) (ok, needsRehash bool, err error) {
	p, salt, want, err := parse(phc)
	if err != nil {
		return false, false, err
	}
	if err := acquire(ctx); err != nil {
		return false, false, err
	}
	got := argon2.IDKey([]byte(password), salt, p.Time, p.MemoryKiB, p.Threads, uint32(len(want)))
	release()
	ok = subtle.ConstantTimeCompare(got, want) == 1
	needsRehash = p != current || len(salt) != SaltLen || len(want) != KeyLen
	return ok, needsRehash, nil
}

// ParamsOf returns a PHC string's parameters.
func ParamsOf(phc string) (Params, error) {
	p, _, _, err := parse(phc)
	return p, err
}

func parse(phc string) (Params, []byte, []byte, error) {
	parts := strings.Split(phc, "$")
	// "", "argon2id", "v=19", "m=...,t=...,p=...", salt, hash
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" || parts[2] != "v=19" {
		return Params{}, nil, nil, ErrFormat
	}
	var p Params
	seen := 0
	for _, kv := range strings.Split(parts[3], ",") {
		k, v, found := strings.Cut(kv, "=")
		n, err := strconv.ParseUint(v, 10, 32)
		if !found || err != nil {
			return Params{}, nil, nil, ErrFormat
		}
		switch k {
		case "m":
			p.MemoryKiB = uint32(n)
			seen |= 1
		case "t":
			p.Time = uint32(n)
			seen |= 2
		case "p":
			if n > 255 {
				return Params{}, nil, nil, ErrFormat
			}
			p.Threads = uint8(n)
			seen |= 4
		default:
			return Params{}, nil, nil, ErrFormat
		}
	}
	if seen != 7 || !p.valid() {
		return Params{}, nil, nil, ErrFormat
	}
	enc := base64.RawStdEncoding
	salt, err := enc.DecodeString(parts[4])
	if err != nil || len(salt) < minSaltLen || len(salt) > maxSaltLen {
		return Params{}, nil, nil, ErrFormat
	}
	key, err := enc.DecodeString(parts[5])
	if err != nil || len(key) < minKeyLen || len(key) > maxKeyLen {
		return Params{}, nil, nil, ErrFormat
	}
	return p, salt, key, nil
}

// Filler returns a filler PHC string with the given parameters, of a random password that nobody
// knows. Checking against it costs the same as against a real one: that way a nonexistent email or
// an account without a password takes the same as a real account.
func Filler(p Params) (string, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	return Hash(base64.RawStdEncoding.EncodeToString(secret), p)
}
