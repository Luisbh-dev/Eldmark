// Package logx monta el registro de la plataforma (plataforma.md §2.3): log/slog con JSONHandler a
// la salida estándar, con los campos time, level, msg, req, route, status, ms y, cuando se
// conocen, account y character.
//
// Nunca se registran contraseñas, tokens, billetes, cuerpos ni texto del chat; el correo va
// enmascarado con [MaskEmail].
package logx

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"log/slog"
	"strings"
	"sync"
)

// New devuelve un registro JSON sobre w con el nivel dado.
func New(w io.Writer, level slog.Leveler) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level}))
}

// Discard devuelve un registro que no escribe nada (pruebas).
func Discard() *slog.Logger {
	return slog.New(slog.DiscardHandler)
}

// MaskEmail enmascara un correo para el registro: «aneira@example.org» → «a***@example.org». Sin
// arroba devuelve «***»: nunca escribe un correo entero.
func MaskEmail(email string) string {
	if email == "" {
		return ""
	}
	at := strings.LastIndexByte(email, '@')
	if at <= 0 || at == len(email)-1 {
		return "***"
	}
	first := email[:1]
	if first[0] >= 0x80 {
		// Un primer carácter no ASCII no se corta a medias.
		first = ""
	}
	return first + "***" + email[at:]
}

// NewRequestID devuelve un id de petición aleatorio (16 caracteres hexadecimales), el que va en
// el campo req del registro y en la cabecera X-Request-Id.
func NewRequestID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Request son los datos de una petición que el registro escribe al terminarla. Los manejadores
// rellenan Account y Character cuando los conocen, con [SetAccount] y [SetCharacter].
type Request struct {
	ID string

	mu        sync.Mutex
	account   int64
	character int64
}

type requestKey struct{}

// WithRequest guarda en el contexto los datos de la petición.
func WithRequest(ctx context.Context, r *Request) context.Context {
	return context.WithValue(ctx, requestKey{}, r)
}

// RequestFrom devuelve los datos de la petición del contexto, o nil.
func RequestFrom(ctx context.Context) *Request {
	r, _ := ctx.Value(requestKey{}).(*Request)
	return r
}

// RequestID devuelve el id de la petición del contexto, o "".
func RequestID(ctx context.Context) string {
	if r := RequestFrom(ctx); r != nil {
		return r.ID
	}
	return ""
}

// SetAccount anota la cuenta de la petición para su línea del registro.
func SetAccount(ctx context.Context, accountID int64) {
	if r := RequestFrom(ctx); r != nil {
		r.mu.Lock()
		r.account = accountID
		r.mu.Unlock()
	}
}

// SetCharacter anota el personaje de la petición para su línea del registro.
func SetCharacter(ctx context.Context, characterID int64) {
	if r := RequestFrom(ctx); r != nil {
		r.mu.Lock()
		r.character = characterID
		r.mu.Unlock()
	}
}

// Attrs devuelve req y, si se conocen, account y character.
func (r *Request) Attrs() []slog.Attr {
	r.mu.Lock()
	defer r.mu.Unlock()
	attrs := []slog.Attr{slog.String("req", r.ID)}
	if r.account != 0 {
		attrs = append(attrs, slog.Int64("account", r.account))
	}
	if r.character != 0 {
		attrs = append(attrs, slog.Int64("character", r.character))
	}
	return attrs
}
