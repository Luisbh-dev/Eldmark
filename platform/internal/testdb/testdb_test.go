package testdb_test

import (
	"context"
	"os"
	"strings"
	"testing"

	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func TestNewGivesIsolatedMigratedDatabases(t *testing.T) {
	ctx := context.Background()
	a, b := testdb.New(t), testdb.New(t)
	if a.Config().ConnConfig.Database == b.Config().ConnConfig.Database {
		t.Fatal("cada prueba tiene su base")
	}
	testdb.Exec(t, a, "insert into accounts (email, age_confirmed_at) values ('a@eldmark.test', now())")
	var n int
	if err := b.QueryRow(ctx, "select count(*) from accounts").Scan(&n); err != nil || n != 0 {
		t.Fatalf("la otra base no ve la fila: %d %v", n, err)
	}
	ms, err := migrate.Load(migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	if err := b.QueryRow(ctx, "select count(*) from schema_migrations").Scan(&n); err != nil || n != len(ms) {
		t.Fatalf("la plantilla tiene todas las migraciones: %d de %d (%v)", n, len(ms), err)
	}
	if !strings.Contains(strings.Join(testdb.Tables(t, b), ","), "character_leases") {
		t.Fatal("Tables lista las tablas del esquema")
	}
}

func TestNewEmptyHasNoSchema(t *testing.T) {
	pool := testdb.NewEmpty(t)
	if tables := testdb.Tables(t, pool); len(tables) != 0 {
		t.Fatalf("base vacía: %v", tables)
	}
}

func TestDumpSchemaIsStable(t *testing.T) {
	pool := testdb.New(t)
	first, second := testdb.DumpSchema(t, pool), testdb.DumpSchema(t, pool)
	if first != second || strings.Contains(first, `\restrict`) {
		t.Fatal("dos volcados seguidos son iguales y sin las líneas \\restrict")
	}
	if strings.Contains(first, "OWNER TO") || strings.Contains(first, "GRANT ") {
		t.Fatal("sin dueños ni privilegios")
	}
}
