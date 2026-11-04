// Package clock provides the platform's injectable clock (plataforma.md §15: "Go's clock is
// injectable"). The platform code asks a [Clock] for the time and passes it to statements as a
// parameter instead of using PostgreSQL's now() where a deadline matters (links, sessions, purges):
// that way the tests move the clock forward without waiting.
package clock

import (
	"sync"
	"time"
)

// Clock provides the time.
type Clock interface {
	Now() time.Time
}

// System is the system clock, in UTC.
type System struct{}

// Now returns the system time in UTC.
func (System) Now() time.Time { return time.Now().UTC() }

// Fake is a test clock that only advances when told to. It is safe across goroutines.
type Fake struct {
	mu sync.Mutex
	t  time.Time
}

// NewFake returns a clock stopped at t.
func NewFake(t time.Time) *Fake { return &Fake{t: t.UTC()} }

// Now returns the clock's time.
func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

// Advance moves the clock forward by d.
func (f *Fake) Advance(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

// Set sets the clock to t.
func (f *Fake) Set(t time.Time) {
	f.mu.Lock()
	f.t = t.UTC()
	f.mu.Unlock()
}
