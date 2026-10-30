package privacy_test

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/characters"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/privacy"
	"eldmark/platform/internal/progress"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

var ctx = context.Background()

const day = 24 * time.Hour

// newPlatform monta la plataforma con el almacén del progreso de verdad (lo que monta serve): la purga borra
// de verdad el estado, la retención vacía el libro y la exportación lo lee.
func newPlatform(t *testing.T) *platformtest.Platform {
	t.Helper()
	rules, err := progress.LoadRules(gamedata.Raw())
	if err != nil {
		t.Fatal(err)
	}
	return platformtest.NewWithProgress(t, func(now func() time.Time) persistence.ProgressStore {
		return progress.New(rules, now)
	}, rules)
}

func idText(id int64) string { return strconv.FormatInt(id, 10) }

// deleteCharacter borra el personaje por la API pública (con su nombre de confirmación).
func deleteCharacter(t *testing.T, p *platformtest.Platform, pl *platformtest.Player, id int64, name string) {
	t.Helper()
	platformtest.Expect(t, p.PublicDo("DELETE", "/v1/characters/"+idText(id), pl.Token,
		map[string]any{"confirm_name": name}), http.StatusOK, "")
}

// run hace una vuelta de las retenciones y falla si da error.
func run(t *testing.T, p *platformtest.Platform) privacy.Result {
	t.Helper()
	res, err := p.Privacy.Run(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// La exportación (§11.2) lleva todas las secciones y, en cada personaje, su progreso de ProgressStore.Export:
// el registro y el libro de uno vivo, solo el libro de una lápida que lo conserva, y null en una lápida sin
// libro. De la operación GM no sale ni el actor, ni la note, ni el detail.
func TestExportHasEverySectionAndTheProgress(t *testing.T) {
	p := newPlatform(t)
	gm := p.NewPlayer("gm@example.org")
	p.Exec(`update accounts set role = 'gm' where account_id = $1`, gm.ID)
	other := p.NewPlayer("otra@example.org")
	otherChar := p.NewCharacter(other, "Odalys", "vardheim")
	pl := p.NewPlayer("ana@example.org")
	alive := p.NewCharacter(pl, "Aneira", "vardheim")
	ledgered := p.NewCharacter(pl, "Brenna", "vardheim")
	bare := p.NewCharacter(pl, "Cora", "vardheim")
	now := p.Clock.Now()

	// El libro: una operación de juego y una GM de Aneira, y una de juego de Brenna.
	p.Exec(`insert into economy_ops (op_id, kind, zone_id) values (5001, 1, 'vado_gris'), (5003, 1, 'vado_gris')`)
	p.Exec(`insert into economy_ops (op_id, kind, actor_account_id, zone_id, note, detail)
		values (5002, 4, $1, 'vado_gris', 'devolución del fallo 12',
		'{"command": "currency_add", "source": "gm", "args": ["42", "oro", "50"]}')`, gm.ID)
	p.Exec(`insert into op_participants (op_id, character_id) values (5001, $1), (5002, $1), (5003, $2)`, alive, ledgered)
	p.Exec(`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
		values ($1, 1, 1, 5002, 50, 50, 7), ($2, 1, 1, 5003, 10, 10, 1)`, alive, ledgered)
	p.Exec(`insert into item_events (op_id, character_id, def_id, uid, reason, count_delta)
		values (5001, $1, 'potion_health', null, 64, -1)`, alive)

	// Las demás secciones, con una fila cada una.
	p.Exec(`insert into entitlements (account_id, world_id, kind, quantity, source) values ($1, 1, 'character_slots', 2, 'grant')`,
		pl.ID)
	p.Exec(`insert into ignores (account_id, ignored_account_id, ignored_character_id, ignored_name) values ($1, $2, $3, 'Odalys')`,
		pl.ID, other.ID, otherChar)
	p.Exec(`insert into sanctions (account_id, world_id, kind, reason, author_account_id, starts_at) values ($1, 1, 'warning',
		'lenguaje', $2, $3)`, pl.ID, gm.ID, now)
	p.Exec(`insert into reports (world_id, reporter_account_id, reporter_character_id, target_account_id, target_character_id,
		target_name, category, comment, context) values (1, $1, $2, $3, $4, 'Odalys', 'language', 'insultos', '{}')`,
		pl.ID, alive, other.ID, otherChar)
	p.Exec(`insert into chat_messages (world_id, zone_id, zone_channel, channel, sender_character_id, sender_account_id, text,
		sent_at, message_key) values (1, 'vado_gris', 0, 2, $1, $2, 'hola', $3, 'k1')`, alive, pl.ID, now)

	// Brenna y Cora, borrados y purgados a los 7 días: dos lápidas, una con libro.
	deleteCharacter(t, p, pl, ledgered, "Brenna")
	deleteCharacter(t, p, pl, bare, "Cora")
	p.Clock.Advance(7*day + time.Second)
	if err := p.Characters.Purger().PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	if n := p.Count(`select count(*) from characters where character_id = any($1) and purged_at is not null`,
		[]int64{ledgered, bare}); n != 2 {
		t.Fatalf("lápidas: %d", n)
	}

	p.Login(pl)
	res := p.PublicDo("POST", "/v1/account/export", pl.Token, map[string]any{"password": platformtest.Password})
	platformtest.Expect(t, res, http.StatusOK, "")
	for _, secret := range []string{"devolución", "currency_add", "actor_account_id", `"detail"`, `"note"`, "argon2",
		"gm@example.org", "author"} {
		if strings.Contains(res.Raw, secret) {
			t.Errorf("la exportación lleva %q: %s", secret, res.Raw)
		}
	}
	for _, key := range []string{"account", "legal_acceptances", "consents", "sessions", "access_events", "entitlements",
		"realms", "characters", "ignores", "sanctions", "reports", "chat"} {
		v, ok := res.Body[key]
		if list, isList := v.([]any); !ok || v == nil || (isList && len(list) == 0) {
			t.Errorf("sección %s vacía: %v", key, v)
		}
	}
	chars := map[string]map[string]any{}
	for _, c := range res.Body["characters"].([]any) {
		row := c.(map[string]any)
		chars[row["character_id"].(string)] = row
	}
	if len(chars) != 3 {
		t.Fatalf("personajes: %v", res.Body["characters"])
	}
	opsOf := func(prog map[string]any) map[string]map[string]any {
		out := map[string]map[string]any{}
		for _, o := range prog["ops"].([]any) {
			op := o.(map[string]any)
			out[op["op_id"].(string)] = op
		}
		return out
	}

	// Aneira: el registro y sus dos operaciones; la GM, con el tipo, la fecha y el apunte.
	prog, ok := chars[idText(alive)]["progress"].(map[string]any)
	if !ok {
		t.Fatalf("Aneira sin progreso: %v", chars[idText(alive)])
	}
	if rec, ok := prog["record"].(map[string]any); !ok || rec["race_id"] != "race_vardheim" {
		t.Fatalf("registro de Aneira: %v", prog["record"])
	}
	ops := opsOf(prog)
	gmOp := ops["5002"]
	if len(ops) != 2 || gmOp == nil || gmOp["kind"].(json.Number).String() != "4" || gmOp["created_at_unix"] == nil {
		t.Fatalf("operaciones de Aneira: %v", prog["ops"])
	}
	if want := []string{"created_at_unix", "items", "kind", "ledger", "op_id", "ref_op_id", "zone_id"}; !reflect.DeepEqual(
		sortedKeys(gmOp), want) {
		t.Errorf("claves de la GM: %v", sortedKeys(gmOp))
	}
	if entries := gmOp["ledger"].([]any); len(entries) != 1 || entries[0].(map[string]any)["delta"].(json.Number).String() != "50" {
		t.Errorf("apunte de la GM: %v", gmOp["ledger"])
	}
	if items := ops["5001"]["items"].([]any); len(items) != 1 || items[0].(map[string]any)["def_id"] != "potion_health" {
		t.Errorf("evento de objeto: %v", ops["5001"])
	}

	// Brenna: lápida con libro → sin registro y con su operación. Cora: lápida sin libro → null.
	tomb := chars[idText(ledgered)]
	prog, ok = tomb["progress"].(map[string]any)
	if !ok || prog["record"] != nil || tomb["purged_at"] == nil || tomb["name"] != nil {
		t.Fatalf("lápida con libro: %v", tomb)
	}
	if ops := opsOf(prog); len(ops) != 1 || ops["5003"] == nil {
		t.Fatalf("libro de la lápida: %v", prog["ops"])
	}
	if v, has := chars[idText(bare)]["progress"]; !has || v != nil {
		t.Fatalf("lápida sin libro: %v", chars[idText(bare)])
	}
	if len(res.Body["ignores"].([]any)) != 1 || res.Body["ignores"].([]any)[0].(map[string]any)["ignored_name"] != "Odalys" {
		t.Errorf("ignorados: %v", res.Body["ignores"])
	}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Las retenciones de la tabla de §11.1 borran lo que ha pasado su plazo y nada más: en cada tabla, una fila
// un minuto pasada del plazo y otra un minuto dentro. Un reporte abierto al año pasa a dismissed (caducado)
// y cuenta desde ahí; las sanciones de una cuenta purgada hace más de un año desaparecen y las de una purgada
// hace menos, o las de una viva, no. Una segunda vuelta no hace nada.
func TestRetentionsDeleteWhatExpiredAndNothingElse(t *testing.T) {
	p := newPlatform(t)
	now := p.Clock.Now()
	old := func(d time.Duration) time.Time { return now.Add(-d - time.Minute) }    // pasado el plazo
	recent := func(d time.Duration) time.Time { return now.Add(-d + time.Minute) } // dentro del plazo
	pl := p.NewPlayer("ana@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	z := p.NewZone(1, "vado_gris", 0).Start()

	// Accesos (30 días).
	p.Exec(`insert into auth_events (account_id, kind, user_agent, at) values ($1, 'login', 'ret-viejo', $2),
		($1, 'login', 'ret-nuevo', $3)`, pl.ID, old(privacy.AuthEventsRetention), recent(privacy.AuthEventsRetention))
	// Sesiones: caducada hace más de 7 días (se borra, con su billete); caducada hace menos pero abierta hace
	// más de 30 días (se queda sin IP ni agente); y una reciente, entera.
	var gone, stripped, kept int64
	session := func(created, refreshExpires time.Time, tag byte) int64 {
		var sid int64
		p.Scalar(&sid, `insert into sessions (account_id, access_hash, access_expires_at, refresh_hash, refresh_expires_at,
			ip, user_agent, created_at) values ($1, $2, $3, $4, $3, '203.0.113.9', 'ret-agente', $5) returning session_id`,
			pl.ID, []byte{tag, 1}, refreshExpires, []byte{tag, 2}, created)
		return sid
	}
	gone = session(old(privacy.ExpiredSessionRetention).Add(-12*time.Hour), old(privacy.ExpiredSessionRetention), 0xa1)
	stripped = session(old(privacy.SessionAccessRetention), recent(privacy.ExpiredSessionRetention), 0xa2)
	kept = session(recent(privacy.SessionAccessRetention), now.Add(time.Hour), 0xa3)
	// Enlaces (7 días desde que caducan).
	p.Exec(`insert into account_tokens (token_hash, account_id, purpose, email, expires_at, created_at)
		values ('\xb1', $1, 'reset_password', null, $2, $2), ('\xb2', $1, 'revert_email', 'vieja@example.org', $3, $3)`,
		pl.ID, old(privacy.ExpiredTokenRetention), recent(privacy.ExpiredTokenRetention))
	// Billetes (1 día desde que caducan): uno de la sesión que se borra, dos de la reciente.
	ticket := func(ticketID int64, sid int64, expires time.Time) {
		p.Exec(`insert into enter_tickets (ticket_id, world_id, character_id, session_id, zone_instance_id, issued_at,
			expires_at) values ($1, 1, $2, $3, $4, $5, $5)`, ticketID, id, sid, z.ID, expires)
	}
	ticket(9001, gone, now)
	ticket(9002, kept, old(privacy.TicketRetention))
	ticket(9003, kept, recent(privacy.TicketRetention))
	// Instancias terminadas (30 días): parada y sustituida hace más (con un bloque de ids, un arrendamiento y
	// una fortaleza que la nombran), perdida hace menos; la viva no se toca.
	instance := func(uuid, status string, ended time.Time) {
		p.Exec(`insert into zone_instances (zone_instance_id, world_id, zone_id, channel, public_host, public_port, realms,
			build_id, protocol_version, record_format, max_players, status, started_at, ended_at)
			values ($1, 1, 'vado_gris', 0, '203.0.113.5', 24600, '{1,2}', 'b', 7, 1, 64, $2, $3, $3)`, uuid, status, ended)
	}
	const stopped, replaced, lost = "00000000-0000-4000-8000-0000000000a1", "00000000-0000-4000-8000-0000000000a2",
		"00000000-0000-4000-8000-0000000000a3"
	instance(stopped, "stopped", old(privacy.InstanceRetention))
	instance(replaced, "replaced", old(privacy.InstanceRetention))
	instance(lost, "lost", recent(privacy.InstanceRetention))
	p.Exec(`insert into id_blocks (first_id, zone_instance_id) values (900001, $1), (901025, $2)`, stopped, lost)
	p.Exec(`insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, expires_at)
		values ($1, 1, $2, $2, $2, $3)`, id, replaced, old(privacy.InstanceRetention))
	p.Exec(`insert into fortresses (world_id, fortress_id, zone_id, record, updated_by) values (1, 'f1', 'vado_gris', '{}', $1)`,
		stopped)
	// Correos de prueba (7 días).
	p.Exec(`insert into outbound_mail (to_email, template, body, created_at) values ('a@example.org', 'ret-viejo', '', $1),
		('a@example.org', 'ret-nuevo', '', $2)`, old(privacy.MailRetention), recent(privacy.MailRetention))
	// Reportes (1 año desde el cierre): cerrado hace más (con su prueba y la sanción que lo cita), cerrado hace
	// menos, abierto desde hace más (se cierra ahora) y en revisión desde hace menos.
	report := func(status string, created time.Time, closed *time.Time) int64 {
		var rid int64
		p.Scalar(&rid, `insert into reports (world_id, reporter_account_id, target_name, category, context, status,
			created_at, closed_at) values (1, $1, 'Odalys', 'language', '{}', $2, $3, $4) returning report_id`,
			pl.ID, status, created, closed)
		p.Exec(`insert into report_evidence (report_id, seq, sender_name, channel, text, sent_at) values ($1, 0, 'Odalys', 2,
			'insulto', $2)`, rid, created)
		return rid
	}
	closedOld, closedRecent := old(privacy.ReportRetention), recent(privacy.ReportRetention)
	r1 := report("actioned", closedOld.Add(-day), &closedOld)
	r2 := report("dismissed", closedRecent.Add(-day), &closedRecent)
	r3 := report("open", old(privacy.ReportRetention), nil)
	r4 := report("in_review", recent(privacy.ReportRetention), nil)
	// Auditoría (1 año).
	p.Exec(`insert into audit_log (source, command, args, at) values ('platform', 'ret_viejo', '{}', $1),
		('platform', 'ret_nuevo', '{}', $2)`, old(privacy.AuditRetention), recent(privacy.AuditRetention))
	// Sanciones: de una cuenta purgada hace más de un año (una cita el reporte r2), de una purgada hace menos y
	// una de hace dos años de una cuenta viva.
	purgedLong := p.NewPlayer("vieja@example.org")
	purgedShort := p.NewPlayer("reciente@example.org")
	for acc, at := range map[int64]time.Time{purgedLong.ID: old(privacy.PurgedSanctionRetention),
		purgedShort.ID: recent(privacy.PurgedSanctionRetention)} {
		p.Exec(`update accounts set email = null, password_hash = null, status = 'purged', purged_at = $2 where account_id = $1`,
			acc, at)
	}
	sanction := func(acc int64, at time.Time) int64 {
		var sid int64
		p.Scalar(&sid, `insert into sanctions (account_id, kind, reason, starts_at, created_at) values ($1, 'warning', '', $2, $2)
			returning sanction_id`, acc, at)
		return sid
	}
	s1 := sanction(purgedLong.ID, now.Add(-2*365*day))
	sanction(purgedShort.ID, now.Add(-2*365*day))
	sanction(pl.ID, now.Add(-2*365*day))
	p.Exec(`insert into sanction_reports (sanction_id, report_id) values ($1, $2)`, s1, r2)
	// Huellas de correos sancionados: vencida y vigente.
	p.Exec(`insert into sanctioned_email_hashes (hmac, until) values ('\xc1', $1), ('\xc2', $2)`,
		now.Add(-time.Minute), now.Add(time.Minute))
	// Nombres reservados: vencido y en plazo (el activo de Aneira no se toca).
	p.Exec(`insert into character_names (world_id, name_key, status, reserved_until) values (1, 'vencido', 'reserved', $1),
		(1, 'reservado', 'reserved', $2)`, now.Add(-time.Minute), now.Add(time.Minute))
	// El chat no es de este trabajo (social.ChatRetentionJob): ni uno de hace un año se toca.
	p.Exec(`insert into chat_messages (world_id, zone_id, zone_channel, channel, sender_character_id, sender_account_id, text,
		sent_at, message_key) values (1, 'vado_gris', 0, 2, $1, $2, 'hola', $3, 'k1')`, id, pl.ID, now.Add(-365*day))

	res := run(t, p)
	want := privacy.Result{privacy.StepReportsClosed: 1, privacy.StepReports: 1, privacy.StepAudit: 1,
		privacy.StepSanctions: 1, privacy.StepSanctionedEmails: 1, privacy.StepAuthEvents: 1, privacy.StepSessionAccess: 1,
		privacy.StepSessions: 1, privacy.StepTokens: 1, privacy.StepTickets: 1, privacy.StepInstances: 2,
		privacy.StepMail: 1, privacy.StepNames: 1, privacy.StepLedger: 0, privacy.StepLedgerTombstones: 0}
	if !reflect.DeepEqual(res, want) {
		t.Fatalf("vuelta: %v\nse esperaba %v", res, want)
	}
	for _, c := range []struct {
		what string
		sql  string
		args []any
		want int
	}{
		{"accesos", `select count(*) from auth_events where user_agent like 'ret-%'`, nil, 1},
		{"el acceso que queda", `select count(*) from auth_events where user_agent = 'ret-nuevo'`, nil, 1},
		{"sesión caducada", `select count(*) from sessions where session_id = $1`, []any{gone}, 0},
		{"sesión vieja sin IP", `select count(*) from sessions where session_id = $1 and ip is null and user_agent is null`,
			[]any{stripped}, 1},
		{"sesión reciente", `select count(*) from sessions where session_id = $1 and ip is not null and user_agent = 'ret-agente'`,
			[]any{kept}, 1},
		{"enlaces", `select count(*) from account_tokens where token_hash in ('\xb1', '\xb2')`, nil, 1},
		{"el enlace que queda", `select count(*) from account_tokens where token_hash = '\xb2'`, nil, 1},
		{"billetes", `select count(*) from enter_tickets where ticket_id in (9001, 9002, 9003)`, nil, 1},
		{"el billete que queda", `select count(*) from enter_tickets where ticket_id = 9003`, nil, 1},
		{"instancias", `select count(*) from zone_instances where zone_instance_id in ($1, $2, $3)`,
			[]any{stopped, replaced, lost}, 1},
		{"la instancia viva", `select count(*) from zone_instances where zone_instance_id = $1 and status = 'live'`,
			[]any{z.ID}, 1},
		{"bloques de ids", `select count(*) from id_blocks where first_id in (900001, 901025)`, nil, 1},
		{"arrendamiento sin instancia", `select count(*) from character_leases where character_id = $1
			and zone_instance_id is null`, []any{id}, 1},
		{"fortaleza sin instancia", `select count(*) from fortresses where fortress_id = 'f1' and updated_by is null`, nil, 1},
		{"correos", `select count(*) from outbound_mail where template like 'ret-%'`, nil, 1},
		{"el correo que queda", `select count(*) from outbound_mail where template = 'ret-nuevo'`, nil, 1},
		{"reportes", `select count(*) from reports where report_id in ($1, $2, $3, $4)`, []any{r1, r2, r3, r4}, 3},
		{"el cerrado viejo", `select count(*) from reports where report_id = $1`, []any{r1}, 0},
		{"su prueba", `select count(*) from report_evidence where report_id = $1`, []any{r1}, 0},
		{"las pruebas que quedan", `select count(*) from report_evidence where report_id in ($1, $2, $3)`,
			[]any{r2, r3, r4}, 3},
		{"el abierto, caducado", `select count(*) from reports where report_id = $1 and status = 'dismissed'
			and closed_at = $2 and resolution = 'caducado'`, []any{r3, now}, 1},
		{"el abierto reciente, igual", `select count(*) from reports where report_id = $1 and status = 'in_review'
			and closed_at is null and resolution is null`, []any{r4}, 1},
		{"auditoría", `select count(*) from audit_log where command like 'ret_%'`, nil, 1},
		{"la auditoría que queda", `select count(*) from audit_log where command = 'ret_nuevo'`, nil, 1},
		{"sanciones de la purgada hace más de un año", `select count(*) from sanctions where account_id = $1`,
			[]any{purgedLong.ID}, 0},
		{"su enlace con el reporte", `select count(*) from sanction_reports where sanction_id = $1`, []any{s1}, 0},
		{"sanciones de la purgada hace menos", `select count(*) from sanctions where account_id = $1`, []any{purgedShort.ID}, 1},
		{"sanciones de una cuenta viva", `select count(*) from sanctions where account_id = $1`, []any{pl.ID}, 1},
		{"las dos cuentas purgadas siguen como lápida", `select count(*) from accounts where account_id in ($1, $2)
			and status = 'purged'`, []any{purgedLong.ID, purgedShort.ID}, 2},
		{"huellas", `select count(*) from sanctioned_email_hashes where hmac in ('\xc1', '\xc2')`, nil, 1},
		{"la huella vigente", `select count(*) from sanctioned_email_hashes where hmac = '\xc2'`, nil, 1},
		{"nombres", `select count(*) from character_names where name_key in ('vencido', 'reservado', 'aneira')`, nil, 2},
		{"el nombre vencido", `select count(*) from character_names where name_key = 'vencido'`, nil, 0},
		{"el chat", `select count(*) from chat_messages`, nil, 1},
		{"el personaje", `select count(*) from characters where character_id = $1 and purged_at is null`, []any{id}, 1},
	} {
		if got := p.Count(c.sql, c.args...); got != c.want {
			t.Errorf("%s: %d, se esperaban %d", c.what, got, c.want)
		}
	}
	if again := run(t, p); again.Total() != 0 {
		t.Fatalf("una segunda vuelta borra más: %v", again)
	}
	// Al año del cierre automático, el reporte caducado se borra como cualquier cerrado.
	p.Clock.Advance(privacy.ReportRetention + time.Second)
	run(t, p)
	if n := p.Count(`select count(*) from reports where report_id = $1`, r3); n != 0 {
		t.Fatal("el reporte caducado no se borra al año de cerrarse")
	}
}

// La retención del libro (§11.1, progresion.md §3.5): al año de su purga, el libro de un personaje se borra
// en varias transacciones (más de un lote de 10 000 apuntes) y después su lápida; la operación que comparte
// con un personaje vivo se queda para él. Una lápida sin libro se borra también al año; una purgada dos días
// después, y el vivo, se quedan. La cuenta y purge_log no se tocan.
func TestLedgerRetentionEmptiesAndRemovesTombstones(t *testing.T) {
	p := newPlatform(t)
	pl := p.NewPlayer("ana@example.org")
	alive := p.NewCharacter(pl, "Aneira", "vardheim")
	big := p.NewCharacter(pl, "Brenna", "vardheim")
	bare := p.NewCharacter(pl, "Cora", "vardheim")
	later := p.NewCharacter(pl, "Dalia", "vardheim")
	const entries = progress.RetentionBatch + 50
	p.Exec(`insert into economy_ops (op_id, kind, zone_id) values (7001, 1, 'vado_gris'), (7002, 1, 'vado_gris'),
		(7003, 1, 'vado_gris')`)
	p.Exec(`insert into op_participants (op_id, character_id) values (7001, $1), (7002, $1), (7002, $2), (7003, $3)`,
		big, alive, later)
	p.Exec(`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
		select $1, 1, n, 7001, 1, n, 1 from generate_series(1, $2::int) n`, big, entries)
	p.Exec(`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
		values ($1, 2, 1, 7002, 5, 5, 3), ($2, 2, 1, 7002, 5, 5, 3), ($3, 1, 1, 7003, 1, 1, 1)`, big, alive, later)
	p.Exec(`insert into item_events (op_id, character_id, def_id, uid, reason, count_delta) values (7001, $1, 'potion_health',
		null, 64, -1)`, big)
	deleteCharacter(t, p, pl, big, "Brenna")
	deleteCharacter(t, p, pl, bare, "Cora")
	p.Clock.Advance(2 * day)
	p.Login(pl)
	deleteCharacter(t, p, pl, later, "Dalia")
	p.Clock.Advance(5*day + time.Second)
	purger := p.Characters.Purger()
	if err := purger.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	var purgedAt time.Time
	p.Scalar(&purgedAt, `select purged_at from characters where character_id = $1`, big)
	p.Clock.Advance(2 * day)
	if err := purger.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	if n := p.Count(`select count(*) from characters where purged_at is not null`); n != 3 {
		t.Fatalf("lápidas: %d", n)
	}

	// Antes del año no se borra nada.
	p.Clock.Set(purgedAt.Add(progress.Retention - time.Second))
	if res := run(t, p); res[privacy.StepLedger] != 0 || res[privacy.StepLedgerTombstones] != 0 {
		t.Fatalf("antes del año: %v", res)
	}
	p.Clock.Set(purgedAt.Add(progress.Retention + time.Second))
	res := run(t, p)
	// Brenna: sus apuntes, el evento, sus dos participaciones y la operación 7001 (la 7002 es también de Aneira).
	if want := int64(entries + 1 + 1 + 2 + 1); res[privacy.StepLedger] != want || res[privacy.StepLedgerTombstones] != 2 {
		t.Fatalf("al año: %v (se esperaban %d filas del libro y 2 lápidas)", res, want)
	}
	for _, c := range []struct {
		what string
		sql  string
		args []any
		want int
	}{
		{"las lápidas de Brenna y Cora", `select count(*) from characters where character_id = any($1)`,
			[]any{[]int64{big, bare}}, 0},
		{"la lápida de Dalia, con su libro", `select count(*) from ledger_entries where character_id = $1`, []any{later}, 1},
		{"Dalia sigue", `select count(*) from characters where character_id = $1 and purged_at is not null`, []any{later}, 1},
		{"el libro de Aneira", `select count(*) from ledger_entries where character_id = $1`, []any{alive}, 1},
		{"la operación compartida", `select count(*) from op_participants where op_id = 7002`, nil, 1},
		{"operaciones", `select count(*) from economy_ops where op_id in (7001, 7002, 7003)`, nil, 2},
		{"libro de Brenna", `select count(*) from ledger_entries where character_id = $1`, []any{big}, 0},
		{"purge_log", `select count(*) from purge_log where kind = 'character'`, nil, 3},
		{"la cuenta", `select count(*) from accounts where account_id = $1 and status = 'active'`, []any{pl.ID}, 1},
	} {
		if got := p.Count(c.sql, c.args...); got != c.want {
			t.Errorf("%s: %d, se esperaban %d", c.what, got, c.want)
		}
	}
	if again := run(t, p); again.Total() != 0 {
		t.Fatalf("una segunda vuelta borra más: %v", again)
	}
	// La marca de la retención no sobrevive a su transacción: fuera, el libro sigue siendo de solo añadir.
	if _, err := p.Pool.Exec(ctx, `delete from ledger_entries where character_id = $1`, alive); err == nil {
		t.Fatal("se pudo borrar el libro fuera de la retención")
	}
}

// Una restauración en el límite y la purga horaria a la vez (§4.4, §11.2): la restauración ve el último
// segundo de plazo y la purga el primero después; gana una y el personaje queda entero (vivo, con nombre y
// progreso, sin fila en purge_log) o purgado (lápida sin progreso y 404 a la restauración), nunca a medias.
func TestRestoreAtTheLimitRacesTheHourlyPurge(t *testing.T) {
	p := newPlatform(t)
	outcomes := map[int]int{}
	for round := 0; round < 10; round++ {
		pl := p.NewPlayer("carrera" + strconv.Itoa(round) + "@example.org")
		name := "Carrera" + string(rune('a'+round))
		id := p.NewCharacter(pl, name, "vardheim")
		deleteCharacter(t, p, pl, id, name)
		var until time.Time
		p.Scalar(&until, `select restore_until from characters where character_id = $1`, id)
		p.Clock.Set(until.Add(-time.Second))
		p.Login(pl)
		purger := characters.NewPurger(p.Pool, p.ProgressStore, clock.NewFake(until.Add(time.Second)), nil)
		start := make(chan struct{})
		var wg sync.WaitGroup
		var status int
		var purgeErr error
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			status = p.PublicDo("POST", "/v1/characters/"+idText(id)+"/restore", pl.Token, nil).Status
		}()
		go func() {
			defer wg.Done()
			<-start
			purgeErr = purger.PurgeExpired(ctx)
		}()
		close(start)
		wg.Wait()
		if purgeErr != nil {
			t.Fatal(purgeErr)
		}
		outcomes[status]++
		whole := p.Count(`select count(*) from characters c join character_names n on n.character_id = c.character_id
			where c.character_id = $1 and c.deleted_at is null and c.purged_at is null and c.name is not null
			and n.status = 'active'`, id)
		purged := p.Count(`select count(*) from characters where character_id = $1 and purged_at is not null and name is null`, id)
		state := p.Count(`select count(*) from character_progress where character_id = $1`, id)
		logged := p.Count(`select count(*) from purge_log where kind = 'character' and id = $1`, id)
		switch status {
		case http.StatusOK:
			if whole != 1 || purged != 0 || state != 1 || logged != 0 {
				t.Fatalf("ronda %d: restaurado a medias (entero %d, lápida %d, progreso %d, purge_log %d)", round, whole,
					purged, state, logged)
			}
		case http.StatusNotFound:
			if whole != 0 || purged != 1 || state != 0 || logged != 1 {
				t.Fatalf("ronda %d: purgado a medias (entero %d, lápida %d, progreso %d, purge_log %d)", round, whole,
					purged, state, logged)
			}
		default:
			t.Fatalf("ronda %d: la restauración da %d", round, status)
		}
	}
	t.Logf("restaurados %d, purgados %d", outcomes[http.StatusOK], outcomes[http.StatusNotFound])
}

// Una cuenta expulsada exporta y pide la supresión con su sesión de privacidad, y se purga; su correo no
// vuelve a registrarse hasta que vence su huella (un año desde la purga: la expulsión es permanente), que la
// retención borra. Lo mismo con una suspendida que se suprime con purge-now: la huella dura hasta 90 días
// tras el fin de la suspensión (§11.2).
func TestSanctionedAccountsArePurgedAndTheirEmailWaits(t *testing.T) {
	p := newPlatform(t)
	adm := p.NewPlayer("admin@example.org")
	p.Exec(`update accounts set role = 'admin' where account_id = $1`, adm.ID)
	register := func(email string) bool {
		t.Helper()
		res := p.PublicDo("POST", "/v1/accounts", "", map[string]any{"email": email, "password": platformtest.Password,
			"age_confirmed": true, "accept": map[string]any{"terms": 1, "privacy": 1, "rules": 1},
			"consents": map[string]any{"crash_reports": false, "analytics": false}})
		platformtest.Expect(t, res, http.StatusAccepted, "")
		return p.Count(`select count(*) from accounts where email = $1`, email) == 1
	}

	banned := p.NewPlayer("expulsada@example.org")
	char := p.NewCharacter(banned, "Bruna", "vardheim")
	p.Exec(`insert into sanctions (account_id, kind, reason, author_account_id, starts_at) values ($1, 'ban', 'trampas', $2, $3)`,
		banned.ID, adm.ID, p.Clock.Now())
	p.Login(banned)
	if scope := p.Count(`select count(*) from sessions where account_id = $1 and scope = 'privacy' and revoked_at is null`,
		banned.ID); scope != 1 {
		t.Fatal("sin sesión de privacidad")
	}
	exp := p.PublicDo("POST", "/v1/account/export", banned.Token, map[string]any{"password": platformtest.Password})
	platformtest.Expect(t, exp, http.StatusOK, "")
	chars := exp.Body["characters"].([]any)
	if len(chars) != 1 || chars[0].(map[string]any)["progress"].(map[string]any)["record"] == nil ||
		len(exp.Body["sanctions"].([]any)) != 1 {
		t.Fatalf("exportación de la expulsada: %s", exp.Raw)
	}
	platformtest.Expect(t, p.PublicDo("POST", "/v1/account/deletion", banned.Token,
		map[string]any{"password": platformtest.Password}), http.StatusAccepted, "")
	p.Clock.Advance(14*day + time.Second)
	if err := p.Accounts.PurgeDue(ctx); err != nil {
		t.Fatal(err)
	}
	purgedAt := p.Clock.Now()
	if n := p.Count(`select count(*) from accounts where account_id = $1 and status = 'purged' and email is null`,
		banned.ID); n != 1 {
		t.Fatal("la expulsada no se purga")
	}
	if n := p.Count(`select count(*) from characters where character_id = $1 and purged_at = $2`, char, purgedAt); n != 1 {
		t.Fatal("su personaje no queda como lápida")
	}
	var until time.Time
	p.Scalar(&until, `select until from sanctioned_email_hashes`)
	if !until.Equal(purgedAt.Add(365 * day)) {
		t.Fatalf("huella de la expulsada hasta %v", until)
	}
	if register("expulsada@example.org") {
		t.Fatal("el correo de la expulsada vuelve a registrarse")
	}
	p.Clock.Set(until.Add(-time.Second))
	if res := run(t, p); res[privacy.StepSanctionedEmails] != 0 || register("expulsada@example.org") {
		t.Fatal("la huella vence antes de tiempo")
	}
	p.Clock.Set(until)
	if res := run(t, p); res[privacy.StepSanctionedEmails] != 1 {
		t.Fatalf("la huella vencida no se borra: %v", res)
	}
	if !register("expulsada@example.org") {
		t.Fatal("pasado su plazo, el correo no se registra")
	}

	// Suspendida tres días y suprimida con purge-now.
	suspended := p.NewPlayer("suspendida@example.org")
	ends := p.Clock.Now().Add(3 * day)
	p.Exec(`insert into sanctions (account_id, kind, reason, author_account_id, starts_at, ends_at)
		values ($1, 'suspension', 'acoso', $2, $3, $4)`, suspended.ID, adm.ID, p.Clock.Now(), ends)
	if res, err := p.Admin.PurgeNow(ctx, &admin.Actor{AccountID: adm.ID, Role: "admin"}, "suspendida@example.org",
		time.Second); err != nil || !res.Purged {
		t.Fatalf("purge-now: %+v %v", res, err)
	}
	p.Scalar(&until, `select until from sanctioned_email_hashes`)
	if !until.Equal(ends.Add(90 * day)) {
		t.Fatalf("huella de la suspendida hasta %v, se esperaba %v", until, ends.Add(90*day))
	}
	p.Clock.Advance(4 * day)
	if register("suspendida@example.org") {
		t.Fatal("el correo de la suspendida vuelve a registrarse")
	}
	p.Clock.Set(until.Add(time.Second))
	run(t, p)
	if n := p.Count(`select count(*) from sanctioned_email_hashes`); n != 0 || !register("suspendida@example.org") {
		t.Fatal("pasado su plazo, la huella de la suspendida sigue")
	}
}
