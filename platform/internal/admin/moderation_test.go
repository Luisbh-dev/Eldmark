package admin_test

import (
	"errors"
	"strings"
	"testing"
	"time"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/sanctions"
)

// reportFrom sends a report through the internal API (§9.4) with two test messages.
func reportFrom(t *testing.T, z *platformtest.Zone, reporter int64, target string) string {
	t.Helper()
	res := z.Do("POST", "/internal/v1/reports", map[string]any{"zone_instance_id": z.ID,
		"reporter_character_id": idStr(reporter), "target_name": target, "category": "harassment",
		"comment": "me sigue insultando", "context": map[string]any{"zone": "vado_gris", "tick": 1200},
		"evidence": []any{
			map[string]any{"sender_name": target, "channel": 3, "text": "eres malísima", "sent_at_unix": 1800000000},
			map[string]any{"sender_name": target, "channel": 3, "text": "vete del juego", "sent_at_unix": 1800000010},
		}})
	platformtest.Expect(t, res, 200, "")
	return res.String("report_id")
}

// reports list|show|close: a moderator reads the queue and a report with its evidence (each read
// leaves its row, with the target by id); only an admin closes it, once.
func TestReports(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	_, mod := staff(t, p, "mod@example.org", sanctions.RoleModerator)
	_, adm := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	a := p.NewPlayer("a@example.org")
	idA := p.NewCharacter(a, "Aneira", "vardheim")
	b := p.NewPlayer("b@example.org")
	idB := p.NewCharacter(b, "Bran", "vardheim")
	z.Join(a, idA)
	reportID := reportFrom(t, z, idA, "Bran")

	list, err := p.Admin.Reports(ctx, mod, admin.ReportFilter{})
	if err != nil || len(list) != 1 || idStr(list[0].ID) != reportID || list[0].Evidence != 2 ||
		*list[0].ReporterName != "Aneira" || list[0].TargetName != "Bran" || list[0].Status != "open" {
		t.Fatalf("%+v %v", list, err)
	}
	row := lastAudit(t, p, "reports list")
	if !is(row.Actor, mod.AccountID) || row.Args["status"] != "open" || row.Source != "cli" {
		t.Fatalf("%+v", row)
	}
	id := list[0].ID
	d, err := p.Admin.Report(ctx, mod, id)
	if err != nil || len(d.Evidence) != 2 || d.Evidence[1].Text != "vete del juego" || !is(d.TargetCharacterID, idB) ||
		!strings.Contains(string(d.Context), "vado_gris") {
		t.Fatalf("%+v %v", d, err)
	}
	row = lastAudit(t, p, "reports show")
	if !is(row.Actor, mod.AccountID) || !is(row.TargetAccount, b.ID) || !is(row.TargetCharacter, idB) ||
		row.Args["report_id"] != reportID || row.World == nil || *row.World != 1 {
		t.Fatalf("%+v", row)
	}
	if _, err := p.Admin.Report(ctx, mod, 424242); !errors.Is(err, admin.ErrReportNotFound) {
		t.Fatal(err)
	}
	// Closing is admin-only: with the moderator's account it does not get past Authorize.
	var actorErr *admin.ActorError
	if _, err := p.Admin.Authorize(ctx, "mod@example.org", sanctions.RoleAdmin); !errors.As(err, &actorErr) {
		t.Fatal(err)
	}
	if err := p.Admin.CloseReport(ctx, mod, id, "dismissed", ""); !errors.As(err, &actorErr) {
		t.Fatalf("un moderador no cierra: %v", err)
	}
	if err := p.Admin.CloseReport(ctx, adm, id, "open", ""); err == nil {
		t.Fatal("estado de cierre")
	}
	if err := p.Admin.CloseReport(ctx, adm, id, "actioned", "silencio de 24 h"); err != nil {
		t.Fatal(err)
	}
	if err := p.Admin.CloseReport(ctx, adm, id, "dismissed", ""); !errors.Is(err, admin.ErrReportClosed) {
		t.Fatal(err)
	}
	var handled int64
	var resolution string
	p.Scalar(&handled, `select handled_by from reports where report_id = $1`, id)
	p.Scalar(&resolution, `select resolution from reports where report_id = $1`, id)
	if handled != adm.AccountID || resolution != "silencio de 24 h" {
		t.Fatal(handled, resolution)
	}
	row = lastAudit(t, p, "reports close")
	if row.Args["status"] != "actioned" || row.Args["resolution"] != nil {
		t.Fatalf("%+v", row)
	}
	if list, _ := p.Admin.Reports(ctx, mod, admin.ReportFilter{}); len(list) != 0 {
		t.Fatal("cerrado no está en la cola")
	}
	if list, _ := p.Admin.Reports(ctx, mod, admin.ReportFilter{Status: "all"}); len(list) != 1 {
		t.Fatal("all")
	}
	if _, err := p.Admin.Reports(ctx, mod, admin.ReportFilter{Status: "raro"}); err == nil {
		t.Fatal("estado desconocido")
	}
}

// chat (SOC-15): a character's history between two dates (what it sent and the whispers it
// received, with the zone and its copy), audited; the 30-day retention deletes what has expired and
// the query stops seeing it.
func TestChatHistoryAndRetention(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 1).Start()
	_, mod := staff(t, p, "mod@example.org", sanctions.RoleModerator)
	a := p.NewPlayer("a@example.org")
	idA := p.NewCharacter(a, "Aneira", "vardheim")
	b := p.NewPlayer("b@example.org")
	idB := p.NewCharacter(b, "Bran", "vardheim")
	now := p.Clock.Now()
	n := 0
	msg := func(sender int64, target *int64, channel int, ago time.Duration, text string) map[string]any {
		n++
		m := map[string]any{"key": z.ID + ":" + idStr(int64(n)), "channel": channel, "sender_character_id": idStr(sender),
			"target_character_id": nil, "text": text, "sent_at_unix": now.Add(-ago).Unix()}
		if target != nil {
			m["target_character_id"] = idStr(*target)
		}
		return m
	}
	res := z.Do("POST", "/internal/v1/chat", map[string]any{"zone_instance_id": z.ID, "messages": []any{
		msg(idB, nil, 2, 40*24*time.Hour, "hace cuarenta días"),
		msg(idB, nil, 2, 10*24*time.Hour, "hace diez días"),
		msg(idA, &idB, 3, 2*time.Hour, "susurro a Bran"),
		msg(idB, nil, 1, time.Hour, "hace una hora"),
		msg(idA, nil, 2, time.Hour, "de Aneira, no sale"),
	}})
	platformtest.Expect(t, res, 204, "")
	who, lines, err := p.Admin.Chat(ctx, mod, admin.ChatQuery{World: 1, Character: "bran", From: now.Add(-11 * 24 * time.Hour),
		To: now})
	if err != nil || who.ID != idB || len(lines) != 3 {
		t.Fatalf("%v %v", lines, err)
	}
	if lines[0].Text != "hace diez días" || lines[1].Text != "susurro a Bran" || *lines[1].TargetName != "Bran" ||
		*lines[1].SenderName != "Aneira" || lines[2].Text != "hace una hora" {
		t.Fatalf("orden y contenido: %+v", lines)
	}
	for _, l := range lines {
		if l.ZoneID != "vado_gris" || l.ZoneChannel != 1 {
			t.Fatalf("zona y copia: %+v", l)
		}
	}
	row := lastAudit(t, p, "chat")
	if !is(row.TargetCharacter, idB) || !is(row.TargetAccount, b.ID) || !is(row.Actor, mod.AccountID) ||
		row.Args["from"] != now.Add(-11*24*time.Hour).UTC().Format(time.RFC3339) || row.Args["os_user"] != "prueba" {
		t.Fatalf("%+v", row)
	}
	all := admin.ChatQuery{World: 1, Character: "Bran", From: now.Add(-50 * 24 * time.Hour), To: now.Add(time.Hour)}
	if _, lines, _ := p.Admin.Chat(ctx, mod, all); len(lines) != 4 {
		t.Fatalf("con lo de hace cuarenta días: %d", len(lines))
	}
	// The retention (hourly job chat_retention) deletes what is older than 30 days and nothing else.
	deleted, err := p.Social.PurgeChat(ctx)
	if err != nil || deleted != 1 {
		t.Fatalf("borrados %d: %v", deleted, err)
	}
	if _, lines, _ := p.Admin.Chat(ctx, mod, all); len(lines) != 3 {
		t.Fatalf("lo caducado desaparece: %d", len(lines))
	}
	p.Clock.Advance(20*24*time.Hour + time.Second)
	if deleted, _ := p.Social.PurgeChat(ctx); deleted != 1 {
		t.Fatalf("a los 20 días más, el de hace diez: %d", deleted)
	}
	if n := p.Count(`select count(*) from chat_messages`); n != 3 {
		t.Fatal(n)
	}
	// Dates reversed, character that does not exist.
	if _, _, err := p.Admin.Chat(ctx, mod, admin.ChatQuery{World: 1, Character: "Bran", From: now, To: now}); err == nil {
		t.Fatal("rango vacío")
	}
	q := all
	q.Character = "Nadie"
	if _, _, err := p.Admin.Chat(ctx, mod, q); !errors.Is(err, admin.ErrCharacterNotFound) {
		t.Fatal(err)
	}
}

// audit: the query with --since, --actor-name and --target, itself audited (without the names
// typed).
func TestAuditQuery(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	_, mod := staff(t, p, "mod@example.org", sanctions.RoleModerator)
	gm, _ := staff(t, p, "gm@example.org", sanctions.RoleGM)
	idGM := p.NewCharacter(gm, "Celadora", "vardheim")
	b := p.NewPlayer("b@example.org")
	idB := p.NewCharacter(b, "Bran", "vardheim")
	c := p.NewPlayer("c@example.org")
	idC := p.NewCharacter(c, "Cora", "vardheim")
	since := p.Clock.Now().Add(-time.Hour)
	entry := func(n int, target int64, targetAccount int64, command string, ago time.Duration) map[string]any {
		return map[string]any{"key": z.ID + ":" + idStr(int64(n)), "actor_account_id": idStr(gm.ID),
			"actor_character_id": idStr(idGM), "command": command, "target_character_id": idStr(target),
			"target_account_id": idStr(targetAccount), "args": map[string]any{"target": idStr(target)},
			"at_unix": p.Clock.Now().Add(-ago).Unix(), "source": "zone"}
	}
	platformtest.Expect(t, z.Do("POST", "/internal/v1/audit", map[string]any{"zone_instance_id": z.ID, "entries": []any{
		entry(1, idB, b.ID, "teleport", 2*time.Hour),
		entry(2, idB, b.ID, "inv_show", 30*time.Minute),
		entry(3, idC, c.ID, "teleport", 20*time.Minute),
	}}), 204, "")
	rows, err := p.Admin.Audit(ctx, mod, admin.AuditQuery{Since: since, World: 1})
	if err != nil || len(rows) != 2 {
		t.Fatalf("desde hace una hora: %d %v", len(rows), err)
	}
	rows, _ = p.Admin.Audit(ctx, mod, admin.AuditQuery{Since: since.Add(-2 * time.Hour), World: 1, ActorName: "Celadora",
		Target: "bran"})
	if len(rows) != 2 || rows[0].Command != "teleport" || *rows[1].ActorName != "Celadora" || *rows[1].TargetName != "Bran" {
		t.Fatalf("filtros: %+v", rows)
	}
	row := lastAudit(t, p, "audit")
	if !is(row.TargetCharacter, idB) || !is(row.TargetAccount, b.ID) || row.Args["actor_account_id"] != idStr(gm.ID) {
		t.Fatalf("%+v", row)
	}
	// The previous queries are also in the audit.
	rows, _ = p.Admin.Audit(ctx, mod, admin.AuditQuery{Since: since, World: 1, Command: "audit"})
	if len(rows) != 2 || rows[0].Source != "cli" || !is(rows[0].ActorAccountID, mod.AccountID) {
		t.Fatalf("las lecturas se auditan: %+v", rows)
	}
	if _, err := p.Admin.Audit(ctx, mod, admin.AuditQuery{World: 1}); err == nil {
		t.Fatal("sin --since")
	}
}

// purge-now (§11.2): it revokes the sessions (deletion) and, with a character still in the world
// after the deadline, answers character_busy without purging anything; once it is out, it purges the
// account and its characters.
func TestPurgeNow(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	_, adm := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	pl := p.NewPlayer("borrar@example.org")
	id := p.NewCharacter(pl, "Bran", "vardheim")
	lease := z.Join(pl, id)
	res, err := p.Admin.PurgeNow(ctx, adm, "borrar@example.org", 50*time.Millisecond)
	if !errors.Is(err, admin.ErrBusy) || res.Revoked != 1 {
		t.Fatalf("con el personaje dentro: %+v %v", res, err)
	}
	if n := p.Count(`select count(*) from sessions where account_id = $1 and revoke_reason = 'deletion'`, pl.ID); n != 1 {
		t.Fatal("sesiones")
	}
	if n := p.Count(`select count(*) from accounts where account_id = $1 and status = 'active'`, pl.ID); n != 1 {
		t.Fatal("no se purga nada")
	}
	// The heartbeat kicks out (session_revoked) and the zone releases after the final save.
	hb := z.Heartbeat(1, platformtest.Lease{CharacterID: id, LeaseID: lease})
	if r := hb.Body["revoked"].([]any); len(r) != 1 || r[0].(map[string]any)["reason"] != "session_revoked" {
		t.Fatal(hb.Raw)
	}
	platformtest.Expect(t, z.Release(id, lease), 204, "")
	res, err = p.Admin.PurgeNow(ctx, adm, "Borrar@example.org", time.Second)
	if err != nil || !res.Purged {
		t.Fatalf("%+v %v", res, err)
	}
	if n := p.Count(`select count(*) from accounts where account_id = $1 and status = 'purged' and email is null`, pl.ID); n != 1 {
		t.Fatal("cuenta purgada")
	}
	if n := p.Count(`select count(*) from characters where character_id = $1 and purged_at is not null and name is null`, id); n != 1 {
		t.Fatal("lápida del personaje")
	}
	if n := p.Count(`select count(*) from purge_log`); n != 2 {
		t.Fatal(n)
	}
	if n := p.Count(`select count(*) from audit_log where command = 'purge-now' and target_account_id = $1`, pl.ID); n != 2 {
		t.Fatal(n)
	}
	if _, err := p.Admin.PurgeNow(ctx, adm, "borrar@example.org", 0); !errors.Is(err, admin.ErrAccountNotFound) {
		t.Fatal(err)
	}
	if _, err := p.Admin.PurgeNow(ctx, adm, "admin@example.org", 0); !errors.Is(err, admin.ErrSelf) {
		t.Fatal(err)
	}
}

// create-account and bootstrap: verified accounts with the texts accepted (they get in without
// terms_required); bootstrap only with no admin.
func TestCreateAccountAndBootstrap(t *testing.T) {
	p := platformtest.New(t)
	const password = "otra contraseña larga"
	id, err := p.Admin.Bootstrap(ctx, "Jefa@Example.org", password)
	if err != nil {
		t.Fatal(err)
	}
	row := lastAudit(t, p, "bootstrap")
	if row.Actor != nil || !is(row.TargetAccount, id) || row.Args["os_user"] != "prueba" {
		t.Fatalf("%+v", row)
	}
	if _, err := p.Admin.Bootstrap(ctx, "otra@example.org", password); !errors.Is(err, admin.ErrHasAdmin) {
		t.Fatal(err)
	}
	actor, err := p.Admin.Authorize(ctx, "jefa@example.org", sanctions.RoleAdmin)
	if err != nil {
		t.Fatal(err)
	}
	gmID, err := p.Admin.CreateAccount(ctx, actor, "gm@example.org", password, sanctions.RoleGM)
	if err != nil {
		t.Fatal(err)
	}
	row = lastAudit(t, p, "create-account")
	if !is(row.Actor, id) || !is(row.TargetAccount, gmID) || row.Args["role"] != "gm" {
		t.Fatalf("%+v", row)
	}
	login := p.PublicDo("POST", "/v1/sessions", "", map[string]any{"email": "gm@example.org", "password": password})
	platformtest.Expect(t, login, 200, "")
	acc := p.PublicDo("GET", "/v1/account", login.String("access_token"), nil)
	pending := acc.Body["pending"].(map[string]any)
	if acc.Body["email_verified"] != true || acc.Body["role"] != "gm" || pending["terms_required"] != false {
		t.Fatalf("cuenta creada: %s", acc.Raw)
	}
	// An email reserved by another account's live revert_email (platform.md §4.3) is not valid
	// either.
	p.Exec(`insert into account_tokens (token_hash, account_id, purpose, email, expires_at, created_at)
		values ('\x01', $1, 'revert_email', 'reservado@example.org', $2, $3)`, gmID, p.Clock.Now().Add(time.Hour), p.Clock.Now())
	for _, c := range []struct {
		email, password, role string
		want                  error
	}{
		{"gm@example.org", password, "player", accounts.ErrEmailTaken},
		{"reservado@example.org", password, "player", accounts.ErrEmailReserved},
		{"no es un correo", password, "player", accounts.ErrEmailInvalid},
		{"x@example.org", "corta", "player", accounts.ErrPasswordInvalid},
		{"x@example.org", password, "rey", accounts.ErrRoleInvalid},
	} {
		if _, err := p.Admin.CreateAccount(ctx, actor, c.email, c.password, c.role); !errors.Is(err, c.want) {
			t.Errorf("%+v: %v", c, err)
		}
	}
}

// No CLI audit_log row (set-role, purge-now, chat --character, reports show, audit --target,
// sanctions) nor a sanction_denied (from the zone or the CLI) carries an email or a character's name
// in args (§9.1); all the CLI ones carry os_user.
func TestAuditHasNoPersonalData(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	_, adm := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	modPl, mod := staff(t, p, "mod@example.org", sanctions.RoleModerator)
	idMod := p.NewCharacter(modPl, "Moderadora", "vardheim")
	other, _ := staff(t, p, "jefa@example.org", sanctions.RoleAdmin)
	p.NewCharacter(other, "Jefa", "vardheim")
	a := p.NewPlayer("aneira@example.org")
	idA := p.NewCharacter(a, "Aneira", "vardheim")
	b := p.NewPlayer("bran@example.org")
	p.NewCharacter(b, "Bran", "vardheim")
	gone := p.NewPlayer("gone@example.org")
	p.NewCharacter(gone, "Olvidada", "vardheim")
	z.Join(a, idA)
	z.Join(modPl, idMod)
	reportID := reportFrom(t, z, idA, "Bran")
	platformtest.Expect(t, z.Do("POST", "/internal/v1/chat", map[string]any{"zone_instance_id": z.ID, "messages": []any{
		map[string]any{"key": z.ID + ":1", "channel": 2, "sender_character_id": idStr(idA), "target_character_id": nil,
			"text": "hola Bran", "sent_at_unix": p.Clock.Now().Unix()}}}), 204, "")
	// The zone's: a denied sanction (a moderator requests ban).
	platformtest.Expect(t, z.Do("POST", "/internal/v1/sanctions", map[string]any{"zone_instance_id": z.ID,
		"author_character_id": idStr(idMod), "target_name": "Bran", "kind": "ban", "minutes": 0, "reason": "Bran insulta",
		"report_ids": []any{}}), 403, "forbidden")
	// The CLI's.
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	_, err := p.Admin.SetRole(ctx, adm, "bran@example.org", sanctions.RoleModerator)
	must(err)
	_, err = p.Admin.SetRole(ctx, adm, "bran@example.org", sanctions.RolePlayer)
	must(err)
	_, _, err = p.Admin.Chat(ctx, mod, admin.ChatQuery{World: 1, Character: "Aneira", From: p.Clock.Now().Add(-time.Hour),
		To: p.Clock.Now().Add(time.Hour)})
	must(err)
	id, _ := p.Admin.Reports(ctx, mod, admin.ReportFilter{})
	_, err = p.Admin.Report(ctx, mod, id[0].ID)
	must(err)
	_, err = p.Admin.Audit(ctx, mod, admin.AuditQuery{Since: p.Clock.Now().Add(-time.Hour), World: 1, Target: "Bran",
		ActorName: "Moderadora"})
	must(err)
	_, _, err = p.Admin.Sanction(ctx, adm, admin.SanctionOrder{World: 1, Target: "Bran", Kind: sanctions.KindMute,
		Duration: time.Hour, Reason: "Bran insulta a Aneira"})
	must(err)
	var denied *admin.DeniedError
	if _, _, err := p.Admin.Sanction(ctx, adm, admin.SanctionOrder{World: 1, Target: "Jefa", Kind: sanctions.KindWarning,
		Reason: "Jefa"}); !errors.As(err, &denied) {
		t.Fatal(err)
	}
	_, _, err = p.Admin.Sanctions(ctx, mod, 1, "Bran")
	must(err)
	_, err = p.Admin.PurgeNow(ctx, adm, "gone@example.org", 0)
	must(err)
	_ = reportID

	secrets := []string{"@", "aneira", "bran", "jefa", "moderadora", "olvidada", "gone"}
	rows, err := p.Pool.Query(ctx, `select command, source, args::text, actor_account_id is not null from audit_log`)
	must(err)
	defer rows.Close()
	cli := 0
	for rows.Next() {
		var command, source, args string
		var hasActor bool
		must(rows.Scan(&command, &source, &args, &hasActor))
		lower := strings.ToLower(args)
		for _, s := range secrets {
			if strings.Contains(lower, s) {
				t.Errorf("%s (%s): args con %q: %s", command, source, s, args)
			}
		}
		if source == "cli" {
			cli++
			if !strings.Contains(args, `"os_user": "prueba"`) || !hasActor {
				t.Errorf("%s sin os_user o sin actor: %s", command, args)
			}
		}
	}
	must(rows.Err())
	if cli < 10 {
		t.Fatalf("filas de la CLI: %d", cli)
	}
}
