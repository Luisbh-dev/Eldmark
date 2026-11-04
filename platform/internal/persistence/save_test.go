package persistence_test

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/zones"
)

// inWorld is a character claimed in a live zone.
type inWorld struct {
	p     *platformtest.Platform
	z     *platformtest.Zone
	pl    *platformtest.Player
	id    int64
	lease string
}

func newInWorld(t *testing.T) *inWorld {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	return &inWorld{p: p, z: z, pl: pl, id: id, lease: z.Join(pl, id)}
}

func (w *inWorld) body(seq int) map[string]any { return w.z.SaveBody(w.id, w.lease, seq) }

// leaseState is what the lease stores from the last save.
func (w *inWorld) leaseState() (seq, version int64) {
	w.p.T.Helper()
	if err := w.p.Pool.QueryRow(context.Background(), `select last_seq, last_save_version from character_leases
		where character_id = $1`, w.id).Scan(&seq, &version); err != nil {
		w.p.T.Fatal(err)
	}
	return seq, version
}

func expectSave(t *testing.T, res *platformtest.Response, applied, duplicate bool, version int64) {
	t.Helper()
	platformtest.Expect(t, res, 200, "")
	if res.Body["applied"] != applied || res.Body["duplicate"] != duplicate || res.Int("save_version") != version ||
		res.String("instance_status") == "" {
		t.Fatalf("se esperaba applied=%v duplicate=%v save_version=%d: %s", applied, duplicate, version, res.Raw)
	}
}

// Idempotency by (lease_id, seq): a retry with the same bytes (the deadline expired but the save was
// applied) is duplicate with the save_version of that time and does not call Apply again, so the
// next one, with its new ops, passes S2; the same seq with another body is seq_conflict and a lower
// one, stale_seq.
func TestSaveSeqIdempotency(t *testing.T) {
	w := newInWorld(t)
	first := w.body(1)
	first["progress"].(map[string]any)["ops"] = []any{map[string]any{"op_id": "5"}}
	raw := platformtest.Marshal(first)
	expectSave(t, w.z.Save(w.id, raw), true, false, 1)
	expectSave(t, w.z.Save(w.id, raw), false, true, 1)

	second := w.body(2)
	second["progress"].(map[string]any)["ops"] = []any{map[string]any{"op_id": "6"}}
	expectSave(t, w.z.Save(w.id, second), true, false, 2)
	if seq, version := w.leaseState(); seq != 2 || version != 2 {
		t.Fatalf("arrendamiento: seq %d, versión %d", seq, version)
	}
	other := w.body(2)
	other["reason"] = 2
	platformtest.Expect(t, w.z.Save(w.id, other), 409, "seq_conflict")
	platformtest.Expect(t, w.z.Save(w.id, raw), 409, "stale_seq")
	// An op_id already stored in a new seq is the fake's S2: nothing written.
	third := w.body(3)
	third["progress"].(map[string]any)["ops"] = []any{map[string]any{"op_id": "5"}}
	res := w.z.Save(w.id, third)
	platformtest.Expect(t, res, 400, "invalid_save")
	if res.Field("check") != "S2" {
		t.Fatal(res.Raw)
	}
	if seq, _ := w.leaseState(); seq != 2 {
		t.Fatal("un invalid_save no escribe")
	}
	if !strings.Contains(w.p.Logs.String(), "guardado rechazado") {
		t.Fatal("se registra")
	}
}

// A duplicate returns the save_version from when it was applied (character_leases'), even if the
// store's has moved on.
func TestDuplicateKeepsItsSaveVersion(t *testing.T) {
	w := newInWorld(t)
	raw := platformtest.Marshal(w.body(1))
	expectSave(t, w.z.Save(w.id, raw), true, false, 1)
	inst, _ := zones.ParseUUID(w.z.ID)
	if _, err := w.p.Progress.Apply(context.Background(), nil, persistence.SaveKey{CharacterID: w.id, InstanceID: inst},
		json.RawMessage(`{"progress_format": 1}`)); err != nil {
		t.Fatal(err)
	}
	if w.p.Progress.SaveVersion(w.id) != 2 {
		t.Fatal("el almacén sigue")
	}
	expectSave(t, w.z.Save(w.id, raw), false, true, 1)
}

// Without the lease: another lease_id, another instance or no row (purged character) -> lease_lost.
func TestSaveLeaseLost(t *testing.T) {
	w := newInWorld(t)
	b := w.body(1)
	b["lease_id"] = zones.FormatUUID(zones.NewUUID())
	platformtest.Expect(t, w.z.Save(w.id, b), 409, "lease_lost")
	// From another instance of the same zone and channel (replacement) with the right lease_id.
	fresh := w.p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, fresh.Register(map[string]any{"replace": true}), 200, "")
	platformtest.Expect(t, fresh.Live(), 204, "")
	b = fresh.SaveBody(w.id, w.lease, 1)
	platformtest.Expect(t, fresh.Save(w.id, b), 409, "lease_lost")
	// Without a lease row.
	w.p.Exec(`delete from character_leases where character_id = $1`, w.id)
	platformtest.Expect(t, w.z.Save(w.id, w.body(1)), 409, "lease_lost")
	// The envelope's instance has to be within the token's scope.
	other := w.p.NewZone(1, "test_world", 0).Start()
	b = w.body(1)
	b["zone_instance_id"] = other.ID
	platformtest.Expect(t, w.z.Save(w.id, b), 403, "forbidden")
}

// A late save after releasing is valid (lease_id does not change on release); after another claim,
// it is not.
func TestLateSaveAfterReleaseAndAfterAnotherClaim(t *testing.T) {
	w := newInWorld(t)
	platformtest.Expect(t, w.z.Release(w.id, w.lease), 204, "")
	platformtest.Expect(t, w.z.Release(w.id, w.lease), 204, "") // repeated
	expectSave(t, w.z.Save(w.id, w.body(1)), true, false, 1)
	var free bool
	w.p.Scalar(&free, `select zone_instance_id is null from character_leases where character_id = $1`, w.id)
	if !free {
		t.Fatal("el guardado tardío no vuelve a tomar el arrendamiento")
	}
	old := w.lease
	w.lease = w.z.Join(w.pl, w.id)
	if w.lease == old {
		t.Fatal("una reclamación cambia el lease_id")
	}
	b := w.z.SaveBody(w.id, old, 2)
	platformtest.Expect(t, w.z.Save(w.id, b), 409, "lease_lost")
	platformtest.Expect(t, w.z.Release(w.id, old), 409, "lease_lost")
	// The new lease starts at seq 1.
	expectSave(t, w.z.Save(w.id, w.body(1)), true, false, 2)
}

// release_lease releases the lease with the save: the character can enter again.
func TestSaveWithReleaseLease(t *testing.T) {
	w := newInWorld(t)
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 409, "character_busy")
	b := w.body(1)
	b["release_lease"] = true
	b["reason"] = 3
	expectSave(t, w.z.Save(w.id, b), true, false, 1)
	var free bool
	w.p.Scalar(&free, `select zone_instance_id is null and released_at = $2 from character_leases where character_id = $1`,
		w.id, w.p.Clock.Now())
	if !free {
		t.Fatal("liberado")
	}
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 200, "")
}

// Envelope errors are 400 invalid_save with check envelope, before touching the database.
func TestEnvelopeErrors(t *testing.T) {
	w := newInWorld(t)
	cases := map[string]func(map[string]any){
		"campo desconocido":  func(b map[string]any) { b["world_id"] = 1 },
		"save_format 2":      func(b map[string]any) { b["save_format"] = 2 },
		"otro personaje":     func(b map[string]any) { b["character_id"] = strconv.FormatInt(w.id+1, 10) },
		"id sin comillas":    func(b map[string]any) { b["character_id"] = w.id },
		"seq 0":              func(b map[string]any) { b["seq"] = 0 },
		"seq 1.5":            func(b map[string]any) { b["seq"] = 1.5 },
		"reason 6":           func(b map[string]any) { b["reason"] = 6 },
		"sin progress":       func(b map[string]any) { delete(b, "progress") },
		"progress null":      func(b map[string]any) { b["progress"] = nil },
		"sin lease_id":       func(b map[string]any) { delete(b, "lease_id") },
		"lease_id roto":      func(b map[string]any) { b["lease_id"] = "x" },
		"pvp incompleto":     func(b map[string]any) { b["pvp"] = map[string]any{"kills": 1} },
		"pvp negativo":       func(b map[string]any) { b["pvp"] = pvp(-1) },
		"pvp con otra clave": func(b map[string]any) { p := pvp(1); p["score"] = 1; b["pvp"] = p },
		// The five int4 totals of character_pvp_stats (only gate_damage is bigint): more than 2^31 - 1 was
		// a 500 that the zone retried endlessly.
		"kills de más de int4":    func(b map[string]any) { p := pvp(1); p["kills"] = int64(1) << 31; b["pvp"] = p },
		"defend_s de más de int4": func(b map[string]any) { p := pvp(1); p["defend_s"] = 3000000000; b["pvp"] = p },
		"instancia rota":          func(b map[string]any) { b["zone_instance_id"] = strings.ToUpper(w.z.ID) },
		"release_lease texto":     func(b map[string]any) { b["release_lease"] = "sí" },
	}
	for name, mutate := range cases {
		b := w.body(1)
		mutate(b)
		res := w.z.Save(w.id, b)
		platformtest.Expect(t, res, 400, "invalid_save")
		if res.Field("check") != "envelope" {
			t.Errorf("%s: %s", name, res.Raw)
		}
	}
	for _, raw := range []string{"", "{", "[]", `{"save_format": 1} {}`} {
		res := w.z.Save(w.id, raw)
		platformtest.Expect(t, res, 400, "invalid_save")
	}
	res := w.z.Do("PUT", "/internal/v1/characters/x/state", w.body(1))
	platformtest.Expect(t, res, 400, "invalid_save")
	if seq, _ := w.leaseState(); seq != 0 || w.p.Progress.SaveVersion(w.id) != 0 {
		t.Fatal("nada escrito")
	}
}

func pvp(n int) map[string]any {
	return map[string]any{"kills": n, "deaths": n, "assists": n, "captures": n, "gate_damage": n, "defend_s": n}
}

// The pvp section: a save with "kills": 4.0 is applied; one without pvp does not change
// character_pvp_stats and one with lower kills does not lower it.
func TestSavePvP(t *testing.T) {
	w := newInWorld(t)
	raw := `{"save_format": 1, "character_id": "` + strconv.FormatInt(w.id, 10) + `", "zone_instance_id": "` + w.z.ID +
		`", "lease_id": "` + w.lease + `", "seq": 1.0, "reason": 1, "release_lease": false,
		"progress": {"progress_format": 1.0, "level": 2.0},
		"pvp": {"kills": 4.0, "deaths": 1, "assists": 0, "captures": 1, "gate_damage": 450, "defend_s": 120}}`
	expectSave(t, w.z.Save(w.id, raw), true, false, 1)
	stats := func() []int64 {
		var k, d, a, c, g, s int64
		if err := w.p.Pool.QueryRow(context.Background(), `select kills, deaths, assists, captures, gate_damage, defend_s
			from character_pvp_stats where character_id = $1`, w.id).Scan(&k, &d, &a, &c, &g, &s); err != nil {
			t.Fatal(err)
		}
		return []int64{k, d, a, c, g, s}
	}
	want := []int64{4, 1, 0, 1, 450, 120}
	if got := stats(); !equal(got, want) {
		t.Fatalf("pvp %v", got)
	}
	expectSave(t, w.z.Save(w.id, w.body(2)), true, false, 2) // without pvp
	if got := stats(); !equal(got, want) {
		t.Fatalf("sin pvp no cambia: %v", got)
	}
	b := w.body(3)
	b["pvp"] = map[string]any{"kills": 2, "deaths": 5, "assists": 0, "captures": 1, "gate_damage": 100, "defend_s": 130}
	expectSave(t, w.z.Save(w.id, b), true, false, 3)
	if got := stats(); !equal(got, []int64{4, 5, 0, 1, 450, 130}) {
		t.Fatalf("greatest: %v", got)
	}
	// Each column's cap is valid: 2^31 - 1 in the int4 ones and more in gate_damage (bigint).
	b = w.body(4)
	b["pvp"] = map[string]any{"kills": 1<<31 - 1, "deaths": 1<<31 - 1, "assists": 1<<31 - 1, "captures": 1<<31 - 1,
		"gate_damage": int64(1) << 40, "defend_s": 1<<31 - 1}
	expectSave(t, w.z.Save(w.id, b), true, false, 4)
	// The next claim brings the totals.
	b = w.body(5)
	b["release_lease"] = true
	expectSave(t, w.z.Save(w.id, b), true, false, 5)
	ticket, _ := w.p.MustEnter(w.pl, w.id)
	res := w.z.Claim(ticket, w.id)
	platformtest.Expect(t, res, 200, "")
	if res.Body["pvp"].(map[string]any)["deaths"].(json.Number).String() != "2147483647" {
		t.Fatal(res.Raw)
	}
}

func equal(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// An *InvalidSaveError from the fake is 400 invalid_save with its check and its detail, and nothing
// is written.
func TestInvalidSaveFromTheStore(t *testing.T) {
	w := newInWorld(t)
	w.p.Progress.SetApplyHook(func(persistence.SaveKey, json.RawMessage) error {
		return &persistence.InvalidSaveError{Check: "S4", Detail: "los objetos no cuadran"}
	})
	b := w.body(1)
	b["pvp"] = pvp(7)
	res := w.z.Save(w.id, b)
	platformtest.Expect(t, res, 400, "invalid_save")
	if res.Field("check") != "S4" || res.Field("detail") != "los objetos no cuadran" {
		t.Fatal(res.Raw)
	}
	if seq, _ := w.leaseState(); seq != 0 || w.p.Count(`select kills from character_pvp_stats where character_id = $1`, w.id) != 0 {
		t.Fatal("nada escrito")
	}
}

// A 23505 on COMMIT (a deferred constraint, like the slots one of progresion.md) is 400
// invalid_save with check S8 and the SQLSTATE and the constraint in detail; nothing is written.
func TestDeferredConstraintAtCommit(t *testing.T) {
	w := newInWorld(t)
	w.p.Exec(`create table test_slots (character_id bigint, slot int,
		constraint test_slots_unique unique (character_id, slot) deferrable initially deferred)`)
	w.p.Progress.SetApplyTxHook(func(ctx context.Context, tx pgx.Tx, key persistence.SaveKey, _ json.RawMessage) error {
		_, err := tx.Exec(ctx, `insert into test_slots values ($1, 0), ($1, 0)`, key.CharacterID)
		return err
	})
	b := w.body(1)
	b["pvp"] = pvp(3)
	res := w.z.Save(w.id, b)
	platformtest.Expect(t, res, 400, "invalid_save")
	if res.Field("check") != "S8" || !strings.Contains(res.Field("detail"), "23505") ||
		!strings.Contains(res.Field("detail"), "test_slots_unique") {
		t.Fatal(res.Raw)
	}
	if seq, _ := w.leaseState(); seq != 0 || w.p.Count(`select count(*) from test_slots`) != 0 ||
		w.p.Count(`select kills from character_pvp_stats where character_id = $1`, w.id) != 0 {
		t.Fatal("nada escrito")
	}
}

// A 40001 that repeats: the platform retries the whole transaction (four attempts) and then answers
// 503 db_unavailable; nothing is written.
func TestSerializationFailureThatRepeats(t *testing.T) {
	w := newInWorld(t)
	var calls atomic.Int32
	w.p.Progress.SetApplyHook(func(persistence.SaveKey, json.RawMessage) error {
		calls.Add(1)
		return &pgconn.PgError{Code: "40001", Message: "could not serialize access"}
	})
	res := w.z.Save(w.id, w.body(1))
	platformtest.Expect(t, res, 503, "db_unavailable")
	if calls.Load() != 4 {
		t.Fatalf("intentos: %d", calls.Load())
	}
	if seq, _ := w.leaseState(); seq != 0 {
		t.Fatal("nada escrito")
	}
	// One that clashes once and then goes through: it is applied.
	calls.Store(0)
	w.p.Progress.SetApplyHook(func(persistence.SaveKey, json.RawMessage) error {
		if calls.Add(1) == 1 {
			return &pgconn.PgError{Code: "40P01"}
		}
		return nil
	})
	expectSave(t, w.z.Save(w.id, w.body(1)), true, false, 1)
}

// 100 concurrent saves of the same character: eight at a time, each with the next seq from a
// shared counter (so they cross and arrive out of order). Those that are applied are exactly the
// final save_version; the others are stale_seq.
func TestConcurrentSaves(t *testing.T) {
	w := newInWorld(t)
	bodies := make([][]byte, 100)
	for i := range bodies {
		bodies[i] = platformtest.Marshal(w.body(i + 1))
	}
	var next, applied, stale atomic.Int32
	var wg sync.WaitGroup
	errs := make(chan string, 100)
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(next.Add(1)) - 1
				if i >= len(bodies) {
					return
				}
				res := w.z.Save(w.id, bodies[i])
				switch {
				case res.Status == 200 && res.Body["applied"] == true:
					applied.Add(1)
				case res.Code() == "stale_seq":
					stale.Add(1)
				default:
					errs <- res.Raw
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Fatal(e)
	}
	seq, version := w.leaseState()
	if int64(applied.Load()) != version || w.p.Progress.SaveVersion(w.id) != version || applied.Load()+stale.Load() != 100 ||
		seq != 100 {
		t.Fatalf("aplicados %d, viejos %d, save_version %d (almacén %d), seq %d", applied.Load(), stale.Load(), version,
			w.p.Progress.SaveVersion(w.id), seq)
	}
	t.Logf("aplicados %d de 100", applied.Load())
}

// After replace, the replaced instance sends its final save and it is valid (instance_status
// replaced); until then, claiming the character on the new one gives character_busy, and afterwards
// the claim brings that final one.
func TestReplacedInstanceFinalSave(t *testing.T) {
	w := newInWorld(t)
	expectSave(t, w.z.Save(w.id, w.body(1)), true, false, 1)
	fresh := w.p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, fresh.Register(map[string]any{"replace": true}), 200, "")
	platformtest.Expect(t, fresh.Live(), 204, "")

	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 409, "character_busy")
	// A hand-made ticket for the new one (enter does not give it with the character inside).
	var session int64
	w.p.Scalar(&session, `select session_id from sessions where account_id = $1 and revoked_at is null`, w.pl.ID)
	w.p.Exec(`insert into enter_tickets (ticket_id, world_id, character_id, session_id, zone_instance_id, issued_at,
		expires_at) values (77, 1, $1, $2, $3, $4, $5)`, w.id, session, fresh.ID, w.p.Clock.Now(), w.p.Clock.Now().Add(10*time.Second))
	platformtest.Expect(t, fresh.Claim(77, w.id), 409, "character_busy")

	final := w.body(2)
	final["reason"] = 4
	final["release_lease"] = true
	final["progress"].(map[string]any)["level"] = 9
	res := w.z.Save(w.id, final)
	expectSave(t, res, true, false, 2)
	if res.String("instance_status") != "replaced" {
		t.Fatal(res.Raw)
	}
	res = fresh.Claim(77, w.id)
	platformtest.Expect(t, res, 200, "")
	if res.Body["progress"].(map[string]any)["level"].(json.Number).String() != "9" {
		t.Fatalf("la reclamación trae el final: %s", res.Raw)
	}
}

// Without a final save, the replaced instance's lease expires with the TTL.
func TestReplacedInstanceLeaseExpires(t *testing.T) {
	w := newInWorld(t)
	fresh := w.p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, fresh.Register(map[string]any{"replace": true}), 200, "")
	platformtest.Expect(t, fresh.Live(), 204, "")
	platformtest.Expect(t, w.p.Enter(w.pl, w.id), 409, "character_busy")
	w.p.Clock.Advance(31 * time.Second)
	w.p.Login(w.pl)
	fresh.Join(w.pl, w.id)
}

// Several saves in a batch: all or none; all new or all repeated.
func TestSaveMany(t *testing.T) {
	w := newInWorld(t)
	b := w.p.NewPlayer("b@example.org")
	idB := w.p.NewCharacter(b, "Bran", "vardheim")
	leaseB := w.z.Join(b, idB)
	batch := func(saves ...map[string]any) []byte {
		raws := make([]json.RawMessage, len(saves))
		for i, s := range saves {
			raws[i] = platformtest.Marshal(s)
		}
		return platformtest.Marshal(map[string]any{"zone_instance_id": w.z.ID, "saves": raws})
	}
	first := batch(w.body(1), w.z.SaveBody(idB, leaseB, 1))
	res := w.z.Do("POST", "/internal/v1/saves", first)
	platformtest.Expect(t, res, 200, "")
	saves := res.Body["saves"].([]any)
	if len(saves) != 2 || saves[0].(map[string]any)["applied"] != true || saves[1].(map[string]any)["character_id"] !=
		strconv.FormatInt(idB, 10) {
		t.Fatal(res.Raw)
	}
	res = w.z.Do("POST", "/internal/v1/saves", first)
	platformtest.Expect(t, res, 200, "")
	if res.Body["saves"].([]any)[1].(map[string]any)["duplicate"] != true {
		t.Fatal(res.Raw)
	}
	// A mix of new and repeated.
	platformtest.Expect(t, w.z.Do("POST", "/internal/v1/saves", batch(w.body(1), w.z.SaveBody(idB, leaseB, 2))), 409,
		"seq_conflict")
	// One without a lease: the whole batch fails, with the character.
	res = w.z.Do("POST", "/internal/v1/saves", batch(w.body(2), w.z.SaveBody(idB, zones.FormatUUID(zones.NewUUID()), 2)))
	platformtest.Expect(t, res, 409, "lease_lost")
	if res.ErrValue("character_id") != strconv.FormatInt(idB, 10) {
		t.Fatal(res.Raw)
	}
	if seq, _ := w.leaseState(); seq != 1 {
		t.Fatal("todo o nada")
	}
	// The same character twice and an envelope from another instance: envelope.
	platformtest.Expect(t, w.z.Do("POST", "/internal/v1/saves", batch(w.body(2), w.body(3))), 400, "invalid_save")
	other := w.body(2)
	other["zone_instance_id"] = zones.FormatUUID(zones.NewUUID())
	platformtest.Expect(t, w.z.Do("POST", "/internal/v1/saves", batch(other)), 400, "invalid_save")
	// A pvp total that does not fit in its column: envelope (final), not a 500 that takes down the
	// batch.
	big := w.body(2)
	big["pvp"] = map[string]any{"kills": 3000000000, "deaths": 0, "assists": 0, "captures": 0, "gate_damage": 0, "defend_s": 0}
	res = w.z.Do("POST", "/internal/v1/saves", batch(big, w.z.SaveBody(idB, leaseB, 2)))
	platformtest.Expect(t, res, 400, "invalid_save")
	if res.Field("check") != "envelope" {
		t.Fatal(res.Raw)
	}
}

// Operation and ledger: only with a lease on the instance (the character's for the ledger; some
// participant's for the operation); otherwise, 404.
func TestOpsAndLedger(t *testing.T) {
	w := newInWorld(t)
	b := w.p.NewPlayer("b@example.org")
	idB := w.p.NewCharacter(b, "Bran", "vardheim")
	w.p.Progress.AddOp(77, []int64{w.id}, json.RawMessage(`{"op": {"op_id": "77", "kind": 4}}`))
	w.p.Progress.AddOp(78, []int64{idB}, json.RawMessage(`{"op": {"op_id": "78", "kind": 4}}`))
	q := "?zone_instance_id=" + w.z.ID
	res := w.z.Do("GET", "/internal/v1/ops/77"+q, nil)
	platformtest.Expect(t, res, 200, "")
	if res.Body["op"].(map[string]any)["op_id"] != "77" {
		t.Fatal(res.Raw)
	}
	platformtest.Expect(t, w.z.Do("GET", "/internal/v1/ops/78"+q, nil), 404, "not_found")
	platformtest.Expect(t, w.z.Do("GET", "/internal/v1/ops/79"+q, nil), 404, "not_found")
	platformtest.Expect(t, w.z.Do("GET", "/internal/v1/ops/x"+q, nil), 404, "not_found")

	ledger := func(id int64, extra string) *platformtest.Response {
		return w.z.Do("GET", "/internal/v1/characters/"+strconv.FormatInt(id, 10)+"/ledger"+q+extra, nil)
	}
	res = ledger(w.id, "&limit=100&before_entry_id=900")
	platformtest.Expect(t, res, 200, "")
	if _, ok := res.Body["entries"]; !ok {
		t.Fatal(res.Raw)
	}
	platformtest.Expect(t, ledger(idB, ""), 404, "not_found")
	platformtest.Expect(t, ledger(w.id, "&limit=0"), 400, "validation")
	platformtest.Expect(t, ledger(w.id, "&limit=101"), 400, "validation")
	platformtest.Expect(t, ledger(w.id, "&before_entry_id=-1"), 400, "validation")
	// Another instance of another zone sees neither the ledger nor the operation.
	other := w.p.NewZone(1, "test_world", 0).Start()
	platformtest.Expect(t, other.Do("GET", "/internal/v1/ops/77?zone_instance_id="+other.ID, nil), 404, "not_found")
	platformtest.Expect(t, other.Do("GET", "/internal/v1/characters/"+strconv.FormatInt(w.id, 10)+
		"/ledger?zone_instance_id="+other.ID, nil), 404, "not_found")
	// Without zone_instance_id: 400.
	platformtest.Expect(t, w.z.Do("GET", "/internal/v1/ops/77", nil), 400, "validation")
}
