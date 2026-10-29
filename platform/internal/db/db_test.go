package db_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func TestClassifyRealErrors(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	cases := map[string]struct {
		sql   string
		kind  db.Kind
		state string
	}{
		"clave primaria":    {"insert into worlds (world_id, name) values (1, 'Otro')", db.KindIntegrity, "23505"},
		"CHECK":             {"insert into worlds (world_id, name, status) values (2, 'Otro', 'raro')", db.KindIntegrity, "23514"},
		"clave ajena":       {"insert into account_realms (account_id, world_id, realm) values (999, 1, 1)", db.KindIntegrity, "23503"},
		"no nulo":           {"insert into worlds (world_id) values (3)", db.KindIntegrity, "23502"},
		"disparador":        {"do $$ begin raise exception 'solo añadir'; end $$", db.KindIntegrity, "P0001"},
		"serialización":     {"do $$ begin raise exception 'choque' using errcode = '40001'; end $$", db.KindRetryable, "40001"},
		"interbloqueo":      {"do $$ begin raise exception 'choque' using errcode = '40P01'; end $$", db.KindRetryable, "40P01"},
		"plazo":             {"set local statement_timeout = 1; select pg_sleep(1)", db.KindUnavailable, "57014"},
		"error de sintaxis": {"selec 1", db.KindOther, "42601"},
	}
	for name, c := range cases {
		err := db.InTx(ctx, pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, c.sql)
			return err
		})
		if got := db.Classify(err); got != c.kind || db.SQLState(err) != c.state {
			t.Errorf("%s: %v (%s), se esperaba %v (%s): %v", name, got, db.SQLState(err), c.kind, c.state, err)
		}
	}
	err := db.InTx(ctx, pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, "insert into worlds (world_id, name) values (1, 'Otro')")
		return err
	})
	if db.Constraint(err) != "worlds_pkey" {
		t.Errorf("la restricción que saltó: %q", db.Constraint(err))
	}
	if db.Classify(nil) != db.KindOther || db.SQLState(errors.New("x")) != "" {
		t.Error("sin error de PostgreSQL no hay SQLSTATE")
	}
}

func TestUnavailableDatabase(t *testing.T) {
	// Un socket en una carpeta vacía: la base «parada».
	pool, err := db.Open(context.Background(), "host="+filepath.Join(t.TempDir(), "nadie")+" user=eldmark dbname=eldmark")
	if err != nil {
		t.Fatalf("Open no conecta todavía: %v", err)
	}
	defer pool.Close()
	err = db.Ping(context.Background(), pool, time.Second)
	if err == nil || db.Classify(err) != db.KindUnavailable {
		t.Fatalf("sin servidor, no disponible: %v (%v)", err, db.Classify(err))
	}
	if _, err := db.Open(context.Background(), "postgres://a:b@host:puerto"); err == nil {
		t.Fatal("una cadena que no se entiende")
	}
}

func TestInTxRetriesSerializationFailures(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	testdb.Exec(t, pool, "create table intentos (n int)")
	attempts := 0
	err := db.InTx(ctx, pool, pgx.TxOptions{IsoLevel: pgx.Serializable}, func(tx pgx.Tx) error {
		attempts++
		if _, err := tx.Exec(ctx, "insert into intentos values ($1)", attempts); err != nil {
			return err
		}
		if attempts < 3 {
			_, err := tx.Exec(ctx, "do $$ begin raise exception 'choque' using errcode = '40001'; end $$")
			return err
		}
		return nil
	})
	if err != nil || attempts != 3 {
		t.Fatalf("a la tercera va: %v, %d intentos", err, attempts)
	}
	var rows, last int
	if err := pool.QueryRow(ctx, "select count(*), max(n) from intentos").Scan(&rows, &last); err != nil || rows != 1 || last != 3 {
		t.Fatalf("solo queda el intento bueno: %d filas, el %d (%v)", rows, last, err)
	}

	attempts = 0
	err = db.InTx(ctx, pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		attempts++
		if _, err := tx.Exec(ctx, "insert into intentos values (100)"); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, "do $$ begin raise exception 'choque' using errcode = '40P01'; end $$")
		return err
	})
	if !errors.Is(err, db.ErrConflict) || db.Classify(err) != db.KindRetryable || attempts != db.MaxAttempts {
		t.Fatalf("agotados los reintentos: %v (%v), %d intentos", err, db.Classify(err), attempts)
	}
	if err := pool.QueryRow(ctx, "select count(*) from intentos where n = 100").Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("nada escrito: %d (%v)", rows, err)
	}
}

// Un error de una restricción diferida salta en el COMMIT y es de integridad, no se reintenta.
func TestDeferredConstraintFailsAtCommit(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	testdb.Exec(t, pool, `create table ranuras (contenedor int, ranura int,
		constraint ranura_unica unique (contenedor, ranura) deferrable initially deferred)`)
	attempts := 0
	err := db.InTx(ctx, pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		attempts++
		_, err := tx.Exec(ctx, "insert into ranuras values (1, 1), (1, 1)")
		return err
	})
	if db.Classify(err) != db.KindIntegrity || db.Constraint(err) != "ranura_unica" || attempts != 1 {
		t.Fatalf("el COMMIT falla con la restricción diferida y no se reintenta: %v (%v), %d intentos", err, db.Classify(err), attempts)
	}
}

func TestPing(t *testing.T) {
	pool := testdb.New(t)
	if err := db.Ping(context.Background(), pool, time.Second); err != nil {
		t.Fatal(err)
	}
	var app string
	if err := pool.QueryRow(context.Background(), "show application_name").Scan(&app); err != nil || app == "" {
		t.Fatalf("application_name: %q %v", app, err)
	}
}

// El pool tiene al menos MinPoolConns conexiones salvo que la cadena diga otra cosa.
func TestOpenPoolSize(t *testing.T) {
	pool, err := db.Open(context.Background(), "host=127.0.0.1 port=1 user=x dbname=x")
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if n := pool.Config().MaxConns; n < db.MinPoolConns {
		t.Fatalf("MaxConns %d", n)
	}
	small, err := db.Open(context.Background(), "postgres://x@127.0.0.1:1/x?pool_max_conns=3")
	if err != nil {
		t.Fatal(err)
	}
	defer small.Close()
	if n := small.Config().MaxConns; n != 3 {
		t.Fatalf("pool_max_conns: %d", n)
	}
}
