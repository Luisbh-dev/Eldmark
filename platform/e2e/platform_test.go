//go:build e2e

package e2e

import (
	"strconv"
	"testing"
	"time"
)

// Test timeouts (generous: the §15 goal is < 30 s per test with everything).
const (
	liveTimeout = 60 * time.Second // a zone, from start to live (with the instance_alive retries)
	botTimeout  = 90 * time.Second // a bot, from start to exit
	saveTimeout = 20 * time.Second // a save that is awaited
	zoneStop    = 30 * time.Second // a zone's orderly shutdown
)

// TestEnterAndSave (platform.md §15, P10): a test_world zone with --platform and a bot with an
// account that creates its character, joins with the ticket, plays and leaves. Its save reaches the
// database (save_version > 0 and character_progress.saved_at set) and the lease is freed; the zone
// shuts down in order and deregisters.
func TestEnterAndSave(t *testing.T) {
	h := New(t)
	acc := h.NewAccount("viajera@eldmark.test")
	zone := h.StartZone()
	instance := zone.WaitLive(liveTimeout)

	bot := h.StartBot(acc, "--character=Viajera", "--quit-after-ticks=300")
	if code := bot.Wait(t, botTimeout); code != 0 {
		t.Fatalf("the bot exits with code %d (expected 0: it got to play)", code)
	}
	report := bot.ReadReport(t)
	if report.Platform.Code != "" || !report.Platform.Created {
		t.Fatalf("bot report: platform = %+v (expected to enter with a created character)", report.Platform)
	}
	id, err := strconv.ParseInt(report.Platform.CharacterID, 10, 64)
	if err != nil {
		t.Fatalf("character_id of the report: %q", report.Platform.CharacterID)
	}
	h.Logf("el bot ha jugado y salido con el personaje %d", id)

	// The final save and the release come out when the body leaves: they can arrive just after the bot
	// closes.
	h.WaitFor(saveTimeout, "el guardado final y la liberación", func() bool {
		requireRunning(t, zone.Process)
		return h.Exists(`select 1 from character_leases where character_id = $1 and zone_instance_id is null
			and released_at is not null and last_save_version > 0`, id)
	})
	var saveVersion int64
	var savedAt *time.Time
	var claimedBy, lastZone string
	h.Scalar(&saveVersion, `select save_version from character_progress where character_id = $1`, id)
	h.Scalar(&savedAt, `select saved_at from character_progress where character_id = $1`, id)
	h.Scalar(&lastZone, `select coalesce(last_zone_id, '') from character_progress where character_id = $1`, id)
	h.Scalar(&claimedBy, `select claimed_by::text from character_leases where character_id = $1`, id)
	if saveVersion <= 0 || savedAt == nil {
		t.Fatalf("character_progress: save_version %d, saved_at %v (expected a save)", saveVersion, savedAt)
	}
	if lastZone != ZoneID || claimedBy != instance {
		t.Fatalf("last_zone_id %q and lease claimed by %s (expected %s and %s)", lastZone, claimedBy, ZoneID,
			instance)
	}
	if n := countConsumed(h, id); n != 1 {
		t.Fatalf("character's consumed tickets: %d (expected 1)", n)
	}
	h.CheckBooks(id)
	h.Logf("guardado: save_version %d, saved_at %s", saveVersion, savedAt.Format(time.RFC3339Nano))

	if code := zone.Stop(zoneStop); code != 0 {
		t.Fatalf("the zone exits with code %d after the orderly shutdown", code)
	}
	var status string
	h.Scalar(&status, `select status from zone_instances where zone_instance_id = $1`, instance)
	if status != "stopped" {
		t.Fatalf("the instance is left in %q after the orderly shutdown (expected stopped)", status)
	}
	h.Logf("TestEnterAndSave: %.1f s", h.Elapsed().Seconds())
}

// TestZoneCrash (platform.md §15, P10; TEC-25): with --save-interval=5, a bot plays in the zone;
// after its first save, we wait more than an interval and kill the zone with kill -9. What is lost
// is bounded by the checkpoint: the last saved_at ends up less than 5 s + 1 s of margin from the
// kill (and is later than the first one, so it came from a checkpoint and not from the arrival
// save), and what is saved adds up (CheckBooks). Another instance of the zone starts right away: its
// registration gets 409 instance_alive and retries every 2 s until the old one has gone 3 s without
// heartbeating, and then the platform marks it lost and frees its leases (§5.3). A second bot with
// the same account joins with the same character in the new instance, without repeating the kit or
// duplicating anything. The first bot does not reconnect.
func TestZoneCrash(t *testing.T) {
	const saveInterval = 5 * time.Second
	const margin = time.Second
	h := New(t)
	acc := h.NewAccount("superviviente@eldmark.test")
	old := h.StartZone("--save-interval=5")
	oldInstance := old.WaitLive(liveTimeout)

	first := h.StartBot(acc, "--character=Superviviente", "--quit-after-ticks=7200")
	id := h.WaitCharacter("Superviviente", botTimeout, first.Process, old.Process)
	var firstSave time.Time
	h.WaitFor(saveTimeout, "el primer guardado del personaje", func() bool {
		requireRunning(t, first.Process, old.Process)
		var at *time.Time
		h.Scalar(&at, `select saved_at from character_progress where character_id = $1`, id)
		if at == nil {
			return false
		}
		firstSave = *at
		return true
	})
	h.Logf("primer guardado del personaje %d: %s", id, firstSave.Format(time.RFC3339Nano))

	// More than an interval after the first save: without checkpoints, the kill would land more than 5 s
	// + 1 s away.
	time.Sleep(saveInterval + 2*margin)
	requireRunning(t, first.Process, old.Process)
	killedAt := old.Kill()
	first.Kill() // it does not need to reconnect: that way it does not burn CPU while the other one starts
	h.Logf("kill -9 a %s", old.Name)

	replacement := h.StartZone("--save-interval=5")
	newInstance := replacement.WaitLive(liveTimeout)
	if newInstance == oldInstance {
		t.Fatalf("the new instance is the old one (%s)", newInstance)
	}
	var oldStatus string
	h.Scalar(&oldStatus, `select status from zone_instances where zone_instance_id = $1`, oldInstance)
	if oldStatus != "lost" {
		t.Fatalf("the dead instance is left in %q (expected lost)", oldStatus)
	}

	// The last thing that arrived from the old one: nothing more can arrive (it is lost and its leases
	// are free).
	var savedAt time.Time
	var saveVersion int64
	h.Scalar(&savedAt, `select saved_at from character_progress where character_id = $1`, id)
	h.Scalar(&saveVersion, `select save_version from character_progress where character_id = $1`, id)
	lost := killedAt.Sub(savedAt)
	h.Logf("último guardado de la vieja: %s (save_version %d); kill − saved_at = %.2f s", savedAt.Format(time.RFC3339Nano),
		saveVersion, lost.Seconds())
	if !savedAt.After(firstSave) {
		t.Fatalf("there was no checkpoint after the first save (%s): saved_at %s", firstSave, savedAt)
	}
	if lost >= saveInterval+margin {
		t.Fatalf("kill - saved_at = %v; with --save-interval=5 it has to be < %v", lost, saveInterval+margin)
	}
	h.CheckBooks(id) // what was left by the old one: nothing half-done

	second := h.StartBot(acc, "--character=Superviviente", "--quit-after-ticks=240")
	h.WaitFor(botTimeout, "el personaje en la instancia nueva", func() bool {
		requireRunning(t, second.Process, replacement.Process)
		return h.Exists(`select 1 from character_leases where character_id = $1 and zone_instance_id = $2::uuid`,
			id, newInstance)
	})
	h.Logf("el segundo bot ha entrado con el personaje %d en %s", id, newInstance)
	if code := second.Wait(t, botTimeout); code != 0 {
		t.Fatalf("the second bot exits with code %d", code)
	}
	report := second.ReadReport(t)
	if report.Platform.Code != "" || report.Platform.Created || report.Platform.CharacterID != strconv.FormatInt(id, 10) {
		t.Fatalf("second bot report: platform = %+v (expected the already created character %d)", report.Platform, id)
	}
	if code := replacement.Stop(zoneStop); code != 0 {
		t.Fatalf("the new zone exits with code %d after the orderly shutdown", code)
	}
	h.CheckBooks(id) // and after joining again: the kit is not repeated and nothing is duplicated
	// Who marks the old one as lost depends on when the new one's registration arrives: the lost-instances
	// job (every min(5 s, HEARTBEAT_S) = 1 s) or the registration itself (§5.3). Either is valid; which
	// one it was is noted.
	h.Logf("registro de la nueva con 409 instance_alive: %v; la vieja pasó a lost por el trabajo de perdidas: %v, "+
		"por el registro: %v", replacement.LogContains("Hay otra instancia viva"),
		h.PlatformLogContains("instancia perdida: sin latido"),
		h.PlatformLogContains("instancia sin latido dada por perdida al registrar otra"))
	h.Logf("TestZoneCrash: %.1f s", h.Elapsed().Seconds())
}

// countConsumed is the character's consumed tickets.
func countConsumed(h *Harness, characterID int64) int {
	h.T.Helper()
	var n int
	h.Scalar(&n, `select count(*) from enter_tickets where character_id = $1 and consumed_at is not null`, characterID)
	return n
}
