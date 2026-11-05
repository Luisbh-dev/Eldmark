//go:build e2e

package e2e

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/app"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/services"
	"eldmark/platform/internal/testdb"
)

// Harness environment variables.
const (
	godotVar        = "ELDMARK_GODOT"         // path of the Godot 4.7.2 executable; without it, the tests are skipped
	requireGodotVar = "ELDMARK_REQUIRE_GODOT" // 1 (CI): without ELDMARK_GODOT they fail instead of being skipped
	artifactsVar    = "ELDMARK_E2E_ARTIFACTS" // folder where the logs of each test are kept (optional)
)

// The tests' platform (platform.md §15, P10): a single zone deployment, test_world in world 1 and
// channel 0, which is the entry zone of both realms; 1 s heartbeat and 6 s leases.
const (
	ZoneID     = "test_world"
	WorldID    = 1
	HeartbeatS = 1
	LeaseTTLS  = 6
)

// Harness timeouts.
const (
	importTimeout = 10 * time.Minute
	bootTimeout   = 20 * time.Second // the platform, until the end of its startup
	stopTimeout   = 15 * time.Second // the platform, when the test ends
	pollEvery     = 100 * time.Millisecond
	tailLines     = 40 // lines from the end of each log that are copied into the output of a failing test
)

var (
	godotBin  string // ELDMARK_GODOT
	repoRoot  string // root of the Godot project (two folders above platform/e2e)
	importLog string // TestMain's import log
	importErr error  // why the import failed (all the tests fail with it)
)

func TestMain(m *testing.M) {
	os.Exit(testMain(m))
}

func testMain(m *testing.M) int {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	repoRoot = root
	godotBin = os.Getenv(godotVar)
	if godotBin != "" {
		importErr = importProject()
	}
	return testdb.Main(m)
}

// importProject imports the project once (godot --headless --import): zones and bots load imported
// scenes and resources. It needs the LFS objects already downloaded.
func importProject() error {
	if _, err := os.Stat(filepath.Join(repoRoot, "project.godot")); err != nil {
		return fmt.Errorf("no está el proyecto de Godot en %s: %w", repoRoot, err)
	}
	dir := os.Getenv(artifactsVar)
	if dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	f, err := os.CreateTemp(dir, "import-*.log")
	if err != nil {
		return err
	}
	importLog = f.Name()
	ctx, cancel := context.WithTimeout(context.Background(), importTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, godotBin, "--headless", "--path", repoRoot, "--import")
	cmd.Dir = repoRoot
	cmd.Env = childEnv(nil)
	cmd.Stdout, cmd.Stderr = f, f
	start := time.Now()
	err = cmd.Run()
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return fmt.Errorf("%s --headless --path %s --import: %w (registro en %s)", godotBin, repoRoot, err, importLog)
	}
	fmt.Fprintf(os.Stderr, "e2e: proyecto importado en %.1f s\n", time.Since(start).Seconds())
	return nil
}

// requireGodot skips the test without ELDMARK_GODOT (or makes it fail with ELDMARK_REQUIRE_GODOT=1)
// and makes it fail if the import failed.
func requireGodot(t *testing.T) {
	t.Helper()
	if godotBin == "" {
		if os.Getenv(requireGodotVar) == "1" {
			t.Fatalf("%s is not set and %s=1", godotVar, requireGodotVar)
		}
		t.Skipf("%s is not set (the path to the Godot 4.7.2 executable): without Godot there is no end-to-end", godotVar)
	}
	if importErr != nil {
		t.Fatalf("the project import failed: %v\n%s", importErr, tail(importLog, tailLines))
	}
}

// childEnv is the environment of a Godot process: the test's own without any ELDMARK_* variable (an
// inherited ELDMARK_ZONE_TOKEN_FILE would clash with the test's) plus extra.
func childEnv(extra []string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "ELDMARK_") {
			env = append(env, kv)
		}
	}
	return append(env, extra...)
}

// Harness is a test's platform (the real one, the one from serve, in this process and on a fresh
// database) with what is needed to start zones and bots against it. Everything is stopped when the
// test ends: first the Godot processes, then the platform and finally the database.
type Harness struct {
	T           *testing.T
	Pool        *pgxpool.Pool
	Cfg         *config.Config
	PublicURL   string // the public API (the bots' one): http://127.0.0.1:<port>
	InternalURL string // the internal API (the zones' one)
	Protocol    int    // the protocol_version from progression_rules.json (the X-Eldmark-Protocol header)
	Dir         string // the test's logs and reports
	ZoneToken   string // the zones' ELDMARK_ZONE_TOKEN (scope 1:test_world:0)
	TicketKeys  string // ELDMARK_TICKET_KEYS, the same in the platform and in the zones
	Started     time.Time

	mu    sync.Mutex
	procs []*Process
	seq   map[string]int
}

// Option changes the platform's ELDMARK_* variables before starting it.
type Option func(env map[string]string)

// New starts the test's platform: fresh database with all the migrations, the §15 configuration
// loaded with config.Load (ELDMARK_ENV=test), serve's services (services.Mount) and both APIs on
// free ports. It returns once startup has finished.
func New(t *testing.T, opts ...Option) *Harness {
	t.Helper()
	requireGodot(t)
	h := &Harness{T: t, Started: time.Now()}
	h.Dir = artifactsDir(t)
	h.Pool = testdb.New(t)
	t.Cleanup(h.dumpLogsOnFailure)

	rules, err := gamedata.Load()
	if err != nil {
		t.Fatal(err)
	}
	h.Protocol = rules.ProtocolVersion
	h.ZoneToken = "e2e-" + randomHex(t, 16)
	h.TicketKeys = "1:" + base64.StdEncoding.EncodeToString(randomBytes(t, 32))
	tokenHash := sha256.Sum256([]byte(h.ZoneToken))
	env := map[string]string{
		"ELDMARK_ENV":          "test",
		"ELDMARK_DATABASE_URL": testdb.ConnString(h.Pool),
		"ELDMARK_ZONE_TOKENS":  fmt.Sprintf("%d:%s:0:%s", WorldID, ZoneID, hex.EncodeToString(tokenHash[:])),
		"ELDMARK_TICKET_KEYS":  h.TicketKeys,
		"ELDMARK_ENTRY_ZONES":  "vardheim=" + ZoneID + ",solmarch=" + ZoneID,
		"ELDMARK_HEARTBEAT_S":  strconv.Itoa(HeartbeatS),
		"ELDMARK_LEASE_TTL_S":  strconv.Itoa(LeaseTTLS),
	}
	for _, o := range opts {
		o(env)
	}
	h.Cfg, err = config.Load(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if err != nil {
		t.Fatal(err)
	}
	h.Cfg.PublicAddr, h.Cfg.InternalAddr = "127.0.0.1:0", "127.0.0.1:0"
	h.startPlatform()
	t.Cleanup(h.killAll)
	return h
}

func (h *Harness) startPlatform() {
	t := h.T
	t.Helper()
	logFile, err := os.Create(filepath.Join(h.Dir, "plataforma.log"))
	if err != nil {
		t.Fatal(err)
	}
	log := logx.New(logFile, slog.LevelInfo)
	a, err := app.New(h.Cfg, h.Pool, log, migrate.FS())
	if err != nil {
		t.Fatal(err)
	}
	closeServices, err := services.Mount(a, h.Cfg, h.Pool, log)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Listen(); err != nil {
		closeServices()
		t.Fatal(err)
	}
	h.PublicURL, h.InternalURL = "http://"+a.PublicAddr(), "http://"+a.InternalAddr()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Serve(ctx) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("the platform stopped with an error: %v", err)
			}
		case <-time.After(stopTimeout):
			t.Errorf("the platform does not stop within %v", stopTimeout)
		}
		closeServices()
		_ = logFile.Close()
	})
	deadline := time.Now().Add(bootTimeout)
	for !a.Started() {
		select {
		case err := <-done:
			t.Fatalf("the platform stopped at startup: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("the platform does not finish starting within %v", bootTimeout)
		}
		time.Sleep(20 * time.Millisecond)
	}
	h.Logf("platform ready (public %s, internal %s)", h.PublicURL, h.InternalURL)
}

// artifactsDir is the test's log folder: ELDMARK_E2E_ARTIFACTS/<test> (emptied) or a temporary one.
func artifactsDir(t *testing.T) string {
	t.Helper()
	root := os.Getenv(artifactsVar)
	if root == "" {
		return t.TempDir()
	}
	dir := filepath.Join(root, strings.ReplaceAll(t.Name(), "/", "_"))
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

// Logf writes to the test's output with the seconds since harness startup in front.
func (h *Harness) Logf(format string, args ...any) {
	h.T.Helper()
	h.T.Logf("[%5.1f s] %s", time.Since(h.Started).Seconds(), fmt.Sprintf(format, args...))
}

// Elapsed is the seconds since harness startup.
func (h *Harness) Elapsed() time.Duration { return time.Since(h.Started) }

// dumpLogsOnFailure copies the end of each log into the output of a test that has failed.
func (h *Harness) dumpLogsOnFailure() {
	if !h.T.Failed() {
		return
	}
	entries, err := os.ReadDir(h.Dir)
	if err != nil {
		return
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && (strings.HasSuffix(e.Name(), ".log") || strings.HasSuffix(e.Name(), ".json")) {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		h.T.Logf("--- %s (final)\n%s", name, tail(filepath.Join(h.Dir, name), tailLines))
	}
	h.T.Logf("logs in %s", h.Dir)
}

// tail is the last n lines of the file path.
func tail(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("(no se puede leer: %v)", err)
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

func randomBytes(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

func randomHex(t *testing.T, n int) string { return hex.EncodeToString(randomBytes(t, n)) }

// --- Accounts ----------------------------------------------------------------------------------------------

// Account is a test account with its password in a file (the bots' --password-file).
type Account struct {
	ID           int64
	Email        string
	Password     string
	PasswordFile string
}

// NewAccount registers an account through the public API (POST /v1/accounts, with the three texts
// accepted) and leaves its password in a test file.
func (h *Harness) NewAccount(email string) *Account {
	t := h.T
	t.Helper()
	acc := &Account{Email: email, Password: "contraseña de " + randomHex(t, 6)}
	body := map[string]any{"email": email, "password": acc.Password, "age_confirmed": true,
		"accept":   map[string]any{"terms": 1, "privacy": 1, "rules": 1},
		"consents": map[string]any{"crash_reports": false, "analytics": false}}
	status, raw := h.PublicJSON(http.MethodPost, "/v1/accounts", body)
	if status != http.StatusAccepted {
		t.Fatalf("registration of %s: %d %s", email, status, raw)
	}
	h.Scalar(&acc.ID, `select account_id from accounts where email = $1`, email)
	acc.PasswordFile = filepath.Join(h.Dir, fmt.Sprintf("cuenta%d.pw", acc.ID))
	if err := os.WriteFile(acc.PasswordFile, []byte(acc.Password+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return acc
}

// PublicJSON makes a request to the public API with the protocol header and returns the status and
// the body.
func (h *Harness) PublicJSON(method, path string, body any) (int, string) {
	t := h.T
	t.Helper()
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, h.PublicURL+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Eldmark-Protocol", strconv.Itoa(h.Protocol))
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return res.StatusCode, string(raw)
}

// --- Database ----------------------------------------------------------------------------------------------

// Scalar reads a row from the database into dst or makes the test fail.
func (h *Harness) Scalar(dst any, sql string, args ...any) {
	h.T.Helper()
	if err := h.Pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		h.T.Fatalf("%v\n%s", err, sql)
	}
}

// Exists says whether the query returns any row.
func (h *Harness) Exists(sql string, args ...any) bool {
	h.T.Helper()
	var ok bool
	h.Scalar(&ok, "select exists ("+sql+")", args...)
	return ok
}

// WaitFor waits for cond to hold, checking it every 100 ms, or makes the test fail when timeout
// passes.
func (h *Harness) WaitFor(timeout time.Duration, what string, cond func() bool) {
	h.T.Helper()
	deadline := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(deadline) {
			h.T.Fatalf("%s does not arrive within %v", what, timeout)
		}
		time.Sleep(pollEvery)
	}
}

// CheckBooks checks by SQL that the character's saved data adds up, with nothing duplicated or
// half-done (TEC-25; the sums of progression.md §15 P8): by definition, the sum of count_delta in
// item_events is the sum of count of its live objects; per currency, the sum of delta in
// ledger_entries is the balance; the kit (STARTER_KIT operation) was given only once, and has some
// live object (otherwise, the rest would say nothing).
func (h *Harness) CheckBooks(characterID int64) {
	t := h.T
	t.Helper()
	ctx := context.Background()
	mismatches := func(what, sql string) {
		t.Helper()
		rows, err := h.Pool.Query(ctx, sql, characterID)
		if err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
		defer rows.Close()
		var bad []string
		for rows.Next() {
			var key string
			var booked, held int64
			if err := rows.Scan(&key, &booked, &held); err != nil {
				t.Fatal(err)
			}
			bad = append(bad, fmt.Sprintf("%s: %d en el libro y %d guardados", key, booked, held))
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		if len(bad) > 0 {
			t.Fatalf("%s of character %d do not add up: %s", what, characterID, strings.Join(bad, "; "))
		}
	}
	mismatches("los objetos", `select coalesce(e.def_id, i.def_id), coalesce(e.n, 0), coalesce(i.n, 0)
		from (select def_id, sum(count_delta) n from item_events where character_id = $1 group by def_id) e
		full join (select def_id, sum(count) n from item_instances where character_id = $1 and retired_at is null
			group by def_id) i on i.def_id = e.def_id
		where coalesce(e.n, 0) <> coalesce(i.n, 0)`)
	mismatches("los saldos", `select coalesce(l.currency, w.currency)::text, coalesce(l.n, 0), coalesce(w.balance, 0)
		from (select currency, sum(delta) n from ledger_entries where character_id = $1 group by currency) l
		full join (select currency, balance from character_wallets where character_id = $1) w on w.currency = l.currency
		where coalesce(l.n, 0) <> coalesce(w.balance, 0)`)
	var kits, alive int
	h.Scalar(&kits, `select count(*) from economy_ops o join op_participants p on p.op_id = o.op_id
		where p.character_id = $1 and o.kind = 3`, characterID)
	h.Scalar(&alive, `select count(*) from item_instances where character_id = $1 and retired_at is null`, characterID)
	if kits != 1 || alive == 0 {
		t.Fatalf("character %d has %d STARTER_KIT operations and %d live items (expected 1 and some)",
			characterID, kits, alive)
	}
}

// WaitCharacter waits for the character name (not deleted) to exist in the tests' world and returns
// its id.
func (h *Harness) WaitCharacter(name string, timeout time.Duration, procs ...*Process) int64 {
	h.T.Helper()
	var id int64
	h.WaitFor(timeout, "el personaje "+name, func() bool {
		requireRunning(h.T, procs...)
		err := h.Pool.QueryRow(context.Background(), `select character_id from characters
			where world_id = $1 and name = $2 and deleted_at is null`, WorldID, name).Scan(&id)
		return err == nil
	})
	return id
}

// --- Godot processes ---------------------------------------------------------------------------------------

// Process is a Godot process of the test (a zone or a bot), with the output going to its log.
type Process struct {
	Name string
	Log  string // standard output and standard error

	cmd  *exec.Cmd
	done chan struct{}
	code int   // the exit code; -1 if it was ended by a signal
	err  error // the error from Wait that is not an exit code
}

// start launches godot --headless --path <root> -- args with the environment from childEnv(env).
func (h *Harness) start(name string, env []string, args ...string) *Process {
	t := h.T
	t.Helper()
	p := &Process{Name: name, Log: filepath.Join(h.Dir, name+".log"), done: make(chan struct{})}
	f, err := os.Create(p.Log)
	if err != nil {
		t.Fatal(err)
	}
	all := append([]string{"--headless", "--path", repoRoot, "--"}, args...)
	p.cmd = exec.Command(godotBin, all...)
	p.cmd.Dir = repoRoot
	p.cmd.Env = childEnv(env)
	p.cmd.Stdout, p.cmd.Stderr = f, f
	setDeathSignal(p.cmd)
	if err := p.cmd.Start(); err != nil {
		_ = f.Close()
		t.Fatalf("%s does not start: %v", name, err)
	}
	go func() {
		err := p.cmd.Wait()
		var exit *exec.ExitError
		switch {
		case err == nil:
			p.code = 0
		case errors.As(err, &exit):
			p.code = exit.ExitCode()
		default:
			p.code, p.err = -1, err
		}
		_ = f.Close()
		close(p.done)
	}()
	h.mu.Lock()
	h.procs = append(h.procs, p)
	h.mu.Unlock()
	h.Logf("%s started: %s", name, strings.Join(args, " "))
	return p
}

// next gives the name of the next process of class kind (zona1, zona2, bot1...: those of their
// logs).
func (h *Harness) next(kind string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.seq == nil {
		h.seq = map[string]int{}
	}
	h.seq[kind]++
	return kind + strconv.Itoa(h.seq[kind])
}

// killAll kills the processes still alive when the test ends.
func (h *Harness) killAll() {
	h.mu.Lock()
	procs := append([]*Process(nil), h.procs...)
	h.mu.Unlock()
	for _, p := range procs {
		if !p.Exited() {
			p.Kill()
		}
	}
}

// Exited says whether the process has finished.
func (p *Process) Exited() bool {
	select {
	case <-p.done:
		return true
	default:
		return false
	}
}

// Code is the exit code (only after finishing; -1 if it was ended by a signal).
func (p *Process) Code() int { return p.code }

// Wait waits for the process to finish and returns its exit code; if it does not finish within
// timeout, it kills it and makes the test fail.
func (p *Process) Wait(t *testing.T, timeout time.Duration) int {
	t.Helper()
	select {
	case <-p.done:
	case <-time.After(timeout):
		p.Kill()
		t.Fatalf("%s does not finish within %v", p.Name, timeout)
	}
	if p.err != nil {
		t.Fatalf("%s: %v", p.Name, p.err)
	}
	return p.code
}

// Kill sends it SIGKILL (kill -9) and waits for it to finish; it returns the time just before the
// signal.
func (p *Process) Kill() time.Time {
	at := time.Now()
	if p.Exited() {
		return at
	}
	_ = p.cmd.Process.Kill()
	<-p.done
	return at
}

// requireRunning makes the test fail if any of the processes has already finished.
func requireRunning(t *testing.T, procs ...*Process) {
	t.Helper()
	for _, p := range procs {
		if p != nil && p.Exited() {
			t.Fatalf("%s ended early with code %d", p.Name, p.code)
		}
	}
}

// LogContains says whether the process's log has any line with text (read it after finishing:
// Godot's output may not be complete while it runs).
func (p *Process) LogContains(text string) bool { return fileContains(p.Log, text) }

// PlatformLogContains says whether the platform's log (line-delimited JSON) has any line with text.
func (h *Harness) PlatformLogContains(text string) bool {
	return fileContains(filepath.Join(h.Dir, "plataforma.log"), text)
}

func fileContains(path, text string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if strings.Contains(sc.Text(), text) {
			return true
		}
	}
	return false
}

// --- Zones -------------------------------------------------------------------------------------------------

// Zone is a test_world zone server with --platform against the test's platform.
type Zone struct {
	*Process
	h        *Harness
	Port     int    // the UDP port (and the public_port of its registration, which identifies it in zone_instances)
	StopFile string // --stop-file: creating it requests the orderly shutdown
	Report   string // --report
	Instance string // its zone_instance_id, from WaitLive
}

// StartZone starts a test_world zone with --platform (the test's internal API), a free UDP port,
// --stop-file, --report and args (--save-interval=5...). The token and the ticket keys go in the
// environment.
func (h *Harness) StartZone(args ...string) *Zone {
	h.T.Helper()
	name := h.next("zona")
	z := &Zone{h: h, Port: freeUDPPort(h.T), StopFile: filepath.Join(h.Dir, name+".stop"),
		Report: filepath.Join(h.Dir, name+".json")}
	all := append([]string{"--server", "--zone=" + ZoneID, "--world=" + strconv.Itoa(WorldID),
		"--port=" + strconv.Itoa(z.Port), "--platform=" + h.InternalURL, "--stop-file=" + z.StopFile,
		"--report=" + z.Report}, args...)
	z.Process = h.start(name, []string{"ELDMARK_ZONE_TOKEN=" + h.ZoneToken, "ELDMARK_TICKET_KEYS=" + h.TicketKeys}, all...)
	return z
}

// WaitLive waits for the zone's instance to be live on the platform and returns its
// zone_instance_id.
func (z *Zone) WaitLive(timeout time.Duration) string {
	h := z.h
	h.T.Helper()
	h.WaitFor(timeout, z.Name+" en live", func() bool {
		requireRunning(h.T, z.Process)
		err := h.Pool.QueryRow(context.Background(), `select zone_instance_id::text from zone_instances
			where public_port = $1 and status = 'live'`, z.Port).Scan(&z.Instance)
		return err == nil
	})
	h.Logf("%s in live (instance %s)", z.Name, z.Instance)
	return z.Instance
}

// Stop requests the orderly shutdown (creates the --stop-file: final saves, release and
// deregistration) and returns the exit code.
func (z *Zone) Stop(timeout time.Duration) int {
	z.h.T.Helper()
	if err := os.WriteFile(z.StopFile, nil, 0o644); err != nil {
		z.h.T.Fatal(err)
	}
	code := z.Wait(z.h.T, timeout)
	z.h.Logf("%s closed with code %d", z.Name, code)
	return code
}

// freeUDPPort is a UDP port that is free at this moment.
func freeUDPPort(t *testing.T) int {
	t.Helper()
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}

// --- Bots --------------------------------------------------------------------------------------------------

// Bot is a --bot client with an account (platform.md §19.16): it logs in, ensures the character,
// requests enter and joins with the ticket in the zone the platform gives.
type Bot struct {
	*Process
	Account *Account
	Report  string
}

// StartBot starts a bot with the account and args (--character=<name>, --quit-after-ticks=N...).
func (h *Harness) StartBot(acc *Account, args ...string) *Bot {
	h.T.Helper()
	name := h.next("bot")
	b := &Bot{Account: acc, Report: filepath.Join(h.Dir, name+".json")}
	all := append([]string{"--bot", "--platform=" + h.PublicURL, "--login=" + acc.Email,
		"--password-file=" + acc.PasswordFile, "--report=" + b.Report}, args...)
	b.Process = h.start(name, nil, all...)
	return b
}

// BotReport is what the test looks at in the bot's report.
type BotReport struct {
	Raw      map[string]any
	Platform struct {
		Code        string `json:"code"`
		Status      int    `json:"status"`
		Message     string `json:"message"`
		CharacterID string `json:"character_id"`
		Created     bool   `json:"created"`
	} `json:"platform"`
}

// ReadReport reads the bot's report (it writes it on exit).
func (b *Bot) ReadReport(t *testing.T) *BotReport {
	t.Helper()
	data, err := os.ReadFile(b.Report)
	if err != nil {
		t.Fatalf("report of %s: %v", b.Name, err)
	}
	r := &BotReport{}
	if err := json.Unmarshal(data, &r.Raw); err != nil {
		t.Fatalf("report of %s: %v", b.Name, err)
	}
	if err := json.Unmarshal(data, r); err != nil {
		t.Fatalf("report of %s: %v", b.Name, err)
	}
	return r
}
