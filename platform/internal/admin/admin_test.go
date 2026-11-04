package admin_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"testing"
	"time"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

var ctx = context.Background()

func idStr(id int64) string { return strconv.FormatInt(id, 10) }

// staff creates an account with that role and returns its player and its --actor.
func staff(t *testing.T, p *platformtest.Platform, email, role string) (*platformtest.Player, *admin.Actor) {
	t.Helper()
	pl := p.NewPlayer(email)
	p.Exec(`update accounts set role = $2 where account_id = $1`, pl.ID, role)
	return pl, &admin.Actor{AccountID: pl.ID, Role: role}
}

// auditRow reads an audit_log row by its command (the last one).
type auditRow struct {
	Source          string
	Actor           *int64
	ActorCharacter  *int64
	TargetAccount   *int64
	TargetCharacter *int64
	World           *int16
	Zone            *string
	Args            map[string]any
	At              time.Time
}

func lastAudit(t *testing.T, p *platformtest.Platform, command string) auditRow {
	t.Helper()
	var r auditRow
	var args []byte
	err := p.Pool.QueryRow(ctx, `select source, actor_account_id, actor_character_id, target_account_id,
		target_character_id, world_id, zone_id, args, at from audit_log where command = $1 order by id desc limit 1`,
		command).Scan(&r.Source, &r.Actor, &r.ActorCharacter, &r.TargetAccount, &r.TargetCharacter, &r.World, &r.Zone,
		&args, &r.At)
	if err != nil {
		t.Fatalf("fila %s: %v", command, err)
	}
	if err := json.Unmarshal(args, &r.Args); err != nil {
		t.Fatal(err)
	}
	return r
}

func is(p *int64, v int64) bool { return p != nil && *p == v }

// --actor (§9.1): without it, with an email without an account, with a role that is not enough,
// with the account sanctioned or with deletion requested, it is not executed (ActorError, code 2 in
// the CLI); moderator is enough to read and admin is needed for the rest.
func TestAuthorize(t *testing.T) {
	p := platformtest.New(t)
	player := p.NewPlayer("p@example.org")
	mod, _ := staff(t, p, "mod@example.org", sanctions.RoleModerator)
	adm, _ := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	banned, _ := staff(t, p, "banned@example.org", sanctions.RoleAdmin)
	leaving, _ := staff(t, p, "leaving@example.org", sanctions.RoleAdmin)
	p.Exec(`insert into sanctions (account_id, kind, reason, starts_at) values ($1, 'ban', 'x', $2)`, banned.ID,
		p.Clock.Now().Add(-time.Minute))
	p.Exec(`update accounts set status = 'pending_deletion' where account_id = $1`, leaving.ID)
	deny := func(email, need string) {
		t.Helper()
		var actorErr *admin.ActorError
		if _, err := p.Admin.Authorize(ctx, email, need); !errors.As(err, &actorErr) {
			t.Errorf("%q con %s: %v", email, need, err)
		}
	}
	deny("", sanctions.RoleModerator)
	deny("nadie@example.org", sanctions.RoleModerator)
	deny(player.Email, sanctions.RoleModerator)
	deny(mod.Email, sanctions.RoleAdmin)
	deny(banned.Email, sanctions.RoleModerator)
	deny(leaving.Email, sanctions.RoleModerator)
	if a, err := p.Admin.Authorize(ctx, " MOD@example.org", sanctions.RoleModerator); err != nil || a.AccountID != mod.ID {
		t.Fatalf("moderator para leer: %v %v", a, err)
	}
	if a, err := p.Admin.Authorize(ctx, adm.Email, sanctions.RoleAdmin); err != nil || a.Role != sanctions.RoleAdmin {
		t.Fatalf("admin: %v %v", a, err)
	}
	// An admin who loses the role between the check and the command does not finish it.
	actor, _ := p.Admin.Authorize(ctx, adm.Email, sanctions.RoleAdmin)
	p.Exec(`update accounts set role = 'gm' where account_id = $1`, adm.ID)
	var actorErr *admin.ActorError
	if _, err := p.Admin.BlockName(ctx, actor, "Malnombre", ""); !errors.As(err, &actorErr) {
		t.Fatalf("rol perdido a mitad: %v", err)
	}
	if n := p.Count(`select count(*) from name_blacklist`); n != 0 {
		t.Fatal(n)
	}
}

// set-role (§9.1) revokes the account's sessions (role_changed) and the next heartbeat kicks out
// its character (<= HEARTBEAT_S); it leaves the fixed row that S2 reads (source cli, command
// set-role, target_account_id and args {from, to, os_user}); on logging back in, the claim brings
// the new role. RoleAt gives the pre-change role for an earlier instant.
func TestSetRole(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	_, actor := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	gm, _ := staff(t, p, "gm@example.org", sanctions.RoleGM)
	id := p.NewCharacter(gm, "Celadora", "vardheim")
	lease := z.Join(gm, id)
	hb := z.Heartbeat(1, platformtest.Lease{CharacterID: id, LeaseID: lease})
	if len(hb.Body["revoked"].([]any)) != 0 {
		t.Fatal(hb.Raw)
	}
	before := p.Clock.Now()
	p.Clock.Advance(time.Second)
	res, err := p.Admin.SetRole(ctx, actor, "GM@example.org", sanctions.RolePlayer)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Changed || res.From != sanctions.RoleGM || res.To != sanctions.RolePlayer || res.Revoked != 1 {
		t.Fatalf("%+v", res)
	}
	// The next heartbeat kicks it out (with a final save: session_revoked).
	hb = z.Heartbeat(1, platformtest.Lease{CharacterID: id, LeaseID: lease})
	revoked := hb.Body["revoked"].([]any)
	if len(revoked) != 1 {
		t.Fatalf("revoked: %s", hb.Raw)
	}
	r := revoked[0].(map[string]any)
	if r["reason"] != "session_revoked" || r["lease_id"] != lease || r["character_id"] != idStr(id) ||
		r["text"] != "Tu cuenta ha cambiado: vuelve a entrar" {
		t.Fatalf("revoked: %v", r)
	}
	if n := p.Count(`select count(*) from sessions where account_id = $1 and (revoked_at is null
		or revoke_reason <> 'role_changed')`, gm.ID); n != 0 {
		t.Fatal("sesiones sin revocar")
	}
	platformtest.Expect(t, p.PublicDo("GET", "/v1/account", gm.Token, nil), 401, "unauthorized")
	// The fixed row of §9.1.
	row := lastAudit(t, p, "set-role")
	if row.Source != "cli" || !is(row.Actor, actor.AccountID) || !is(row.TargetAccount, gm.ID) || row.TargetCharacter != nil ||
		row.ActorCharacter != nil || row.World != nil || row.Zone != nil || !row.At.Equal(p.Clock.Now()) ||
		len(row.Args) != 3 || row.Args["from"] != "gm" || row.Args["to"] != "player" || row.Args["os_user"] != "prueba" {
		t.Fatalf("fila set-role: %+v", row)
	}
	// S2: the role at an instant before the change is the previous one.
	for at, want := range map[time.Time]string{before: "gm", p.Clock.Now(): "player",
		p.Clock.Now().Add(time.Hour): "player"} {
		if got, err := sanctions.RoleAt(ctx, p.Pool, gm.ID, at); err != nil || got != want {
			t.Errorf("RoleAt(%v) = %q %v, se esperaba %s", at, got, err, want)
		}
	}
	// It logs back in with the new role (the zone released after its final save).
	platformtest.Expect(t, z.Release(id, lease), 204, "")
	p.Login(gm)
	ticket, _ := p.MustEnter(gm, id)
	claim := z.Claim(ticket, id)
	platformtest.Expect(t, claim, 200, "")
	if role := claim.Body["account"].(map[string]any)["role"]; role != "player" {
		t.Fatalf("rol en la reclamación: %v", role)
	}
	// The same role again changes nothing and leaves no row; on itself, on an email without an account
	// or on an unknown role, error.
	res, err = p.Admin.SetRole(ctx, actor, gm.Email, sanctions.RolePlayer)
	if err != nil || res.Changed || p.Count(`select count(*) from audit_log where command = 'set-role'`) != 1 {
		t.Fatalf("mismo rol: %+v %v", res, err)
	}
	if _, err := p.Admin.SetRole(ctx, actor, "admin@example.org", sanctions.RolePlayer); !errors.Is(err, admin.ErrSelf) {
		t.Fatal(err)
	}
	if _, err := p.Admin.SetRole(ctx, actor, "nadie@example.org", sanctions.RoleGM); !errors.Is(err, admin.ErrAccountNotFound) {
		t.Fatal(err)
	}
	if _, err := p.Admin.SetRole(ctx, actor, gm.Email, "rey"); !errors.Is(err, accounts.ErrRoleInvalid) {
		t.Fatal(err)
	}
}

// S2 (progression.md §13.3) only reads the CLI's set-role rows: a zone audit batch with an entry
// source = 'cli' or command = 'set-role' rejects it, and a set-role row with another source
// (written by hand) does not change RoleAt. With several changes, RoleAt gives the role of each
// stretch.
func TestRoleAtOnlyReadsCLI(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	_, actor := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	pl := p.NewPlayer("p@example.org")
	entry := func(key, source, command string) map[string]any {
		return map[string]any{"key": key, "actor_account_id": idStr(actor.AccountID), "actor_character_id": nil,
			"command": command, "target_character_id": nil, "target_account_id": idStr(pl.ID),
			"args": map[string]any{"from": "admin", "to": "player"}, "at_unix": p.Clock.Now().Add(time.Hour).Unix(),
			"source": source}
	}
	res := z.Do("POST", "/internal/v1/audit", map[string]any{"zone_instance_id": z.ID, "entries": []any{
		entry(z.ID+":1", "cli", "item_give"), entry(z.ID+":2", "zone", "set-role"), entry(z.ID+":3", "cli", "set-role"),
	}})
	platformtest.Expect(t, res, 200, "")
	if len(res.Body["rejected"].([]any)) != 3 {
		t.Fatalf("rejected: %s", res.Raw)
	}
	p.Exec(`insert into audit_log (source, command, target_account_id, args, at)
		values ('zone', 'set-role', $1, '{"from": "admin", "to": "player"}', $2)`, pl.ID, p.Clock.Now().Add(time.Hour))
	if role, err := sanctions.RoleAt(ctx, p.Pool, pl.ID, p.Clock.Now()); err != nil || role != "player" {
		t.Fatalf("S2 ve una fila que no es de la CLI: %q %v", role, err)
	}
	t0 := p.Clock.Now()
	p.Clock.Advance(time.Minute)
	if _, err := p.Admin.SetRole(ctx, actor, pl.Email, sanctions.RoleGM); err != nil {
		t.Fatal(err)
	}
	t1 := p.Clock.Now()
	p.Clock.Advance(time.Minute)
	if _, err := p.Admin.SetRole(ctx, actor, pl.Email, sanctions.RoleModerator); err != nil {
		t.Fatal(err)
	}
	for at, want := range map[time.Time]string{t0: "player", t1: "gm", t1.Add(30 * time.Second): "gm",
		p.Clock.Now(): "moderator"} {
		if got, _ := sanctions.RoleAt(ctx, p.Pool, pl.ID, at); got != want {
			t.Errorf("RoleAt(%v) = %q, se esperaba %s", at.Sub(t0), got, want)
		}
	}
	if got, _ := sanctions.RoleAt(ctx, p.Pool, 999999, t0); got != "" {
		t.Errorf("cuenta inexistente: %q", got)
	}
}

// names block|unblock (SOC-13): the NameRules key goes to the blacklist (create -> 422 reserved,
// also with other capitalization and accents) and leaves it; it warns about whoever already has
// that name.
func TestNamesBlock(t *testing.T) {
	p := platformtest.New(t)
	_, actor := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	pl := p.NewPlayer("p@example.org")
	holder := p.NewCharacter(pl, "Malnombre", "vardheim")
	res, err := p.Admin.BlockName(ctx, actor, "MALNÓMBRE", "ofensivo")
	if err != nil || !res.Changed || res.Key != "malnombre" || len(res.Holders) != 1 || res.Holders[0].ID != holder {
		t.Fatalf("%+v %v", res, err)
	}
	if res, _ := p.Admin.BlockName(ctx, actor, "Malnombre", ""); res.Changed {
		t.Fatal("ya estaba")
	}
	row := lastAudit(t, p, "names block")
	if row.Args["term"] != "malnombre" || row.Args["os_user"] != "prueba" || !is(row.Actor, actor.AccountID) {
		t.Fatalf("%+v", row)
	}
	create := func(name string) *platformtest.Response {
		return p.PublicDo("POST", "/v1/worlds/1/characters", pl.Token, map[string]any{"name": name,
			"realm": "vardheim", "race_id": "race_vardheim", "appearance": platformtest.Appearance,
			"starter_template_id": "squire"})
	}
	if res, err := p.Admin.BlockName(ctx, actor, "Ínsulto", ""); err != nil || res.Key != "insulto" || len(res.Holders) != 0 {
		t.Fatalf("%+v %v", res, err)
	}
	r := create("Insulto")
	platformtest.Expect(t, r, 422, "name_invalid")
	if r.ErrValue("reason") != "reserved" {
		t.Fatal(r.Raw)
	}
	if res, err := p.Admin.UnblockName(ctx, actor, "insulto"); err != nil || !res.Changed {
		t.Fatal(err)
	}
	if res, _ := p.Admin.UnblockName(ctx, actor, "Insulto"); res.Changed {
		t.Fatal("ya no estaba")
	}
	platformtest.Expect(t, create("Insulto"), 201, "")
	if _, err := p.Admin.BlockName(ctx, actor, "!!", ""); !errors.Is(err, admin.ErrInvalidName) {
		t.Fatal(err)
	}
	if n := p.Count(`select count(*) from audit_log where command in ('names block', 'names unblock')`); n != 3 {
		t.Fatalf("filas: %d", n)
	}
}

// Two admins who remove each other's role at the same time: set-role locks both rows in id order
// and checks the --actor's role again, so one wins and the other is not executed (they are never
// both left without an admin).
func TestSetRoleRace(t *testing.T) {
	p := platformtest.New(t)
	for round := 0; round < 8; round++ {
		a, actorA := staff(t, p, "a"+strconv.Itoa(round)+"@example.org", sanctions.RoleAdmin)
		b, actorB := staff(t, p, "b"+strconv.Itoa(round)+"@example.org", sanctions.RoleAdmin)
		errs := make(chan error, 2)
		go func() { _, err := p.Admin.SetRole(ctx, actorA, b.Email, sanctions.RolePlayer); errs <- err }()
		go func() { _, err := p.Admin.SetRole(ctx, actorB, a.Email, sanctions.RolePlayer); errs <- err }()
		var ok, refused int
		for range 2 {
			var actorErr *admin.ActorError
			switch err := <-errs; {
			case err == nil:
				ok++
			case errors.As(err, &actorErr):
				refused++
			default:
				t.Fatal(err)
			}
		}
		admins := p.Count(`select count(*) from accounts where account_id in ($1, $2) and role = 'admin'`, a.ID, b.ID)
		if ok != 1 || refused != 1 || admins != 1 {
			t.Fatalf("ronda %d: %d hechos, %d sin ejecutar, %d admins", round, ok, refused, admins)
		}
	}
	if n := p.Count(`select count(*) from audit_log where command = 'set-role'`); n != 8 {
		t.Fatalf("filas set-role: %d", n)
	}
}
