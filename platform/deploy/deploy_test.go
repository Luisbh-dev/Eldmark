package deploy_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/progress"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/internal/testdb"
)

var ctx = context.Background()

// binDir holds the platform binary that the tests compile (once per package).
var (
	binOnce sync.Once
	binPath string
	binErr  error
	binDir  string
)

func TestMain(m *testing.M) {
	code := testdb.Main(m)
	if binDir != "" {
		_ = os.RemoveAll(binDir)
	}
	os.Exit(code)
}

// requireTool returns the path of a system tool; if it is missing, the test is skipped, except with
// ELDMARK_REQUIRE_DEPLOY_TOOLS=1 (CI), which fails.
func requireTool(t *testing.T, name string) string {
	t.Helper()
	path, err := exec.LookPath(name)
	if err != nil {
		if os.Getenv("ELDMARK_REQUIRE_DEPLOY_TOOLS") == "1" {
			t.Fatalf("falta %s (ELDMARK_REQUIRE_DEPLOY_TOOLS=1)", name)
		}
		t.Skipf("falta %s", name)
	}
	return path
}

// requirePG skips (or fails with ELDMARK_REQUIRE_PG=1) if the PostgreSQL binaries the scripts use
// (initdb, pg_ctl, pg_dump...) are not there.
func requirePG(t *testing.T) string {
	t.Helper()
	dir := testdb.BinDir()
	if dir == "" {
		if os.Getenv("ELDMARK_REQUIRE_PG") == "1" {
			t.Fatal("no se encuentran los binarios de PostgreSQL (ELDMARK_REQUIRE_PG=1)")
		}
		t.Skip("no se encuentran los binarios de PostgreSQL")
	}
	return dir
}

// platformBinary compiles eldmark-platform once for the scripts.
func platformBinary(t *testing.T) string {
	t.Helper()
	binOnce.Do(func() {
		goTool, err := exec.LookPath("go")
		if err != nil {
			goTool = filepath.Join(runtime.GOROOT(), "bin", "go")
		}
		binDir, binErr = os.MkdirTemp("", "eldbin-")
		if binErr != nil {
			return
		}
		binPath = filepath.Join(binDir, "eldmark-platform")
		cmd := exec.Command(goTool, "build", "-o", binPath, "./cmd/eldmark-platform")
		cmd.Dir = ".."
		cmd.Env = append(os.Environ(), "GOTOOLCHAIN=local")
		if out, err := cmd.CombinedOutput(); err != nil {
			binErr = fmt.Errorf("go build: %v: %s", err, out)
		}
	})
	if binErr != nil {
		t.Fatal(binErr)
	}
	return binPath
}

// sharedDir is a temporary folder that the postgres user can also enter (when the tests run as
// root, the scripts bring up PostgreSQL with that user).
func sharedDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "eldtest-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

// script runs a script from this folder with bash and the given environment (on top of the
// process's, with ELDMARK_PG_BIN) and returns the exit code and the output (both together).
func script(t *testing.T, env map[string]string, name string, args ...string) (int, string) {
	t.Helper()
	cmd := scriptCmd(t, env, name, args...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return 0, out.String()
	case errors.As(err, &exit):
		return exit.ExitCode(), out.String()
	}
	t.Fatalf("%s: %v\n%s", name, err, out.String())
	return 0, ""
}

func scriptCmd(t *testing.T, env map[string]string, name string, args ...string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(requireTool(t, "bash"), append([]string{name}, args...)...)
	cmd.Env = os.Environ()
	if dir := testdb.BinDir(); dir != "" {
		cmd.Env = append(cmd.Env, "ELDMARK_PG_BIN="+dir)
	}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	return cmd
}

func mustScript(t *testing.T, env map[string]string, name string, args ...string) string {
	t.Helper()
	code, out := script(t, env, name, args...)
	if code != 0 {
		t.Fatalf("%s %v: código %d\n%s", name, args, code, out)
	}
	return out
}

func mustContain(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Fatalf("falta %q en la salida:\n%s", w, out)
		}
	}
}

// files lists the names in a folder that match the pattern, in order.
func files(t *testing.T, dir, pattern string) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(dir, pattern))
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(matches)
	return matches
}

func lines(t *testing.T, path string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return len(strings.Split(strings.TrimSpace(string(data)), "\n"))
}

// The scripts pass bash -n and, if present, shellcheck (no warnings).
func TestScriptsPassShellcheck(t *testing.T) {
	scripts := files(t, ".", "*.sh")
	if len(scripts) != 5 {
		t.Fatalf("scripts: %v", scripts)
	}
	bash := requireTool(t, "bash")
	for _, s := range scripts {
		if out, err := exec.Command(bash, "-n", s).CombinedOutput(); err != nil {
			t.Errorf("bash -n %s: %v: %s", s, err, out)
		}
		info, err := os.Stat(s)
		if err != nil || info.Mode()&0o111 == 0 && s != "pglib.sh" {
			t.Errorf("%s no es ejecutable", s)
		}
	}
	shellcheck := requireTool(t, "shellcheck")
	args := append([]string{"-x", "-s", "bash"}, scripts...)
	if out, err := exec.Command(shellcheck, args...).CombinedOutput(); err != nil {
		t.Fatalf("shellcheck: %v\n%s", err, out)
	}
}

// Backups, purges.txt and test restore (§11.2, §12, the P9b test): a copy taken before purging,
// restored with the most recent purges.txt, ends up purged and passes the checks; the most recent
// one (--dir) has nothing left to purge again; a copy whose audit stores the email of an account
// purged afterwards does not pass; and the rotation keeps the daily copies that apply without losing
// the most recent purges.txt. The platform uses the real progression store (progression.md P7, like
// serve and the admin command): the copy carries the characters' progress and reapply-purges deletes
// it again.
func TestBackupAndRestoreCheck(t *testing.T) {
	requirePG(t)
	bin := platformBinary(t)
	rules, err := progress.LoadRules(gamedata.Raw())
	if err != nil {
		t.Fatal(err)
	}
	p := platformtest.NewWithProgress(t, func(now func() time.Time) persistence.ProgressStore {
		return progress.New(rules, now)
	}, rules)
	if _, err := p.Admin.Bootstrap(ctx, "jefa@example.org", platformtest.Password); err != nil {
		t.Fatal(err)
	}
	jefa, err := p.Admin.Authorize(ctx, "jefa@example.org", sanctions.RoleAdmin)
	if err != nil {
		t.Fatal(err)
	}
	zone := p.NewZone(1, "vado_gris", 0).Start()
	a := p.NewPlayer("a@example.org")
	zone.Join(a, p.NewCharacter(a, "Aldric", "vardheim"))
	b := p.NewPlayer("b@example.org")
	p.NewCharacter(b, "Corwin", "vardheim")
	dairine := p.NewCharacter(b, "Dairine", "vardheim")
	c := p.NewPlayer("c@example.org")
	p.NewCharacter(c, "Eamon", "solmarch")

	dir := t.TempDir()
	env := map[string]string{"ELDMARK_DATABASE_URL": testdb.ConnString(p.Pool), "ELDMARK_BACKUP_DIR": dir}
	mustContain(t, mustScript(t, env, "backup.sh"), "(0 purgas)", "también semanal")
	first := files(t, filepath.Join(dir, "daily"), "*.dump")
	if len(first) != 1 {
		t.Fatalf("copias: %v", first)
	}

	// After the copy, b deletes Dairine and requests erasure right away (purge-now): Corwin, who was
	// never deleted, also ends up as a tombstone.
	platformtest.Expect(t, p.PublicDo("DELETE", "/v1/characters/"+strconv.FormatInt(dairine, 10), b.Token,
		map[string]any{"confirm_name": "Dairine"}), http.StatusOK, "")
	if _, err := p.Admin.PurgeNow(ctx, jefa, "b@example.org", 0); err != nil {
		t.Fatal(err)
	}
	out := mustScript(t, env, "backup.sh")
	mustContain(t, out, "(3 purgas)")
	if strings.Contains(out, "también semanal") {
		t.Fatalf("dos semanales en el mismo día:\n%s", out)
	}
	latest := filepath.Join(dir, "purges.txt")
	if n := lines(t, latest); n != 3 {
		t.Fatalf("purges.txt con %d líneas", n)
	}
	if d, w := files(t, filepath.Join(dir, "daily"), "*"), files(t, filepath.Join(dir, "weekly"), "*"); len(d) != 4 || len(w) != 2 {
		t.Fatalf("diarias %v, semanales %v", d, w)
	}
	if strings.Contains(string(readFile(t, latest)), "@") {
		t.Fatal("purges.txt lleva correos")
	}

	// The copy from before purging, with the most recent purges.txt.
	rc := map[string]string{"ELDMARK_PLATFORM_BIN": bin}
	out = mustScript(t, rc, "restore_check.sh", first[0], latest)
	mustContain(t, out, "Borrados de la copia: 1 arrendamientos y 1 billetes",
		"Purgados ahora: 1 cuentas y 2 personajes", "bien: filas de audit_log con el correo de una cuenta purgada: 0",
		"bien: personajes purgados con datos personales: 0",
		"bien: purged_at distinto del de purges.txt: 0", "Restauración de prueba correcta")
	// The most recent one, with --dir: everything is already purged.
	out = mustScript(t, rc, "restore_check.sh", "--dir", dir)
	mustContain(t, out, "ya purgados o sin fila en la copia: 3", "Restauración de prueba correcta")

	// A copy whose audit stores the email of c (a row that should not exist, §9.1), and c purged
	// afterwards: restore_check.sh fails and says so.
	p.Exec(`insert into audit_log (source, command, args) values ('platform', 'prueba', '{"email": "c@example.org"}')`)
	mustScript(t, env, "backup.sh")
	withEmail := files(t, filepath.Join(dir, "daily"), "*.dump")
	if _, err := p.Admin.PurgeNow(ctx, jefa, "c@example.org", 0); err != nil {
		t.Fatal(err)
	}
	mustScript(t, env, "backup.sh")
	code, out := script(t, rc, "restore_check.sh", withEmail[len(withEmail)-1], latest)
	if code != 1 {
		t.Fatalf("restore_check.sh con un correo en la auditoría: código %d\n%s", code, out)
	}
	mustContain(t, out, "MAL: filas de audit_log con el correo de una cuenta purgada: 1")

	// Rotation: with 2 daily copies, the 2 most recent stay, each with its purges.txt.
	env["ELDMARK_BACKUP_DAILY"] = "2"
	mustContain(t, mustScript(t, env, "backup.sh"), "rotada:")
	dumps := files(t, filepath.Join(dir, "daily"), "*.dump")
	if len(dumps) != 2 || len(files(t, filepath.Join(dir, "daily"), "*.purges.txt")) != 2 {
		t.Fatalf("tras rotar: %v", files(t, filepath.Join(dir, "daily"), "*"))
	}
	if n := lines(t, latest); n != 5 {
		t.Fatalf("el purges.txt más reciente tiene %d líneas", n)
	}
	if len(files(t, filepath.Join(dir, "weekly"), "*.dump")) != 1 {
		t.Fatal("la rotación de las diarias ha tocado la semanal")
	}
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// Invalid usages: 2; files that do not exist: 1.
func TestRestoreCheckUsage(t *testing.T) {
	for _, args := range [][]string{{}, {"solo-uno"}, {"--dir"}, {"a", "b", "c"}} {
		if code, out := script(t, nil, "restore_check.sh", args...); code != 2 {
			t.Errorf("%v: código %d\n%s", args, code, out)
		}
	}
	if code, out := script(t, nil, "restore_check.sh", "/no/existe.dump", "/no/purges.txt"); code != 1 ||
		!strings.Contains(out, "no se puede leer la copia") {
		t.Errorf("sin copia: %d\n%s", code, out)
	}
	if code, out := script(t, nil, "backup.sh"); code != 1 || !strings.Contains(out, "ELDMARK_BACKUP_DIR") {
		t.Errorf("backup.sh sin carpeta: %d\n%s", code, out)
	}
}

// Point-in-time recovery (pitr_check.sh): it recovers the rows from before the deletion.
func TestPitrCheck(t *testing.T) {
	requirePG(t)
	mustContain(t, mustScript(t, nil, "pitr_check.sh"), "Recuperación a un instante correcta: 1500 filas")
}

func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

// dev.sh: prepares the database, the environment and the two accounts (and a second time repeats
// nothing); env gives the variables; up starts serve, which reaches /ready, and a TERM stops it
// along with PostgreSQL; reset deletes everything.
func TestDevScript(t *testing.T) {
	requirePG(t)
	dir := sharedDir(t)
	pgAddr, public, internal := freeAddr(t), freeAddr(t), freeAddr(t)
	_, pgPort, _ := net.SplitHostPort(pgAddr)
	env := map[string]string{"ELDMARK_DEV_DIR": dir, "ELDMARK_DEV_PG_PORT": pgPort, "ELDMARK_PLATFORM_BIN": platformBinary(t),
		"ELDMARK_DEV_PUBLIC_ADDR": public, "ELDMARK_DEV_INTERNAL_ADDR": internal}
	t.Cleanup(func() { script(t, env, "dev.sh", "stop") })

	out := mustScript(t, env, "dev.sh", "prepare")
	mustContain(t, out, "cuenta admin: admin@eldmark.test", "cuenta de prueba: prueba@eldmark.test",
		"--platform=http://"+internal, "zone_token_vado_gris")
	envFile := string(readFile(t, filepath.Join(dir, "dev_platform.env")))
	for _, secret := range []string{"ELDMARK_TICKET_KEYS=", "ELDMARK_ZONE_TOKENS="} {
		if strings.Contains(envFile, secret) {
			t.Fatalf("dev_platform.env lleva %s en claro:\n%s", secret, envFile)
		}
	}
	tokens := string(readFile(t, filepath.Join(dir, "dev_secrets", "zone_tokens")))
	if !regexp.MustCompile(`^1:vado_gris:0:[0-9a-f]{64},1:test_world:0:[0-9a-f]{64}\n$`).MatchString(tokens) {
		t.Fatalf("zone_tokens: %q", tokens)
	}
	out = mustScript(t, env, "dev.sh", "prepare")
	if strings.Contains(out, "cuenta admin:") || strings.Contains(out, "entorno nuevo") {
		t.Fatalf("la segunda vez repite:\n%s", out)
	}
	exports := mustScript(t, env, "dev.sh", "env")
	mustContain(t, exports, "export ELDMARK_ENV=dev", "export ELDMARK_ZONE_TOKENS_FILE=")
	conn, err := pgx.Connect(ctx, "postgres://eldmark@"+pgAddr+"/eldmark?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	var admins, players int
	err = conn.QueryRow(ctx, `select count(*) filter (where email = 'admin@eldmark.test' and role = 'admin'),
		count(*) filter (where email = 'prueba@eldmark.test' and role = 'player' and email_verified_at is not null)
		from accounts`).Scan(&admins, &players)
	_ = conn.Close(ctx)
	if err != nil || admins != 1 || players != 1 {
		t.Fatalf("cuentas: %d admin, %d de prueba (%v)", admins, players, err)
	}

	up := scriptCmd(t, env, "dev.sh", "up")
	var upOut bytes.Buffer
	up.Stdout, up.Stderr = &upOut, &upOut
	if err := up.Start(); err != nil {
		t.Fatal(err)
	}
	ready := false
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		res, err := http.Get("http://" + public + "/ready")
		if err == nil {
			res.Body.Close()
			if res.StatusCode == http.StatusOK {
				ready = true
				break
			}
		}
	}
	if err := up.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- up.Wait() }()
	select {
	case err := <-done:
		if err != nil || !ready {
			t.Fatalf("dev.sh up: listo %v, salida %v\n%s", ready, err, upOut.String())
		}
	case <-time.After(20 * time.Second):
		_ = up.Process.Kill()
		t.Fatalf("dev.sh up no para con TERM\n%s", upOut.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "dev_pg", "data", "postmaster.pid")); !os.IsNotExist(err) {
		t.Fatalf("PostgreSQL sigue en marcha tras parar up (%v)", err)
	}
	mustScript(t, env, "dev.sh", "reset")
	for _, gone := range []string{"dev_pg", "dev_secrets", "dev_platform.env"} {
		if _, err := os.Stat(filepath.Join(dir, gone)); !os.IsNotExist(err) {
			t.Fatalf("reset deja %s", gone)
		}
	}
}

// composeConfig is what gets inspected from "docker compose config --format json".
type composeConfig struct {
	Services map[string]struct {
		Environment map[string]*string `json:"environment"`
		Logging     struct {
			Driver  string            `json:"driver"`
			Options map[string]string `json:"options"`
		} `json:"logging"`
		Ports    []map[string]any          `json:"ports"`
		Networks map[string]map[string]any `json:"networks"`
		Secrets  []struct {
			Source string `json:"source"`
		} `json:"secrets"`
		Profiles []string `json:"profiles"`
	} `json:"services"`
	Networks map[string]struct {
		Internal bool `json:"internal"`
	} `json:"networks"`
	Secrets map[string]struct {
		File string `json:"file"`
	} `json:"secrets"`
}

// The compose file is validated without a daemon (docker compose config -q) with the two examples
// and not without them; everything goes to journald; only Caddy and the zones publish ports; the
// database does not leave its internal network; the platform reads each secret from its file; and
// X-Real-IP is only accepted from Caddy's IP.
func TestComposeConfig(t *testing.T) {
	docker := requireTool(t, "docker")
	if out, err := exec.Command(docker, "compose", "version").CombinedOutput(); err != nil {
		if os.Getenv("ELDMARK_REQUIRE_DEPLOY_TOOLS") == "1" {
			t.Fatalf("docker compose: %v: %s", err, out)
		}
		t.Skipf("falta docker compose: %s", out)
	}
	compose := func(args ...string) ([]byte, error) {
		cmd := exec.Command(docker, append([]string{"compose"}, args...)...)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		if err != nil {
			return out, fmt.Errorf("%v: %s", err, stderr.String())
		}
		return out, nil
	}
	if _, err := compose("config", "-q"); err == nil {
		t.Fatal("el compose vale sin las variables del entorno")
	}
	for _, envFile := range []string{"staging.env.example", "production.env.example"} {
		if _, err := compose("--env-file", envFile, "--profile", "*", "config", "-q"); err != nil {
			t.Fatalf("%s: %v", envFile, err)
		}
		raw, err := compose("--env-file", envFile, "--profile", "*", "config", "--format", "json")
		if err != nil {
			t.Fatalf("%s: %v", envFile, err)
		}
		var cfg composeConfig
		if err := json.Unmarshal(raw, &cfg); err != nil {
			t.Fatal(err)
		}
		if len(cfg.Services) != 7 {
			t.Fatalf("%s: servicios %d", envFile, len(cfg.Services))
		}
		for name, s := range cfg.Services {
			if s.Logging.Driver != "journald" || s.Logging.Options["tag"] != "{{.Name}}" {
				t.Errorf("%s: %s no escribe en journald con su nombre: %+v", envFile, name, s.Logging)
			}
			if len(s.Ports) > 0 && name != "caddy" && name != "zone-vado-gris" {
				t.Errorf("%s: %s publica puertos %v", envFile, name, s.Ports)
			}
			for k, v := range s.Environment {
				for _, secret := range []string{"ELDMARK_DATABASE_URL", "ELDMARK_TICKET_KEYS", "ELDMARK_ZONE_TOKENS",
					"ELDMARK_ZONE_TOKEN", "ELDMARK_SMTP_URL", "ELDMARK_EMAIL_HMAC_KEY", "POSTGRES_PASSWORD"} {
					if k == secret {
						t.Errorf("%s: %s lleva %s en claro (%v)", envFile, name, k, v != nil)
					}
				}
			}
		}
		db := cfg.Services["db"]
		if _, onData := db.Networks["data"]; len(db.Networks) != 1 || !onData || !cfg.Networks["data"].Internal {
			t.Errorf("%s: la base no está sola en la red interna data: %v", envFile, db.Networks)
		}
		platform := cfg.Services["platform"]
		caddyIP := cfg.Services["caddy"].Networks["edge"]["ipv4_address"]
		if trusted := platform.Environment["ELDMARK_TRUSTED_PROXIES"]; trusted == nil || caddyIP == nil ||
			*trusted != fmt.Sprint(caddyIP)+"/32" {
			t.Errorf("%s: ELDMARK_TRUSTED_PROXIES %v y la IP de Caddy %v", envFile, trusted, caddyIP)
		}
		if len(platform.Secrets) != 5 {
			t.Errorf("%s: secretos de la plataforma %v", envFile, platform.Secrets)
		}
		for name, s := range cfg.Secrets {
			if filepath.Base(s.File) != name || filepath.Base(filepath.Dir(s.File)) != "secrets" {
				t.Errorf("%s: el secreto %s sale de %s", envFile, name, s.File)
			}
		}
		for _, ops := range []string{"backup", "restore-check", "pitr-check"} {
			if p := cfg.Services[ops].Profiles; len(p) != 1 || p[0] != "ops" {
				t.Errorf("%s: %s sin el perfil ops: %v", envFile, ops, p)
			}
		}
	}
}

// The Caddyfile sets X-Real-IP to the IP of whoever connects, passes to platform:24680 and writes
// no access log (§10.1); if caddy is present, it is adapted and the configuration has no "logs".
func TestCaddyfile(t *testing.T) {
	text := string(readFile(t, "Caddyfile"))
	for _, want := range []string{"reverse_proxy platform:24680", "header_up X-Real-IP {remote_host}",
		"{$ELDMARK_DOMAIN}", "email {$ELDMARK_ACME_EMAIL}"} {
		if !strings.Contains(text, want) {
			t.Errorf("el Caddyfile no tiene %q", want)
		}
	}
	if regexp.MustCompile(`(?m)^\s*log(\s|$|\{)`).MatchString(text) {
		t.Error("el Caddyfile tiene una directiva log")
	}
	// caddy does not come on the CI machines: without it, only the above.
	caddy, err := exec.LookPath("caddy")
	if err != nil {
		t.Skip("falta caddy: no se adapta el Caddyfile")
	}
	cmd := exec.Command(caddy, "adapt", "--config", "Caddyfile", "--adapter", "caddyfile")
	cmd.Env = append(os.Environ(), "ELDMARK_DOMAIN=staging.eldmark.example", "ELDMARK_ACME_EMAIL=ops@eldmark.example")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("caddy adapt: %v", err)
	}
	if strings.Contains(string(out), `"logs"`) || !strings.Contains(string(out), `"X-Real-Ip"`) {
		t.Fatalf("configuración adaptada:\n%s", out)
	}
}

// The CI secrets check (tools/check_secrets.sh, §10.3): the real examples pass; a test staging.env
// in the index, a file under secrets/ or an example with the value of a secret do not (and the
// value does not appear in the output). Neither does this repository's index.
func TestCheckSecrets(t *testing.T) {
	git := requireTool(t, "git")
	bash := requireTool(t, "bash")
	check, err := filepath.Abs("../../tools/check_secrets.sh")
	if err != nil {
		t.Fatal(err)
	}
	repo := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command(git, args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	checkRepo := func() (int, string) {
		t.Helper()
		out, err := exec.Command(bash, check, repo).CombinedOutput()
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return exit.ExitCode(), string(out)
		}
		if err != nil {
			t.Fatal(err)
		}
		return 0, string(out)
	}
	write := func(rel, content string) {
		t.Helper()
		path := filepath.Join(repo, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("init", "-q")
	for _, example := range []string{"staging.env.example", "production.env.example"} {
		write("platform/deploy/"+example, string(readFile(t, example)))
	}
	run("add", "-A")
	if code, out := checkRepo(); code != 0 {
		t.Fatalf("los ejemplos de verdad no pasan: %d\n%s", code, out)
	}
	write("platform/deploy/staging.env", "ELDMARK_ENV=staging\n")
	run("add", "-f", "platform/deploy/staging.env")
	if code, out := checkRepo(); code != 1 || !strings.Contains(out, "platform/deploy/staging.env") {
		t.Fatalf("staging.env en el índice: %d\n%s", code, out)
	}
	run("rm", "-q", "--cached", "platform/deploy/staging.env")
	write("platform/deploy/secrets/ticket_keys", "1:AAAA\n")
	run("add", "-f", "platform/deploy/secrets/ticket_keys")
	if code, out := checkRepo(); code != 1 || !strings.Contains(out, "secrets/ticket_keys") {
		t.Fatalf("secrets/ en el índice: %d\n%s", code, out)
	}
	run("rm", "-q", "--cached", "platform/deploy/secrets/ticket_keys")
	write("platform/deploy/staging.env.example", string(readFile(t, "staging.env.example"))+
		"ELDMARK_TICKET_KEYS=1:c2VjcmV0by1kZS1wcnVlYmE=\n")
	if code, out := checkRepo(); code != 1 || !strings.Contains(out, "staging.env.example") ||
		strings.Contains(out, "c2VjcmV0") {
		t.Fatalf("ejemplo con un secreto: %d\n%s", code, out)
	}
	// This repository's index (if tested from a clone).
	if err := exec.Command(git, "-C", "../..", "rev-parse", "--git-dir").Run(); err == nil {
		if out, err := exec.Command(bash, check, "../..").CombinedOutput(); err != nil {
			t.Fatalf("el repositorio no pasa la comprobación de secretos: %v\n%s", err, out)
		}
	}
}
