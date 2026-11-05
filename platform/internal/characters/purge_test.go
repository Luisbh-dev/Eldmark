package characters_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// The hourly purge leaves as a tombstone the character whose restore window expired (§11.2):
// without a name, with purged_at and its purge_log row, without progression, stats or tickets; the
// name stays reserved for as long as it should.
func TestPurgeExpiredLeavesATombstone(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Brenna", "vardheim")
	keep := h.mustCreate(p, "Aneira", "vardheim")
	zone := h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")
	h.expect(h.enter(p, id), http.StatusOK, "")
	h.advance(2*day, p)
	h.expect(h.remove(p, id, "Brenna"), http.StatusOK, "")
	purger := h.svc.Purger()
	ctx := context.Background()

	// Within the window, it is not purged.
	if err := purger.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	if h.count(`select count(*) from characters where purged_at is not null`) != 0 {
		t.Fatal("purged within the window")
	}
	// Expired, but with a live lease (deletion does not allow it, but the purge checks it).
	h.clock.Advance(7*day + time.Second)
	h.lease(id, zone, h.clock.Now().Add(20*time.Second))
	if err := purger.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	if h.count(`select count(*) from characters where purged_at is not null`) != 0 ||
		!strings.Contains(h.logs.String(), "personaje sin purgar") {
		t.Fatal("purged with a live lease")
	}
	h.clock.Advance(21 * time.Second)
	if err := purger.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	purgedAt := h.clock.Now()
	var name, key *string
	var at time.Time
	h.scalar(&name, `select name from characters where character_id = $1`, id)
	h.scalar(&key, `select name_key from characters where character_id = $1`, id)
	h.scalar(&at, `select purged_at from characters where character_id = $1`, id)
	if name != nil || key != nil || !at.Equal(purgedAt) {
		t.Fatalf("tombstone: %v %v %v", name, key, at)
	}
	if h.count(`select count(*) from purge_log where kind = 'character' and id = $1 and purged_at = $2`, id, purgedAt) != 1 ||
		h.count(`select count(*) from character_pvp_stats where character_id = $1`, id) != 0 ||
		h.count(`select count(*) from character_leases where character_id = $1`, id) != 0 ||
		h.count(`select count(*) from enter_tickets where character_id = $1`, id) != 0 {
		t.Fatal("the purge leaves rows behind")
	}
	if h.progress.Has(id) || !h.progress.Has(keep) {
		t.Fatal("ProgressStore.Purge of one that should not be touched")
	}
	// The name stays reserved (until restore_until + 30 days), now without a character.
	if h.count(`select count(*) from character_names where name_key = 'brenna' and status = 'reserved'
		and character_id is null and reserved_until > $1`, h.clock.Now()) != 1 {
		t.Fatal("the name is no longer reserved")
	}
	// It neither appears in the list nor can be restored; the other one stays intact.
	h.login(p)
	l := h.list(p)
	if l.body["used"] != 1.0 {
		t.Errorf("list after the purge: %s", l.raw)
	}
	h.expect(h.restore(p, id), http.StatusNotFound, "not_found")
	if h.count(`select count(*) from characters where character_id = $1 and name = 'Aneira' and purged_at is null`, keep) != 1 {
		t.Error("the other character should not change")
	}
	// Another round does nothing more.
	if err := purger.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	if h.count(`select count(*) from purge_log`) != 1 {
		t.Error("repeated purge")
	}
}

// A restoration right before the purge wins: the purge checks again with the row locked.
func TestRestoredCharacterIsNotPurged(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	id := h.mustCreate(p, "Brenna", "vardheim")
	h.expect(h.remove(p, id, "Brenna"), http.StatusOK, "")
	h.advance(7*day-time.Second, p)
	h.expect(h.restore(p, id), http.StatusOK, "")
	h.clock.Advance(2 * time.Second)
	if err := h.svc.Purger().PurgeExpired(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.count(`select count(*) from characters where purged_at is null and deleted_at is null and character_id = $1`, id) != 1 {
		t.Fatal("a restored character was purged")
	}
}

// An account's purge (P1) leaves all its characters as tombstones, the living ones too, whose names
// stay reserved 30 days; with a character in the world it purges nothing.
func TestAccountPurgeWithCharacters(t *testing.T) {
	h := newHarness(t)
	p := h.newPlayer("ana@example.org")
	alive := h.mustCreate(p, "Aneira", "vardheim")
	deleted := h.mustCreate(p, "Brenna", "vardheim")
	h.advance(2*day, p)
	h.expect(h.remove(p, deleted, "Brenna"), http.StatusOK, "")
	zone := h.zone("vado_gris", 0, []int16{1, 2}, 0, 64, "live")
	h.expect(h.do(call{method: "POST", path: "/v1/account/deletion", token: p.token, body: map[string]any{"password": password}}),
		http.StatusAccepted, "")
	h.clock.Advance(14*day + time.Second)
	h.lease(alive, zone, h.clock.Now().Add(20*time.Second))
	ctx := context.Background()
	if err := h.accounts.PurgeDue(ctx); err != nil {
		t.Fatal(err)
	}
	if h.count(`select count(*) from accounts where account_id = $1 and status = 'pending_deletion'`, p.id) != 1 ||
		h.count(`select count(*) from characters where purged_at is not null`) != 0 ||
		!strings.Contains(h.logs.String(), "un personaje está en el mundo") {
		t.Fatal("with a character in the world nothing is purged")
	}
	h.clock.Advance(21 * time.Second)
	if err := h.accounts.PurgeDue(ctx); err != nil {
		t.Fatal(err)
	}
	at := h.clock.Now()
	if h.count(`select count(*) from accounts where account_id = $1 and status = 'purged'`, p.id) != 1 {
		t.Fatal("the account was not purged")
	}
	if h.count(`select count(*) from characters where account_id = $1 and purged_at = $2 and name is null`, p.id, at) != 2 ||
		h.count(`select count(*) from purge_log where kind = 'character'`) != 2 ||
		h.progress.Has(alive) || h.progress.Has(deleted) {
		t.Fatal("the account's characters are not left as tombstones")
	}
	var reserved time.Time
	h.scalar(&reserved, `select reserved_until from character_names where name_key = 'aneira' and status = 'reserved'
		and character_id is null`)
	if !reserved.Equal(at.Add(30 * day)) {
		t.Errorf("the live one's name, reserved until %v", reserved)
	}
	// The deleted one keeps its reservation (restore_until + 30 days).
	h.scalar(&reserved, `select reserved_until from character_names where name_key = 'brenna'`)
	if !reserved.After(at.Add(15 * day)) {
		t.Errorf("the deleted one's name, reserved until %v", reserved)
	}
}
