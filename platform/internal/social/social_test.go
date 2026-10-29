package social_test

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/internal/zones"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func idStr(id int64) string { return strconv.FormatInt(id, 10) }

func auditEntry(key, source string, actor any, command string) map[string]any {
	return map[string]any{"key": key, "actor_account_id": actor, "actor_character_id": nil, "command": command,
		"target_character_id": "41", "target_account_id": "7", "args": map[string]any{"target": "41"},
		"at_unix": 1800000000, "source": source}
}

// Un lote de auditoría con entradas malas inserta las demás y devuelve sus claves: una sin un
// campo; con source cli; con la key <uuid>:<n> de otra instancia; con un op:<op_id> de un bloque de
// otra instancia; con un command de la CLI o de la plataforma; console con actor o zone sin él.
// Reenviar no duplica, y la entrada op:<op_id> de un bloque propio vale.
func TestAuditBatch(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	other := p.NewZone(1, "test_world", 0).Start()
	blockOf := func(zone *platformtest.Zone) string {
		res := zone.Do("POST", "/internal/v1/id-blocks", map[string]any{"zone_instance_id": zone.ID})
		platformtest.Expect(t, res, 200, "")
		return res.String("first")
	}
	own := blockOf(z)         // 1
	foreign := blockOf(other) // 1025
	ownOp, _ := strconv.Atoi(own)
	missing := map[string]any{"key": z.ID + ":9", "source": "zone"}
	entries := []any{
		auditEntry(z.ID+":1", "zone", "7", "item_give"),
		auditEntry("op:"+strconv.Itoa(ownOp+5), "zone", "7", "op_revert"),
		auditEntry(z.ID+":2", "console", nil, "fort_reset"),
		auditEntry(z.ID+":3", "cli", "7", "item_give"),
		auditEntry(other.ID+":4", "zone", "7", "item_give"),
		auditEntry("op:"+foreign, "zone", "7", "item_give"),
		auditEntry("op:99999", "zone", "7", "item_give"),
		auditEntry(z.ID+":5", "zone", "7", "set-role"),
		auditEntry(z.ID+":6", "zone", "7", "sanction_denied"),
		auditEntry(z.ID+":7", "console", "7", "fort_reset"),
		auditEntry(z.ID+":8", "zone", nil, "item_give"),
		missing,
		auditEntry(z.ID+":10", "platform", "7", "item_give"),
	}
	body := map[string]any{"zone_instance_id": z.ID, "entries": entries}
	res := z.Do("POST", "/internal/v1/audit", body)
	platformtest.Expect(t, res, 200, "")
	got := res.Body["rejected"].([]any)
	want := []string{z.ID + ":3", other.ID + ":4", "op:" + foreign, "op:99999", z.ID + ":5", z.ID + ":6", z.ID + ":7",
		z.ID + ":8", z.ID + ":9", z.ID + ":10"}
	if len(got) != len(want) {
		t.Fatalf("rejected: %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("rejected[%d] = %v, se esperaba %s", i, got[i], want[i])
		}
	}
	if n := p.Count(`select count(*) from audit_log where world_id = 1 and zone_id = 'vado_gris'
		and at = to_timestamp(1800000000)`); n != 3 {
		t.Fatalf("insertadas: %d", n)
	}
	if n := p.Count(`select count(*) from audit_log where source = 'console' and actor_account_id is null`); n != 1 {
		t.Fatal("la de la consola")
	}
	// La fila op:<op_id> es la misma que escribiría el guardado (S8): on conflict do nothing.
	p.Exec(`insert into audit_log (world_id, source, command, event_key) values (1, 'zone', 'item_give', 'op:77777')
		on conflict (event_key) do nothing`)
	z.Do("POST", "/internal/v1/audit", body)
	if n := p.Count(`select count(*) from audit_log where zone_id = 'vado_gris'`); n != 3 {
		t.Fatalf("reenviar no duplica: %d", n)
	}
}

// Un lote de chat: world_id, zone_id y zone_channel de la instancia y sender_account_id de
// characters; un emisor de otro mundo, un texto de más de 255 caracteres o una key ajena van a
// rejected. Los lotes valen también con la instancia perdida.
func TestChatBatch(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 1).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	far := p.NewCharacterIn(pl, 2, "Lejana", 1)
	msg := func(key string, sender int64, text string) map[string]any {
		return map[string]any{"key": key, "channel": 2, "sender_character_id": idStr(sender), "target_character_id": nil,
			"text": text, "sent_at_unix": 1800000000}
	}
	whisper := msg(z.ID+":2", id, "hola")
	whisper["target_character_id"] = idStr(far)
	whisper["channel"] = 3
	res := z.Do("POST", "/internal/v1/chat", map[string]any{"zone_instance_id": z.ID, "messages": []any{
		msg(z.ID+":1", id, "¡Hola, Vado Gris!"),
		whisper,
		msg(z.ID+":3", far, "de otro mundo"),
		msg(z.ID+":4", id, strings.Repeat("a", 256)),
		msg(zones.FormatUUID(zones.NewUUID())+":5", id, "ajena"),
		msg(z.ID+":6", id, strings.Repeat("ñ", 255)),
	}})
	platformtest.Expect(t, res, 200, "")
	got := res.Body["rejected"].([]any)
	if len(got) != 3 {
		t.Fatalf("rejected: %v", got)
	}
	var zoneChannel, account int64
	var world int
	var zoneID string
	p.Scalar(&zoneChannel, `select zone_channel from chat_messages where message_key = $1`, z.ID+":1")
	p.Scalar(&account, `select sender_account_id from chat_messages where message_key = $1`, z.ID+":1")
	p.Scalar(&world, `select world_id from chat_messages where message_key = $1`, z.ID+":1")
	p.Scalar(&zoneID, `select zone_id from chat_messages where message_key = $1`, z.ID+":1")
	if zoneChannel != 1 || account != pl.ID || world != 1 || zoneID != "vado_gris" {
		t.Fatalf("relleno de la instancia: canal %d cuenta %d mundo %d zona %s", zoneChannel, account, world, zoneID)
	}
	if n := p.Count(`select count(*) from chat_messages`); n != 3 {
		t.Fatal(n)
	}
	if strings.Contains(p.Logs.String(), "Vado Gris!") {
		t.Fatal("el texto del chat no va al registro")
	}
	p.Exec(`update zone_instances set status = 'lost' where zone_instance_id = $1`, z.ID)
	platformtest.Expect(t, z.Do("POST", "/internal/v1/chat", map[string]any{"zone_instance_id": z.ID,
		"messages": []any{msg(z.ID+":7", id, "tarde")}}), 204, "")
}

// Un reporte, un ignorado o una sanción con world_id en el cuerpo → 400; sin él, el nombre se
// resuelve en el mundo de la instancia (hay una «Bran» en cada mundo).
func TestWorldComesFromTheInstance(t *testing.T) {
	p := platformtest.New(t)
	w1 := p.NewZone(1, "vado_gris", 0).Start()
	w2 := p.NewZone(2, "vado_gris", 0).Start()
	gm := p.NewPlayer("gm@example.org")
	p.Exec(`update accounts set role = 'gm' where account_id = $1`, gm.ID)
	gmChar := p.NewCharacterIn(gm, 2, "Celadora", 1)
	b1 := p.NewPlayer("b1@example.org")
	p.NewCharacter(b1, "Bran", "vardheim")
	b2 := p.NewPlayer("b2@example.org")
	bran2 := p.NewCharacterIn(b2, 2, "Bran", 1)
	// El GM, dentro de la instancia del mundo 2.
	p.Exec(`insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, expires_at)
		values ($1, 2, gen_random_uuid(), $2, $2, $3)`, gmChar, w2.ID, p.Clock.Now().Add(30*time.Second))

	ignore := map[string]any{"zone_instance_id": w2.ID, "character_id": idStr(gmChar), "target_name": "Bran"}
	report := map[string]any{"zone_instance_id": w2.ID, "reporter_character_id": idStr(gmChar), "target_name": "bran",
		"category": "language", "comment": "insultos", "context": map[string]any{"zone": "vado_gris", "tick": 1200},
		"evidence": []any{map[string]any{"sender_name": "Bran", "channel": 2, "text": "…", "sent_at_unix": 1800000000}}}
	sanction := map[string]any{"zone_instance_id": w2.ID, "author_character_id": idStr(gmChar), "target_name": "BRAN",
		"kind": "mute", "minutes": 60, "reason": "insultos", "report_ids": []any{}}
	for path, body := range map[string]map[string]any{"/internal/v1/ignores": ignore, "/internal/v1/reports": report,
		"/internal/v1/sanctions": sanction} {
		withWorld := map[string]any{"world_id": 1}
		for k, v := range body {
			withWorld[k] = v
		}
		platformtest.Expect(t, w2.Do("POST", path, withWorld), 400, "bad_request")
	}

	res := w2.Do("POST", "/internal/v1/ignores", ignore)
	platformtest.Expect(t, res, 200, "")
	if res.String("ignored_account_id") != idStr(b2.ID) || res.String("name") != "Bran" {
		t.Fatalf("ignorado del mundo 2: %s", res.Raw)
	}
	res = w2.Do("POST", "/internal/v1/reports", report)
	platformtest.Expect(t, res, 200, "")
	reportID := res.String("report_id")
	var target, world int64
	p.Scalar(&target, `select target_character_id from reports where report_id = $1::bigint`, reportID)
	p.Scalar(&world, `select world_id from reports where report_id = $1::bigint`, reportID)
	if target != bran2 || world != 2 || p.Count(`select count(*) from report_evidence where report_id = $1::bigint`, reportID) != 1 {
		t.Fatalf("reporte: objetivo %d mundo %d", target, world)
	}
	sanction["report_ids"] = []any{reportID}
	res = w2.Do("POST", "/internal/v1/sanctions", sanction)
	platformtest.Expect(t, res, 200, "")
	if res.Int("ends_at_unix") != p.Clock.Now().Add(time.Hour).Unix() {
		t.Fatal(res.Raw)
	}
	var sanctioned int64
	p.Scalar(&sanctioned, `select account_id from sanctions where sanction_id = $1::bigint`, res.String("sanction_id"))
	if sanctioned != b2.ID || p.Count(`select count(*) from sanction_reports`) != 1 {
		t.Fatal("sanción en el mundo 2")
	}
	// Desde la instancia del mundo 1 el GM no tiene arrendamiento: 403.
	ignore["zone_instance_id"] = w1.ID
	platformtest.Expect(t, w1.Do("POST", "/internal/v1/ignores", ignore), 403, "forbidden")
}

// Ignorados (§9.3): con arrendamiento; no a uno mismo; nombre que no existe → 404; la reclamación
// trae las cuentas ignoradas; dejar de ignorar por el nombre que se escribió.
func TestIgnores(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	a := p.NewPlayer("a@example.org")
	idA := p.NewCharacter(a, "Aneira", "vardheim")
	alt := p.NewCharacter(a, "Alterna", "vardheim")
	b := p.NewPlayer("b@example.org")
	p.NewCharacter(b, "Bran", "vardheim")
	body := func(target string) map[string]any {
		return map[string]any{"zone_instance_id": z.ID, "character_id": idStr(idA), "target_name": target}
	}
	platformtest.Expect(t, z.Do("POST", "/internal/v1/ignores", body("Bran")), 403, "forbidden") // aún fuera
	z.Join(a, idA)
	platformtest.Expect(t, z.Do("POST", "/internal/v1/ignores", body("Bran")), 200, "")
	platformtest.Expect(t, z.Do("POST", "/internal/v1/ignores", body("brán")), 200, "") // la misma cuenta
	platformtest.Expect(t, z.Do("POST", "/internal/v1/ignores", body("Alterna")), 400, "validation")
	platformtest.Expect(t, z.Do("POST", "/internal/v1/ignores", body("Nadie")), 404, "not_found")
	if n := p.Count(`select count(*) from ignores where account_id = $1`, a.ID); n != 1 {
		t.Fatal(n)
	}
	// La reclamación siguiente trae la cuenta ignorada.
	lease := ""
	p.Scalar(&lease, `select lease_id::text from character_leases where character_id = $1`, idA)
	platformtest.Expect(t, z.Release(idA, lease), 204, "")
	ticket, _ := p.MustEnter(a, idA)
	res := z.Claim(ticket, idA)
	platformtest.Expect(t, res, 200, "")
	ids := res.Body["account"].(map[string]any)["ignored_account_ids"].([]any)
	if len(ids) != 1 || ids[0] != idStr(b.ID) {
		t.Fatalf("ignored_account_ids: %v", ids)
	}
	// Bran cambia de nombre: dejar de ignorar por el nombre escrito sigue valiendo.
	p.Exec(`update characters set name = 'Brandon', name_key = 'brandon' where account_id = $1`, b.ID)
	platformtest.Expect(t, z.Do("DELETE", "/internal/v1/ignores", body("Bran")), 204, "")
	platformtest.Expect(t, z.Do("DELETE", "/internal/v1/ignores", body("Bran")), 204, "")
	if n := p.Count(`select count(*) from ignores`); n != 0 {
		t.Fatal(n)
	}
	_ = alt
	// Hasta 100.
	for i := 0; i < 100; i++ {
		p.Exec(`insert into accounts (email, age_confirmed_at) values ($1, now())`, "x"+strconv.Itoa(i)+"@example.org")
		p.Exec(`insert into ignores (account_id, ignored_account_id, ignored_name)
			select $1, max(account_id), 'X' from accounts`, a.ID)
	}
	platformtest.Expect(t, z.Do("POST", "/internal/v1/ignores", body("Brandon")), 409, "ignore_list_full")
}

// Reportes (§9.4): con arrendamiento; 1 por objetivo cada 10 min y 10 por hora por cuenta (429).
func TestReportLimits(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	a := p.NewPlayer("a@example.org")
	idA := p.NewCharacter(a, "Aneira", "vardheim")
	z.Join(a, idA)
	targets := p.NewPlayer("t@example.org")
	for i := 0; i < 11; i++ {
		p.NewCharacterIn(targets, 1, "Objetivo"+string(rune('a'+i)), 1)
	}
	report := func(target string) *platformtest.Response {
		return z.Do("POST", "/internal/v1/reports", map[string]any{"zone_instance_id": z.ID,
			"reporter_character_id": idStr(idA), "target_name": target, "category": "bot", "comment": "",
			"context": map[string]any{"x": 1}, "evidence": []any{}})
	}
	platformtest.Expect(t, report("Objetivoa"), 200, "")
	res := report("objetivoa")
	platformtest.Expect(t, res, 429, "rate_limited")
	if res.Header.Get("Retry-After") == "" {
		t.Fatal("Retry-After")
	}
	for i := 1; i < 10; i++ {
		platformtest.Expect(t, report("Objetivo"+string(rune('a'+i))), 200, "")
	}
	platformtest.Expect(t, report("Objetivok"), 429, "rate_limited") // el 11.º en la hora
	p.Clock.Advance(61 * time.Minute)
	platformtest.Expect(t, report("Objetivok"), 200, "")
	platformtest.Expect(t, report("Objetivoa"), 200, "") // pasaron los 10 min
	// Cuerpos que no valen.
	bad := map[string]any{"zone_instance_id": z.ID, "reporter_character_id": idStr(idA), "target_name": "Objetivob",
		"category": "spam", "comment": "", "context": map[string]any{}, "evidence": []any{}}
	platformtest.Expect(t, z.Do("POST", "/internal/v1/reports", bad), 400, "validation")
	bad["category"], bad["context"] = "bot", []any{}
	platformtest.Expect(t, z.Do("POST", "/internal/v1/reports", bad), 400, "validation")
}

// Sanciones (§9.5): la plataforma autoriza. Un moderador que pide ban → 403 y fila
// sanction_denied (el objetivo por id, sin nombres); un GM no sanciona a un admin; sin
// arrendamiento → 403; un GM silencia (el latido y la reclamación lo dicen) y fuerza un
// renombrado (must_rename).
func TestSanctionAuthorization(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	mod := p.NewPlayer("mod@example.org")
	gm := p.NewPlayer("gm@example.org")
	admin := p.NewPlayer("admin@example.org")
	player := p.NewPlayer("p@example.org")
	p.Exec(`update accounts set role = 'moderator' where account_id = $1`, mod.ID)
	p.Exec(`update accounts set role = 'gm' where account_id = $1`, gm.ID)
	p.Exec(`update accounts set role = 'admin' where account_id = $1`, admin.ID)
	idMod := p.NewCharacter(mod, "Moderadora", "vardheim")
	idGM := p.NewCharacter(gm, "Celadora", "vardheim")
	p.NewCharacter(admin, "Jefa", "vardheim")
	idPlayer := p.NewCharacter(player, "Bran", "vardheim")
	z.Join(mod, idMod)
	leasePlayer := z.Join(player, idPlayer)
	sanction := func(author int64, target, kind string, minutes int) *platformtest.Response {
		return z.Do("POST", "/internal/v1/sanctions", map[string]any{"zone_instance_id": z.ID,
			"author_character_id": idStr(author), "target_name": target, "kind": kind, "minutes": minutes,
			"reason": "normas", "report_ids": []any{}})
	}
	platformtest.Expect(t, sanction(idMod, "Bran", "ban", 0), 403, "forbidden")
	platformtest.Expect(t, sanction(idMod, "Bran", "mute", 8*24*60), 403, "forbidden")
	platformtest.Expect(t, sanction(idGM, "Bran", "warning", 0), 403, "forbidden") // el GM aún no está dentro
	z.Join(gm, idGM)
	platformtest.Expect(t, sanction(idGM, "Jefa", "warning", 0), 403, "forbidden")
	platformtest.Expect(t, sanction(idGM, "Celadora", "warning", 0), 403, "forbidden") // a sí mismo
	denied := p.Count(`select count(*) from audit_log where source = 'platform' and command = 'sanction_denied'`)
	if denied != 5 {
		t.Fatalf("filas sanction_denied: %d", denied)
	}
	var args string
	p.Scalar(&args, `select args::text from audit_log where command = 'sanction_denied' order by id limit 1`)
	if strings.Contains(args, "Bran") || strings.Contains(args, "@") || !strings.Contains(args, `"denied": "role"`) {
		t.Fatalf("args sin nombres ni correos: %s", args)
	}
	if n := p.Count(`select count(*) from audit_log where command = 'sanction_denied' and target_account_id = $1
		and target_character_id = $2 and actor_account_id = $3`, player.ID, idPlayer, mod.ID); n != 2 {
		t.Fatalf("objetivo y autor por id: %d", n)
	}
	if n := p.Count(`select count(*) from sanctions`); n != 0 {
		t.Fatal("ninguna sanción")
	}

	platformtest.Expect(t, sanction(idMod, "Bran", "warning", 0), 200, "")
	res := sanction(idGM, "Bran", "mute", 30)
	platformtest.Expect(t, res, 200, "")
	until := p.Clock.Now().Add(30 * time.Minute).Unix()
	if res.Int("ends_at_unix") != until {
		t.Fatal(res.Raw)
	}
	hb := z.Heartbeat(3, platformtest.Lease{CharacterID: idPlayer, LeaseID: leasePlayer})
	mutes := hb.Body["mutes"].([]any)
	if len(mutes) != 1 || mutes[0].(map[string]any)["until_unix"].(json.Number).String() != strconv.FormatInt(until, 10) {
		t.Fatalf("mutes: %s", hb.Raw)
	}
	platformtest.Expect(t, sanction(idGM, "Bran", "rename", 0), 200, "")
	var mustRename bool
	p.Scalar(&mustRename, `select must_rename from characters where character_id = $1`, idPlayer)
	if !mustRename {
		t.Fatal("must_rename")
	}
	if n := p.Count(`select count(*) from audit_log where source = 'platform' and command = 'sanction'`); n != 3 {
		t.Fatalf("filas sanction: %d", n)
	}
	// La reclamación siguiente trae el silencio.
	platformtest.Expect(t, z.Release(idPlayer, leasePlayer), 204, "")
	p.Exec(`update characters set must_rename = false where character_id = $1`, idPlayer)
	ticket, _ := p.MustEnter(player, idPlayer)
	claim := z.Claim(ticket, idPlayer)
	platformtest.Expect(t, claim, 200, "")
	if claim.Body["account"].(map[string]any)["muted_until_unix"].(json.Number).String() != strconv.FormatInt(until, 10) {
		t.Fatal(claim.Raw)
	}
	// Cuerpos que no valen: un tipo desconocido, un silencio sin duración, una expulsión con ella,
	// un reporte que no existe.
	platformtest.Expect(t, sanction(idGM, "Bran", "jail", 0), 400, "validation")
	platformtest.Expect(t, sanction(idGM, "Bran", "mute", 0), 400, "validation")
	platformtest.Expect(t, sanction(idGM, "Bran", "ban", 60), 400, "validation")
	res = z.Do("POST", "/internal/v1/sanctions", map[string]any{"zone_instance_id": z.ID,
		"author_character_id": idStr(idGM), "target_name": "Bran", "kind": "warning", "minutes": 0,
		"reason": "normas", "report_ids": []any{"424242"}})
	platformtest.Expect(t, res, 400, "validation")
	platformtest.Expect(t, sanction(idGM, "Nadie", "warning", 0), 404, "not_found")
}
