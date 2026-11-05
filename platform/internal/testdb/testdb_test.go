package testdb_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func TestNewGivesIsolatedMigratedDatabases(t *testing.T) {
	ctx := context.Background()
	a, b := testdb.New(t), testdb.New(t)
	if a.Config().ConnConfig.Database == b.Config().ConnConfig.Database {
		t.Fatal("each test has its own database")
	}
	testdb.Exec(t, a, "insert into accounts (email, age_confirmed_at) values ('a@eldmark.test', now())")
	var n int
	if err := b.QueryRow(ctx, "select count(*) from accounts").Scan(&n); err != nil || n != 0 {
		t.Fatalf("the other database does not see the row: %d %v", n, err)
	}
	ms, err := migrate.Load(migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	if err := b.QueryRow(ctx, "select count(*) from schema_migrations").Scan(&n); err != nil || n != len(ms) {
		t.Fatalf("the template has all the migrations: %d of %d (%v)", n, len(ms), err)
	}
	if !strings.Contains(strings.Join(testdb.Tables(t, b), ","), "character_leases") {
		t.Fatal("Tables lists the schema's tables")
	}
}

func TestNewEmptyHasNoSchema(t *testing.T) {
	pool := testdb.NewEmpty(t)
	if tables := testdb.Tables(t, pool); len(tables) != 0 {
		t.Fatalf("empty database: %v", tables)
	}
}

func TestDumpSchemaIsStable(t *testing.T) {
	pool := testdb.New(t)
	first, second := testdb.DumpSchema(t, pool), testdb.DumpSchema(t, pool)
	if first != second || strings.Contains(first, `\restrict`) {
		t.Fatal("two consecutive dumps are equal and have no \\restrict lines")
	}
	if strings.Contains(first, "OWNER TO") || strings.Contains(first, "GRANT ") {
		t.Fatal("no owners or privileges")
	}
}

// If the test process dies without returning from m.Run (here, a panic; likewise with the go test
// deadline or a Ctrl-C), the watchdog stops the server and deletes the cluster's folder: no other
// run with the same TMPDIR is needed to clean it up (§2.6).
func TestClusterDiesWithTheProcess(t *testing.T) {
	if os.Getenv("ELDMARK_TESTDB_CHILD") == "1" {
		testdb.New(t)
		panic("el proceso de pruebas muere sin pasar por el final de Main")
	}
	if runtime.GOOS == "windows" {
		t.Skip("the watchdog is Unix-only")
	}
	if os.Getenv("ELDMARK_TEST_DATABASE_URL") != "" {
		t.Skip("with a shared server there is no cluster")
	}
	testdb.New(t) // without PostgreSQL, it is skipped (or fails with ELDMARK_REQUIRE_PG=1) like the others
	// A temporary folder of its own for the child (the postgres user must be able to enter it).
	tmp, err := os.MkdirTemp("", "eldwd-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tmp) })
	if err := os.Chmod(tmp, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestClusterDiesWithTheProcess$", "-test.count=1")
	cmd.Env = append(os.Environ(), "ELDMARK_TESTDB_CHILD=1", "TMPDIR="+tmp)
	out, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(out), "muere sin pasar") {
		t.Fatalf("the child had to die with the panic: %v\n%s", err, out)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		left, _ := filepath.Glob(filepath.Join(tmp, "eldpg-*"))
		if len(left) == 0 {
			return
		}
		if time.Now().After(deadline) {
			// With no valid watchdog, the child's orphaned server is killed by hand.
			for _, dir := range left {
				pid, _ := os.ReadFile(filepath.Join(dir, "data", "postmaster.pid"))
				if n, err := strconv.Atoi(strings.SplitN(string(pid), "\n", 2)[0]); err == nil {
					if p, err := os.FindProcess(n); err == nil {
						_ = p.Kill()
					}
				}
			}
			t.Fatalf("the child's cluster is still there: %v", left)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
