// Package logx sets up the platform's log (platform.md §2.3): log/slog with a JSONHandler to
// standard output, with the fields time, level, msg, req, route, status, ms and, when known,
// account and character.
//
// Passwords, tokens, tickets, bodies and chat text are never logged; the email goes masked with
// [MaskEmail].
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

// New returns a JSON logger over w with the given level.
func New(w io.Writer, level slog.Leveler) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level}))
}

// Discard returns a logger that writes nothing (tests).
func Discard() *slog.Logger {
	return slog.New(slog.DiscardHandler)
}

// MaskEmail masks an email for the log: "aneira@example.org" -> "a***@example.org". Without an at
// sign it returns "***": it never writes a whole email.
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
		// A non-ASCII first character is not cut in half.
		first = ""
	}
	return first + "***" + email[at:]
}

// NewRequestID returns a random request id (16 hexadecimal characters), the one that goes in the
// log's req field and in the X-Request-Id header.
func NewRequestID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Request is the data of a request that the log writes when it finishes. The handlers fill in
// Account and Character when they know them, with [SetAccount] and [SetCharacter].
type Request struct {
	ID string

	mu        sync.Mutex
	account   int64
	character int64
}

type requestKey struct{}

// WithRequest stores the request's data in the context.
func WithRequest(ctx context.Context, r *Request) context.Context {
	return context.WithValue(ctx, requestKey{}, r)
}

// RequestFrom returns the request's data from the context, or nil.
func RequestFrom(ctx context.Context) *Request {
	r, _ := ctx.Value(requestKey{}).(*Request)
	return r
}

// RequestID returns the request's id from the context, or "".
func RequestID(ctx context.Context) string {
	if r := RequestFrom(ctx); r != nil {
		return r.ID
	}
	return ""
}

// SetAccount records the request's account for its log line.
func SetAccount(ctx context.Context, accountID int64) {
	if r := RequestFrom(ctx); r != nil {
		r.mu.Lock()
		r.account = accountID
		r.mu.Unlock()
	}
}

// SetCharacter records the request's character for its log line.
func SetCharacter(ctx context.Context, characterID int64) {
	if r := RequestFrom(ctx); r != nil {
		r.mu.Lock()
		r.character = characterID
		r.mu.Unlock()
	}
}

// Attrs returns req and, if known, account and character.
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
