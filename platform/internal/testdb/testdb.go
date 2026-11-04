// Package testdb gives tests a real, ephemeral PostgreSQL database (platform.md §2.6), without
// Docker.
//
// Usage:
//
//	func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }
//
//	func TestSomething(t *testing.T) {
//		pool := testdb.New(t) // fresh database with all the migrations
//		…
//	}
//
// The first test that asks for a database brings up a cluster with initdb in a temporary folder
// (os.MkdirTemp("", "eldpg-")) and creates the template tmpl with all the migrations; each test
// receives "create database t_<n> template tmpl", which is dropped when it finishes. Main stops
// the cluster and deletes the folder; if the process dies before getting there (a panic, the go
// test deadline, a Ctrl-C), a watchdog does it (on Unix, a separate sh waiting on a pipe). The
// server listens only on a Unix socket inside that folder, so two packages running at the same
// time do not collide; if the socket path exceeds the 107 B the system allows (a long TMPDIR), it
// listens on 127.0.0.1 with a free port.
//
// Variables:
//   - ELDMARK_PG_BIN: folder of the binaries (otherwise pg_config --bindir; otherwise the highest
//     /usr/lib/postgresql/*/bin).
//   - ELDMARK_PG_USER: user that initdb and pg_ctl run as when the tests run as root, which
//     initdb does not allow (postgres by default, with runuser -u <user> --).
//   - ELDMARK_TEST_DATABASE_URL: use an already running server instead of the ephemeral cluster.
//   - ELDMARK_REQUIRE_PG=1 (CI): with no binaries or server, the tests fail instead of being
//     skipped.
package testdb

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/migrate"
)

// Maximum length of a Unix socket path (sun_path is 108 B with the trailing null).
const maxSocketPath = 107

// Database user in the ephemeral cluster (initdb -U).
const superuser = "eldmark"

type cluster struct {
	binDir  string
	runAs   string // user for runuser, or "" if not needed
	dir     string // temporary folder, "" with ELDMARK_TEST_DATABASE_URL
	host    string // socket folder or 127.0.0.1
	port    int
	baseURL string // with ELDMARK_TEST_DATABASE_URL
	prefix  string // prefix of this process's databases
	tmpl    string // template name
	admin   *pgxpool.Pool
	created []string
	mu      sync.Mutex

	watchdog     *exec.Cmd // the watchdog (startWatchdog), or nil
	watchdogPipe *os.File  // its input: "done" on a clean finish; closed when the process dies
}

// state is the package's cluster, brought up by the first test that asks for a database.
var state struct {
	once    sync.Once
	c       *cluster
	err     error
	skip    string
	inMain  bool
	counter atomic.Int64
}

// Main runs the package's tests and, when done, stops the cluster and deletes its folder. It is
// called from TestMain: os.Exit(testdb.Main(m)).
func Main(m *testing.M) int {
	state.inMain = true
	code := m.Run()
	if c := state.c; c != nil {
		if err := c.close(); err != nil {
			fmt.Fprintf(os.Stderr, "testdb: %v\n", err)
			if code == 0 {
				code = 1
			}
		}
	}
	return code
}

// New returns a pool on a fresh database with all the embedded migrations, which is dropped when
// the test finishes. Without PostgreSQL, it skips the test (or fails it with ELDMARK_REQUIRE_PG=1).
func New(t testing.TB) *pgxpool.Pool {
	t.Helper()
	return newDatabase(t, true)
}

// NewEmpty is like [New] but with no migrations (to test migrate itself).
func NewEmpty(t testing.TB) *pgxpool.Pool {
	t.Helper()
	return newDatabase(t, false)
}

func get(t testing.TB) *cluster {
	t.Helper()
	if !state.inMain {
		t.Fatal("testdb: falta TestMain con os.Exit(testdb.Main(m)) en este paquete")
	}
	state.once.Do(func() { state.c, state.skip, state.err = start() })
	if state.err != nil {
		t.Fatalf("testdb: %v", state.err)
	}
	if state.skip != "" {
		if os.Getenv("ELDMARK_REQUIRE_PG") == "1" {
			t.Fatalf("testdb: %s (ELDMARK_REQUIRE_PG=1)", state.skip)
		}
		t.Skipf("testdb: %s", state.skip)
	}
	return state.c
}

func newDatabase(t testing.TB, migrated bool) *pgxpool.Pool {
	t.Helper()
	c := get(t)
	name := fmt.Sprintf("%s_t%d", c.prefix, state.counter.Add(1))
	template := "template0"
	if migrated {
		template = c.tmpl
	}
	ctx := context.Background()
	if _, err := c.admin.Exec(ctx, fmt.Sprintf("create database %s template %s", name, template)); err != nil {
		t.Fatalf("testdb: create database %s: %v", name, err)
	}
	c.mu.Lock()
	c.created = append(c.created, name)
	c.mu.Unlock()
	pool, err := c.pool(ctx, name, testPoolConns)
	if err != nil {
		t.Fatalf("testdb: %v", err)
	}
	t.Cleanup(func() {
		pool.Close()
		if _, err := c.admin.Exec(context.Background(), fmt.Sprintf("drop database if exists %s with (force)", name)); err != nil {
			t.Errorf("testdb: drop database %s: %v", name, err)
		}
	})
	return pool
}

// testPoolConns is the size of each test database's pool: serve's four periodic jobs each hold
// two connections at once (the lock's and the job's) and there are still some left for requests.
const testPoolConns = 10

// ConnString returns the connection string of a pool from [New] (to pass it to a command).
func ConnString(pool *pgxpool.Pool) string { return pool.Config().ConnString() }

// DumpSchema returns the pool's database schema with pg_dump -s, without owners, privileges or
// the \restrict lines that change on every dump.
func DumpSchema(t testing.TB, pool *pgxpool.Pool) string {
	t.Helper()
	c := get(t)
	if c.binDir == "" {
		t.Skip("testdb: sin binarios de PostgreSQL no hay pg_dump")
	}
	cc := pool.Config().ConnConfig
	cmd := exec.Command(filepath.Join(c.binDir, "pg_dump"), "--schema-only", "--no-owner", "--no-privileges",
		"-h", cc.Host, "-p", strconv.Itoa(int(cc.Port)), "-U", cc.User, "-d", cc.Database)
	cmd.Env = append(os.Environ(), "PGPASSWORD="+cc.Password)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("testdb: pg_dump: %v: %s", err, stderr.String())
	}
	var kept []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, `\restrict`) || strings.HasPrefix(line, `\unrestrict`) {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

func (c *cluster) pool(ctx context.Context, database string, maxConns int32) (*pgxpool.Pool, error) {
	conn := fmt.Sprintf("host=%s port=%d user=%s dbname=%s sslmode=disable", c.host, c.port, superuser, database)
	if c.baseURL != "" {
		conn = withDatabase(c.baseURL, database)
	}
	// The string carries the database, so the pool's ConnString can be passed to a command.
	cfg, err := pgxpool.ParseConfig(conn)
	if err != nil {
		return nil, errors.New("testdb: ELDMARK_TEST_DATABASE_URL no se entiende")
	}
	cfg.MaxConns = maxConns
	cfg.ConnConfig.RuntimeParams["application_name"] = "eldmark-testdb"
	return pgxpool.NewWithConfig(ctx, cfg)
}

// withDatabase changes the database in a connection string, in URL form (postgres://…/db) or as
// key=value pairs (where the last dbname wins).
func withDatabase(base, database string) string {
	if strings.HasPrefix(base, "postgres://") || strings.HasPrefix(base, "postgresql://") {
		if u, err := url.Parse(base); err == nil {
			u.Path = "/" + database
			return u.String()
		}
	}
	return base + " dbname=" + database
}

// start brings up the cluster (or connects to the ELDMARK_TEST_DATABASE_URL server) and creates
// the template. It returns skip if there is no PostgreSQL.
func start() (*cluster, string, error) {
	c := &cluster{prefix: fmt.Sprintf("eldt%d", os.Getpid())}
	c.binDir = findBinDir()
	if base := os.Getenv("ELDMARK_TEST_DATABASE_URL"); base != "" {
		c.baseURL = base
	} else {
		if c.binDir == "" {
			return nil, "no se encuentran los binarios de PostgreSQL (ELDMARK_PG_BIN, pg_config o /usr/lib/postgresql/*/bin)", nil
		}
		reapStale()
		if err := c.initCluster(); err != nil {
			c.removeDir()
			return nil, "", err
		}
	}
	ctx := context.Background()
	admin, err := c.pool(ctx, "postgres", 4)
	if err != nil {
		_ = c.close()
		return nil, "", err
	}
	c.admin = admin
	if err := c.createTemplate(ctx); err != nil {
		_ = c.close()
		return nil, "", err
	}
	return c, "", nil
}

func (c *cluster) createTemplate(ctx context.Context) error {
	c.tmpl = c.prefix + "_tmpl"
	if _, err := c.admin.Exec(ctx, "create database "+c.tmpl); err != nil {
		return fmt.Errorf("create database %s: %w", c.tmpl, err)
	}
	c.created = append(c.created, c.tmpl)
	pool, err := c.pool(ctx, c.tmpl, 2)
	if err != nil {
		return err
	}
	defer pool.Close()
	runner, err := migrate.New(pool, migrate.FS())
	if err != nil {
		return err
	}
	if _, err := runner.Up(ctx); err != nil {
		return fmt.Errorf("migraciones de la plantilla: %w", err)
	}
	return nil
}

func (c *cluster) close() error {
	var errs []error
	if c.admin != nil {
		if c.baseURL != "" {
			// On a foreign server, this process's databases are dropped.
			c.mu.Lock()
			names := append([]string(nil), c.created...)
			c.mu.Unlock()
			for _, name := range names {
				if _, err := c.admin.Exec(context.Background(), fmt.Sprintf("drop database if exists %s with (force)", name)); err != nil {
					errs = append(errs, err)
				}
			}
		}
		c.admin.Close()
	}
	if c.dir != "" {
		if out, err := c.run("pg_ctl", "-s", "-D", filepath.Join(c.dir, "data"), "-m", "immediate", "stop"); err != nil {
			errs = append(errs, fmt.Errorf("pg_ctl stop: %v: %s", err, out))
		}
		c.removeDir()
	}
	return errors.Join(errs...)
}

func (c *cluster) removeDir() {
	if c.dir != "" {
		_ = os.RemoveAll(c.dir)
		c.dir = ""
	}
	c.stopWatchdog()
}

// stopWatchdog dismisses the watchdog once cleanup is done: "done" and wait for it to exit.
func (c *cluster) stopWatchdog() {
	if c.watchdog == nil {
		return
	}
	_, _ = c.watchdogPipe.WriteString("done\n")
	_ = c.watchdogPipe.Close()
	_ = c.watchdog.Wait()
	c.watchdog, c.watchdogPipe = nil, nil
}

// initCluster creates the cluster with initdb and starts it with pg_ctl.
func (c *cluster) initCluster() error {
	dir, err := os.MkdirTemp("", "eldpg-")
	if err != nil {
		return err
	}
	c.dir = dir
	if err := os.WriteFile(filepath.Join(dir, "owner.pid"), []byte(strconv.Itoa(os.Getpid())), 0o644); err != nil {
		return err
	}
	if os.Geteuid() == 0 {
		c.runAs = os.Getenv("ELDMARK_PG_USER")
		if c.runAs == "" {
			c.runAs = "postgres"
		}
		u, err := user.Lookup(c.runAs)
		if err != nil {
			return fmt.Errorf("las pruebas corren como root e initdb no lo admite: falta el usuario %q (ELDMARK_PG_USER): %w", c.runAs, err)
		}
		uid, _ := strconv.Atoi(u.Uid)
		gid, _ := strconv.Atoi(u.Gid)
		if err := os.Chown(dir, uid, gid); err != nil {
			return err
		}
	}
	// The watchdog, before initdb: it also cleans up if the process dies while starting the cluster.
	if err := c.startWatchdog(); err != nil {
		return fmt.Errorf("vigilante del clúster: %w", err)
	}
	data := filepath.Join(dir, "data")
	out, err := c.run("initdb", "-D", data, "-U", superuser, "--auth=trust", "-E", "UTF8", "--no-locale", "--no-sync", "--no-instructions")
	if err != nil {
		return fmt.Errorf("initdb en %s: %v: %s (si corre como root, el usuario %q tiene que poder entrar en la carpeta temporal)",
			dir, err, out, c.runAs)
	}
	common := "-c fsync=off -c synchronous_commit=off -c full_page_writes=off -c max_connections=200"
	if len(filepath.Join(dir, ".s.PGSQL.5432")) <= maxSocketPath {
		c.host, c.port = dir, 5432
		out, err = c.run("pg_ctl", "-w", "-s", "-D", data, "-l", filepath.Join(dir, "postgres.log"), "start",
			"-o", fmt.Sprintf("-k '%s' -c listen_addresses= %s", dir, common))
		if err != nil {
			return fmt.Errorf("pg_ctl start: %v: %s%s", err, out, c.serverLog())
		}
		return nil
	}
	// Path too long for a socket: TCP on loopback with a free port (retried if another process takes
	// it in between).
	for attempt := 0; attempt < 5; attempt++ {
		port, perr := freePort()
		if perr != nil {
			return perr
		}
		c.host, c.port = "127.0.0.1", port
		out, err = c.run("pg_ctl", "-w", "-s", "-D", data, "-l", filepath.Join(dir, "postgres.log"), "start",
			"-o", fmt.Sprintf("-k '' -c listen_addresses=127.0.0.1 -p %d %s", port, common))
		if err == nil {
			return nil
		}
	}
	return fmt.Errorf("pg_ctl start: %v: %s%s", err, out, c.serverLog())
}

func (c *cluster) serverLog() string {
	if c.dir == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(c.dir, "postgres.log"))
	if err != nil || len(data) == 0 {
		return ""
	}
	return "\n" + string(data)
}

// argv is the command line of a PostgreSQL binary, with runuser if needed.
func (c *cluster) argv(bin string, args ...string) []string {
	path := filepath.Join(c.binDir, bin)
	if c.runAs != "" {
		return append([]string{"runuser", "-u", c.runAs, "--", path}, args...)
	}
	return append([]string{path}, args...)
}

// run executes a PostgreSQL binary, with runuser if needed, from the temporary folder.
func (c *cluster) run(bin string, args ...string) (string, error) {
	argv := c.argv(bin, args...)
	cmd := exec.Command(argv[0], argv[1:]...)
	if c.dir != "" {
		cmd.Dir = c.dir
	}
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// BinDir returns the folder of the PostgreSQL binaries used by the tests (the one from [Main]:
// ELDMARK_PG_BIN, pg_config --bindir or the highest /usr/lib/postgresql/*/bin), or "" if there is
// none. For tests that run pg_dump, pg_restore or the platform/deploy scripts.
func BinDir() string { return findBinDir() }

// findBinDir looks for the binaries: ELDMARK_PG_BIN, pg_config --bindir or the highest
// /usr/lib/postgresql/*/bin.
func findBinDir() string {
	if dir := os.Getenv("ELDMARK_PG_BIN"); dir != "" {
		// The given one wins: without initdb in it, nowhere else is searched.
		if _, err := os.Stat(filepath.Join(dir, "initdb")); err != nil {
			return ""
		}
		return dir
	}
	if out, err := exec.Command("pg_config", "--bindir").Output(); err == nil {
		dir := strings.TrimSpace(string(out))
		if _, err := os.Stat(filepath.Join(dir, "initdb")); err == nil {
			return dir
		}
	}
	matches, _ := filepath.Glob("/usr/lib/postgresql/*/bin/initdb")
	sort.Slice(matches, func(i, j int) bool {
		return versionOf(matches[i]) < versionOf(matches[j])
	})
	if len(matches) == 0 {
		return ""
	}
	return filepath.Dir(matches[len(matches)-1])
}

func versionOf(initdb string) int {
	v, _ := strconv.Atoi(filepath.Base(filepath.Dir(filepath.Dir(initdb))))
	return v
}

// reapStale stops and deletes the clusters left by a test process that died without reaching the
// end of Main (an expired deadline, a kill).
func reapStale() {
	dirs, _ := filepath.Glob(filepath.Join(os.TempDir(), "eldpg-*"))
	for _, dir := range dirs {
		data, err := os.ReadFile(filepath.Join(dir, "owner.pid"))
		if err != nil {
			continue
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
		if err != nil || pid == os.Getpid() || processAlive(pid) {
			continue
		}
		stale := &cluster{binDir: findBinDir(), dir: dir}
		if os.Geteuid() == 0 {
			stale.runAs = os.Getenv("ELDMARK_PG_USER")
			if stale.runAs == "" {
				stale.runAs = "postgres"
			}
		}
		if _, err := os.Stat(filepath.Join(dir, "data", "postmaster.pid")); err == nil {
			_, _ = stale.run("pg_ctl", "-s", "-D", filepath.Join(dir, "data"), "-m", "immediate", "stop")
		}
		_ = os.RemoveAll(dir)
	}
}

// Exec runs a statement with no arguments (several, with the simple protocol) on the pool's
// database; it fails the test on error.
func Exec(t testing.TB, pool *pgxpool.Pool, sql string) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql); err != nil {
		t.Fatalf("testdb: %v\n%s", err, sql)
	}
}

// Tables returns the tables of the public schema, without schema_migrations, in order.
func Tables(t testing.TB, pool *pgxpool.Pool) []string {
	t.Helper()
	rows, err := pool.Query(context.Background(),
		`select tablename from pg_tables where schemaname = 'public' and tablename <> 'schema_migrations' order by tablename`)
	if err != nil {
		t.Fatalf("testdb: %v", err)
	}
	names, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatalf("testdb: %v", err)
	}
	return names
}
