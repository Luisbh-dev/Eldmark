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

// The end-to-end progression tests (progression.md §15 P8): the bot with --bot-scenario=progress
// (equips the bow from its bag, gives itself 50 gold and a health potion through DEBUG_COMMAND 41
// and 40) against a test_world zone with --platform --debug-commands, and what the bot saw (the
// progress key of its report) against what the real store's Load returns, field by field.

const (
	// scenarioTimeout: a bot with the scenario, from start to finishing it (three steps with a
	// one-second pause).
	scenarioTimeout = 90 * time.Second
	// goldGiven: what the scenario gives (BotProgressScenario.GOLD_AMOUNT).
	goldGiven    = 50
	currencyGold = 1
)

// savedItem is an entry of the record's items (progression.md §3.4): Load's and the bot report's
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

// savedRecord is what is compared from Load's record.
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

// botProgress is the bot report's progress key (NetClient.progress_report): what the client knows
// about its progression through INVENTORY_FULL/DELTA, WALLET_UPDATE and PROGRESS_UPDATE.
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

// botScenario is the report's scenario key (BotProgressScenario.to_report).
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

// progressReport is what these tests read from the bot's report.
type progressReport struct {
	Progress *botProgress `json:"progress"`
	Scenario *botScenario `json:"scenario"`
}

// readProgressReport reads the bot's report (the final one, or a partial one from the scenario);
// error if it cannot yet be read in full.
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

// makeAdmin gives the admin role to the account (DEBUG_COMMANDs 40 and 41 require it with the
// platform, progression.md §10). Without a set-role row in audit_log, S2 takes the role from accounts
// (sanctions.RoleAt).
func makeAdmin(h *Harness, acc *Account) {
	h.T.Helper()
	if _, err := h.Pool.Exec(context.Background(), `update accounts set role = 'admin' where account_id = $1`,
		acc.ID); err != nil {
		h.T.Fatal(err)
	}
}

// progressRules are the exported rules (the platform's).
func progressRules(t *testing.T) *progress.Rules {
	t.Helper()
	rules, err := progress.LoadRules(gamedata.Raw())
	if err != nil {
		t.Fatal(err)
	}
	return rules
}

// loadRecord is the character's record as given by the store's Load (the one for the next claim).
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

// compareWithLoad compares, field by field, what the bot saw with Load's record: each object (uid,
// def_id, container, slot, quantity, durability, rarity, bound, seed and affixes), each balance, the
// level, the XP (the level's plus total_to(level)), the realm points, the bag slots and the active
// weapon slot.
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

// itemAt is the object in that slot (nil if empty).
func itemAt(rec savedRecord, container, slot int) *savedItem {
	for i := range rec.Items {
		if rec.Items[i].Container == container && rec.Items[i].Slot == slot {
			return &rec.Items[i]
		}
	}
	return nil
}

// countOf is the total quantity of def_id.
func countOf(rec savedRecord, defID string) int {
	n := 0
	for _, it := range rec.Items {
		if it.DefID == defID {
			n += it.Count
		}
	}
	return n
}

// balanceOf is the currency's balance.
func balanceOf(rec savedRecord, currency int) int64 {
	for _, w := range rec.Wallets {
		if w.Currency == currency {
			return w.Balance
		}
	}
	return -1
}

// characterOf is the bot report's character_id.
func characterOf(t *testing.T, report *BotReport) int64 {
	t.Helper()
	id, err := strconv.ParseInt(report.Platform.CharacterID, 10, 64)
	if err != nil {
		t.Fatalf("character_id del informe: %q", report.Platform.CharacterID)
	}
	return id
}

// TestProgressEndToEnd (progression.md §15 P8): the real platform, a test_world zone with
// --debug-commands and a bot of an admin account with the progress scenario, which creates its
// character with the squire template (the bow in the bag), equips it, gives itself 50 gold and a
// potion and leaves. What the bot saw is, field by field, what Load returns after its final save;
// the two GM operations are in the ledger with their audit row, and everything adds up.
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

	// The final save and the release come out when the body leaves.
	h.WaitFor(saveTimeout, "el guardado final y la liberación", func() bool {
		requireRunning(t, zone.Process)
		return h.Exists(`select 1 from character_leases where character_id = $1 and zone_instance_id is null
			and released_at is not null and last_save_version > 0`, id)
	})
	rec := loadRecord(h, rules, id)
	compareWithLoad(t, rules, "tras salir", seen.Progress, rec)

	// What has to be there, besides the bot and the database saying the same thing.
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

	// The two GM operations from DEBUG_COMMAND: by the admin, with the note "debug", and each with its
	// audit row (S8's or the zone batch's, which are not duplicated: the same event_key).
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

// TestProgressCrash (progression.md §15 P8; TEC-25): the same with kill -9 on the zone as soon as
// the bot has seen the gold arrive (its partial report says gold), before the potion. What is saved
// adds up by SQL (by definition, sum of count_delta = sum of count of the live objects; per
// currency, sum of delta = balance; a single kit) and a second bot of the same account joins
// another instance with exactly what Load says, and leaves with it saved again.
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
		r, err := readProgressReport(first.Report) // partial while being written: read again
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
	h.CheckBooks(id) // what was left by the old one: nothing half-done
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
	h.CheckBooks(id) // and after joining again: the kit is not repeated and nothing is duplicated
	if code := replacement.Stop(zoneStop); code != 0 {
		t.Fatalf("la zona nueva sale con el código %d tras el cierre ordenado", code)
	}
	h.Logf("TestProgressCrash: %.1f s", h.Elapsed().Seconds())
}
