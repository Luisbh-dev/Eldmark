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
			t.Fatalf("missing %s (ELDMARK_REQUIRE_DEPLOY_TOOLS=1)", name)
		}
		t.Skipf("missing %s", name)
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
			t.Fatal("PostgreSQL binaries not found (ELDMARK_REQUIRE_PG=1)")
		}
		t.Skip("PostgreSQL binaries not found")
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
		t.Fatalf("%s %v: code %d\n%s", name, args, code, out)
	}
	return out
}

func mustContain(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Fatalf("missing %q in the output:\n%s", w, out)
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
	if len(scripts) != 6 {
		t.Fatalf("scripts: %v", scripts)
	}
	bash := requireTool(t, "bash")
	for _, s := range scripts {
		if out, err := exec.Command(bash, "-n", s).CombinedOutput(); err != nil {
			t.Errorf("bash -n %s: %v: %s", s, err, out)
		}
		info, err := os.Stat(s)
		if err != nil || info.Mode()&0o111 == 0 && s != "pglib.sh" {
			t.Errorf("%s is not executable", s)
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
		t.Fatalf("copies: %v", first)
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
		t.Fatalf("two weekly ones on the same day:\n%s", out)
	}
	latest := filepath.Join(dir, "purges.txt")
	if n := lines(t, latest); n != 3 {
		t.Fatalf("purges.txt with %d lines", n)
	}
	if d, w := files(t, filepath.Join(dir, "daily"), "*"), files(t, filepath.Join(dir, "weekly"), "*"); len(d) != 4 || len(w) != 2 {
		t.Fatalf("daily %v, weekly %v", d, w)
	}
	if strings.Contains(string(readFile(t, latest)), "@") {
		t.Fatal("purges.txt carries emails")
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
		t.Fatalf("restore_check.sh with an email in the audit: code %d\n%s", code, out)
	}
	mustContain(t, out, "MAL: filas de audit_log con el correo de una cuenta purgada: 1")

	// Rotation: with 2 daily copies, the 2 most recent stay, each with its purges.txt.
	env["ELDMARK_BACKUP_DAILY"] = "2"
	mustContain(t, mustScript(t, env, "backup.sh"), "rotada:")
	dumps := files(t, filepath.Join(dir, "daily"), "*.dump")
	if len(dumps) != 2 || len(files(t, filepath.Join(dir, "daily"), "*.purges.txt")) != 2 {
		t.Fatalf("after rotating: %v", files(t, filepath.Join(dir, "daily"), "*"))
	}
	if n := lines(t, latest); n != 5 {
		t.Fatalf("the most recent purges.txt has %d lines", n)
	}
	if len(files(t, filepath.Join(dir, "weekly"), "*.dump")) != 1 {
		t.Fatal("rotating the daily ones touched the weekly one")
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
			t.Errorf("%v: code %d\n%s", args, code, out)
		}
	}
	if code, out := script(t, nil, "restore_check.sh", "/no/existe.dump", "/no/purges.txt"); code != 1 ||
		!strings.Contains(out, "no se puede leer la copia") {
		t.Errorf("no backup: %d\n%s", code, out)
	}
	if code, out := script(t, nil, "backup.sh"); code != 1 || !strings.Contains(out, "ELDMARK_BACKUP_DIR") {
		t.Errorf("backup.sh without a folder: %d\n%s", code, out)
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
			t.Fatalf("dev_platform.env carries %s in plain text:\n%s", secret, envFile)
		}
	}
	tokens := string(readFile(t, filepath.Join(dir, "dev_secrets", "zone_tokens")))
	if !regexp.MustCompile(`^1:vado_gris:0:[0-9a-f]{64},1:test_world:0:[0-9a-f]{64}\n$`).MatchString(tokens) {
		t.Fatalf("zone_tokens: %q", tokens)
	}
	out = mustScript(t, env, "dev.sh", "prepare")
	if strings.Contains(out, "cuenta admin:") || strings.Contains(out, "entorno nuevo") {
		t.Fatalf("the second time it repeats:\n%s", out)
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
		t.Fatalf("accounts: %d admin, %d test (%v)", admins, players, err)
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
			t.Fatalf("dev.sh up: ready %v, output %v\n%s", ready, err, upOut.String())
		}
	case <-time.After(20 * time.Second):
		_ = up.Process.Kill()
		t.Fatalf("dev.sh up does not stop on TERM\n%s", upOut.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "dev_pg", "data", "postmaster.pid")); !os.IsNotExist(err) {
		t.Fatalf("PostgreSQL is still running after stopping up (%v)", err)
	}
	mustScript(t, env, "dev.sh", "reset")
	for _, gone := range []string{"dev_pg", "dev_secrets", "dev_platform.env"} {
		if _, err := os.Stat(filepath.Join(dir, gone)); !os.IsNotExist(err) {
			t.Fatalf("reset leaves %s", gone)
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

		StopGracePeriod string `json:"stop_grace_period"`

		Volumes []struct {
			Source string `json:"source"`
			Target string `json:"target"`
		} `json:"volumes"`

		Build struct {
			Context    string `json:"context"`
			Dockerfile string `json:"dockerfile"`
		} `json:"build"`
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
		t.Skipf("docker compose missing: %s", out)
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
		t.Fatal("the compose file is valid without the environment variables")
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
			t.Fatalf("%s: services %d", envFile, len(cfg.Services))
		}
		for name, s := range cfg.Services {
			if s.Logging.Driver != "journald" || s.Logging.Options["tag"] != "{{.Name}}" {
				t.Errorf("%s: %s does not write to journald under its name: %+v", envFile, name, s.Logging)
			}
			if len(s.Ports) > 0 && name != "caddy" && name != "zone-vado-gris" {
				t.Errorf("%s: %s publishes ports %v", envFile, name, s.Ports)
			}
			for k, v := range s.Environment {
				for _, secret := range []string{"ELDMARK_DATABASE_URL", "ELDMARK_TICKET_KEYS", "ELDMARK_ZONE_TOKENS",
					"ELDMARK_ZONE_TOKEN", "ELDMARK_SMTP_URL", "ELDMARK_EMAIL_HMAC_KEY", "POSTGRES_PASSWORD"} {
					if k == secret {
						t.Errorf("%s: %s carries %s in plain text (%v)", envFile, name, k, v != nil)
					}
				}
			}
		}
		db := cfg.Services["db"]
		if _, onData := db.Networks["data"]; len(db.Networks) != 1 || !onData || !cfg.Networks["data"].Internal {
			t.Errorf("%s: the database is not alone on the internal data network: %v", envFile, db.Networks)
		}
		platform := cfg.Services["platform"]
		caddyIP := cfg.Services["caddy"].Networks["edge"]["ipv4_address"]
		if trusted := platform.Environment["ELDMARK_TRUSTED_PROXIES"]; trusted == nil || caddyIP == nil ||
			*trusted != fmt.Sprint(caddyIP)+"/32" {
			t.Errorf("%s: ELDMARK_TRUSTED_PROXIES %v and the Caddy IP %v", envFile, trusted, caddyIP)
		}
		if len(platform.Secrets) != 5 {
			t.Errorf("%s: platform secrets %v", envFile, platform.Secrets)
		}
		for name, s := range cfg.Secrets {
			if filepath.Base(s.File) != name || filepath.Base(filepath.Dir(s.File)) != "secrets" {
				t.Errorf("%s: the secret %s comes from %s", envFile, name, s.File)
			}
		}
		// The zone (TEC-20): built from the exported server, with time to save before the kill and a volume for
		// Godot's logs.
		zone := cfg.Services["zone-vado-gris"]
		if len(zone.Profiles) != 1 || zone.Profiles[0] != "zonas" {
			t.Errorf("%s: the zone is not in the zonas profile: %v", envFile, zone.Profiles)
		}
		if grace, err := time.ParseDuration(zone.StopGracePeriod); err != nil || grace < 30*time.Second {
			t.Errorf("%s: stop_grace_period %q is too short for the final saves", envFile, zone.StopGracePeriod)
		}
		if zone.Build.Dockerfile != "platform/deploy/zone.Dockerfile" || zone.Build.Context == "" {
			t.Errorf("%s: the zone is not built from zone.Dockerfile: %+v", envFile, zone.Build)
		}
		hasLogs := false
		for _, v := range zone.Volumes {
			if v.Source == "zone_vado_gris_logs" && strings.HasPrefix(v.Target, "/home/eldmark/") {
				hasLogs = true
			}
		}
		if !hasLogs {
			t.Errorf("%s: the zone has no volume for its logs: %+v", envFile, zone.Volumes)
		}
		for _, ops := range []string{"backup", "restore-check", "pitr-check"} {
			if p := cfg.Services[ops].Profiles; len(p) != 1 || p[0] != "ops" {
				t.Errorf("%s: %s without the ops profile: %v", envFile, ops, p)
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
			t.Errorf("the Caddyfile does not have %q", want)
		}
	}
	if regexp.MustCompile(`(?m)^\s*log(\s|$|\{)`).MatchString(text) {
		t.Error("the Caddyfile has a log directive")
	}
	// caddy does not come on the CI machines: without it, only the above.
	caddy, err := exec.LookPath("caddy")
	if err != nil {
		t.Skip("caddy missing: the Caddyfile is not adapted")
	}
	cmd := exec.Command(caddy, "adapt", "--config", "Caddyfile", "--adapter", "caddyfile")
	cmd.Env = append(os.Environ(), "ELDMARK_DOMAIN=staging.eldmark.example", "ELDMARK_ACME_EMAIL=ops@eldmark.example")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("caddy adapt: %v", err)
	}
	if strings.Contains(string(out), `"logs"`) || !strings.Contains(string(out), `"X-Real-Ip"`) {
		t.Fatalf("adapted configuration:\n%s", out)
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
		t.Fatalf("the real examples do not pass: %d\n%s", code, out)
	}
	write("platform/deploy/staging.env", "ELDMARK_ENV=staging\n")
	run("add", "-f", "platform/deploy/staging.env")
	if code, out := checkRepo(); code != 1 || !strings.Contains(out, "platform/deploy/staging.env") {
		t.Fatalf("staging.env in the index: %d\n%s", code, out)
	}
	run("rm", "-q", "--cached", "platform/deploy/staging.env")
	write("platform/deploy/secrets/ticket_keys", "1:AAAA\n")
	run("add", "-f", "platform/deploy/secrets/ticket_keys")
	if code, out := checkRepo(); code != 1 || !strings.Contains(out, "secrets/ticket_keys") {
		t.Fatalf("secrets/ in the index: %d\n%s", code, out)
	}
	run("rm", "-q", "--cached", "platform/deploy/secrets/ticket_keys")
	write("platform/deploy/staging.env.example", string(readFile(t, "staging.env.example"))+
		"ELDMARK_TICKET_KEYS=1:c2VjcmV0by1kZS1wcnVlYmE=\n")
	if code, out := checkRepo(); code != 1 || !strings.Contains(out, "staging.env.example") ||
		strings.Contains(out, "c2VjcmV0") {
		t.Fatalf("example with a secret: %d\n%s", code, out)
	}
	// This repository's index (if tested from a clone).
	if err := exec.Command(git, "-C", "../..", "rev-parse", "--git-dir").Run(); err == nil {
		if out, err := exec.Command(bash, check, "../..").CombinedOutput(); err != nil {
			t.Fatalf("the repository does not pass the secrets check: %v\n%s", err, out)
		}
	}
}

// The zone image (TEC-20): the exported server on debian-slim with an unprivileged user, an entrypoint that
// turns SIGTERM and SIGINT into the server's --stop-file (Godot scripts cannot catch signals) and a HEALTHCHECK
// on the freshness of the report. The Dockerfile has its own ignore file so that the build context stays small.
func TestZoneImageFiles(t *testing.T) {
	dockerfile := string(readFile(t, "zone.Dockerfile"))
	for _, want := range []string{"FROM debian:bookworm-slim", "--uid 10001", "USER eldmark:eldmark", "HEALTHCHECK",
		"ENTRYPOINT [\"/usr/local/bin/zone-entrypoint.sh\"]", "exports/server", "EXPOSE 24600/udp"} {
		if !strings.Contains(dockerfile, want) {
			t.Errorf("zone.Dockerfile lacks %q", want)
		}
	}
	entrypoint := string(readFile(t, "zone-entrypoint.sh"))
	for _, want := range []string{"trap request_stop TERM INT", "--stop-file=", "--report=", "--healthcheck", "wait \"$pid\""} {
		if !strings.Contains(entrypoint, want) {
			t.Errorf("zone-entrypoint.sh lacks %q", want)
		}
	}
	ignore := string(readFile(t, "zone.Dockerfile.dockerignore"))
	if !strings.HasPrefix(ignore, "*\n") || !strings.Contains(ignore, "!exports/server") {
		t.Errorf("zone.Dockerfile.dockerignore does not restrict the context: %q", ignore)
	}
}

// The entrypoint, run for real with a fake server (a script that waits for the stop-file): SIGTERM creates the
// --stop-file, the server finishes by itself and the entrypoint exits with the server's code; the health check
// follows the age of the report.
func TestZoneEntrypoint(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("signals and bash scripts")
	}
	bash := requireTool(t, "bash")
	dir := t.TempDir()
	fake := filepath.Join(dir, "fake-server.sh")
	// The "server": arguments after "--" are the options; it writes the report, waits for the stop-file and exits 0
	// (or with the code in FAKE_EXIT).
	script := "#!/usr/bin/env bash\n" +
		"for a in \"$@\"; do case \"$a\" in --stop-file=*) stop=\"${a#*=}\";; --report=*) report=\"${a#*=}\";; esac; done\n" +
		"echo '{\"closed\": false}' > \"$report\"\n" +
		"echo ready\n" +
		"while [ ! -f \"$stop\" ]; do sleep 0.1; done\n" +
		"echo '{\"closed\": true}' > \"$report\"\n" +
		"exit \"${FAKE_EXIT:-0}\"\n"
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		sig  syscall.Signal
		exit string
		want int
	}{{syscall.SIGTERM, "0", 0}, {syscall.SIGINT, "3", 3}} {
		run := filepath.Join(dir, "run"+tc.exit)
		cmd := exec.Command(bash, "zone-entrypoint.sh", "--server", "--zone=vado_gris")
		cmd.Env = append(os.Environ(), "ELDMARK_RUN_DIR="+run, "ELDMARK_SERVER_BIN="+fake, "FAKE_EXIT="+tc.exit)
		var out bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &out
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		report := filepath.Join(run, "report.json")
		deadline := time.Now().Add(10 * time.Second)
		for !strings.Contains(string(readFileOrEmpty(report)), "false") {
			if time.Now().After(deadline) {
				_ = cmd.Process.Kill()
				t.Fatalf("the fake server never wrote its report:\n%s", out.String())
			}
			time.Sleep(50 * time.Millisecond)
		}
		health := func() error {
			c := exec.Command(bash, "zone-entrypoint.sh", "--healthcheck")
			c.Env = append(os.Environ(), "ELDMARK_RUN_DIR="+run)
			return c.Run()
		}
		if err := health(); err != nil {
			t.Fatalf("a fresh report is healthy: %v", err)
		}
		old := time.Now().Add(-2 * time.Minute)
		if err := os.Chtimes(report, old, old); err != nil {
			t.Fatal(err)
		}
		if err := health(); err == nil {
			t.Fatal("a report two minutes old is unhealthy")
		}
		if err := cmd.Process.Signal(tc.sig); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			code := 0
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				code = exitErr.ExitCode()
			} else if err != nil {
				t.Fatal(err)
			}
			if code != tc.want {
				t.Fatalf("%v: the entrypoint exits with %d, expected the server's %d:\n%s", tc.sig, code, tc.want, out.String())
			}
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			t.Fatalf("%v: the entrypoint does not finish:\n%s", tc.sig, out.String())
		}
		if !strings.Contains(string(readFileOrEmpty(report)), "true") {
			t.Fatalf("%v: the server did not get to write its final report", tc.sig)
		}
	}
}

func readFileOrEmpty(path string) []byte {
	data, _ := os.ReadFile(path)
	return data
}
