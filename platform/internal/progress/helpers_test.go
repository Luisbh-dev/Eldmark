package progress_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/characters"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/progress"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/internal/zones"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

// Los casos de las comprobaciones del guardado que genera la zona (progresion.md §13.3,
// tools/progression/write_fixtures.gd).
const saveCasesPath = "../../../tests/fixtures/progression/save_cases.json"

type saveCases struct {
	Format     int    `json:"format"`
	About      string `json:"about"`
	NowUnix    int64  `json:"now_unix"`
	WorldID    int16  `json:"world_id"`
	ZoneID     string `json:"zone_id"`
	InstanceID string `json:"instance_id"`
	IDBlocks   []struct {
		InstanceID    string   `json:"instance_id"`
		First         jsonx.ID `json:"first"`
		Count         int64    `json:"count"`
		GrantedAtUnix int64    `json:"granted_at_unix"`
	} `json:"id_blocks"`
	Accounts []struct {
		AccountID jsonx.ID `json:"account_id"`
		Role      string   `json:"role"`
	} `json:"accounts"`
	Characters []struct {
		CharacterID       jsonx.ID `json:"character_id"`
		AccountID         jsonx.ID `json:"account_id"`
		Realm             int16    `json:"realm"`
		RaceID            string   `json:"race_id"`
		Appearance        string   `json:"appearance"`
		StarterTemplateID string   `json:"starter_template_id"`
	} `json:"characters"`
	Cases []saveCase `json:"cases"`
}

type saveCase struct {
	Name  string `json:"name"`
	Rule  string `json:"rule"`
	Steps []struct {
		CharacterID jsonx.ID        `json:"character_id"`
		Progress    json.RawMessage `json:"progress"`
		Expect      string          `json:"expect"`
	} `json:"steps"`
}

func loadCases(t testing.TB) *saveCases {
	t.Helper()
	data, err := os.ReadFile(saveCasesPath)
	if err != nil {
		t.Fatal(err)
	}
	var c saveCases
	if err := jsonx.DecodeBytes(data, &c); err != nil {
		t.Fatal(err)
	}
	if c.Format != 1 || len(c.Cases) == 0 {
		t.Fatalf("save_cases.json: formato %d, %d casos", c.Format, len(c.Cases))
	}
	return &c
}

// world es una base nueva con lo que piden los casos: las cuentas con su rol, los personajes (con Create), las
// dos instancias y sus bloques de ids; el almacén con el reloj de los casos.
type world struct {
	t     testing.TB
	pool  *pgxpool.Pool
	cases *saveCases
	clock *fakeNow
	store *progress.Store
	rules *progress.Rules
}

// fakeNow es un reloj que se puede mover.
type fakeNow struct{ at time.Time }

func (f *fakeNow) now() time.Time          { return f.at }
func (f *fakeNow) advance(d time.Duration) { f.at = f.at.Add(d) }

// newWorld monta la base de los casos (la otra instancia, en el canal 1 para que las dos estén vivas).
func newWorld(t testing.TB, c *saveCases) *world {
	t.Helper()
	w := &world{t: t, pool: testdb.New(t), cases: c, clock: &fakeNow{at: time.Unix(c.NowUnix, 0).UTC()}}
	w.rules = embedded(t)
	w.store = progress.New(w.rules, w.clock.now)
	for _, a := range c.Accounts {
		w.exec(`insert into accounts (account_id, email, role, age_confirmed_at) overriding system value
			values ($1, $2, $3, now())`, int64(a.AccountID), fmt.Sprintf("c%d@example.org", a.AccountID), a.Role)
	}
	for i, inst := range []string{c.InstanceID, otherInstance(c)} {
		w.exec(`insert into zone_instances (zone_instance_id, world_id, zone_id, channel, public_host, public_port,
				realms, build_id, protocol_version, record_format, max_players, status, live_at)
			values ($1, $2, $3, $4, '127.0.0.1', 24600, '{1,2}', 'prueba', 7, 1, 64, 'live', now())`,
			inst, c.WorldID, c.ZoneID, i)
	}
	for _, b := range c.IDBlocks {
		if b.Count != zones.BlockSize {
			t.Fatalf("bloque de %d ids", b.Count)
		}
		w.exec(`insert into id_blocks (first_id, zone_instance_id, granted_at) values ($1, $2, to_timestamp($3))`,
			int64(b.First), b.InstanceID, b.GrantedAtUnix)
	}
	for _, ch := range c.Characters {
		id := int64(ch.CharacterID)
		w.exec(`insert into characters (character_id, world_id, account_id, name, name_key, realm) overriding system value
			values ($1, $2, $3, $4, $5, $6)`, id, c.WorldID, int64(ch.AccountID), fmt.Sprintf("P%d", id),
			fmt.Sprintf("p%d", id), ch.Realm)
		appearance, err := base64.StdEncoding.DecodeString(ch.Appearance)
		if err != nil || len(appearance) != 8 {
			t.Fatalf("apariencia %q", ch.Appearance)
		}
		if err := w.rules.ValidateCreate(ch.Realm, ch.RaceID, [8]byte(appearance), ch.StarterTemplateID); err != nil {
			t.Fatalf("el personaje %d de los casos no valdría al crearlo: %v", id, err)
		}
		w.tx(func(tx pgx.Tx) error {
			return w.store.Create(context.Background(), tx, c.WorldID, id, persistence.CreateParams{RaceID: ch.RaceID,
				Appearance: [8]byte(appearance), StarterTemplateID: ch.StarterTemplateID})
		})
	}
	return w
}

// otherInstance es la instancia del segundo bloque de los casos.
func otherInstance(c *saveCases) string {
	for _, b := range c.IDBlocks {
		if b.InstanceID != c.InstanceID {
			return b.InstanceID
		}
	}
	return ""
}

func (w *world) exec(sql string, args ...any) {
	w.t.Helper()
	if _, err := w.pool.Exec(context.Background(), sql, args...); err != nil {
		w.t.Fatalf("%v\n%s", err, sql)
	}
}

func (w *world) scalar(dst any, sql string, args ...any) {
	w.t.Helper()
	if err := w.pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		w.t.Fatalf("%v\n%s", err, sql)
	}
}

func (w *world) count(sql string, args ...any) int {
	w.t.Helper()
	var n int
	w.scalar(&n, sql, args...)
	return n
}

func (w *world) tx(fn func(pgx.Tx) error) {
	w.t.Helper()
	if err := db.InTx(context.Background(), w.pool, pgx.TxOptions{}, fn); err != nil {
		w.t.Fatal(err)
	}
}

// key es la SaveKey de un guardado de los casos para el personaje id (la instancia que reclama, la de los
// casos, salvo que se diga otra).
func (w *world) key(id int64) persistence.SaveKey {
	inst, ok := zones.ParseUUID(w.cases.InstanceID)
	if !ok {
		w.t.Fatal(w.cases.InstanceID)
	}
	return persistence.SaveKey{WorldID: w.cases.WorldID, CharacterID: id, InstanceID: inst, ZoneID: w.cases.ZoneID}
}

// apply aplica un guardado en su transacción y devuelve «applied» o el check del error (S8 para un error
// de la base que no es pasajero, con la regla de plataforma.md §7.3); otro error hace fallar la prueba.
func (w *world) apply(id int64, body json.RawMessage) (string, int64) {
	w.t.Helper()
	return w.applyKey(w.key(id), body)
}

func (w *world) applyKey(key persistence.SaveKey, body json.RawMessage) (string, int64) {
	w.t.Helper()
	var version int64
	err := db.InTx(context.Background(), w.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		var err error
		version, err = w.store.Apply(context.Background(), tx, key, body)
		return err
	})
	return outcome(w.t, err), version
}

// outcome es «applied», el check de un *persistence.InvalidSaveError o «S8» con un error de la base que no es
// pasajero.
func outcome(t testing.TB, err error) string {
	t.Helper()
	var invalid *persistence.InvalidSaveError
	switch {
	case err == nil:
		return "applied"
	case errors.As(err, &invalid):
		return invalid.Check
	case db.Deterministic(err):
		return "S8"
	}
	t.Fatalf("error inesperado: %v", err)
	return ""
}

// step devuelve el cuerpo del paso i del caso name.
func (c *saveCases) step(t testing.TB, name string, i int) (int64, json.RawMessage) {
	t.Helper()
	for _, sc := range c.Cases {
		if sc.Name == name {
			return int64(sc.Steps[i].CharacterID), sc.Steps[i].Progress
		}
	}
	t.Fatalf("no hay caso %s", name)
	return 0, nil
}

// edit decodifica un cuerpo, lo cambia y lo vuelve a codificar.
func edit(t testing.TB, body json.RawMessage, change func(m map[string]any)) json.RawMessage {
	t.Helper()
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&m); err != nil {
		t.Fatal(err)
	}
	change(m)
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// load lee el registro de la reclamación de un personaje.
func (w *world) load(id int64) map[string]any {
	w.t.Helper()
	raw, err := w.store.Load(context.Background(), w.pool, id)
	if err != nil {
		w.t.Fatal(err)
	}
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&m); err != nil {
		w.t.Fatal(err)
	}
	return m
}

func id(v int64) string { return strconv.FormatInt(v, 10) }

// purgeAccount purga los personajes de una cuenta como la purga de la cuenta (plataforma.md §11.2), con la
// purga de verdad de internal/characters sobre este almacén y la hora del reloj.
func (w *world) purgeAccount(accountID int64) {
	w.t.Helper()
	purger := characters.NewPurger(w.pool, w.store, nil, nil)
	w.tx(func(tx pgx.Tx) error {
		if _, err := tx.Exec(context.Background(), `select 1 from accounts where account_id = $1 for no key update`,
			accountID); err != nil {
			return err
		}
		return purger.PurgeAccountCharacters(context.Background(), tx, accountID, w.clock.now())
	})
}

// gmOp es una GM de la consola con un apunte de oro (delta y saldo tras él).
func gmOp(opID, at, delta, balanceAfter int64) map[string]any {
	reason := 7
	if delta < 0 {
		reason = 66
	}
	return map[string]any{"op_id": id(opID), "kind": 4, "actor_account_id": nil, "ref_op_id": nil,
		"note": "ajuste de prueba", "detail": map[string]any{"command": "currency_add",
			"args": []any{"42", "oro", id(delta)}, "at_unix": at, "source": "console"},
		"ledger": []any{map[string]any{"currency": 1, "delta": delta, "balance_after": balanceAfter, "reason": reason,
			"ref_kind": 0, "ref_id": "0"}}, "items": []any{}}
}

// withOps es body con estas operaciones y el oro de la foto en gold.
func withOps(t testing.TB, body json.RawMessage, gold int64, ops ...map[string]any) json.RawMessage {
	t.Helper()
	return edit(t, body, func(m map[string]any) {
		list := make([]any, 0, len(ops))
		for _, o := range ops {
			list = append(list, o)
		}
		m["ops"] = list
		for _, wl := range m["wallets"].([]any) {
			wallet := wl.(map[string]any)
			if wallet["currency"].(json.Number).String() == "1" {
				wallet["balance"] = gold
			}
		}
	})
}
