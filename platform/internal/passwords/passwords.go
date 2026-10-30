// Package passwords calcula y comprueba los hashes de contraseña de las cuentas (plataforma.md §0
// y §4.2): argon2id en una cadena PHC
//
//	$argon2id$v=19$m=19456,t=2,p=1$<sal en base64 sin relleno>$<hash en base64 sin relleno>
//
// con sal de 16 B y hash de 32 B. La contraseña no se normaliza. Como mucho runtime.NumCPU()
// cálculos a la vez en todo el proceso (cada uno reserva m KiB de memoria): los demás esperan
// turno.
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

// Params son los parámetros de argon2id: memoria en KiB, pasadas e hilos.
type Params struct {
	MemoryKiB, Time uint32
	Threads         uint8
}

// String devuelve los parámetros como en la cadena PHC: m=19456,t=2,p=1.
func (p Params) String() string {
	return "m=" + strconv.FormatUint(uint64(p.MemoryKiB), 10) + ",t=" + strconv.FormatUint(uint64(p.Time), 10) +
		",p=" + strconv.FormatUint(uint64(p.Threads), 10)
}

// Tamaños de la sal y del hash que escribe Hash.
const (
	SaltLen = 16
	KeyLen  = 32
)

// Topes de lo que se acepta al leer una cadena PHC: una cadena dañada o maliciosa en la base no
// puede pedir gigas de memoria ni horas de cálculo.
const (
	maxMemoryKiB = 1 << 20 // 1 GiB
	maxTime      = 64
	minSaltLen   = 8
	maxSaltLen   = 64
	minKeyLen    = 16
	maxKeyLen    = 64
)

// ErrFormat es el error de una cadena PHC que no se entiende o que pide parámetros fuera de los
// topes.
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

// Hash calcula el hash de una contraseña con sal nueva de crypto/rand.
func Hash(password string, p Params) (string, error) {
	return HashContext(context.Background(), password, p)
}

// HashContext es [Hash] con un contexto para la espera de turno.
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

// Verify comprueba una contraseña contra su cadena PHC en tiempo constante. needsRehash dice que
// la cadena no usa los parámetros actuales (o el tamaño de sal y hash de Hash): el inicio de
// sesión la reescribe.
func Verify(password, phc string, current Params) (ok, needsRehash bool, err error) {
	return VerifyContext(context.Background(), password, phc, current)
}

// VerifyContext es [Verify] con un contexto para la espera de turno.
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

// ParamsOf devuelve los parámetros de una cadena PHC.
func ParamsOf(phc string) (Params, error) {
	p, _, _, err := parse(phc)
	return p, err
}

func parse(phc string) (Params, []byte, []byte, error) {
	parts := strings.Split(phc, "$")
	// "", "argon2id", "v=19", "m=…,t=…,p=…", sal, hash
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

// Filler devuelve una cadena PHC de relleno con los parámetros dados, de una contraseña
// aleatoria que nadie conoce. Comprobar contra ella cuesta lo mismo que contra una de verdad: así
// un correo inexistente o una cuenta sin contraseña tardan lo mismo que una cuenta real.
func Filler(p Params) (string, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	return Hash(base64.RawStdEncoding.EncodeToString(secret), p)
}
