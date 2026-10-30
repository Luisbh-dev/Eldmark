// Package ratelimit da los límites de ritmo en memoria de la plataforma (plataforma.md §4.2): un
// cubo de fichas por clave y un LRU que acota cuántas claves se recuerdan. En la fase 5 hay una
// sola instancia de la plataforma, así que vale la memoria; reiniciar la plataforma reinicia los
// contadores (§16).
package ratelimit

import (
	"container/list"
	"math"
	"sync"
	"time"
)

// LRU es un mapa con capacidad fija que olvida la clave usada hace más tiempo. No es seguro entre
// gorrutinas: quien lo usa lo protege.
type LRU[K comparable, V any] struct {
	capacity int
	order    *list.List // frente: lo más reciente
	items    map[K]*list.Element
}

type entry[K comparable, V any] struct {
	key   K
	value V
}

// NewLRU devuelve un LRU con la capacidad dada (al menos 1).
func NewLRU[K comparable, V any](capacity int) *LRU[K, V] {
	return &LRU[K, V]{capacity: max(1, capacity), order: list.New(), items: map[K]*list.Element{}}
}

// Get devuelve el valor de la clave y la marca como reciente.
func (l *LRU[K, V]) Get(key K) (V, bool) {
	if el, ok := l.items[key]; ok {
		l.order.MoveToFront(el)
		return el.Value.(*entry[K, V]).value, true
	}
	var zero V
	return zero, false
}

// Put guarda el valor de la clave; si no cabe, olvida la menos reciente.
func (l *LRU[K, V]) Put(key K, value V) {
	if el, ok := l.items[key]; ok {
		el.Value.(*entry[K, V]).value = value
		l.order.MoveToFront(el)
		return
	}
	l.items[key] = l.order.PushFront(&entry[K, V]{key: key, value: value})
	for l.order.Len() > l.capacity {
		oldest := l.order.Back()
		l.order.Remove(oldest)
		delete(l.items, oldest.Value.(*entry[K, V]).key)
	}
}

// Delete olvida la clave.
func (l *LRU[K, V]) Delete(key K) {
	if el, ok := l.items[key]; ok {
		l.order.Remove(el)
		delete(l.items, key)
	}
}

// Len devuelve cuántas claves recuerda.
func (l *LRU[K, V]) Len() int { return l.order.Len() }

// DefaultCapacity es cuántas claves recuerda cada límite (plataforma.md §4.2: LRU de 100 000).
const DefaultCapacity = 100_000

// Limiter es un cubo de fichas por clave: cada clave tiene hasta Burst fichas, que se rellenan a
// razón de Rate por segundo; cada intento gasta una. Es seguro entre gorrutinas.
type Limiter struct {
	mu      sync.Mutex
	rate    float64 // fichas por segundo
	burst   float64
	buckets *LRU[string, *bucket]
}

type bucket struct {
	tokens float64
	last   time.Time
}

// New devuelve un límite de n intentos cada per, con ráfaga burst (como mucho capacity claves).
func New(n int, per time.Duration, burst, capacity int) *Limiter {
	return &Limiter{rate: float64(n) / per.Seconds(), burst: float64(burst), buckets: NewLRU[string, *bucket](capacity)}
}

func (l *Limiter) fill(key string, now time.Time) *bucket {
	b, ok := l.buckets.Get(key)
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets.Put(key, b)
		return b
	}
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens = math.Min(l.burst, b.tokens+elapsed*l.rate)
		b.last = now
	}
	return b
}

// wait es lo que falta para tener una ficha entera.
func (l *Limiter) wait(b *bucket) time.Duration {
	if b.tokens >= 1 {
		return 0
	}
	return time.Duration(math.Ceil((1 - b.tokens) / l.rate * float64(time.Second)))
}

// Check dice cuánto falta para poder intentarlo con esa clave (0: ya), sin gastar ficha.
func (l *Limiter) Check(key string, now time.Time) time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.wait(l.fill(key, now))
}

// Take gasta una ficha de la clave (aunque no quede ninguna entera: quien llama ya miró Check).
func (l *Limiter) Take(key string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.fill(key, now)
	b.tokens = math.Max(b.tokens-1, -l.burst)
}

// Allow gasta una ficha si la hay. Si no, devuelve false y cuánto falta.
func (l *Limiter) Allow(key string, now time.Time) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.fill(key, now)
	if w := l.wait(b); w > 0 {
		return false, w
	}
	b.tokens--
	return true, 0
}

// Key es una clave de un límite.
type Key struct {
	Limiter *Limiter
	Key     string
}

// AllowAll gasta una ficha de cada clave solo si todas tienen; si no, no gasta ninguna y devuelve
// la mayor espera.
func AllowAll(now time.Time, keys ...Key) (bool, time.Duration) {
	var wait time.Duration
	for _, k := range keys {
		wait = max(wait, k.Limiter.Check(k.Key, now))
	}
	if wait > 0 {
		return false, wait
	}
	for _, k := range keys {
		k.Limiter.Take(k.Key, now)
	}
	return true, 0
}

// RetryAfterSeconds redondea una espera hacia arriba a segundos enteros (al menos 1), para
// retry_after_s y Retry-After.
func RetryAfterSeconds(d time.Duration) int {
	if d <= 0 {
		return 1
	}
	return int(math.Ceil(d.Seconds()))
}
