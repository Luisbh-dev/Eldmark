package passwords

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"
)

var fast = Params{MemoryKiB: 8, Time: 1, Threads: 1}

func TestHashAndVerify(t *testing.T) {
	phc, err := Hash("contraseña larga", fast)
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^\$argon2id\$v=19\$m=8,t=1,p=1\$[A-Za-z0-9+/]{22}\$[A-Za-z0-9+/]{43}$`).MatchString(phc) {
		t.Fatalf("cadena PHC: %s", phc)
	}
	ok, rehash, err := Verify("contraseña larga", phc, fast)
	if err != nil || !ok || rehash {
		t.Fatalf("la buena: %v %v %v", ok, rehash, err)
	}
	ok, _, err = Verify("contraseña larga ", phc, fast)
	if err != nil || ok {
		t.Fatalf("la mala: %v %v", ok, err)
	}
	// Not normalized: another Unicode form of the same letter is another password.
	if ok, _, _ := Verify("contraseña larga", phc, fast); ok {
		t.Fatal("la contraseña no se normaliza")
	}
	other, _ := Hash("contraseña larga", fast)
	if other == phc {
		t.Fatal("cada hash lleva su sal")
	}
}

// needsRehash: the string's parameters are not the current ones (platform.md §4.2).
func TestNeedsRehash(t *testing.T) {
	phc, _ := Hash("otra contraseña", fast)
	current := Params{MemoryKiB: 16, Time: 1, Threads: 1}
	ok, rehash, err := Verify("otra contraseña", phc, current)
	if err != nil || !ok || !rehash {
		t.Fatalf("con otros parámetros: %v %v %v", ok, rehash, err)
	}
	if p, err := ParamsOf(phc); err != nil || p != fast {
		t.Fatalf("ParamsOf: %v %v", p, err)
	}
}

func TestBadStrings(t *testing.T) {
	phc, _ := Hash("x", fast)
	parts := strings.Split(phc, "$")
	cases := map[string]string{
		"vacía":          "",
		"bcrypt":         "$2a$10$abcdefghijklmnopqrstuuabcdefghijklmnopqrstuvwxyz01234",
		"argon2i":        strings.Replace(phc, "argon2id", "argon2i", 1),
		"versión":        strings.Replace(phc, "v=19", "v=16", 1),
		"sin p":          strings.Replace(phc, ",p=1", "", 1),
		"memoria enorme": strings.Replace(phc, "m=8", "m=4194304", 1),
		"pasadas 0":      strings.Replace(phc, "t=1", "t=0", 1),
		"sal corta":      "$argon2id$v=19$m=8,t=1,p=1$c2FsdA$" + parts[5],
		"hash roto":      "$argon2id$v=19$m=8,t=1,p=1$" + parts[4] + "$***",
		"de más":         phc + "$x",
	}
	for name, s := range cases {
		if _, _, err := Verify("x", s, fast); !errors.Is(err, ErrFormat) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestFillerCostsTheSame(t *testing.T) {
	f, err := Filler(fast)
	if err != nil {
		t.Fatal(err)
	}
	if p, err := ParamsOf(f); err != nil || p != fast {
		t.Fatalf("relleno: %v %v", p, err)
	}
	if ok, _, _ := Verify("", f, fast); ok {
		t.Fatal("nadie conoce la contraseña del relleno")
	}
}

func TestContextCancelsTheWait(t *testing.T) {
	// It occupies all the slots and checks that a wait with a cancelled context does not hang.
	n := cap(slots)
	for i := 0; i < n; i++ {
		slots <- struct{}{}
	}
	defer func() {
		for i := 0; i < n; i++ {
			<-slots
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := HashContext(ctx, "x", fast); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("sin plaza: %v", err)
	}
}

// It measures the cost of the production parameters (platform.md §0: 59 ms on the probe machine).
// It only reports.
func TestProductionCost(t *testing.T) {
	if testing.Short() {
		t.Skip("-short")
	}
	prod := Params{MemoryKiB: 19456, Time: 2, Threads: 1}
	phc, err := Hash("medida", prod)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	const n = 5
	for i := 0; i < n; i++ {
		if ok, _, _ := Verify("medida", phc, prod); !ok {
			t.Fatal("la buena")
		}
	}
	t.Logf("argon2id %s: %.1f ms por comprobación", prod, float64(time.Since(start).Microseconds())/1000/n)
}
