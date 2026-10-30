//go:build e2e

package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"testing"
	"time"

	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/progress"
)

// Las pruebas del progreso de extremo a extremo (progresion.md §15 P8): el bot con --bot-scenario=progress (equipa
// el arco de su bolsa, se da 50 de oro y una poción de vida por DEBUG_COMMAND 41 y 40) contra una zona test_world
// con --platform --debug-commands, y lo que vio el bot (la clave progress de su informe) frente a lo que devuelve
// Load del almacén de verdad, campo a campo.

const (
	// scenarioTimeout: un bot con el escenario, de arrancar a acabarlo (tres pasos con un segundo de pausa).
	scenarioTimeout = 90 * time.Second
	// goldGiven: lo que da el escenario (BotProgressScenario.GOLD_AMOUNT).
	goldGiven    = 50
	currencyGold = 1
)

// savedItem es una entrada de items del registro (progresion.md §3.4): la de Load y la del informe del bot
// (ItemInstance.to_dictionary).
type savedItem struct {
	UID        string  `json:"uid"`
	DefID      string  `json:"def_id"`
	Container  int     `json:"container"`
	Slot       int     `json:"slot"`
	Count      int     `json:"count"`
	Durability *int    `json:"durability"`
	Rarity     int     `json:"rarity"`
	Bound      bool    `json:"bound"`
	Seed       string  `json:"seed"`
	Affixes    []int64 `json:"affixes"`
}

type savedWallet struct {
	Currency int   `json:"currency"`
	Balance  int64 `json:"balance"`
}

// savedRecord es lo que se compara del registro de Load.
type savedRecord struct {
	Items             []savedItem   `json:"items"`
	Wallets           []savedWallet `json:"wallets"`
	Level             int           `json:"level"`
	XPTotal           int64         `json:"xp_total"`
	RealmPoints       int64         `json:"realm_points"`
	BagSlots          int           `json:"bag_slots"`
	ActiveWeaponSlot  int           `json:"active_weapon_slot"`
	StarterTemplateID string        `json:"starter_template_id"`
	StarterGranted    bool          `json:"starter_granted"`
}

// botProgress es la clave progress del informe del bot (NetClient.progress_report): lo que el cliente sabe de su
// progreso por INVENTORY_FULL/DELTA, WALLET_UPDATE y PROGRESS_UPDATE.
type botProgress struct {
	Items            []savedItem   `json:"items"`
	Wallets          []savedWallet `json:"wallets"`
	Level            int           `json:"level"`
	XPInLevel        int64         `json:"xp_in_level"`
	RealmPoints      int64         `json:"realm_points"`
	BagSlots         int           `json:"bag_slots"`
	ActiveWeaponSlot int           `json:"active_weapon_slot"`
	Pending          int           `json:"pending"`
}

// botScenario es la clave scenario del informe (BotProgressScenario.to_report).
type botScenario struct {
	Name            string   `json:"name"`
	Phase           string   `json:"phase"`
	Completed       []string `json:"completed"`
	Error           string   `json:"error"`
	BowSlot         []int    `json:"bow_slot"`
	AlreadyEquipped bool     `json:"already_equipped"`
	GoldBefore      int64    `json:"gold_before"`
	PotionsBefore   int      `json:"potions_before"`
}

// progressReport es lo que estas pruebas leen del informe del bot.
type progressReport struct {
	Progress *botProgress `json:"progress"`
	Scenario *botScenario `json:"scenario"`
}

// readProgressReport lee el informe del bot (el final, o uno a medias del escenario); error si aún no se puede
// leer entero.
func readProgressReport(path string) (*progressReport, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	r := &progressReport{}
	if err := json.Unmarshal(data, r); err != nil {
		return nil, err
	}
	return r, nil
}

// makeAdmin da el rol admin a la cuenta (los DEBUG_COMMAND 40 y 41 lo piden con plataforma, progresion.md §10).
// Sin fila set-role en audit_log, S2 toma el rol de accounts (sanctions.RoleAt).
func makeAdmin(h *Harness, acc *Account) {
	h.T.Helper()
	if _, err := h.Pool.Exec(context.Background(), `update accounts set role = 'admin' where account_id = $1`,
		acc.ID); err != nil {
		h.T.Fatal(err)
	}
}

// progressRules son las reglas exportadas (las de la plataforma).
func progressRules(t *testing.T) *progress.Rules {
	t.Helper()
	rules, err := progress.LoadRules(gamedata.Raw())
	if err != nil {
		t.Fatal(err)
	}
	return rules
}

// loadRecord es el registro del personaje como lo da Load del almacén (el de la reclamación siguiente).
func loadRecord(h *Harness, rules *progress.Rules, characterID int64) savedRecord {
	h.T.Helper()
	raw, err := progress.New(rules, nil).Load(context.Background(), h.Pool, characterID)
	if err != nil {
		h.T.Fatalf("Load del personaje %d: %v", characterID, err)
	}
	var rec savedRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		h.T.Fatalf("Load del personaje %d: %v\n%s", characterID, err, raw)
	}
	return rec
}

// compareWithLoad compara, campo a campo, lo que vio el bot con el registro de Load: cada objeto (uid, def_id,
// contenedor, ranura, cantidad, durabilidad, rareza, ligado, semilla y afijos), cada saldo, el nivel, la XP (la del
// nivel más total_to(nivel)), los puntos de reino, las ranuras de la bolsa y la ranura de arma activa.
func compareWithLoad(t *testing.T, rules *progress.Rules, what string, seen *botProgress, rec savedRecord) {
	t.Helper()
	if seen == nil {
		t.Fatalf("%s: el informe del bot no trae progress", what)
	}
	if seen.Pending != 0 {
		t.Fatalf("%s: el bot tenía %d peticiones del inventario sin respuesta", what, seen.Pending)
	}
	if len(seen.Items) != len(rec.Items) {
		t.Fatalf("%s: el bot ve %d objetos y Load da %d\nbot:  %+v\nLoad: %+v", what, len(seen.Items),
			len(rec.Items), seen.Items, rec.Items)
	}
	for i := range rec.Items {
		a, b := seen.Items[i], rec.Items[i]
		if a.Affixes == nil {
			a.Affixes = []int64{}
		}
		if b.Affixes == nil {
			b.Affixes = []int64{}
		}
		if !reflect.DeepEqual(a, b) {
			t.Fatalf("%s: objeto %d distinto\nbot:  %+v\nLoad: %+v", what, i, a, b)
		}
	}
	if !reflect.DeepEqual(seen.Wallets, rec.Wallets) {
		t.Fatalf("%s: saldos distintos: el bot %+v, Load %+v", what, seen.Wallets, rec.Wallets)
	}
	if seen.Level != rec.Level || rules.TotalTo(seen.Level)+seen.XPInLevel != rec.XPTotal {
		t.Fatalf("%s: el bot ve el nivel %d con %d de XP en él; Load da el nivel %d con %d en total", what,
			seen.Level, seen.XPInLevel, rec.Level, rec.XPTotal)
	}
	if seen.RealmPoints != rec.RealmPoints || seen.BagSlots != rec.BagSlots ||
		seen.ActiveWeaponSlot != rec.ActiveWeaponSlot {
		t.Fatalf("%s: puntos de reino %d/%d, bolsa %d/%d, ranura activa %d/%d (bot/Load)", what, seen.RealmPoints,
			rec.RealmPoints, seen.BagSlots, rec.BagSlots, seen.ActiveWeaponSlot, rec.ActiveWeaponSlot)
	}
}

// itemAt es el objeto de esa ranura (nil si está vacía).
func itemAt(rec savedRecord, container, slot int) *savedItem {
	for i := range rec.Items {
		if rec.Items[i].Container == container && rec.Items[i].Slot == slot {
			return &rec.Items[i]
		}
	}
	return nil
}

// countOf es la cantidad total de def_id.
func countOf(rec savedRecord, defID string) int {
	n := 0
	for _, it := range rec.Items {
		if it.DefID == defID {
			n += it.Count
		}
	}
	return n
}

// balanceOf es el saldo de la moneda.
func balanceOf(rec savedRecord, currency int) int64 {
	for _, w := range rec.Wallets {
		if w.Currency == currency {
			return w.Balance
		}
	}
	return -1
}

// characterOf es el character_id del informe del bot.
func characterOf(t *testing.T, report *BotReport) int64 {
	t.Helper()
	id, err := strconv.ParseInt(report.Platform.CharacterID, 10, 64)
	if err != nil {
		t.Fatalf("character_id del informe: %q", report.Platform.CharacterID)
	}
	return id
}

// TestProgressEndToEnd (progresion.md §15 P8): la plataforma de verdad, una zona test_world con --debug-commands y
// un bot de una cuenta admin con el escenario progress, que crea su personaje con la plantilla squire (el arco en la
// bolsa), lo equipa, se da 50 de oro y una poción y sale. Lo que vio el bot es, campo a campo, lo que devuelve Load
// después de su guardado final; las dos operaciones GM están en el libro con su fila de auditoría, y todo cuadra.
func TestProgressEndToEnd(t *testing.T) {
	h := New(t)
	rules := progressRules(t)
	acc := h.NewAccount("progreso@eldmark.test")
	makeAdmin(h, acc)
	zone := h.StartZone("--debug-commands")
	zone.WaitLive(liveTimeout)

	bot := h.StartBot(acc, "--character=Progreso", "--loadout=squire", "--bot-scenario=progress")
	if code := bot.Wait(t, scenarioTimeout); code != 0 {
		t.Fatalf("el bot sale con el código %d (se esperaba 0: el escenario entero)", code)
	}
	report := bot.ReadReport(t)
	if report.Platform.Code != "" || !report.Platform.Created {
		t.Fatalf("informe del bot: platform = %+v (se esperaba entrar con un personaje creado)", report.Platform)
	}
	id := characterOf(t, report)
	seen, err := readProgressReport(bot.Report)
	if err != nil {
		t.Fatal(err)
	}
	sc := seen.Scenario
	if sc == nil || sc.Phase != "done" || sc.Error != "" || sc.AlreadyEquipped ||
		!reflect.DeepEqual(sc.BowSlot, []int{1, 1}) {
		t.Fatalf("escenario del informe: %+v (se esperaba done, sin error, con el arco equipado en WEAPON_2)", sc)
	}
	h.Logf("el bot ha hecho el escenario con el personaje %d: %v", id, sc.Completed)

	// El guardado final y la liberación salen al irse el cuerpo.
	h.WaitFor(saveTimeout, "el guardado final y la liberación", func() bool {
		requireRunning(t, zone.Process)
		return h.Exists(`select 1 from character_leases where character_id = $1 and zone_instance_id is null
			and released_at is not null and last_save_version > 0`, id)
	})
	rec := loadRecord(h, rules, id)
	compareWithLoad(t, rules, "tras salir", seen.Progress, rec)

	// Lo que tiene que haber, además de que el bot y la base digan lo mismo.
	if rec.StarterTemplateID != "squire" || !rec.StarterGranted {
		t.Fatalf("plantilla %q y kit dado %v (se esperaba squire y true)", rec.StarterTemplateID, rec.StarterGranted)
	}
	bow, sword := itemAt(rec, 1, 1), itemAt(rec, 1, 0)
	if bow == nil || bow.DefID != "bow_vado" || !bow.Bound || sword == nil || sword.DefID != "sword_shield_vado" {
		t.Fatalf("equipo guardado: WEAPON_1 %+v, WEAPON_2 %+v (se esperaba la espada y el arco, ligado)", sword, bow)
	}
	if got := balanceOf(rec, currencyGold); got != goldGiven {
		t.Fatalf("oro guardado: %d (se esperaba %d)", got, goldGiven)
	}
	if got := countOf(rec, "potion_health"); got != sc.PotionsBefore+1 || got != 4 {
		t.Fatalf("pociones de vida guardadas: %d (las %d del kit y la dada)", got, sc.PotionsBefore)
	}

	// Las dos operaciones GM de DEBUG_COMMAND: del admin, con la nota «debug», y cada una con su fila de auditoría
	// (la de S8 o la del lote de la zona, que no se duplican: la misma event_key).
	ctx := context.Background()
	rows, err := h.Pool.Query(ctx, `select o.op_id, o.actor_account_id, o.note, o.detail->>'command', o.detail->>'source'
		from economy_ops o join op_participants p on p.op_id = o.op_id
		where p.character_id = $1 and o.kind = 4 order by o.op_id`, id)
	if err != nil {
		t.Fatal(err)
	}
	type gmOp struct {
		opID, actor           int64
		note, command, source string
	}
	var ops []gmOp
	for rows.Next() {
		var op gmOp
		if err := rows.Scan(&op.opID, &op.actor, &op.note, &op.command, &op.source); err != nil {
			t.Fatal(err)
		}
		ops = append(ops, op)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	commands := map[string]bool{}
	for _, op := range ops {
		commands[op.command] = true
		if op.actor != acc.ID || op.note != "debug" || op.source != "debug" {
			t.Fatalf("operación GM %d: actor %d, nota %q, source %q (se esperaba la cuenta %d, «debug» y debug)",
				op.opID, op.actor, op.note, op.source, acc.ID)
		}
		var audits int
		h.Scalar(&audits, `select count(*) from audit_log where event_key = $1 and source = 'zone'
			and actor_account_id = $2 and target_character_id = $3 and command = $4`,
			fmt.Sprintf("op:%d", op.opID), acc.ID, id, op.command)
		if audits != 1 {
			t.Fatalf("operación GM %d (%s): %d filas de auditoría con su clave (se esperaba 1)", op.opID, op.command,
				audits)
		}
	}
	if len(ops) != 2 || !commands["currency_add"] || !commands["item_give"] {
		t.Fatalf("operaciones GM del personaje: %+v (se esperaba currency_add e item_give)", ops)
	}
	h.CheckBooks(id)

	if code := zone.Stop(zoneStop); code != 0 {
		t.Fatalf("la zona sale con el código %d tras el cierre ordenado", code)
	}
	h.Logf("TestProgressEndToEnd: %.1f s", h.Elapsed().Seconds())
}

// TestProgressCrash (progresion.md §15 P8; TEC-25): lo mismo con kill -9 a la zona en cuanto el bot ha visto llegar
// el oro (su informe a medias dice gold), antes de la poción. Lo guardado cuadra por SQL (por definición, Σ
// count_delta = Σ count de los objetos vivos; por moneda, Σ delta = saldo; un solo kit) y un segundo bot de la misma
// cuenta entra en otra instancia con exactamente lo que dice Load, y sale con ello guardado otra vez.
func TestProgressCrash(t *testing.T) {
	h := New(t)
	rules := progressRules(t)
	acc := h.NewAccount("caida@eldmark.test")
	makeAdmin(h, acc)
	old := h.StartZone("--debug-commands", "--save-interval=5")
	oldInstance := old.WaitLive(liveTimeout)

	first := h.StartBot(acc, "--character=Caida", "--loadout=squire", "--bot-scenario=progress",
		"--quit-after-ticks=7200")
	id := h.WaitCharacter("Caida", botTimeout, first.Process, old.Process)
	var phase string
	h.WaitFor(scenarioTimeout, "el oro en el bot", func() bool {
		requireRunning(t, first.Process, old.Process)
		r, err := readProgressReport(first.Report) // a medias mientras se escribe: se vuelve a leer
		if err != nil || r.Scenario == nil {
			return false
		}
		if r.Scenario.Error != "" {
			t.Fatalf("el escenario falla: %s", r.Scenario.Error)
		}
		phase = r.Scenario.Phase
		return phase == "gold" || phase == "potion" || phase == "done"
	})
	killedAt := old.Kill()
	first.Kill()
	var gold int64
	h.Scalar(&gold, `select balance from character_wallets where character_id = $1 and currency = 1`, id)
	var savedAt *time.Time
	h.Scalar(&savedAt, `select saved_at from character_progress where character_id = $1`, id)
	h.Logf("kill -9 a %s con el bot en «%s»; en la base, %d de oro (último guardado %.2f s antes del kill)", old.Name,
		phase, gold, killedAt.Sub(*savedAt).Seconds())

	replacement := h.StartZone("--debug-commands", "--save-interval=5")
	newInstance := replacement.WaitLive(liveTimeout)
	var oldStatus string
	h.Scalar(&oldStatus, `select status from zone_instances where zone_instance_id = $1`, oldInstance)
	if newInstance == oldInstance || oldStatus != "lost" {
		t.Fatalf("instancia nueva %s y la vieja %s en %q (se esperaba otra y lost)", newInstance, oldInstance, oldStatus)
	}
	h.CheckBooks(id) // lo que quedó de la vieja: nada a medias
	before := loadRecord(h, rules, id)

	second := h.StartBot(acc, "--character=Caida", "--quit-after-ticks=240")
	if code := second.Wait(t, botTimeout); code != 0 {
		t.Fatalf("el segundo bot sale con el código %d", code)
	}
	report := second.ReadReport(t)
	if report.Platform.Code != "" || report.Platform.Created || characterOf(t, report) != id {
		t.Fatalf("informe del segundo bot: platform = %+v (se esperaba el personaje %d ya creado)", report.Platform, id)
	}
	seen, err := readProgressReport(second.Report)
	if err != nil {
		t.Fatal(err)
	}
	compareWithLoad(t, rules, "al volver tras la caída", seen.Progress, before)
	h.WaitFor(saveTimeout, "el guardado final y la liberación", func() bool {
		requireRunning(t, replacement.Process)
		return h.Exists(`select 1 from character_leases where character_id = $1 and zone_instance_id is null
			and released_at is not null and claimed_by = $2::uuid`, id, newInstance)
	})
	after := loadRecord(h, rules, id)
	compareWithLoad(t, rules, "tras salir de la nueva", seen.Progress, after)
	h.CheckBooks(id) // y tras volver a entrar: el kit no se repite y nada se duplica
	if code := replacement.Stop(zoneStop); code != 0 {
		t.Fatalf("la zona nueva sale con el código %d tras el cierre ordenado", code)
	}
	h.Logf("TestProgressCrash: %.1f s", h.Elapsed().Seconds())
}
