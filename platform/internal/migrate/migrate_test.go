package migrate_test

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func runner(t *testing.T, pool *pgxpool.Pool, fsys fs.FS) *migrate.Runner {
	t.Helper()
	r, err := migrate.New(pool, fsys)
	if err != nil {
		t.Fatalf("migrate.New: %v", err)
	}
	return r
}

// upTo returns the embedded migrations up to the given version (inclusive).
func upTo(t *testing.T, version int) fstest.MapFS {
	t.Helper()
	out := fstest.MapFS{}
	entries, err := fs.ReadDir(migrate.FS(), ".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		var v int
		if _, err := fmt.Sscanf(e.Name(), "%04d_", &v); err != nil || v > version {
			continue
		}
		data, err := fs.ReadFile(migrate.FS(), e.Name())
		if err != nil {
			t.Fatal(err)
		}
		out[e.Name()] = &fstest.MapFile{Data: data}
	}
	return out
}

func appliedVersions(t *testing.T, pool *pgxpool.Pool) []int {
	t.Helper()
	rows, err := pool.Query(context.Background(), "select version from schema_migrations order by version")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []int
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			t.Fatal(err)
		}
		out = append(out, v)
	}
	return out
}

func counts(t *testing.T, pool *pgxpool.Pool) map[string]int64 {
	t.Helper()
	out := map[string]int64{}
	for _, table := range testdb.Tables(t, pool) {
		var n int64
		if err := pool.QueryRow(context.Background(), "select count(*) from "+table).Scan(&n); err != nil {
			t.Fatal(err)
		}
		out[table] = n
	}
	return out
}

func TestEmbeddedMigrations(t *testing.T) {
	ms, err := migrate.Load(migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"0001_accounts", "0002_characters", "0003_zones", "0004_war", "0005_social", "0006_privacy",
		"0010_progress"}
	if len(ms) < len(want) {
		t.Fatalf("faltan migraciones: %d", len(ms))
	}
	for i, id := range want {
		if ms[i].ID() != id {
			t.Errorf("migración %d: %s, se esperaba %s", i, ms[i].ID(), id)
		}
		if ms[i].Irreversible {
			t.Errorf("%s no es irreversible", id)
		}
	}
	// Numbers 0007-0009 are left unused (platform.md §2.4).
	for _, m := range ms {
		if m.Version >= 7 && m.Version <= 9 {
			t.Errorf("%s usa un número reservado", m.ID())
		}
	}
}

// up -> down to the last irreversible (or 0) -> up, with the same pg_dump -s (platform.md §2.4).
func TestUpDownUpKeepsTheSchema(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	r := runner(t, pool, migrate.FS())
	ms := r.Migrations()
	applied, err := r.Up(ctx)
	if err != nil {
		t.Fatalf("up: %v", err)
	}
	if len(applied) != len(ms) {
		t.Fatalf("up aplica todas: %d de %d", len(applied), len(ms))
	}
	first := testdb.DumpSchema(t, pool)
	if !strings.Contains(first, "CREATE TABLE public.accounts") || !strings.Contains(first, "uid_block_seq") {
		t.Fatalf("el volcado no tiene el esquema:\n%.500s", first)
	}
	lastIrreversible := 0
	for _, m := range ms {
		if m.Irreversible {
			lastIrreversible = m.Version
		}
	}
	reversible := 0
	for _, m := range ms {
		if m.Version > lastIrreversible {
			reversible++
		}
	}
	undone, err := r.Down(ctx, reversible)
	if err != nil {
		t.Fatalf("down %d: %v", reversible, err)
	}
	if len(undone) != reversible || undone[0].Version != ms[len(ms)-1].Version {
		t.Fatalf("down deshace de la mayor a la menor: %v", undone)
	}
	if lastIrreversible == 0 {
		if tables := testdb.Tables(t, pool); len(tables) != 0 {
			t.Fatalf("down hasta 0 no deja tablas: %v", tables)
		}
		var seqs int
		if err := pool.QueryRow(ctx, "select count(*) from pg_class where relkind = 'S' and relname = 'uid_block_seq'").Scan(&seqs); err != nil || seqs != 0 {
			t.Fatalf("down quita la secuencia: %d %v", seqs, err)
		}
	}
	if _, err := r.Up(ctx); err != nil {
		t.Fatalf("segundo up: %v", err)
	}
	if second := testdb.DumpSchema(t, pool); second != first {
		t.Fatalf("el esquema cambia tras up → down → up:\n--- antes\n%s\n--- después\n%s", first, second)
	}
	again, err := r.Up(ctx)
	if err != nil || len(again) != 0 {
		t.Fatalf("un up sin pendientes no hace nada: %v %v", again, err)
	}
	if err := r.Check(ctx); err != nil {
		t.Fatalf("check con todo aplicado: %v", err)
	}
}

// With a row in each table (the testdata/seed_NNNN.sql seeds, each from its version's schema),
// applying the next migration does not change any count(*) (platform.md §2.4).
func TestMigrationsKeepTheRows(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	ms := runner(t, pool, migrate.FS()).Migrations()
	seeded := 0
	var before map[string]int64
	for _, m := range ms {
		if _, err := runner(t, pool, upTo(t, m.Version)).Up(ctx); err != nil {
			t.Fatalf("up hasta %s: %v", m.ID(), err)
		}
		if before != nil {
			after := counts(t, pool)
			for table, n := range before {
				if after[table] != n {
					t.Errorf("%s cambia el número de filas de %s: %d → %d", m.ID(), table, n, after[table])
				}
			}
		}
		seed, err := os.ReadFile(fmt.Sprintf("testdata/seed_%04d.sql", m.Version))
		switch {
		case err == nil:
			testdb.Exec(t, pool, string(seed))
			seeded++
		case !errors.Is(err, fs.ErrNotExist):
			t.Fatal(err)
		}
		before = counts(t, pool)
		for table, n := range before {
			if n == 0 {
				t.Errorf("con el esquema %s, la tabla %s no tiene filas: falta en testdata/seed_%04d.sql", m.ID(), table, m.Version)
			}
		}
	}
	if seeded < 7 {
		t.Fatalf("hay semilla para 0001–0006 y 0010: %d", seeded)
	}
}

func TestIrreversibleMigrationsDoNotGoDown(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	fsys := fstest.MapFS{
		"0001_a.up.sql":   {Data: []byte("create table a (id int primary key);")},
		"0001_a.down.sql": {Data: []byte("drop table a;")},
		"0002_datos.up.sql": {Data: []byte(migrate.IrreversibleMarker +
			"\ninsert into a values (1), (2);\ndelete from a where id = 2;")},
		"0002_datos.down.sql": {Data: []byte("do $$ begin raise exception 'irreversible'; end $$;")},
		"0003_b.up.sql":       {Data: []byte("create table b (id int primary key);")},
		"0003_b.down.sql":     {Data: []byte("drop table b;")},
	}
	r := runner(t, pool, fsys)
	if !r.Migrations()[1].Irreversible || r.Migrations()[0].Irreversible {
		t.Fatal("la marca de la primera línea hace irreversible a 0002 y solo a ella")
	}
	if _, err := r.Up(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Down(ctx, 1); err != nil {
		t.Fatalf("0003 sí se deshace: %v", err)
	}
	_, err := r.Down(ctx, 1)
	if err == nil || !strings.Contains(err.Error(), "0002_datos es irreversible") {
		t.Fatalf("0002 no se deshace: %v", err)
	}
	// Not within a multi-step down either: nothing is touched.
	if _, err := r.Up(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Down(ctx, 2); err == nil {
		t.Fatal("down 2 pasaría por la irreversible")
	}
	if got := appliedVersions(t, pool); fmt.Sprint(got) != "[1 2 3]" {
		t.Fatalf("un down rechazado no deshace nada: %v", got)
	}
	// An irreversible one's .down.sql has to raise the exception.
	bad := fstest.MapFS{
		"0001_x.up.sql":   {Data: []byte(migrate.IrreversibleMarker + "\nselect 1;")},
		"0001_x.down.sql": {Data: []byte("select 1;")},
	}
	if _, err := migrate.Load(bad); err == nil {
		t.Fatal("una irreversible sin raise exception en su .down.sql no se carga")
	}
}

func TestChangedChecksumIsRefused(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	fsys := fstest.MapFS{
		"0001_a.up.sql":   {Data: []byte("create table a (id int);")},
		"0001_a.down.sql": {Data: []byte("drop table a;")},
	}
	if _, err := runner(t, pool, fsys).Up(ctx); err != nil {
		t.Fatal(err)
	}
	fsys["0001_a.up.sql"] = &fstest.MapFile{Data: []byte("create table a (id bigint);")}
	fsys["0002_b.up.sql"] = &fstest.MapFile{Data: []byte("create table b (id int);")}
	fsys["0002_b.down.sql"] = &fstest.MapFile{Data: []byte("drop table b;")}
	r := runner(t, pool, fsys)
	if _, err := r.Up(ctx); err == nil || !strings.Contains(err.Error(), "0001_a ha cambiado") {
		t.Fatalf("up con la suma cambiada: %v", err)
	}
	if got := appliedVersions(t, pool); fmt.Sprint(got) != "[1]" {
		t.Fatalf("no se aplica nada más: %v", got)
	}
	if err := r.Check(ctx); !errors.Is(err, migrate.ErrNotMigrated) {
		t.Fatalf("check con la suma cambiada: %v", err)
	}
	if _, err := r.Down(ctx, 1); err == nil {
		t.Fatal("down con la suma cambiada")
	}
	status, err := r.Status(ctx)
	if err != nil || status[0].State != migrate.StateChanged || status[1].State != migrate.StatePending {
		t.Fatalf("status: %+v %v", status, err)
	}
}

func TestPendingBelowTheHighestAppliedIsRefused(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	fsys := fstest.MapFS{
		"0001_a.up.sql":   {Data: []byte("create table a (id int);")},
		"0001_a.down.sql": {Data: []byte("drop table a;")},
		"0003_c.up.sql":   {Data: []byte("create table c (id int);")},
		"0003_c.down.sql": {Data: []byte("drop table c;")},
	}
	if _, err := runner(t, pool, fsys).Up(ctx); err != nil {
		t.Fatal(err)
	}
	fsys["0002_b.up.sql"] = &fstest.MapFile{Data: []byte("create table b (id int);")}
	fsys["0002_b.down.sql"] = &fstest.MapFile{Data: []byte("drop table b;")}
	r := runner(t, pool, fsys)
	_, err := r.Up(ctx)
	want := "La migración 0002 está pendiente por debajo de la 0003 ya aplicada: renumérala"
	if err == nil || err.Error() != want {
		t.Fatalf("se esperaba «%s»: %v", want, err)
	}
	if tables := testdb.Tables(t, pool); fmt.Sprint(tables) != "[a c]" {
		t.Fatalf("no se aplica nada: %v", tables)
	}
	status, err := r.Status(ctx)
	if err != nil || status[1].State != migrate.StateOutOfSeq {
		t.Fatalf("status marca la pendiente fuera de orden: %+v %v", status, err)
	}
}

func TestAFailedMigrationLeavesNothing(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	fsys := fstest.MapFS{
		"0001_a.up.sql":      {Data: []byte("create table a (id int);")},
		"0001_a.down.sql":    {Data: []byte("drop table a;")},
		"0002_mala.up.sql":   {Data: []byte("create table b (id int);\nselect 1 / 0;")},
		"0002_mala.down.sql": {Data: []byte("drop table b;")},
	}
	applied, err := runner(t, pool, fsys).Up(ctx)
	if err == nil || !strings.Contains(err.Error(), "0002_mala") {
		t.Fatalf("la migración rota falla con su nombre: %v", err)
	}
	if len(applied) != 1 {
		t.Fatalf("la anterior sí queda aplicada: %v", applied)
	}
	if tables := testdb.Tables(t, pool); fmt.Sprint(tables) != "[a]" {
		t.Fatalf("la migración rota no deja nada a medias: %v", tables)
	}
}

// Two runners at once: the advisory lock puts them in line and each migration is applied only once.
func TestTwoRunnersAtOnce(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	holder, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := holder.Exec(ctx, "select pg_advisory_lock($1)", migrate.LockKey); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make([][]migrate.Migration, 2)
	errs := make([]error, 2)
	finished := make(chan int, 2)
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i], errs[i] = runner(t, pool, migrate.FS()).Up(ctx)
			finished <- i
		}()
	}
	select {
	case i := <-finished:
		t.Fatalf("el ejecutor %d no esperó al bloqueo: %v", i, errs[i])
	case <-time.After(300 * time.Millisecond):
	}
	if _, err := holder.Exec(ctx, "select pg_advisory_unlock($1)", migrate.LockKey); err != nil {
		t.Fatal(err)
	}
	holder.Release()
	wg.Wait()
	total := 0
	for i := range 2 {
		if errs[i] != nil {
			t.Fatalf("ejecutor %d: %v", i, errs[i])
		}
		total += len(results[i])
	}
	n := len(runner(t, pool, migrate.FS()).Migrations())
	if total != n || len(appliedVersions(t, pool)) != n {
		t.Fatalf("cada migración se aplica una vez: %d aplicadas entre los dos, %d en la tabla, %d en el binario",
			total, len(appliedVersions(t, pool)), n)
	}
}

// Binary N works with schema N + 1: a later migration does not prevent starting.
func TestLaterMigrationsAreAccepted(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	newer := upTo(t, 9999)
	newer["9999_futura.up.sql"] = &fstest.MapFile{Data: []byte("alter table accounts add column apodo text;")}
	newer["9999_futura.down.sql"] = &fstest.MapFile{Data: []byte("alter table accounts drop column apodo;")}
	if _, err := runner(t, pool, newer).Up(ctx); err != nil {
		t.Fatal(err)
	}
	r := runner(t, pool, migrate.FS())
	if err := r.Check(ctx); err != nil {
		t.Fatalf("check con una posterior: %v", err)
	}
	if applied, err := r.Up(ctx); err != nil || len(applied) != 0 {
		t.Fatalf("up del binario viejo no hace nada: %v %v", applied, err)
	}
	status, err := r.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	last := status[len(status)-1]
	if last.Version != 9999 || last.State != migrate.StateUnknown {
		t.Fatalf("status enseña la posterior: %+v", last)
	}
	if _, err := r.Down(ctx, 1); err == nil {
		t.Fatal("el binario viejo no deshace una migración que no conoce")
	}
}

func TestCheckSaysWhy(t *testing.T) {
	pool := testdb.NewEmpty(t)
	ctx := context.Background()
	r := runner(t, pool, migrate.FS())
	err := r.Check(ctx)
	if !errors.Is(err, migrate.ErrNotMigrated) || !strings.Contains(err.Error(), "migrate up") {
		t.Fatalf("base vacía: %v", err)
	}
	if _, err := runner(t, pool, upTo(t, 3)).Up(ctx); err != nil {
		t.Fatal(err)
	}
	err = r.Check(ctx)
	if !errors.Is(err, migrate.ErrNotMigrated) || !strings.Contains(err.Error(), "0004_war") || strings.Contains(err.Error(), "0003_zones") {
		t.Fatalf("faltan 0004 en adelante: %v", err)
	}
	if _, err := r.Down(ctx, 7); err == nil {
		t.Fatal("no se pueden deshacer más de las aplicadas")
	}
	if _, err := r.Down(ctx, 0); err == nil {
		t.Fatal("down 0 no vale")
	}
}

func TestLoadValidatesTheFiles(t *testing.T) {
	ok := func() fstest.MapFS {
		return fstest.MapFS{
			"0001_a.up.sql":   {Data: []byte("select 1;")},
			"0001_a.down.sql": {Data: []byte("select 1;")},
		}
	}
	cases := map[string]func(fstest.MapFS){
		"nombre sin número":   func(f fstest.MapFS) { f["a.up.sql"] = &fstest.MapFile{Data: []byte("x")} },
		"mayúsculas":          func(f fstest.MapFS) { f["0002_B.up.sql"] = &fstest.MapFile{Data: []byte("x")} },
		"sin .down.sql":       func(f fstest.MapFS) { f["0002_b.up.sql"] = &fstest.MapFile{Data: []byte("select 1;")} },
		"sin .up.sql":         func(f fstest.MapFS) { f["0002_b.down.sql"] = &fstest.MapFile{Data: []byte("select 1;")} },
		"número repetido":     func(f fstest.MapFS) { f["0001_otra.up.sql"] = &fstest.MapFile{Data: []byte("select 1;")} },
		"up vacío":            func(f fstest.MapFS) { f["0001_a.up.sql"] = &fstest.MapFile{Data: []byte("  \n")} },
		"número 0000":         func(f fstest.MapFS) { f["0000_cero.up.sql"] = &fstest.MapFile{Data: []byte("select 1;")} },
		"extensión que sobra": func(f fstest.MapFS) { f["0002_b.sql"] = &fstest.MapFile{Data: []byte("select 1;")} },
	}
	if _, err := migrate.Load(ok()); err != nil {
		t.Fatalf("el conjunto bueno: %v", err)
	}
	for name, mutate := range cases {
		f := ok()
		mutate(f)
		if _, err := migrate.Load(f); err == nil {
			t.Errorf("%s: se cargó", name)
		}
	}
}
