package clock

import (
	"testing"
	"time"
)

func TestFake(t *testing.T) {
	t0 := time.Date(2026, 11, 1, 12, 0, 0, 0, time.FixedZone("CET", 3600))
	f := NewFake(t0)
	if !f.Now().Equal(t0) || f.Now().Location() != time.UTC {
		t.Fatalf("in UTC: %s", f.Now())
	}
	f.Advance(90 * time.Second)
	if got := f.Now().Sub(t0); got != 90*time.Second {
		t.Fatal(got)
	}
	f.Set(t0)
	if !f.Now().Equal(t0) {
		t.Fatal(f.Now())
	}
	if (System{}).Now().Location() != time.UTC {
		t.Fatal("the system one, in UTC")
	}
}
