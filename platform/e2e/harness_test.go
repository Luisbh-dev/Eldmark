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

// Variables de entorno del arnés.
const (
	godotVar        = "ELDMARK_GODOT"         // ruta del ejecutable de Godot 4.7.2; sin ella, las pruebas se saltan
	requireGodotVar = "ELDMARK_REQUIRE_GODOT" // 1 (la CI): sin ELDMARK_GODOT fallan en lugar de saltarse
	artifactsVar    = "ELDMARK_E2E_ARTIFACTS" // carpeta donde se conservan los registros de cada prueba (opcional)
)

// La plataforma de las pruebas (plataforma.md §15, P10): un solo despliegue de zona, test_world en el mundo 1 y
// el canal 0, que es la zona de entrada de los dos reinos; latido de 1 s y arrendamientos de 6 s.
const (
	ZoneID     = "test_world"
	WorldID    = 1
	HeartbeatS = 1
	LeaseTTLS  = 6
)

// Plazos del arnés.
const (
	importTimeout = 10 * time.Minute
	bootTimeout   = 20 * time.Second // la plataforma, hasta el final de su arranque
	stopTimeout   = 15 * time.Second // la plataforma, al acabar la prueba
	pollEvery     = 100 * time.Millisecond
	tailLines     = 40 // líneas del final de cada registro que se copian en la salida de una prueba que falla
)

var (
	godotBin  string // ELDMARK_GODOT
	repoRoot  string // la raíz del proyecto de Godot (dos carpetas por encima de platform/e2e)
	importLog string // el registro de la importación de TestMain
	importErr error  // por qué falló la importación (todas las pruebas fallan con él)
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

// importProject importa el proyecto una vez (godot --headless --import): las zonas y los bots cargan escenas y
// recursos importados. Necesita los objetos de LFS ya bajados.
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

// requireGodot salta la prueba sin ELDMARK_GODOT (o la hace fallar con ELDMARK_REQUIRE_GODOT=1) y la hace fallar si
// la importación falló.
func requireGodot(t *testing.T) {
	t.Helper()
	if godotBin == "" {
		if os.Getenv(requireGodotVar) == "1" {
			t.Fatalf("%s no está puesta y %s=1", godotVar, requireGodotVar)
		}
		t.Skipf("%s no está puesta (la ruta del ejecutable de Godot 4.7.2): sin Godot no hay extremo a extremo", godotVar)
	}
	if importErr != nil {
		t.Fatalf("la importación del proyecto falló: %v\n%s", importErr, tail(importLog, tailLines))
	}
}

// childEnv es el entorno de un proceso de Godot: el de la prueba sin ninguna variable ELDMARK_* (una
// ELDMARK_ZONE_TOKEN_FILE heredada chocaría con la de la prueba) más extra.
func childEnv(extra []string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "ELDMARK_") {
			env = append(env, kv)
		}
	}
	return append(env, extra...)
}

// Harness es la plataforma de una prueba (la de verdad, la de serve, en este proceso y sobre una base nueva) con lo
// que hace falta para arrancar zonas y bots contra ella. Todo se para al acabar la prueba: primero los procesos de
// Godot, luego la plataforma y al final la base.
type Harness struct {
	T           *testing.T
	Pool        *pgxpool.Pool
	Cfg         *config.Config
	PublicURL   string // la API pública (la de los bots): http://127.0.0.1:<puerto>
	InternalURL string // la API interna (la de las zonas)
	Protocol    int    // el protocol_version de progression_rules.json (la cabecera X-Eldmark-Protocol)
	Dir         string // los registros y los informes de la prueba
	ZoneToken   string // ELDMARK_ZONE_TOKEN de las zonas (el alcance 1:test_world:0)
	TicketKeys  string // ELDMARK_TICKET_KEYS, la misma en la plataforma y en las zonas
	Started     time.Time

	mu    sync.Mutex
	procs []*Process
	seq   map[string]int
}

// Option cambia las variables ELDMARK_* de la plataforma antes de arrancarla.
type Option func(env map[string]string)

// New arranca la plataforma de la prueba: base nueva con todas las migraciones, la configuración de §15 cargada
// con config.Load (ELDMARK_ENV=test), los servicios de serve (services.Mount) y las dos API en puertos libres.
// Vuelve cuando el arranque ha terminado.
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
				t.Errorf("la plataforma se ha parado con un error: %v", err)
			}
		case <-time.After(stopTimeout):
			t.Errorf("la plataforma no se para en %v", stopTimeout)
		}
		closeServices()
		_ = logFile.Close()
	})
	deadline := time.Now().Add(bootTimeout)
	for !a.Started() {
		select {
		case err := <-done:
			t.Fatalf("la plataforma se ha parado al arrancar: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("la plataforma no termina de arrancar en %v", bootTimeout)
		}
		time.Sleep(20 * time.Millisecond)
	}
	h.Logf("plataforma lista (pública %s, interna %s)", h.PublicURL, h.InternalURL)
}

// artifactsDir es la carpeta de los registros de la prueba: ELDMARK_E2E_ARTIFACTS/<prueba> (vaciada) o una
// temporal.
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

// Logf escribe en la salida de la prueba con los segundos desde el arranque del arnés delante.
func (h *Harness) Logf(format string, args ...any) {
	h.T.Helper()
	h.T.Logf("[%5.1f s] %s", time.Since(h.Started).Seconds(), fmt.Sprintf(format, args...))
}

// Elapsed son los segundos desde el arranque del arnés.
func (h *Harness) Elapsed() time.Duration { return time.Since(h.Started) }

// dumpLogsOnFailure copia el final de cada registro en la salida de una prueba que ha fallado.
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
	h.T.Logf("registros en %s", h.Dir)
}

// tail son las últimas n líneas del archivo path.
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

// --- Cuentas -----------------------------------------------------------------------------------------------

// Account es una cuenta de la prueba con su contraseña en un archivo (el --password-file de los bots).
type Account struct {
	ID           int64
	Email        string
	Password     string
	PasswordFile string
}

// NewAccount registra una cuenta por la API pública (POST /v1/accounts, con los tres textos aceptados) y deja su
// contraseña en un archivo de la prueba.
func (h *Harness) NewAccount(email string) *Account {
	t := h.T
	t.Helper()
	acc := &Account{Email: email, Password: "contraseña de " + randomHex(t, 6)}
	body := map[string]any{"email": email, "password": acc.Password, "age_confirmed": true,
		"accept":   map[string]any{"terms": 1, "privacy": 1, "rules": 1},
		"consents": map[string]any{"crash_reports": false, "analytics": false}}
	status, raw := h.PublicJSON(http.MethodPost, "/v1/accounts", body)
	if status != http.StatusAccepted {
		t.Fatalf("registro de %s: %d %s", email, status, raw)
	}
	h.Scalar(&acc.ID, `select account_id from accounts where email = $1`, email)
	acc.PasswordFile = filepath.Join(h.Dir, fmt.Sprintf("cuenta%d.pw", acc.ID))
	if err := os.WriteFile(acc.PasswordFile, []byte(acc.Password+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return acc
}

// PublicJSON hace una petición a la API pública con la cabecera del protocolo y devuelve el estado y el cuerpo.
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

// --- Base de datos -----------------------------------------------------------------------------------------

// Scalar lee una fila de la base en dst o hace fallar la prueba.
func (h *Harness) Scalar(dst any, sql string, args ...any) {
	h.T.Helper()
	if err := h.Pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		h.T.Fatalf("%v\n%s", err, sql)
	}
}

// Exists dice si la consulta devuelve alguna fila.
func (h *Harness) Exists(sql string, args ...any) bool {
	h.T.Helper()
	var ok bool
	h.Scalar(&ok, "select exists ("+sql+")", args...)
	return ok
}

// WaitFor espera a que cond se cumpla, mirándola cada 100 ms, o hace fallar la prueba al pasar timeout.
func (h *Harness) WaitFor(timeout time.Duration, what string, cond func() bool) {
	h.T.Helper()
	deadline := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(deadline) {
			h.T.Fatalf("no llega %s en %v", what, timeout)
		}
		time.Sleep(pollEvery)
	}
}

// CheckBooks comprueba por SQL que lo guardado del personaje cuadra, sin nada duplicado ni a medias (TEC-25; las
// cuentas de progresion.md §15 P8): por definición, la suma de count_delta de item_events es la de count de sus
// objetos vivos; por moneda, la suma de delta de ledger_entries es el saldo; el kit (operación STARTER_KIT) se dio
// una sola vez, y tiene algún objeto vivo (si no, lo demás no diría nada).
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
			t.Fatalf("%s del personaje %d no cuadran: %s", what, characterID, strings.Join(bad, "; "))
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
		t.Fatalf("el personaje %d tiene %d operaciones STARTER_KIT y %d objetos vivos (se esperaba 1 y alguno)",
			characterID, kits, alive)
	}
}

// WaitCharacter espera a que exista el personaje name (sin borrar) en el mundo de las pruebas y devuelve su id.
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

// --- Procesos de Godot -------------------------------------------------------------------------------------

// Process es un proceso de Godot de la prueba (una zona o un bot), con la salida en su registro.
type Process struct {
	Name string
	Log  string // la salida estándar y la de error

	cmd  *exec.Cmd
	done chan struct{}
	code int   // el código de salida; -1 si lo terminó una señal
	err  error // el error de Wait que no es un código de salida
}

// start lanza godot --headless --path <raíz> -- args con el entorno de childEnv(env).
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
		t.Fatalf("no arranca %s: %v", name, err)
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
	h.Logf("%s arrancado: %s", name, strings.Join(args, " "))
	return p
}

// next da el nombre del siguiente proceso de la clase kind (zona1, zona2, bot1…: los de sus registros).
func (h *Harness) next(kind string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.seq == nil {
		h.seq = map[string]int{}
	}
	h.seq[kind]++
	return kind + strconv.Itoa(h.seq[kind])
}

// killAll mata los procesos que sigan vivos al acabar la prueba.
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

// Exited dice si el proceso ha terminado.
func (p *Process) Exited() bool {
	select {
	case <-p.done:
		return true
	default:
		return false
	}
}

// Code es el código de salida (solo tras terminar; -1 si lo terminó una señal).
func (p *Process) Code() int { return p.code }

// Wait espera a que el proceso termine y devuelve su código de salida; si no termina en timeout, lo mata y hace
// fallar la prueba.
func (p *Process) Wait(t *testing.T, timeout time.Duration) int {
	t.Helper()
	select {
	case <-p.done:
	case <-time.After(timeout):
		p.Kill()
		t.Fatalf("%s no termina en %v", p.Name, timeout)
	}
	if p.err != nil {
		t.Fatalf("%s: %v", p.Name, p.err)
	}
	return p.code
}

// Kill le manda SIGKILL (kill -9) y espera a que termine; devuelve la hora justo antes de la señal.
func (p *Process) Kill() time.Time {
	at := time.Now()
	if p.Exited() {
		return at
	}
	_ = p.cmd.Process.Kill()
	<-p.done
	return at
}

// requireRunning hace fallar la prueba si alguno de los procesos ya ha terminado.
func requireRunning(t *testing.T, procs ...*Process) {
	t.Helper()
	for _, p := range procs {
		if p != nil && p.Exited() {
			t.Fatalf("%s ha terminado antes de tiempo con el código %d", p.Name, p.code)
		}
	}
}

// LogContains dice si el registro del proceso tiene alguna línea con text (léase tras terminar: la salida de
// Godot puede no estar entera mientras corre).
func (p *Process) LogContains(text string) bool { return fileContains(p.Log, text) }

// PlatformLogContains dice si el registro de la plataforma (JSON por líneas) tiene alguna línea con text.
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

// --- Zonas -------------------------------------------------------------------------------------------------

// Zone es un servidor de zona test_world con --platform contra la plataforma de la prueba.
type Zone struct {
	*Process
	h        *Harness
	Port     int    // el puerto UDP (y el public_port de su registro, que la identifica en zone_instances)
	StopFile string // --stop-file: crearlo pide el cierre ordenado
	Report   string // --report
	Instance string // su zone_instance_id, desde WaitLive
}

// StartZone arranca una zona test_world con --platform (la API interna de la prueba), un puerto UDP libre,
// --stop-file, --report y args (--save-interval=5…). El token y las claves del billete van en el entorno.
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

// WaitLive espera a que la instancia de la zona esté live en la plataforma y devuelve su zone_instance_id.
func (z *Zone) WaitLive(timeout time.Duration) string {
	h := z.h
	h.T.Helper()
	h.WaitFor(timeout, z.Name+" en live", func() bool {
		requireRunning(h.T, z.Process)
		err := h.Pool.QueryRow(context.Background(), `select zone_instance_id::text from zone_instances
			where public_port = $1 and status = 'live'`, z.Port).Scan(&z.Instance)
		return err == nil
	})
	h.Logf("%s en live (instancia %s)", z.Name, z.Instance)
	return z.Instance
}

// Stop pide el cierre ordenado (crea el --stop-file: guardados finales, liberación y baja) y devuelve el código
// de salida.
func (z *Zone) Stop(timeout time.Duration) int {
	z.h.T.Helper()
	if err := os.WriteFile(z.StopFile, nil, 0o644); err != nil {
		z.h.T.Fatal(err)
	}
	code := z.Wait(z.h.T, timeout)
	z.h.Logf("%s cerrada con el código %d", z.Name, code)
	return code
}

// freeUDPPort es un puerto UDP libre en este momento.
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

// Bot es un cliente --bot con cuenta (plataforma.md §19.16): inicia sesión, asegura el personaje, pide enter y
// entra con el billete en la zona que da la plataforma.
type Bot struct {
	*Process
	Account *Account
	Report  string
}

// StartBot arranca un bot con la cuenta y args (--character=<nombre>, --quit-after-ticks=N…).
func (h *Harness) StartBot(acc *Account, args ...string) *Bot {
	h.T.Helper()
	name := h.next("bot")
	b := &Bot{Account: acc, Report: filepath.Join(h.Dir, name+".json")}
	all := append([]string{"--bot", "--platform=" + h.PublicURL, "--login=" + acc.Email,
		"--password-file=" + acc.PasswordFile, "--report=" + b.Report}, args...)
	b.Process = h.start(name, nil, all...)
	return b
}

// BotReport es lo que la prueba mira del informe del bot.
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

// ReadReport lee el informe del bot (lo escribe al salir).
func (b *Bot) ReadReport(t *testing.T) *BotReport {
	t.Helper()
	data, err := os.ReadFile(b.Report)
	if err != nil {
		t.Fatalf("informe de %s: %v", b.Name, err)
	}
	r := &BotReport{}
	if err := json.Unmarshal(data, &r.Raw); err != nil {
		t.Fatalf("informe de %s: %v", b.Name, err)
	}
	if err := json.Unmarshal(data, r); err != nil {
		t.Fatalf("informe de %s: %v", b.Name, err)
	}
	return r
}
