package progress_test

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/db"
)

// Each case in save_cases.json, on a fresh database, yields at each step what its expect says: the
// same cases the zone generates with PlayerProgress (progression.md §13.3), so the two
// implementations do not diverge.
func TestApplyFixtures(t *testing.T) {
	c := loadCases(t)
	checks := map[string]int{}
	for _, sc := range c.Cases {
		for _, st := range sc.Steps {
			checks[st.Expect]++
		}
		t.Run(sc.Name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t, c)
			for i, st := range sc.Steps {
				got, _ := w.apply(int64(st.CharacterID), st.Progress)
				if got != st.Expect {
					t.Fatalf("paso %d (%s): %s, se esperaba %s", i, sc.Rule, got, st.Expect)
				}
			}
		})
	}
	for _, check := range []string{"applied", "S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8"} {
		if checks[check] == 0 {
			t.Errorf("ningún paso espera %s", check)
		}
	}
}

// S8 writes the save: save_version goes up one at a time, saved_at is the store's time, balances
// carry their last_seq and entries their seq, objects their created_op, operations the instance's
// zone, and each GM or REVERSAL leaves its audit_log row with op:<op_id> (at = detail.at_unix),
// without duplicating the one the zone's batch already sent.
func TestApplyWritesTheSave(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	_, kit := c.step(t, "valid_reversal", 0)
	_, play := c.step(t, "valid_reversal", 1)
	_, reversal := c.step(t, "valid_reversal", 2)
	start := w.clock.now()
	if got, version := w.apply(42, kit); got != "applied" || version != 1 {
		t.Fatalf("kit: %s %d", got, version)
	}
	w.clock.advance(time.Minute)
	if got, version := w.apply(42, play); got != "applied" || version != 2 {
		t.Fatalf("juego: %s %d", got, version)
	}
	var savedAt time.Time
	var version int64
	w.scalar(&savedAt, `select saved_at from character_progress where character_id = 42`)
	w.scalar(&version, `select save_version from character_progress where character_id = 42`)
	if !savedAt.Equal(start.Add(time.Minute)) || version != 2 {
		t.Fatalf("saved_at %v, save_version %d", savedAt, version)
	}
	if n := w.count(`select count(*) from character_wallets where character_id = 42 and ((currency = 1 and balance = 52
		and last_seq = 2) or (currency = 2 and balance = 30 and last_seq = 1))`); n != 2 {
		t.Fatalf("saldos: %d", n)
	}
	if n := w.count(`select count(*) from ledger_entries where character_id = 42 and ((op_id = 1031 and currency = 1
		and seq = 1 and balance_after = 2 and ref_kind = 2 and ref_id = 3021413298) or (op_id = 1032 and currency = 1
		and seq = 2 and balance_after = 52) or (op_id = 1031 and currency = 2 and seq = 1 and ref_id = 88))`); n != 3 {
		t.Fatalf("apuntes: %d", n)
	}
	if n := w.count(`select count(*) from economy_ops where zone_id = 'vado_gris' and op_id in (1025, 1030, 1031, 1032)`); n != 4 {
		t.Fatalf("operaciones: %d", n)
	}
	if n := w.count(`select count(*) from item_events where character_id = 42`); n != 7 {
		t.Fatalf("eventos: %d", n)
	}
	if n := w.count(`select count(*) from item_instances where created_op = 1025 and uid between 1026 and 1029`); n != 4 {
		t.Fatalf("created_op del kit: %d", n)
	}
	var row struct {
		world                         int16
		zone, source, command, args   string
		actor, actorChar, target, acc int64
		at                            time.Time
	}
	w.scalar(&row.world, `select world_id from audit_log where event_key = 'op:1032'`)
	if err := w.pool.QueryRow(context.Background(), `select zone_id, source, command, args::text, actor_account_id,
			actor_character_id, target_character_id, target_account_id, at
		from audit_log where event_key = 'op:1032'`).Scan(&row.zone, &row.source, &row.command, &row.args, &row.actor,
		&row.actorChar, &row.target, &row.acc, &row.at); err != nil {
		t.Fatal(err)
	}
	if row.world != 1 || row.zone != "vado_gris" || row.source != "zone" || row.command != "currency_add" ||
		row.args != `{"args": ["42", "oro", "50"]}` || row.actor != 77 || row.actorChar != 41 || row.target != 42 ||
		row.acc != 7 || !row.at.Equal(time.Unix(c.NowUnix, 0)) {
		t.Fatalf("auditoría de la GM: %+v", row)
	}
	// The zone batch's entry arrives earlier with the same key: the save neither duplicates nor overwrites it.
	w.exec(`insert into audit_log (world_id, zone_id, source, actor_account_id, actor_character_id, command,
			target_account_id, target_character_id, args, at, event_key)
		values (1, 'vado_gris', 'zone', 77, 41, 'op_revert', 7, 42, '{"args": ["1032", "del lote"]}', now(), 'op:1033')`)
	if got, _ := w.apply(42, reversal); got != "applied" {
		t.Fatalf("reversión: %s", got)
	}
	if n := w.count(`select count(*) from audit_log where event_key = 'op:1033' and args->'args'->>1 = 'del lote'`); n != 1 ||
		w.count(`select count(*) from audit_log where event_key like 'op:%'`) != 2 {
		t.Fatal("la fila de la REVERSAL se duplica o se pisa")
	}
	if n := w.count(`select count(*) from op_reversals where op_id = 1032 and reversal_op_id = 1033`); n != 1 {
		t.Fatalf("op_reversals: %d", n)
	}
	// The console: source console and no actor.
	w.clock.advance(time.Minute)
	idle := edit(t, reversal, func(m map[string]any) { m["ops"] = []any{} })
	if got, _ := w.apply(42, withOps(t, idle, 3, gmOp(1100, w.clock.now().Unix(), 1, 3))); got != "applied" {
		t.Fatalf("GM de la consola: %s", got)
	}
	var source string
	var actor, actorChar *int64
	if err := w.pool.QueryRow(context.Background(), `select source, actor_account_id, actor_character_id from audit_log
		where event_key = 'op:1100'`).Scan(&source, &actor, &actorChar); err != nil || source != "console" ||
		actor != nil || actorChar != nil {
		t.Fatalf("auditoría de la consola: %s %v %v %v", source, actor, actorChar, err)
	}
}

// S7 accepts an expired timer in a late retry (the platform's clock has already passed its end)
// and stores it; one more than 7 days from the store's time, no.
func TestApplyLateRetryKeepsExpiredTimers(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	body := edit(t, kit, func(m map[string]any) {
		m["timers"] = []any{map[string]any{"key": "unstuck", "ends_at_unix": c.NowUnix + 30}}
	})
	w.clock.advance(10 * time.Minute)
	if got, _ := w.apply(42, body); got != "applied" {
		t.Fatalf("reintento tardío: %s", got)
	}
	timers := w.load(42)["timers"].([]any)
	if len(timers) != 1 || timers[0].(map[string]any)["ends_at_unix"].(json.Number).String() != id(c.NowUnix+30) {
		t.Fatalf("temporizadores: %v", timers)
	}
	far := edit(t, kit, func(m map[string]any) {
		m["ops"] = []any{}
		m["timers"] = []any{map[string]any{"key": "unstuck", "ends_at_unix": w.clock.now().Unix() + 7*86400 + 1}}
	})
	if got, _ := w.apply(42, far); got != "S7" {
		t.Fatalf("a más de 7 días: %s", got)
	}
	// With no timers in the body, the set is emptied.
	if got, _ := w.apply(42, edit(t, far, func(m map[string]any) { m["timers"] = []any{} })); got != "applied" ||
		w.count(`select count(*) from character_timers`) != 0 {
		t.Fatalf("sin temporizadores: %s", got)
	}
}

// S2 looks at the actor's role at detail.at_unix: a GM created before set-role demoted the GM to
// player is stored; one created after is not; and a set-role row that is not from the CLI does not count.
func TestApplyActorRoleAtTheTime(t *testing.T) {
	c := loadCases(t)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	_, play := c.step(t, "valid_kit_and_play", 1)
	w := newWorld(t, c)
	w.apply(42, kit)
	w.exec(`update accounts set role = 'player' where account_id = 77`)
	w.exec(`insert into audit_log (source, actor_account_id, command, target_account_id, args, at, event_key)
		values ('cli', 78, 'set-role', 77, '{"from": "gm", "to": "player", "os_user": "prueba"}', to_timestamp($1), 'cli:1')`,
		c.NowUnix+30)
	if got, _ := w.apply(42, play); got != "applied" {
		t.Fatalf("GM de antes del set-role: %s", got)
	}
	w.clock.advance(time.Minute)
	late := withOps(t, play, 57, map[string]any{"op_id": "1100", "kind": 4, "actor_account_id": "77",
		"ref_op_id": nil, "note": "tarde", "detail": map[string]any{"command": "currency_add",
			"args": []any{"42", "oro", "5"}, "at_unix": c.NowUnix + 40, "source": "gm", "actor_character_id": "41"},
		"ledger": []any{map[string]any{"currency": 1, "delta": 5, "balance_after": 57, "reason": 7, "ref_kind": 0,
			"ref_id": "0"}}, "items": []any{}})
	if got, _ := w.apply(42, late); got != "S2" {
		t.Fatalf("GM de después del set-role: %s", got)
	}
	// A set-role row with source zone does not give the earlier role.
	w2 := newWorld(t, c)
	w2.apply(42, kit)
	w2.exec(`update accounts set role = 'player' where account_id = 77`)
	w2.exec(`insert into audit_log (source, actor_account_id, command, target_account_id, args, at, event_key)
		values ('zone', 77, 'set-role', 77, '{"from": "gm", "to": "player"}', to_timestamp($1), 'zona:1')`, c.NowUnix+30)
	if got, _ := w2.apply(42, play); got != "S2" {
		t.Fatalf("set-role de una zona: %s", got)
	}
}

// A slot swap and a three-way rotation fit in one transaction (the slot constraint is deferred).
func TestApplySwapsSlots(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	w.apply(42, kit)
	move := func(slots map[string]int) json.RawMessage {
		return edit(t, kit, func(m map[string]any) {
			m["ops"] = []any{}
			for _, it := range m["items"].([]any) {
				item := it.(map[string]any)
				if s, ok := slots[item["uid"].(string)]; ok {
					item["slot"] = s
				}
			}
		})
	}
	for _, slots := range []map[string]int{{"1028": 2, "1029": 1}, {"1027": 1, "1028": 0, "1029": 2}} {
		if got, _ := w.apply(42, move(slots)); got != "applied" {
			t.Fatalf("%v: %s", slots, got)
		}
		for uid, slot := range slots {
			if n := w.count(`select count(*) from item_instances where uid = $1 and container = 0 and slot = $2`,
				uid, slot); n != 1 {
				t.Fatalf("%v: el uid %s no está en la ranura %d", slots, uid, slot)
			}
		}
	}
}

// Two simultaneous saves of two characters with the same new uid: one goes through and the other
// collides with the primary key (S8) and leaves nothing behind. The same with the same op_id: the
// operation keeps one participant.
func TestDuplicateUid(t *testing.T) {
	c := loadCases(t)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	sameUids := edit(t, kit, func(m map[string]any) { m["ops"].([]any)[0].(map[string]any)["op_id"] = "1900" })
	sameOp := edit(t, kit, func(m map[string]any) {
		for _, it := range m["items"].([]any) {
			item := it.(map[string]any)
			item["uid"] = shift(item["uid"].(string), 100)
		}
		for _, e := range m["ops"].([]any)[0].(map[string]any)["items"].([]any) {
			ev := e.(map[string]any)
			ev["uid"] = shift(ev["uid"].(string), 100)
		}
	})
	for _, tc := range []struct {
		name, constraint string
		other            json.RawMessage
	}{{"uid", "item_instances_pkey", sameUids}, {"op_id", "economy_ops_pkey", sameOp}} {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t, c)
			ctx := context.Background()
			tx1, err := w.pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx1.Rollback(ctx)
			if _, err := w.store.Apply(ctx, tx1, w.key(42), kit); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() {
				done <- db.InTx(ctx, w.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
					_, err := w.store.Apply(ctx, tx, w.key(43), tc.other)
					return err
				})
			}()
			waitForLock(t, w.pool)
			if err := tx1.Commit(ctx); err != nil {
				t.Fatal(err)
			}
			err = <-done
			if got := outcome(t, err); got != "S8" || db.Constraint(err) != tc.constraint {
				t.Fatalf("el segundo: %s (%v)", got, err)
			}
			if w.count(`select count(*) from item_instances where character_id = 43`) != 0 ||
				w.count(`select count(*) from op_participants where op_id = 1025`) != 1 ||
				w.count(`select count(*) from item_instances where uid between 1026 and 1029 and character_id = 42`) != 4 {
				t.Fatal("el guardado que choca deja algo")
			}
		})
	}
}

func shift(uid string, by int64) string {
	v, err := strconv.ParseInt(uid, 10, 64)
	if err != nil {
		panic(err)
	}
	return id(v + by)
}

// waitForLock waits until some database session is waiting on a lock.
func waitForLock(t testing.TB, pool *pgxpool.Pool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		var n int
		if err := pool.QueryRow(context.Background(), `select count(*) from pg_stat_activity
			where datname = current_database() and wait_event_type = 'Lock'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("ninguna transacción espera un bloqueo")
}

// Two simultaneous transactions spend 60 from a balance of 100 (progression.md §5.4): with the
// UPDATE guard, the second touches no row; with Apply, the second waits on the locked progress
// and fails S3. The balance ends at 40 and is the sum of the ledger.
func TestWalletConcurrency(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	ctx := context.Background()
	w.exec(`update character_wallets set balance = 100 where character_id = 43 and currency = 1`)
	spend := `update character_wallets set balance = balance - 60 where character_id = 43 and currency = 1
		and balance - 60 >= 0`
	tx1, err := w.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if tag, err := tx1.Exec(ctx, spend); err != nil || tag.RowsAffected() != 1 {
		t.Fatalf("primera: %v %v", tag, err)
	}
	rows := make(chan int64, 1)
	go func() {
		tx2, err := w.pool.Begin(ctx)
		if err != nil {
			rows <- -1
			return
		}
		defer tx2.Rollback(ctx)
		tag, err := tx2.Exec(ctx, spend)
		if err != nil {
			rows <- -1
			return
		}
		rows <- tag.RowsAffected()
	}()
	waitForLock(t, w.pool)
	if err := tx1.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if n := <-rows; n != 0 {
		t.Fatalf("la segunda toca %d filas", n)
	}
	var balance int64
	w.scalar(&balance, `select balance from character_wallets where character_id = 43 and currency = 1`)
	if balance != 40 {
		t.Fatalf("saldo: %d", balance)
	}

	// With Apply.
	_, kit := c.step(t, "valid_kit_and_play", 0)
	w.apply(42, kit)
	idle := edit(t, kit, func(m map[string]any) { m["ops"] = []any{} })
	if got, _ := w.apply(42, withOps(t, idle, 100, gmOp(1100, c.NowUnix, 100, 100))); got != "applied" {
		t.Fatalf("+100: %s", got)
	}
	tx1, err = w.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx1.Rollback(ctx)
	if _, err := w.store.Apply(ctx, tx1, w.key(42), withOps(t, idle, 40, gmOp(1101, c.NowUnix, -60, 40))); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- db.InTx(ctx, w.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
			_, err := w.store.Apply(ctx, tx, w.key(42), withOps(t, idle, 40, gmOp(1102, c.NowUnix, -60, 40)))
			return err
		})
	}()
	waitForLock(t, w.pool)
	if err := tx1.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if got := outcome(t, <-done); got != "S3" {
		t.Fatalf("el segundo gasto: %s", got)
	}
	var sum int64
	w.scalar(&balance, `select balance from character_wallets where character_id = 42 and currency = 1`)
	w.scalar(&sum, `select coalesce(sum(delta), 0) from ledger_entries where character_id = 42 and currency = 1`)
	if balance != 40 || sum != 40 {
		t.Fatalf("saldo %d, suma del libro %d", balance, sum)
	}
	// Reconstruction: each balance_after is the previous one plus its delta.
	rowsOf, err := w.pool.Query(ctx, `select delta, balance_after from ledger_entries where character_id = 42
		and currency = 1 order by seq`)
	if err != nil {
		t.Fatal(err)
	}
	var running int64
	for rowsOf.Next() {
		var delta, after int64
		if err := rowsOf.Scan(&delta, &after); err != nil {
			t.Fatal(err)
		}
		running += delta
		if running != after {
			t.Fatalf("reconstrucción: %d frente a %d", running, after)
		}
	}
	rowsOf.Close()
}

// The schema allows an operation with two participants (the phase 6 trade one) in one
// transaction and rejects the same participant twice or an entry without a participation; through
// Apply, the same operation in another character's save fails S2 (the SaveMany exception is phase 6).
func TestTwoCharacterOp(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	w.tx(func(tx pgx.Tx) error {
		ctx := context.Background()
		for _, sql := range []string{
			`insert into economy_ops (op_id, kind, zone_id) values (1500, 2, 'vado_gris')`,
			`insert into op_participants (op_id, character_id) values (1500, 42), (1500, 43)`,
			`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
				values (42, 2, 1, 1500, 5, 5, 3), (43, 2, 1, 1500, 5, 5, 3)`,
		} {
			if _, err := tx.Exec(ctx, sql); err != nil {
				return err
			}
		}
		return nil
	})
	for _, tc := range []struct{ sql, state string }{
		{`insert into op_participants (op_id, character_id) values (1500, 42)`, "23505"},
		{`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
			values (49, 2, 1, 1500, 5, 5, 3)`, "23503"},
	} {
		_, err := w.pool.Exec(context.Background(), tc.sql)
		if db.SQLState(err) != tc.state {
			t.Errorf("%s: %v, se esperaba %s", tc.sql, err, tc.state)
		}
	}
	_, kit := c.step(t, "valid_kit_and_play", 0)
	w.apply(42, kit)
	other := edit(t, kit, func(m map[string]any) {
		for _, it := range m["items"].([]any) {
			item := it.(map[string]any)
			item["uid"] = shift(item["uid"].(string), 100)
		}
		for _, e := range m["ops"].([]any)[0].(map[string]any)["items"].([]any) {
			ev := e.(map[string]any)
			ev["uid"] = shift(ev["uid"].(string), 100)
		}
	})
	if got, _ := w.apply(43, other); got != "S2" {
		t.Fatalf("la operación de otro personaje: %s", got)
	}
}

// Reverting gameplay merits (reason 3–5) lowers realm points the same amount (I9, S6); reverting
// a GM's merits does not move them.
func TestApplyReversalOfMeritsLowersRealmPoints(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	_, play := c.step(t, "valid_kit_and_play", 1)
	w.apply(42, kit)
	w.apply(42, play)
	idle := edit(t, play, func(m map[string]any) { m["ops"] = []any{} })
	revert := func(opID, ref int64, entries ...map[string]any) map[string]any {
		ledger := make([]any, 0, len(entries))
		for _, e := range entries {
			ledger = append(ledger, e)
		}
		return map[string]any{"op_id": id(opID), "kind": 5, "actor_account_id": "77", "ref_op_id": id(ref),
			"note": "baja pactada", "detail": map[string]any{"command": "op_revert", "args": []any{id(ref), "baja pactada"},
				"at_unix": c.NowUnix, "source": "gm", "actor_character_id": "41"}, "ledger": ledger, "items": []any{}}
	}
	entry := func(currency, delta, after, ref int64) map[string]any {
		return map[string]any{"currency": currency, "delta": delta, "balance_after": after, "reason": 128,
			"ref_kind": 4, "ref_id": id(ref)}
	}
	body := func(realm, merits int64, op map[string]any) json.RawMessage {
		return edit(t, idle, func(m map[string]any) {
			m["ops"], m["realm_points"] = []any{op}, realm
			for _, wl := range m["wallets"].([]any) {
				wallet := wl.(map[string]any)
				switch wallet["currency"].(json.Number).String() {
				case "1":
					wallet["balance"] = 50
				case "2":
					wallet["balance"] = merits
				}
			}
		})
	}
	// GAMEPLAY 1031 gave 2 gold and 30 merits from a kill (30 realm points).
	op := revert(1100, 1031, entry(1, -2, 50, 1031), entry(2, -30, 0, 1031))
	if got, _ := w.apply(42, body(30, 0, op)); got != "S6" {
		t.Fatalf("puntos de reino sin bajar: %s", got)
	}
	if got, _ := w.apply(42, body(0, 0, op)); got != "applied" {
		t.Fatalf("puntos de reino bajados: %s", got)
	}
	// A GM operation of +10 merits, reverted: realm points do not move.
	w2 := newWorld(t, c)
	w2.apply(42, kit)
	w2.apply(42, play)
	gm := map[string]any{"op_id": "1100", "kind": 4, "actor_account_id": "77", "ref_op_id": nil, "note": "méritos",
		"detail": map[string]any{"command": "currency_add", "args": []any{"42", "meritos", "10"}, "at_unix": c.NowUnix,
			"source": "gm", "actor_character_id": "41"},
		"ledger": []any{map[string]any{"currency": 2, "delta": 10, "balance_after": 40, "reason": 7, "ref_kind": 0,
			"ref_id": "0"}}, "items": []any{}}
	granted := edit(t, idle, func(m map[string]any) {
		m["ops"] = []any{gm}
		m["wallets"].([]any)[1].(map[string]any)["balance"] = 40
	})
	if got, _ := w2.apply(42, granted); got != "applied" {
		t.Fatalf("GM de méritos: %s", got)
	}
	back := edit(t, body(30, 30, revert(1101, 1100, entry(2, -10, 30, 1100))), func(m map[string]any) {
		m["wallets"].([]any)[0].(map[string]any)["balance"] = 52
	})
	if got, _ := w2.apply(42, back); got != "applied" {
		t.Fatalf("revertir la GM de méritos: %s", got)
	}
}

// S2 checks the shape of each operation: detail only on GM and REVERSAL (and with its keys, a
// zone command and args as a list), actor_account_id only on them, ref_op_id only on REVERSAL,
// the note up to 200 characters and an op_id once per body.
func TestApplyOpShape(t *testing.T) {
	c := loadCases(t)
	_, kit := c.step(t, "valid_kit_and_play", 0)
	_, play := c.step(t, "valid_kit_and_play", 1)
	opOf := func(m map[string]any, kind string) map[string]any {
		for _, o := range m["ops"].([]any) {
			if op := o.(map[string]any); op["kind"].(json.Number).String() == kind {
				return op
			}
		}
		t.Fatalf("sin operación de tipo %s", kind)
		return nil
	}
	detailOf := func(m map[string]any) map[string]any { return opOf(m, "4")["detail"].(map[string]any) }
	long := make([]rune, 201)
	for i := range long {
		long[i] = 'a'
	}
	cases := map[string]func(m map[string]any){
		"detail en una GAMEPLAY":       func(m map[string]any) { opOf(m, "2")["detail"] = map[string]any{"command": "x"} },
		"actor en una PLAYER":          func(m map[string]any) { opOf(m, "1")["actor_account_id"] = "77" },
		"ref_op_id en una GM":          func(m map[string]any) { opOf(m, "4")["ref_op_id"] = "1025" },
		"clave desconocida en detail":  func(m map[string]any) { detailOf(m)["ip"] = "203.0.113.7" },
		"command de la CLI":            func(m map[string]any) { detailOf(m)["command"] = "set-role" },
		"args que no es una lista":     func(m map[string]any) { detailOf(m)["args"] = "42 oro 50" },
		"source desconocido":           func(m map[string]any) { detailOf(m)["source"] = "platform" },
		"xp_delta que no es un entero": func(m map[string]any) { detailOf(m)["xp_delta"] = "mucho" },
		"note de 201 caracteres":       func(m map[string]any) { opOf(m, "4")["note"] = string(long) },
		"op_id repetido": func(m map[string]any) {
			opOf(m, "1")["op_id"] = opOf(m, "2")["op_id"]
		},
		"REVERSAL sin ref_op_id": func(m map[string]any) {
			op := opOf(m, "4")
			op["kind"] = 5
			op["ledger"].([]any)[0].(map[string]any)["reason"] = 128
		},
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t, c)
			w.apply(42, kit)
			if got, _ := w.apply(42, edit(t, play, change)); got != "S2" {
				t.Fatalf("%s, se esperaba S2", got)
			}
		})
	}
}
