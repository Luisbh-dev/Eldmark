//go:build e2e

package e2e

import (
	"strconv"
	"testing"
	"time"
)

// Plazos de las pruebas (holgados: la meta de §15 es < 30 s por prueba con todo).
const (
	liveTimeout = 60 * time.Second // una zona, de arrancar a live (con los reintentos de instance_alive)
	botTimeout  = 90 * time.Second // un bot, de arrancar a salir
	saveTimeout = 20 * time.Second // un guardado que se espera
	zoneStop    = 30 * time.Second // el cierre ordenado de una zona
)

// TestEnterAndSave (plataforma.md §15, P10): una zona test_world con --platform y un bot con cuenta que crea su
// personaje, entra con el billete, juega y sale. Su guardado llega a la base (save_version > 0 y
// character_progress.saved_at puesto) y el arrendamiento queda libre; la zona se cierra en orden y se da de baja.
func TestEnterAndSave(t *testing.T) {
	h := New(t)
	acc := h.NewAccount("viajera@eldmark.test")
	zone := h.StartZone()
	instance := zone.WaitLive(liveTimeout)

	bot := h.StartBot(acc, "--character=Viajera", "--quit-after-ticks=300")
	if code := bot.Wait(t, botTimeout); code != 0 {
		t.Fatalf("el bot sale con el código %d (se esperaba 0: llegó a jugar)", code)
	}
	report := bot.ReadReport(t)
	if report.Platform.Code != "" || !report.Platform.Created {
		t.Fatalf("informe del bot: platform = %+v (se esperaba entrar con un personaje creado)", report.Platform)
	}
	id, err := strconv.ParseInt(report.Platform.CharacterID, 10, 64)
	if err != nil {
		t.Fatalf("character_id del informe: %q", report.Platform.CharacterID)
	}
	h.Logf("el bot ha jugado y salido con el personaje %d", id)

	// El guardado final y la liberación salen al irse el cuerpo: pueden llegar justo después de que el bot cierre.
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
		t.Fatalf("character_progress: save_version %d, saved_at %v (se esperaba un guardado)", saveVersion, savedAt)
	}
	if lastZone != ZoneID || claimedBy != instance {
		t.Fatalf("last_zone_id %q y arrendamiento reclamado por %s (se esperaba %s y %s)", lastZone, claimedBy, ZoneID,
			instance)
	}
	if n := countConsumed(h, id); n != 1 {
		t.Fatalf("billetes consumidos del personaje: %d (se esperaba 1)", n)
	}
	h.CheckBooks(id)
	h.Logf("guardado: save_version %d, saved_at %s", saveVersion, savedAt.Format(time.RFC3339Nano))

	if code := zone.Stop(zoneStop); code != 0 {
		t.Fatalf("la zona sale con el código %d tras el cierre ordenado", code)
	}
	var status string
	h.Scalar(&status, `select status from zone_instances where zone_instance_id = $1`, instance)
	if status != "stopped" {
		t.Fatalf("la instancia queda en %q tras el cierre ordenado (se esperaba stopped)", status)
	}
	h.Logf("TestEnterAndSave: %.1f s", h.Elapsed().Seconds())
}

// TestZoneCrash (plataforma.md §15, P10; TEC-25): con --save-interval=5, un bot juega en la zona; tras su primer
// guardado se espera más de un intervalo y se mata la zona con kill -9. Lo perdido está acotado por el punto de
// control: el último saved_at queda a menos de 5 s + 1 s de margen del kill (y es posterior al primero, así que
// salió de un punto de control y no del guardado de la llegada), y lo guardado cuadra (CheckBooks). Otra instancia
// de la zona arranca enseguida: su registro da 409 instance_alive y reintenta cada 2 s hasta que la vieja lleva 3 s
// sin latir, y entonces la plataforma la pasa a lost y libera sus arrendamientos (§5.3). Un segundo bot con la misma
// cuenta entra con el mismo personaje en la instancia nueva, sin repetir el kit ni duplicar nada. El primer bot no
// reconecta.
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

	// Más de un intervalo tras el primer guardado: sin puntos de control, el kill quedaría a más de 5 s + 1 s.
	time.Sleep(saveInterval + 2*margin)
	requireRunning(t, first.Process, old.Process)
	killedAt := old.Kill()
	first.Kill() // no hace falta que reconecte: así no gasta CPU mientras arranca la otra
	h.Logf("kill -9 a %s", old.Name)

	replacement := h.StartZone("--save-interval=5")
	newInstance := replacement.WaitLive(liveTimeout)
	if newInstance == oldInstance {
		t.Fatalf("la instancia nueva es la vieja (%s)", newInstance)
	}
	var oldStatus string
	h.Scalar(&oldStatus, `select status from zone_instances where zone_instance_id = $1`, oldInstance)
	if oldStatus != "lost" {
		t.Fatalf("la instancia muerta queda en %q (se esperaba lost)", oldStatus)
	}

	// Lo último que llegó de la vieja: ya no puede llegar nada más (está lost y sus arrendamientos, libres).
	var savedAt time.Time
	var saveVersion int64
	h.Scalar(&savedAt, `select saved_at from character_progress where character_id = $1`, id)
	h.Scalar(&saveVersion, `select save_version from character_progress where character_id = $1`, id)
	lost := killedAt.Sub(savedAt)
	h.Logf("último guardado de la vieja: %s (save_version %d); kill − saved_at = %.2f s", savedAt.Format(time.RFC3339Nano),
		saveVersion, lost.Seconds())
	if !savedAt.After(firstSave) {
		t.Fatalf("no hubo ningún punto de control tras el primer guardado (%s): saved_at %s", firstSave, savedAt)
	}
	if lost >= saveInterval+margin {
		t.Fatalf("kill − saved_at = %v; con --save-interval=5 tiene que ser < %v", lost, saveInterval+margin)
	}
	h.CheckBooks(id) // lo que quedó de la vieja: nada a medias

	second := h.StartBot(acc, "--character=Superviviente", "--quit-after-ticks=240")
	h.WaitFor(botTimeout, "el personaje en la instancia nueva", func() bool {
		requireRunning(t, second.Process, replacement.Process)
		return h.Exists(`select 1 from character_leases where character_id = $1 and zone_instance_id = $2::uuid`,
			id, newInstance)
	})
	h.Logf("el segundo bot ha entrado con el personaje %d en %s", id, newInstance)
	if code := second.Wait(t, botTimeout); code != 0 {
		t.Fatalf("el segundo bot sale con el código %d", code)
	}
	report := second.ReadReport(t)
	if report.Platform.Code != "" || report.Platform.Created || report.Platform.CharacterID != strconv.FormatInt(id, 10) {
		t.Fatalf("informe del segundo bot: platform = %+v (se esperaba el personaje %d ya creado)", report.Platform, id)
	}
	if code := replacement.Stop(zoneStop); code != 0 {
		t.Fatalf("la zona nueva sale con el código %d tras el cierre ordenado", code)
	}
	h.CheckBooks(id) // y tras volver a entrar: el kit no se repite y nada se duplica
	// Quién pasa la vieja a lost depende de cuándo llega el registro de la nueva: el trabajo de perdidas (cada
	// min(5 s, HEARTBEAT_S) = 1 s) o el propio registro (§5.3). Las dos cosas valen; se anota cuál fue.
	h.Logf("registro de la nueva con 409 instance_alive: %v; la vieja pasó a lost por el trabajo de perdidas: %v, "+
		"por el registro: %v", replacement.LogContains("Hay otra instancia viva"),
		h.PlatformLogContains("instancia perdida: sin latido"),
		h.PlatformLogContains("instancia sin latido dada por perdida al registrar otra"))
	h.Logf("TestZoneCrash: %.1f s", h.Elapsed().Seconds())
}

// countConsumed son los billetes consumidos del personaje.
func countConsumed(h *Harness, characterID int64) int {
	h.T.Helper()
	var n int
	h.Scalar(&n, `select count(*) from enter_tickets where character_id = $1 and consumed_at is not null`, characterID)
	return n
}
