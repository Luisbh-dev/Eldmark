package ratelimit

import (
	"testing"
	"time"
)

var t0 = time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)

func TestLRUForgetsTheOldest(t *testing.T) {
	l := NewLRU[string, int](2)
	l.Put("a", 1)
	l.Put("b", 2)
	if v, ok := l.Get("a"); !ok || v != 1 {
		t.Fatal("a")
	}
	l.Put("c", 3) // forgets b, which is the least recent
	if _, ok := l.Get("b"); ok {
		t.Fatal("b tenía que olvidarse")
	}
	if _, ok := l.Get("a"); !ok || l.Len() != 2 {
		t.Fatal("a sigue")
	}
	l.Delete("a")
	if _, ok := l.Get("a"); ok || l.Len() != 1 {
		t.Fatal("Delete")
	}
}

// 10 per minute with burst 10 (login by IP, platform.md §4.2): the 11th waits.
func TestBucket(t *testing.T) {
	l := New(10, time.Minute, 10, 100)
	for i := 0; i < 10; i++ {
		if ok, _ := l.Allow("ip", t0); !ok {
			t.Fatalf("intento %d", i+1)
		}
	}
	ok, wait := l.Allow("ip", t0)
	if ok || wait != 6*time.Second {
		t.Fatalf("el 11.º: %v %s", ok, wait)
	}
	if ok, _ := l.Allow("otra", t0); !ok {
		t.Fatal("cada clave tiene su cubo")
	}
	if ok, _ := l.Allow("ip", t0.Add(6*time.Second)); !ok {
		t.Fatal("a los 6 s hay otra ficha")
	}
	if ok, _ := l.Allow("ip", t0.Add(6*time.Second)); ok {
		t.Fatal("y solo una")
	}
}

// 3 per hour (registration by IP): the fourth, after 20 min.
func TestSlowBucket(t *testing.T) {
	l := New(3, time.Hour, 3, 100)
	for i := 0; i < 3; i++ {
		l.Allow("ip", t0)
	}
	if ok, wait := l.Allow("ip", t0); ok || wait != 20*time.Minute {
		t.Fatalf("el cuarto: %v %s", ok, wait)
	}
	if RetryAfterSeconds(20*time.Minute) != 1200 || RetryAfterSeconds(1) != 1 || RetryAfterSeconds(0) != 1 {
		t.Fatal("RetryAfterSeconds")
	}
}

func TestAllowAllIsAllOrNothing(t *testing.T) {
	perAccount := New(3, time.Hour, 3, 100)
	perIP := New(10, time.Hour, 10, 100)
	for i := 0; i < 3; i++ {
		if ok, _ := AllowAll(t0, Key{perAccount, "a"}, Key{perIP, "ip"}); !ok {
			t.Fatal(i)
		}
	}
	if ok, _ := AllowAll(t0, Key{perAccount, "a"}, Key{perIP, "ip"}); ok {
		t.Fatal("la cuenta ya no tiene")
	}
	// The IP did not spend a token on the rejected attempt: it has 7 left.
	for i := 0; i < 7; i++ {
		if ok, _ := AllowAll(t0, Key{perAccount, string(rune('b' + i))}, Key{perIP, "ip"}); !ok {
			t.Fatalf("la IP tenía 7 fichas; falla en la %d", i+1)
		}
	}
	if ok, _ := AllowAll(t0, Key{perAccount, "z"}, Key{perIP, "ip"}); ok {
		t.Fatal("la IP ya no tiene")
	}
}
