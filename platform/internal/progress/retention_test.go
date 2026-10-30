package progress_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
)

// La purga de un personaje con kit y apuntes dentro de la purga de su cuenta deja la lápida de characters sin
// estado del progreso y con el libro; las tablas de solo añadir no admiten UPDATE ni DELETE sin la marca de la
// retención (tampoco en la transacción siguiente a una que la puso) y la lápida no se puede borrar con libro.
func TestPurgeKeepsLedger(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	for i := 0; i < 3; i++ {
		_, body := c.step(t, "valid_reversal", i)
		w.apply(42, body)
	}
	w.exec(`insert into character_timers (character_id, key, ends_at) values (42, 'unstuck', now())`)
	w.purgeAccount(7)
	var purged bool
	w.scalar(&purged, `select name is null and purged_at is not null from characters where character_id = 42`)
	if !purged {
		t.Fatal("la fila de characters no es una lápida")
	}
	for _, table := range []string{"character_progress", "character_wallets", "item_instances", "character_timers"} {
		if n := w.count(`select count(*) from ` + table + ` where character_id = 42`); n != 0 {
			t.Errorf("%s: quedan %d filas", table, n)
		}
	}
	for table, want := range map[string]int{"op_participants": 5, "ledger_entries": 4, "item_events": 7} {
		if n := w.count(`select count(*) from ` + table + ` where character_id = 42`); n != want {
			t.Errorf("%s: %d filas, se esperaban %d", table, n, want)
		}
	}
	if n := w.count(`select count(*) from economy_ops`); n != 5 || w.count(`select count(*) from op_reversals`) != 1 {
		t.Errorf("operaciones: %d", n)
	}
	ctx := context.Background()
	for _, sql := range []string{
		`delete from ledger_entries where character_id = 42`,
		`update ledger_entries set delta = 1 where character_id = 42`,
		`delete from item_events where character_id = 42`,
		`delete from op_reversals`,
		`update economy_ops set note = 'otra'`,
		`truncate op_participants cascade`,
	} {
		if _, err := w.pool.Exec(ctx, sql); db.SQLState(err) != "P0001" {
			t.Errorf("%s: %v (se esperaba P0001, de solo añadir)", sql, err)
		}
	}
	if _, err := w.pool.Exec(ctx, `delete from characters where character_id = 42`); db.SQLState(err) != "23503" {
		t.Errorf("borrar la lápida con libro: %v", err)
	}
	// La marca solo vale en su transacción.
	w.tx(func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `select set_config('eldmark.retention_purge', 'on', true)`)
		return err
	})
	if _, err := w.pool.Exec(ctx, `delete from item_events where character_id = 42`); db.SQLState(err) != "P0001" {
		t.Errorf("tras una transacción con la marca: %v", err)
	}
	// Una purga horaria del personaje ya purgado no hace nada (y Purge sobre nada no falla).
	w.tx(func(tx pgx.Tx) error { return w.store.Purge(ctx, tx, 42) })
}

// Con el reloj a +366 días, PurgeRetention borra el libro del personaje purgado en llamadas sucesivas hasta dar
// 0, devuelve su lápida (y la de uno purgado sin libro) en emptied y deja las operaciones de otros: la de dos
// participantes se queda con el que sigue vivo. Antes del año no toca nada.
func TestRetention(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	for i := 0; i < 3; i++ {
		_, body := c.step(t, "valid_reversal", i)
		w.apply(42, body)
	}
	_, kit := c.step(t, "valid_kit_and_play", 0)
	w.apply(43, edit(t, kit, func(m map[string]any) {
		m["ops"].([]any)[0].(map[string]any)["op_id"] = "1500"
		for _, it := range m["items"].([]any) {
			item := it.(map[string]any)
			item["uid"] = shift(item["uid"].(string), 500)
		}
		for _, e := range m["ops"].([]any)[0].(map[string]any)["items"].([]any) {
			ev := e.(map[string]any)
			ev["uid"] = shift(ev["uid"].(string), 500)
		}
	}))
	w.exec(`insert into economy_ops (op_id, kind, zone_id) values (1600, 2, 'vado_gris')`)
	w.exec(`insert into op_participants (op_id, character_id) values (1600, 42), (1600, 43)`)
	w.exec(`insert into ledger_entries (character_id, currency, seq, op_id, delta, balance_after, reason)
		values (42, 2, 2, 1600, 5, 35, 3), (43, 2, 1, 1600, 5, 5, 3)`)
	w.purgeAccount(7) // 42
	w.exec(`update characters set purged_at = now(), name = null, name_key = null where character_id = 49`)
	// retention llama a PurgeRetention como el trabajo horario, una transacción cada vez mientras borre algo,
	// y devuelve el total y todas las lápidas vacías.
	retention := func() (int64, []int64) {
		var total int64
		var all []int64
		for i := 0; ; i++ {
			var deleted int64
			w.tx(func(tx pgx.Tx) error {
				var emptied []int64
				var err error
				deleted, emptied, err = w.store.PurgeRetention(context.Background(), tx)
				if err != nil {
					return err
				}
				all = append(all, emptied...)
				// La plataforma borra las lápidas vacías en la misma transacción.
				for _, id := range emptied {
					if _, err := tx.Exec(context.Background(), `delete from characters where character_id = $1`,
						id); err != nil {
						return err
					}
				}
				return nil
			})
			total += deleted
			if deleted == 0 || i > 10 {
				return total, all
			}
		}
	}
	if deleted, emptied := retention(); deleted != 0 || len(emptied) != 0 {
		t.Fatalf("antes del año: %d borrados, vacías %v", deleted, emptied)
	}
	w.clock.advance(366 * 24 * time.Hour)
	w.exec(`update characters set purged_at = $1 where character_id = 49`, w.clock.now().Add(-366*24*time.Hour))
	deleted, emptied := retention()
	// 42: 5 apuntes, 7 eventos y 6 participaciones; 5 operaciones solo suyas y 1 reversión.
	if deleted != 5+7+6+5+1 {
		t.Errorf("borrados: %d", deleted)
	}
	if !reflect.DeepEqual(emptied, []int64{42, 49}) {
		t.Errorf("lápidas vacías: %v", emptied)
	}
	for table, want := range map[string]int{"ledger_entries": 0, "item_events": 0, "op_participants": 0} {
		if n := w.count(`select count(*) from ` + table + ` where character_id = 42`); n != want {
			t.Errorf("%s de 42: %d", table, n)
		}
	}
	if n := w.count(`select count(*) from characters where character_id in (42, 49)`); n != 0 {
		t.Errorf("las lápidas vacías siguen: %d", n)
	}
	if n := w.count(`select count(*) from economy_ops`); n != 2 {
		t.Errorf("operaciones que quedan: %d (las de 43: 1500 y la de dos, 1600)", n)
	}
	var participants []int64
	rows, err := w.pool.Query(context.Background(), `select character_id from op_participants where op_id = 1600`)
	if err != nil {
		t.Fatal(err)
	}
	if participants, err = pgx.CollectRows(rows, pgx.RowTo[int64]); err != nil || !reflect.DeepEqual(participants, []int64{43}) {
		t.Errorf("participantes de la operación de dos: %v %v", participants, err)
	}
	if n := w.count(`select count(*) from ledger_entries where character_id = 43`); n != 1 {
		t.Errorf("el libro de 43: %d", n)
	}
	// Ya no queda nada que borrar.
	if deleted, emptied := retention(); deleted != 0 || len(emptied) != 0 {
		t.Errorf("otra vuelta: %d, %v", deleted, emptied)
	}
}
