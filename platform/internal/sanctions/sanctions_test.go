package sanctions

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestMinRole(t *testing.T) {
	day := 24 * time.Hour
	cases := []struct {
		kind string
		d    time.Duration
		want string
	}{
		{KindWarning, 0, RoleModerator},
		{KindMute, 7 * day, RoleModerator},
		{KindMute, 7*day + time.Minute, RoleAdmin},
		{KindSuspension, time.Hour, RoleGM},
		{KindSuspension, 8 * day, RoleAdmin},
		{KindRename, 0, RoleGM},
		{KindBan, 0, RoleAdmin},
		{"jail", 0, ""},
	}
	for _, c := range cases {
		if got := MinRole(c.kind, c.d); got != c.want {
			t.Errorf("%s %s: %q, se esperaba %q", c.kind, c.d, got, c.want)
		}
	}
	if !(Rank(RolePlayer) < Rank(RoleModerator) && Rank(RoleModerator) < Rank(RoleGM) && Rank(RoleGM) < Rank(RoleAdmin)) ||
		Rank("root") != -1 {
		t.Fatal("rangos")
	}
}

func TestMessages(t *testing.T) {
	until := time.Date(2026, 11, 3, 18, 0, 0, 0, time.UTC)
	r := &Restriction{Kind: KindSuspension, Until: &until, Reason: "insultos"}
	if got := r.Message(); got != "Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC: insultos" {
		t.Fatal(got)
	}
	if got := (&Restriction{Kind: KindBan, Reason: "bots"}).Message(); got != "Tu cuenta está expulsada: bots" {
		t.Fatal(got)
	}
	if got := (&Restriction{Kind: KindSuspension}).Message(); got != "Tu cuenta está suspendida" {
		t.Fatal(got)
	}
	long := &Restriction{Kind: KindBan, Reason: strings.Repeat("ñ", 300)}
	if msg := long.Message(); len(msg) > MaxTextBytes || !utf8.ValidString(msg) || len(msg) < MaxTextBytes-1 {
		t.Fatalf("cortado a 255 B sin partir un carácter: %d", len(msg))
	}
	if got := PendingDeletionMessage(&until); got != "Tu cuenta se borrará el 3/11/2026 18:00 UTC" {
		t.Fatal(got)
	}
	if Truncate("abc", 5) != "abc" || Truncate("áé", 3) != "á" {
		t.Fatal("Truncate")
	}
}

func TestWarningTextAndTimed(t *testing.T) {
	if got := (Warning{Reason: "spam"}).Text(); got != "Has recibido un aviso de la moderación: spam" {
		t.Fatal(got)
	}
	if got := (Warning{}).Text(); got != "Has recibido un aviso de la moderación" {
		t.Fatal(got)
	}
	if msg := (Warning{Reason: strings.Repeat("é", 200)}).Text(); len(msg) > MaxTextBytes || !utf8.ValidString(msg) {
		t.Fatalf("cortado a 255 B: %d", len(msg))
	}
	for kind, want := range map[string]bool{KindMute: true, KindSuspension: true, KindWarning: false, KindBan: false,
		KindRename: false} {
		if Timed(kind) != want {
			t.Errorf("Timed(%s)", kind)
		}
	}
	if len(Roles) != 4 || Roles[0] != RolePlayer || Roles[3] != RoleAdmin {
		t.Fatal(Roles)
	}
}
