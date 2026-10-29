// Package testdb da a las pruebas una base PostgreSQL real y efímera (plataforma.md §2.6), sin
// Docker.
//
// Uso:
//
//	func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }
//
//	func TestAlgo(t *testing.T) {
//		pool := testdb.New(t) // base nueva con todas las migraciones
//		…
//	}
//
// La primera prueba que pide una base levanta un clúster con initdb en una carpeta temporal
// (os.MkdirTemp("", "eldpg-")) y crea la plantilla tmpl con todas las migraciones; cada prueba
// recibe «create database t_<n> template tmpl», que se borra al terminar. Main para el clúster y
// borra la carpeta. El servidor escucha solo en un socket Unix dentro de esa carpeta, así que dos
// paquetes que corren a la vez no chocan; si la ruta del socket pasa de los 107 B que admite el
// sistema (un TMPDIR largo), escucha en 127.0.0.1 con un puerto libre.
//
// Variables:
//   - ELDMARK_PG_BIN: carpeta de los binarios (si no, pg_config --bindir; si no, el mayor
//     /usr/lib/postgresql/*/bin).
//   - ELDMARK_PG_USER: usuario con el que corren initdb y pg_ctl cuando las pruebas corren como
//     root, que initdb no admite (por defecto postgres, con runuser -u <usuario> --).
//   - ELDMARK_TEST_DATABASE_URL: usa un servidor ya levantado en lugar del clúster efímero.
//   - ELDMARK_REQUIRE_PG=1 (la CI): sin binarios ni servidor, las pruebas fallan en lugar de
//     saltarse.
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

// Longitud máxima de la ruta de un socket Unix (sun_path tiene 108 B con el nulo final).
const maxSocketPath = 107

// Usuario de la base en el clúster efímero (initdb -U).
const superuser = "eldmark"

type cluster struct {
	binDir  string
	runAs   string // usuario para runuser, o "" si no hace falta
	dir     string // carpeta temporal, "" con ELDMARK_TEST_DATABASE_URL
	host    string // carpeta del socket o 127.0.0.1
	port    int
	baseURL string // con ELDMARK_TEST_DATABASE_URL
	prefix  string // prefijo de las bases de este proceso
	tmpl    string // nombre de la plantilla
	admin   *pgxpool.Pool
	created []string
	mu      sync.Mutex
}

// state es el clúster del paquete, que levanta la primera prueba que pide una base.
var state struct {
	once    sync.Once
	c       *cluster
	err     error
	skip    string
	inMain  bool
	counter atomic.Int64
}

// Main ejecuta las pruebas del paquete y, al acabar, para el clúster y borra su carpeta. Se llama
// desde TestMain: os.Exit(testdb.Main(m)).
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

// New devuelve un pool sobre una base nueva con todas las migraciones embebidas, que se borra al
// terminar la prueba. Sin PostgreSQL, salta la prueba (o la falla con ELDMARK_REQUIRE_PG=1).
func New(t testing.TB) *pgxpool.Pool {
	t.Helper()
	return newDatabase(t, true)
}

// NewEmpty es como [New] pero sin ninguna migración (para probar el propio migrate).
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
	pool, err := c.pool(ctx, name, 4)
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

// ConnString devuelve la cadena de conexión de un pool de [New] (para pasarla a una orden).
func ConnString(pool *pgxpool.Pool) string { return pool.Config().ConnString() }

// DumpSchema devuelve el esquema de la base del pool con pg_dump -s, sin dueños, privilegios ni
// las líneas \restrict que cambian en cada volcado.
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
	// La cadena lleva la base, así ConnString del pool sirve para pasarla a una orden.
	cfg, err := pgxpool.ParseConfig(conn)
	if err != nil {
		return nil, errors.New("testdb: ELDMARK_TEST_DATABASE_URL no se entiende")
	}
	cfg.MaxConns = maxConns
	cfg.ConnConfig.RuntimeParams["application_name"] = "eldmark-testdb"
	return pgxpool.NewWithConfig(ctx, cfg)
}

// withDatabase cambia la base de una cadena de conexión, en forma de URL (postgres://…/base) o de
// pares clave=valor (donde el último dbname manda).
func withDatabase(base, database string) string {
	if strings.HasPrefix(base, "postgres://") || strings.HasPrefix(base, "postgresql://") {
		if u, err := url.Parse(base); err == nil {
			u.Path = "/" + database
			return u.String()
		}
	}
	return base + " dbname=" + database
}

// start levanta el clúster (o se conecta al servidor de ELDMARK_TEST_DATABASE_URL) y crea la
// plantilla. Devuelve skip si no hay PostgreSQL.
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
			// En un servidor ajeno se borran las bases de este proceso.
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
}

// initCluster crea el clúster con initdb y lo arranca con pg_ctl.
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
	// Ruta demasiado larga para un socket: TCP en loopback con un puerto libre (se reintenta si
	// otro proceso lo toma entre medias).
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

// run ejecuta un binario de PostgreSQL, con runuser si hace falta, desde la carpeta temporal.
func (c *cluster) run(bin string, args ...string) (string, error) {
	path := filepath.Join(c.binDir, bin)
	var cmd *exec.Cmd
	if c.runAs != "" {
		cmd = exec.Command("runuser", append([]string{"-u", c.runAs, "--", path}, args...)...)
	} else {
		cmd = exec.Command(path, args...)
	}
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

// findBinDir busca los binarios: ELDMARK_PG_BIN, pg_config --bindir o el mayor
// /usr/lib/postgresql/*/bin.
func findBinDir() string {
	if dir := os.Getenv("ELDMARK_PG_BIN"); dir != "" {
		// La dada manda: sin initdb en ella no se busca en otro sitio.
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

// reapStale para y borra los clústeres que dejó un proceso de pruebas que murió sin llegar al
// final de Main (un plazo vencido, un kill).
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

// Exec ejecuta una sentencia sin argumentos (varias, con el protocolo simple) en la base del pool;
// falla la prueba si hay error.
func Exec(t testing.TB, pool *pgxpool.Pool, sql string) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql); err != nil {
		t.Fatalf("testdb: %v\n%s", err, sql)
	}
}

// Tables devuelve las tablas del esquema public, sin schema_migrations, en orden.
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
