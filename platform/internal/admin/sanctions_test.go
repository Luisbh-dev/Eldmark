package admin_test

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/sanctions"
)

// sanctionWorld es lo común de las pruebas de caducidad: una zona viva, un admin para la CLI y una
// jugadora con su personaje «Bran».
type sanctionWorld struct {
	p     *platformtest.Platform
	z     *platformtest.Zone
	actor *admin.Actor
	pl    *platformtest.Player
	id    int64
}

func newSanctionWorld(t *testing.T) *sanctionWorld {
	t.Helper()
	p := platformtest.New(t)
	w := &sanctionWorld{p: p, z: p.NewZone(1, "vado_gris", 0).Start()}
	_, w.actor = staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	w.pl = p.NewPlayer("bran@example.org")
	w.id = p.NewCharacter(w.pl, "Bran", "vardheim")
	return w
}

func (w *sanctionWorld) sanction(t *testing.T, kind string, d time.Duration) int64 {
	t.Helper()
	created, _, err := w.p.Admin.Sanction(ctx, w.actor, admin.SanctionOrder{World: 1, Target: "Bran", Kind: kind,
		Duration: d, Reason: "normas de la comunidad"})
	if err != nil {
		t.Fatal(err)
	}
	return created.SanctionID
}

// claim entra al mundo y reclama: la respuesta de la reclamación.
func (w *sanctionWorld) claim(t *testing.T) *platformtest.Response {
	t.Helper()
	ticket, _ := w.p.MustEnter(w.pl, w.id)
	res := w.z.Claim(ticket, w.id)
	platformtest.Expect(t, res, 200, "")
	return res
}

// leave es la salida del mundo: el guardado final, que libera el arrendamiento.
func (w *sanctionWorld) leave(t *testing.T, claim *platformtest.Response) {
	t.Helper()
	body := w.z.SaveBody(w.id, claim.String("lease_id"), 1)
	body["release_lease"] = true
	platformtest.Expect(t, w.z.Save(w.id, body), 200, "")
}

// reject es la zona que libera al personaje sin que llegue al mundo (REALM, FULL, un prepare que
// falla o la baja en LOADING, §5.2): sin guardado.
func (w *sanctionWorld) reject(t *testing.T, claim *platformtest.Response) {
	t.Helper()
	platformtest.Expect(t, w.z.Release(w.id, claim.String("lease_id")), 204, "")
}

func (w *sanctionWorld) login(t *testing.T) *platformtest.Response {
	t.Helper()
	res := w.p.PublicDo("POST", "/v1/sessions", "", map[string]any{"email": w.pl.Email, "password": platformtest.Password})
	platformtest.Expect(t, res, 200, "")
	w.pl.Token = res.String("access_token")
	return res
}

func (w *sanctionWorld) state(t *testing.T, id int64) string {
	t.Helper()
	_, list, err := w.p.Admin.Sanctions(ctx, w.actor, 1, "Bran")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range list {
		if s.ID == id {
			return s.State
		}
	}
	t.Fatalf("sanción %d no listada", id)
	return ""
}

func account(res *platformtest.Response) map[string]any { return res.Body["account"].(map[string]any) }

// Aviso (§9.5: al entrar, NOTICE con el motivo): la reclamación siguiente lo trae, con el texto
// compuesto por la plataforma, y solo esa; no tiene efecto mecánico y queda anotado en la cuenta.
func TestWarningIsShownOnce(t *testing.T) {
	w := newSanctionWorld(t)
	first := w.claim(t)
	if n := len(account(first)["warnings"].([]any)); n != 0 {
		t.Fatalf("sin avisos: %s", first.Raw)
	}
	w.leave(t, first)
	w.p.Clock.Advance(time.Minute)
	id := w.sanction(t, sanctions.KindWarning, 0)
	w.p.Clock.Advance(time.Minute)
	res := w.claim(t)
	warnings := account(res)["warnings"].([]any)
	if len(warnings) != 1 {
		t.Fatalf("warnings: %s", res.Raw)
	}
	got := warnings[0].(map[string]any)
	if got["sanction_id"] != idStr(id) || got["text"] != "Has recibido un aviso de la moderación: normas de la comunidad" ||
		got["at_unix"].(json.Number).String() != strconv.FormatInt(w.p.Clock.Now().Add(-time.Minute).Unix(), 10) {
		t.Fatalf("aviso: %v", got)
	}
	w.leave(t, res)
	w.p.Clock.Advance(time.Minute)
	again := w.claim(t)
	if n := len(account(again)["warnings"].([]any)); n != 0 {
		t.Fatalf("el aviso sale una sola vez: %s", again.Raw)
	}
	if res := w.login(t); res.String("scope") != "game" || res.Body["restriction"] != nil {
		t.Fatalf("un aviso no restringe: %s", res.Raw)
	}
	if s := w.state(t, id); s != admin.StateNoted {
		t.Fatal(s)
	}
}

// Un aviso no se da por visto si la zona libera al personaje sin que llegue al mundo (§5.2: REALM,
// FULL, prepare o la baja en LOADING; ninguno guarda): la reclamación siguiente lo vuelve a traer.
// Lo da por visto el primer guardado del arrendamiento.
func TestWarningSurvivesARejectedEntry(t *testing.T) {
	w := newSanctionWorld(t)
	id := w.sanction(t, sanctions.KindWarning, 0)
	w.p.Clock.Advance(time.Minute)
	for i := 0; i < 2; i++ {
		res := w.claim(t)
		if warnings := account(res)["warnings"].([]any); len(warnings) != 1 ||
			warnings[0].(map[string]any)["sanction_id"] != idStr(id) {
			t.Fatalf("reclamación %d: %s", i, res.Raw)
		}
		w.reject(t, res)
		w.p.Clock.Advance(time.Second)
	}
	res := w.claim(t)
	if len(account(res)["warnings"].([]any)) != 1 {
		t.Fatalf("tras dos rechazos: %s", res.Raw)
	}
	w.leave(t, res)
	w.p.Clock.Advance(time.Second)
	if res := w.claim(t); len(account(res)["warnings"].([]any)) != 0 {
		t.Fatalf("visto tras entrar y guardar: %s", res.Raw)
	}
}

// Silencio: el latido (mutes) y la reclamación (muted_until_unix) lo dicen hasta su fin; después,
// nada.
func TestMuteExpires(t *testing.T) {
	w := newSanctionWorld(t)
	claim := w.claim(t)
	lease := platformtest.Lease{CharacterID: w.id, LeaseID: claim.String("lease_id")}
	id := w.sanction(t, sanctions.KindMute, time.Hour)
	until := w.p.Clock.Now().Add(time.Hour).Unix()
	hb := w.z.Heartbeat(1, lease)
	mutes := hb.Body["mutes"].([]any)
	if len(mutes) != 1 || mutes[0].(map[string]any)["until_unix"].(json.Number).String() != strconv.FormatInt(until, 10) ||
		mutes[0].(map[string]any)["account_id"] != idStr(w.pl.ID) {
		t.Fatalf("mutes: %s", hb.Raw)
	}
	if s := w.state(t, id); s != admin.StateActive {
		t.Fatal(s)
	}
	w.leave(t, claim)
	w.p.Clock.Advance(30 * time.Minute)
	w.login(t)
	claim = w.claim(t)
	if account(claim)["muted_until_unix"].(json.Number).String() != strconv.FormatInt(until, 10) {
		t.Fatalf("reclamación: %s", claim.Raw)
	}
	w.p.Clock.Advance(30*time.Minute + time.Second)
	hb = w.z.Heartbeat(1, platformtest.Lease{CharacterID: w.id, LeaseID: claim.String("lease_id")})
	if len(hb.Body["mutes"].([]any)) != 0 {
		t.Fatalf("el silencio ha caducado: %s", hb.Raw)
	}
	w.leave(t, claim)
	w.login(t)
	claim = w.claim(t)
	if account(claim)["muted_until_unix"].(json.Number).String() != "0" {
		t.Fatalf("reclamación tras el fin: %s", claim.Raw)
	}
	if s := w.state(t, id); s != admin.StateExpired {
		t.Fatal(s)
	}
}

// Suspensión: tras la contraseña, solo la sesión de privacidad con su fin y su motivo; enter y la
// reclamación dan 403; el latido expulsa (suspended). Al acabar, todo vuelve.
func TestSuspensionExpires(t *testing.T) {
	w := newSanctionWorld(t)
	ticket, _ := w.p.MustEnter(w.pl, w.id) // un billete de antes de la sanción, sin usar
	claim := w.claim(t)
	lease := platformtest.Lease{CharacterID: w.id, LeaseID: claim.String("lease_id")}
	id := w.sanction(t, sanctions.KindSuspension, 3*24*time.Hour)
	end := w.p.Clock.Now().Add(3 * 24 * time.Hour)
	hb := w.z.Heartbeat(1, lease)
	revoked := hb.Body["revoked"].([]any)
	if len(revoked) != 1 || revoked[0].(map[string]any)["reason"] != "suspended" {
		t.Fatalf("latido: %s", hb.Raw)
	}
	w.leave(t, claim)
	res := w.z.Claim(ticket, w.id)
	platformtest.Expect(t, res, 403, "account_blocked")
	if res.ErrValue("kind") != "suspension" || res.ErrValue("until_unix").(json.Number).String() != strconv.FormatInt(end.Unix(), 10) {
		t.Fatal(res.Raw)
	}
	login := w.login(t)
	r := login.Body["restriction"].(map[string]any)
	if login.String("scope") != "privacy" || r["code"] != "account_suspended" || r["reason"] != "normas de la comunidad" {
		t.Fatalf("inicio de sesión: %s", login.Raw)
	}
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 403, "account_suspended")
	w.p.Clock.Advance(3*24*time.Hour - time.Minute)
	if login := w.login(t); login.String("scope") != "privacy" {
		t.Fatalf("un minuto antes del fin: %s", login.Raw)
	}
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 403, "account_suspended")
	w.p.Clock.Advance(time.Minute)
	if login := w.login(t); login.String("scope") != "game" || login.Body["restriction"] != nil {
		t.Fatalf("tras el fin: %s", login.Raw)
	}
	w.leave(t, w.claim(t))
	if s := w.state(t, id); s != admin.StateExpired {
		t.Fatal(s)
	}
}

// Expulsión: permanente (sigue a los diez años) hasta que la CLI la revoca.
func TestBanUntilRevoked(t *testing.T) {
	w := newSanctionWorld(t)
	id := w.sanction(t, sanctions.KindBan, 0)
	if login := w.login(t); login.String("scope") != "privacy" ||
		login.Body["restriction"].(map[string]any)["code"] != "account_banned" ||
		login.Body["restriction"].(map[string]any)["until"] != nil {
		t.Fatalf("inicio de sesión: %s", login.Raw)
	}
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 403, "account_banned")
	w.p.Clock.Advance(10 * 365 * 24 * time.Hour)
	if login := w.login(t); login.String("scope") != "privacy" {
		t.Fatalf("a los diez años: %s", login.Raw)
	}
	if s := w.state(t, id); s != admin.StateActive {
		t.Fatal(s)
	}
	info, err := w.p.Admin.RevokeSanction(ctx, w.actor, id)
	if err != nil || info.State != admin.StateRevoked {
		t.Fatal(err)
	}
	if _, err := w.p.Admin.RevokeSanction(ctx, w.actor, id); !errors.Is(err, admin.ErrAlreadyRevoked) {
		t.Fatal(err)
	}
	if _, err := w.p.Admin.RevokeSanction(ctx, w.actor, 424242); !errors.Is(err, admin.ErrSanctionNotFound) {
		t.Fatal(err)
	}
	if login := w.login(t); login.String("scope") != "game" {
		t.Fatalf("revocada: %s", login.Raw)
	}
	w.claim(t)
	row := lastAudit(t, w.p, "sanction revoke")
	if !is(row.TargetAccount, w.pl.ID) || !is(row.TargetCharacter, w.id) || row.Args["sanction_id"] != idStr(id) ||
		row.Args["kind"] != "ban" {
		t.Fatalf("%+v", row)
	}
}

// Renombrado forzado: enter da 409 rename_required hasta que el jugador elige otro nombre; una
// revocación antes de hacerlo quita must_rename.
func TestRenameUntilRenamed(t *testing.T) {
	w := newSanctionWorld(t)
	id := w.sanction(t, sanctions.KindRename, 0)
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 409, "rename_required")
	if s := w.state(t, id); s != admin.StatePending {
		t.Fatal(s)
	}
	path := "/v1/characters/" + idStr(w.id) + "/rename"
	platformtest.Expect(t, w.p.PublicDo("POST", path, w.pl.Token, map[string]any{"name": "Brandon"}), 200, "")
	w.leave(t, w.claim(t))
	// La sanción sigue apuntada con el id del personaje, que ahora se llama Brandon.
	_, list, err := w.p.Admin.Sanctions(ctx, w.actor, 1, "Brandon")
	if err != nil || len(list) != 1 || list[0].State != admin.StateComplied {
		t.Fatalf("%+v %v", list, err)
	}
	second, _, err := w.p.Admin.Sanction(ctx, w.actor, admin.SanctionOrder{World: 1, Target: "#" + idStr(w.id),
		Kind: sanctions.KindRename, Reason: "suplantación"})
	if err != nil {
		t.Fatal(err)
	}
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 409, "rename_required")
	if _, err := w.p.Admin.RevokeSanction(ctx, w.actor, second.SanctionID); err != nil {
		t.Fatal(err)
	}
	w.claim(t)
}

// La CLI pasa las mismas comprobaciones que la zona con la cuenta del --actor (§9.5): un admin no
// sanciona a otro admin (sanction_denied, source cli, sin nombres); los reportes tienen que ser de
// ese mundo; tipo, duración y motivo se comprueban antes de tocar nada.
func TestCLISanctionChecks(t *testing.T) {
	w := newSanctionWorld(t)
	p := w.p
	other, _ := staff(t, p, "jefa@example.org", sanctions.RoleAdmin)
	p.NewCharacter(other, "Jefa", "vardheim")
	order := admin.SanctionOrder{World: 1, Target: "jefa", Kind: sanctions.KindWarning, Reason: "x"}
	var denied *admin.DeniedError
	if _, _, err := p.Admin.Sanction(ctx, w.actor, order); !errors.As(err, &denied) ||
		denied.Denial != sanctions.DeniedTargetRole {
		t.Fatalf("admin contra admin: %v", err)
	}
	row := lastAudit(t, p, "sanction_denied")
	if row.Source != "cli" || !is(row.Actor, w.actor.AccountID) || row.ActorCharacter != nil || row.Zone != nil ||
		!is(row.TargetAccount, other.ID) || row.Args["denied"] != "target_role" || row.Args["os_user"] != "prueba" {
		t.Fatalf("%+v", row)
	}
	if n := p.Count(`select count(*) from sanctions`); n != 0 {
		t.Fatal(n)
	}
	for _, bad := range []admin.SanctionOrder{
		{World: 1, Target: "Bran", Kind: "jail", Reason: "x"},
		{World: 1, Target: "Bran", Kind: sanctions.KindMute, Reason: "x"},
		{World: 1, Target: "Bran", Kind: sanctions.KindMute, Duration: 90 * time.Second, Reason: "x"},
		{World: 1, Target: "Bran", Kind: sanctions.KindBan, Duration: time.Hour, Reason: "x"},
		{World: 1, Target: "Bran", Kind: sanctions.KindWarning, Reason: "  "},
	} {
		if _, _, err := p.Admin.Sanction(ctx, w.actor, bad); err == nil {
			t.Errorf("%+v debería fallar", bad)
		}
	}
	order = admin.SanctionOrder{World: 1, Target: "Nadie", Kind: sanctions.KindWarning, Reason: "x"}
	if _, _, err := p.Admin.Sanction(ctx, w.actor, order); !errors.Is(err, admin.ErrCharacterNotFound) {
		t.Fatal(err)
	}
	order.Target, order.ReportIDs = "Bran", []int64{424242}
	if _, _, err := p.Admin.Sanction(ctx, w.actor, order); !errors.Is(err, admin.ErrUnknownReports) {
		t.Fatal(err)
	}
	// Con un reporte de verdad: enlazado, y la fila sanction con source cli.
	p.Exec(`insert into reports (world_id, target_account_id, target_character_id, target_name, category, context)
		values (1, $1, $2, 'Bran', 'language', '{}')`, w.pl.ID, w.id)
	var report int64
	p.Scalar(&report, `select max(report_id) from reports`)
	order.ReportIDs = []int64{report, report}
	created, target, err := p.Admin.Sanction(ctx, w.actor, order)
	if err != nil || target.ID != w.id || created.EndsAt != nil {
		t.Fatal(err)
	}
	row = lastAudit(t, p, "sanction")
	if row.Source != "cli" || row.Args["sanction_id"] != idStr(created.SanctionID) ||
		row.Args["report_ids"].([]any)[0] != idStr(report) || !is(row.TargetCharacter, w.id) {
		t.Fatalf("%+v", row)
	}
	var author int64
	p.Scalar(&author, `select author_account_id from sanctions where sanction_id = $1`, created.SanctionID)
	if author != w.actor.AccountID || p.Count(`select count(*) from sanction_reports`) != 1 {
		t.Fatal("autor y reportes")
	}
	if s := strings.ToLower(row.Args["kind"].(string)); s != "warning" {
		t.Fatal(s)
	}
}
