package admin_test

import (
	"context"
	"errors"
	"net/http"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/legal"
)

// purges.txt: backup.sh's COPY text format (with any offset) and RFC 3339; an error names the line.
func TestParsePurges(t *testing.T) {
	in := "account\t3\t2026-10-30 09:46:00.123456+00\n\n" +
		"character\t17\t2026-10-30 11:16:00.5+01:30\r\n" +
		"character\t18\t2026-10-30T09:46:01Z\n"
	got, err := admin.ParsePurges(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 10, 30, 9, 46, 0, 123456000, time.UTC)
	want := []admin.PurgeEntry{
		{Kind: admin.PurgeAccount, ID: 3, PurgedAt: at},
		{Kind: admin.PurgeCharacter, ID: 17, PurgedAt: time.Date(2026, 10, 30, 9, 46, 0, 500000000, time.UTC)},
		{Kind: admin.PurgeCharacter, ID: 18, PurgedAt: time.Date(2026, 10, 30, 9, 46, 1, 0, time.UTC)},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("leído %+v", got)
	}
	if got, err := admin.ParsePurges(strings.NewReader("")); err != nil || len(got) != 0 {
		t.Fatalf("vacío: %v %v", got, err)
	}
	for _, bad := range []string{
		"account 3 2026-10-30 09:46:00+00",
		"session\t3\t2026-10-30 09:46:00+00",
		"account\t0\t2026-10-30 09:46:00+00",
		"account\tx\t2026-10-30 09:46:00+00",
		"account\t3\tayer",
		"account\t3\t2026-10-30 09:46:00+00\textra",
	} {
		_, err := admin.ParsePurges(strings.NewReader("account\t1\t2026-10-30 09:46:00+00\n" + bad + "\n"))
		if err == nil || !strings.Contains(err.Error(), "línea 2") {
			t.Fatalf("%q: %v", bad, err)
		}
	}
}

// pgTool is the path of a PostgreSQL binary used by the tests.
func pgTool(t *testing.T, name string) string {
	t.Helper()
	if dir := testdb.BinDir(); dir != "" {
		return filepath.Join(dir, name)
	}
	path, err := exec.LookPath(name)
	if err != nil {
		t.Skipf("falta %s", name)
	}
	return path
}

// dump is a backup (pg_dump -Fc) of the pool's database, like backup.sh's.
func dump(t *testing.T, pool *pgxpool.Pool) string {
	t.Helper()
	file := filepath.Join(t.TempDir(), "copia.dump")
	if out, err := exec.Command(pgTool(t, "pg_dump"), "-Fc", "-d", testdb.ConnString(pool), "-f", file).
		CombinedOutput(); err != nil {
		t.Fatalf("pg_dump: %v: %s", err, out)
	}
	return file
}

// restore restores the backup into a new empty database, like restore_check.sh.
func restore(t *testing.T, file string) *pgxpool.Pool {
	t.Helper()
	pool := testdb.NewEmpty(t)
	if out, err := exec.Command(pgTool(t, "pg_restore"), "--no-owner", "--no-privileges", "--exit-on-error",
		"-d", testdb.ConnString(pool), file).CombinedOutput(); err != nil {
		t.Fatalf("pg_restore: %v: %s", err, out)
	}
	return pool
}

func purgeLog(t *testing.T, p *platformtest.Platform) []admin.PurgeEntry {
	t.Helper()
	rows, err := p.Pool.Query(ctx, `select kind, id, purged_at from purge_log order by purged_at, kind, id`)
	if err != nil {
		t.Fatal(err)
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (admin.PurgeEntry, error) {
		var e admin.PurgeEntry
		err := r.Scan(&e.Kind, &e.ID, &e.PurgedAt)
		e.PurgedAt = e.PurgedAt.UTC()
		return e, err
	})
	if err != nil {
		t.Fatal(err)
	}
	return list
}

type nameRow struct {
	Status    string
	Character *int64
	Until     *time.Time
}

func nameOf(t *testing.T, p *platformtest.Platform, key string) nameRow {
	t.Helper()
	var r nameRow
	if err := p.Pool.QueryRow(ctx, `select status, character_id, reserved_until from character_names
		where world_id = 1 and name_key = $1`, key).Scan(&r.Status, &r.Character, &r.Until); err != nil {
		t.Fatalf("nombre %s: %v", key, err)
	}
	return r
}

func purgedAt(t *testing.T, p *platformtest.Platform, table, column string, id int64) *time.Time {
	t.Helper()
	var at *time.Time
	p.Scalar(&at, `select purged_at from `+table+` where `+column+` = $1`, id)
	return at
}

// A backup taken before purging, restored and with reapply-purges (§11.2): the tombstones end up
// with the original purged_at (the hourly job's and purge-now's, not the restore time), including
// the account's characters that were never deleted; no lease or ticket from the backup remains; the
// email fingerprint and the name reservation derive from purged_at; and a second pass changes
// nothing.
func TestReapplyPurgesAfterRestore(t *testing.T) {
	p := platformtest.New(t)
	_, adm := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	zone := p.NewZone(1, "vado_gris", 0).Start()
	a := p.NewPlayer("a@example.org")
	aLive := p.NewCharacter(a, "Aldric", "vardheim")
	aGone := p.NewCharacter(a, "Brenna", "vardheim")
	b := p.NewPlayer("b@example.org")
	bLive := p.NewCharacter(b, "Corwin", "vardheim")
	bDeleted := p.NewCharacter(b, "Dairine", "vardheim")
	platformtest.Expect(t, p.PublicDo("DELETE", "/v1/characters/"+idStr(bDeleted), b.Token,
		map[string]any{"confirm_name": "Dairine"}), http.StatusOK, "")
	zone.Join(a, aLive)   // lease and consumed ticket in the backup
	p.MustEnter(b, bLive) // unclaimed ticket in the backup
	p.Exec(`insert into sanctions (account_id, kind, reason, starts_at, created_at) values ($1, 'warning', 'spam', $2, $2)`,
		b.ID, p.Clock.Now())
	copyFile := dump(t, p.Pool)

	// After the backup: Brenna is deleted and the hourly job purges her (t1); account b, with Corwin,
	// who was never deleted, gets purge-now (t2).
	platformtest.Expect(t, p.PublicDo("DELETE", "/v1/characters/"+idStr(aGone), a.Token,
		map[string]any{"confirm_name": "Brenna"}), http.StatusOK, "")
	p.Clock.Advance(7*24*time.Hour + time.Minute)
	if err := p.Characters.Purger().PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	t1 := p.Clock.Now().UTC()
	p.Clock.Advance(time.Hour)
	if _, err := p.Admin.PurgeNow(ctx, adm, "b@example.org", 0); err != nil {
		t.Fatal(err)
	}
	t2 := p.Clock.Now().UTC()
	entries := purgeLog(t, p)
	// Dairine, deleted before the backup, also reaches her 7 days and the hourly job purges her.
	want := []admin.PurgeEntry{{admin.PurgeCharacter, aGone, t1}, {admin.PurgeCharacter, bDeleted, t1},
		{admin.PurgeAccount, b.ID, t2}, {admin.PurgeCharacter, bLive, t2}}
	if !reflect.DeepEqual(entries, want) {
		t.Fatalf("purge_log %+v", entries)
	}
	var hmac []byte
	var hashUntil time.Time
	p.Scalar(&hmac, `select hmac from sanctioned_email_hashes`)
	p.Scalar(&hashUntil, `select until from sanctioned_email_hashes`)
	corwin := nameOf(t, p, "corwin")

	// The backup, restored into another database, with another platform (another clock: the current
	// time).
	r := platformtest.Attach(t, restore(t, copyFile))
	if n := r.Count(`select count(*) from character_leases`); n != 1 {
		t.Fatalf("la copia trae %d arrendamientos", n)
	}
	actor, err := r.Admin.Authorize(ctx, "admin@example.org", sanctions.RoleAdmin)
	if err != nil {
		t.Fatal(err)
	}
	res, err := r.Admin.ReapplyPurges(ctx, actor, entries)
	if err != nil {
		t.Fatal(err)
	}
	if res.Entries != 4 || res.LeasesDeleted != 1 || res.TicketsDeleted != 2 || res.Accounts != 1 ||
		res.Characters != 3 || res.Unchanged != 0 {
		t.Fatalf("resultado %+v", res)
	}
	for _, c := range []struct {
		id int64
		at time.Time
	}{{aGone, t1}, {bDeleted, t1}, {bLive, t2}} {
		if at := purgedAt(t, r, "characters", "character_id", c.id); at == nil || !at.Equal(c.at) {
			t.Fatalf("personaje %d: purged_at %v y no %v", c.id, at, c.at)
		}
	}
	if at := purgedAt(t, r, "accounts", "account_id", b.ID); at == nil || !at.Equal(t2) {
		t.Fatalf("cuenta: purged_at %v y no %v", at, t2)
	}
	if n := r.Count(`select count(*) from accounts where account_id = $1 and status = 'purged' and email is null
		and password_hash is null`, b.ID); n != 1 {
		t.Fatal("la cuenta b no es una lápida")
	}
	if n := r.Count(`select count(*) from characters where character_id in ($1, $2, $3) and name is null`,
		aGone, bLive, bDeleted); n != 3 {
		t.Fatal("quedan nombres en las lápidas")
	}
	if n := r.Count(`select count(*) from characters where character_id = $1 and purged_at is null and name = 'Aldric'`,
		aLive); n != 1 {
		t.Fatal("el personaje vivo de a ha cambiado")
	}
	if n := r.Count(`select count(*) from character_leases`) + r.Count(`select count(*) from enter_tickets`); n != 0 {
		t.Fatalf("quedan %d arrendamientos o billetes de la copia", n)
	}
	if got := purgeLog(t, r); !reflect.DeepEqual(got, want) {
		t.Fatalf("purge_log restaurado %+v", got)
	}
	var rHMAC []byte
	var rUntil time.Time
	r.Scalar(&rHMAC, `select hmac from sanctioned_email_hashes`)
	r.Scalar(&rUntil, `select until from sanctioned_email_hashes`)
	if string(rHMAC) != string(hmac) || !rUntil.Equal(hashUntil) {
		t.Fatalf("huella del correo: %v hasta %v; la original, hasta %v", rHMAC, rUntil, hashUntil)
	}
	if n := r.Count(`select count(*) from sanctions where account_id = $1 and reason <> ''`, b.ID); n != 0 {
		t.Fatal("las sanciones de la cuenta purgada conservan el motivo")
	}
	if got := nameOf(t, r, "corwin"); !reflect.DeepEqual(got, corwin) {
		t.Fatalf("nombre de Corwin %+v; el original %+v", got, corwin)
	}
	// Brenna was alive in the backup: her name stays reserved for 30 days from purged_at.
	if got := nameOf(t, r, "brenna"); got.Status != "reserved" || got.Character != nil || got.Until == nil ||
		!got.Until.Equal(t1.Add(30*24*time.Hour)) {
		t.Fatalf("nombre de Brenna %+v", got)
	}
	row := lastAudit(t, r, "reapply-purges")
	if row.Source != "cli" || !is(row.Actor, adm.AccountID) || row.Args["entries"] != float64(4) ||
		row.Args["leases_deleted"] != float64(1) || row.Args["tickets_deleted"] != float64(2) ||
		row.Args["os_user"] != "prueba" {
		t.Fatalf("fila reapply-purges %+v", row)
	}

	// Idempotent.
	res, err = r.Admin.ReapplyPurges(ctx, actor, entries)
	if err != nil {
		t.Fatal(err)
	}
	if res.Accounts != 0 || res.Characters != 0 || res.Unchanged != 4 || res.LeasesDeleted != 0 {
		t.Fatalf("segunda vuelta %+v", res)
	}
	if got := purgeLog(t, r); !reflect.DeepEqual(got, want) {
		t.Fatalf("purge_log tras la segunda vuelta %+v", got)
	}
}

// noPurge is a character purge that purges nothing.
type noPurge struct{}

func (noPurge) ReapplyPurge(context.Context, int64, time.Time) (bool, error) { return false, nil }

// reapply-purges exits with an error if a purges.txt id is left unpurged (and names it); an id that
// the backup does not have counts as purged; without anything to purge characters, it does nothing.
func TestReapplyPurgesReportsWhatStaysUnpurged(t *testing.T) {
	p := platformtest.New(t)
	_, adm := staff(t, p, "admin@example.org", sanctions.RoleAdmin)
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aldric", "vardheim")
	set, err := legal.Load(legal.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	broken, err := admin.New(admin.Options{Pool: p.Pool, Accounts: p.Accounts, Characters: noPurge{}, Legal: set})
	if err != nil {
		t.Fatal(err)
	}
	at := p.Clock.Now().Add(-time.Hour)
	entries := []admin.PurgeEntry{{admin.PurgeCharacter, id, at}, {admin.PurgeCharacter, id + 1000, at},
		{admin.PurgeAccount, pl.ID + 1000, at}}
	_, err = broken.ReapplyPurges(ctx, adm, entries)
	var unpurged *admin.UnpurgedError
	if !errors.As(err, &unpurged) || len(unpurged.Accounts) != 0 || !reflect.DeepEqual(unpurged.Characters, []int64{id}) ||
		!strings.Contains(err.Error(), strconv.FormatInt(id, 10)) {
		t.Fatalf("sin purgar: %v", err)
	}
	// With the real purge, the same file works (ids that do not exist do not count).
	res, err := p.Admin.ReapplyPurges(ctx, adm, entries)
	if err != nil || res.Characters != 1 || res.Unchanged != 2 {
		t.Fatalf("%+v %v", res, err)
	}
	none, err := admin.New(admin.Options{Pool: p.Pool, Accounts: p.Accounts, Legal: set})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := none.ReapplyPurges(ctx, adm, entries); !errors.Is(err, admin.ErrNoCharacterPurger) {
		t.Fatalf("sin purga de personajes: %v", err)
	}
}
