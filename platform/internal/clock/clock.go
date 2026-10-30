// Package clock da el reloj inyectable de la plataforma (plataforma.md §15: «el reloj de Go es
// inyectable»). El código de la plataforma pide la hora a un [Clock] y la pasa a las sentencias
// como parámetro en lugar de usar now() de PostgreSQL donde un plazo importa (enlaces, sesiones,
// purgas): así las pruebas adelantan el reloj sin esperar.
package clock

import (
	"sync"
	"time"
)

// Clock da la hora.
type Clock interface {
	Now() time.Time
}

// System es el reloj del sistema, en UTC.
type System struct{}

// Now devuelve la hora del sistema en UTC.
func (System) Now() time.Time { return time.Now().UTC() }

// Fake es un reloj de pruebas que solo avanza cuando se le dice. Es seguro entre gorrutinas.
type Fake struct {
	mu sync.Mutex
	t  time.Time
}

// NewFake devuelve un reloj parado en t.
func NewFake(t time.Time) *Fake { return &Fake{t: t.UTC()} }

// Now devuelve la hora del reloj.
func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

// Advance adelanta el reloj d.
func (f *Fake) Advance(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

// Set pone el reloj en t.
func (f *Fake) Set(t time.Time) {
	f.mu.Lock()
	f.t = t.UTC()
	f.mu.Unlock()
}
