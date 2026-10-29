// Package migrate aplica y deshace las migraciones del esquema (plataforma.md §2.4).
//
// Las migraciones son pares NNNN_nombre.up.sql y NNNN_nombre.down.sql embebidos en el binario
// ([FS]). El ejecutor toma pg_advisory_lock(4815162342), aplica las pendientes en orden de número,
// cada una en su transacción, y se niega a seguir si la suma SHA-256 de una aplicada ha cambiado o
// si hay una pendiente por debajo de la mayor aplicada. Una base con migraciones posteriores a las
// del binario vale (expandir y contraer): el binario N funciona con el esquema N + 1.
//
// Una migración sin inversa lleva «-- irreversible» en la primera línea de su .up.sql y su
// .down.sql hace «do $$ begin raise exception 'irreversible'; end $$;». Down no la deshace.
package migrate

import (
	"context"
	"crypto/sha256"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// LockKey es la clave del bloqueo consultivo que serializa a los ejecutores.
const LockKey int64 = 4815162342

// IrreversibleMarker es la primera línea de una migración sin inversa.
const IrreversibleMarker = "-- irreversible"

//go:embed migrations/*.sql
var embedded embed.FS

// FS devuelve las migraciones embebidas en el binario.
func FS() fs.FS {
	sub, err := fs.Sub(embedded, "migrations")
	if err != nil {
		panic(err)
	}
	return sub
}

// Migration es un par up/down.
type Migration struct {
	Version      int
	Name         string // sin número ni extensión: «accounts»
	Up           string
	Down         string
	Checksum     [sha256.Size]byte // del .up.sql
	Irreversible bool
}

// ID devuelve «0001_accounts».
func (m Migration) ID() string { return fmt.Sprintf("%04d_%s", m.Version, m.Name) }

var fileName = regexp.MustCompile(`^(\d{4})_([a-z0-9_]+)\.(up|down)\.sql$`)

// Load lee y comprueba las migraciones de fsys: nombres, pares completos, números sin repetir y la
// marca de las irreversibles.
func Load(fsys fs.FS) ([]Migration, error) {
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return nil, fmt.Errorf("migrate: no se pueden leer las migraciones: %w", err)
	}
	byVersion := map[int]*Migration{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		parts := fileName.FindStringSubmatch(e.Name())
		if parts == nil {
			return nil, fmt.Errorf("migrate: %q no se llama NNNN_nombre.up.sql ni NNNN_nombre.down.sql", e.Name())
		}
		version, _ := strconv.Atoi(parts[1])
		if version == 0 {
			return nil, fmt.Errorf("migrate: %q: los números empiezan en 0001", e.Name())
		}
		data, err := fs.ReadFile(fsys, e.Name())
		if err != nil {
			return nil, fmt.Errorf("migrate: %s: %w", e.Name(), err)
		}
		m := byVersion[version]
		if m == nil {
			m = &Migration{Version: version, Name: parts[2]}
			byVersion[version] = m
		} else if m.Name != parts[2] {
			return nil, fmt.Errorf("migrate: el número %04d está repetido (%s y %s)", version, m.Name, parts[2])
		}
		if parts[3] == "up" {
			m.Up = string(data)
			m.Checksum = sha256.Sum256(data)
		} else {
			m.Down = string(data)
		}
	}
	out := make([]Migration, 0, len(byVersion))
	for _, m := range byVersion {
		switch {
		case strings.TrimSpace(m.Up) == "":
			return nil, fmt.Errorf("migrate: a %s le falta el .up.sql o está vacío", m.ID())
		case strings.TrimSpace(m.Down) == "":
			return nil, fmt.Errorf("migrate: a %s le falta el .down.sql o está vacío", m.ID())
		}
		firstLine, _, _ := strings.Cut(m.Up, "\n")
		m.Irreversible = strings.TrimSpace(firstLine) == IrreversibleMarker
		if m.Irreversible && !strings.Contains(m.Down, "raise exception 'irreversible'") {
			return nil, fmt.Errorf("migrate: %s es irreversible y su .down.sql tiene que hacer raise exception 'irreversible'", m.ID())
		}
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	return out, nil
}

// Applied es una fila de schema_migrations.
type Applied struct {
	Version   int
	Name      string
	Checksum  []byte
	AppliedAt time.Time
}

// State es el estado de una migración frente a la base.
type State string

// Estados.
const (
	StateApplied  State = "aplicada"
	StatePending  State = "pendiente"
	StateChanged  State = "suma distinta"            // aplicada, pero el .up.sql ya no es el mismo
	StateUnknown  State = "posterior"                // aplicada en la base, no está en este binario
	StateOutOfSeq State = "pendiente fuera de orden" // pendiente por debajo de la mayor aplicada
)

// Status es una línea de [Runner.Status].
type Status struct {
	Version   int
	Name      string
	State     State
	AppliedAt time.Time // cero si no está aplicada
}

// Runner aplica las migraciones de un conjunto sobre una base.
type Runner struct {
	pool       *pgxpool.Pool
	migrations []Migration
}

// New prepara un ejecutor con las migraciones de fsys (normalmente [FS]).
func New(pool *pgxpool.Pool, fsys fs.FS) (*Runner, error) {
	migrations, err := Load(fsys)
	if err != nil {
		return nil, err
	}
	return &Runner{pool: pool, migrations: migrations}, nil
}

// Migrations devuelve las migraciones del ejecutor, en orden.
func (r *Runner) Migrations() []Migration { return r.migrations }

const createTable = `create table if not exists schema_migrations (
  version int primary key,
  name text not null,
  checksum bytea not null,
  applied_at timestamptz not null default now()
)`

// withLock ejecuta fn en una conexión con el bloqueo consultivo tomado y la tabla creada.
func (r *Runner) withLock(ctx context.Context, fn func(conn *pgx.Conn) error) error {
	c, err := r.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("migrate: sin conexión con la base: %w", err)
	}
	defer c.Release()
	conn := c.Conn()
	if _, err := conn.Exec(ctx, "select pg_advisory_lock($1)", LockKey); err != nil {
		return fmt.Errorf("migrate: no se pudo tomar el bloqueo: %w", err)
	}
	defer func() {
		// Con el contexto cancelado, el bloqueo se suelta al cerrar la conexión.
		if _, err := conn.Exec(context.WithoutCancel(ctx), "select pg_advisory_unlock($1)", LockKey); err != nil {
			_ = conn.Close(context.Background())
		}
	}()
	if _, err := conn.Exec(ctx, createTable); err != nil {
		return fmt.Errorf("migrate: no se pudo crear schema_migrations: %w", err)
	}
	return fn(conn)
}

func readApplied(ctx context.Context, q interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}) (map[int]Applied, error) {
	rows, err := q.Query(ctx, "select version, name, checksum, applied_at from schema_migrations order by version")
	if err != nil {
		return nil, err
	}
	applied, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Applied, error) {
		var a Applied
		err := row.Scan(&a.Version, &a.Name, &a.Checksum, &a.AppliedAt)
		return a, err
	})
	if err != nil {
		return nil, err
	}
	out := make(map[int]Applied, len(applied))
	for _, a := range applied {
		out[a.Version] = a
	}
	return out, nil
}

// plan compara las migraciones con lo aplicado: devuelve las pendientes o el error que impide
// seguir (suma cambiada o pendiente por debajo de la mayor aplicada).
func (r *Runner) plan(applied map[int]Applied) ([]Migration, error) {
	maxApplied := 0
	for v := range applied {
		maxApplied = max(maxApplied, v)
	}
	var pending []Migration
	for _, m := range r.migrations {
		a, ok := applied[m.Version]
		if !ok {
			pending = append(pending, m)
			continue
		}
		if string(a.Checksum) != string(m.Checksum[:]) {
			return nil, fmt.Errorf("La suma SHA-256 de la migración %s ha cambiado desde que se aplicó: "+
				"una migración aplicada no se edita, se escribe otra", m.ID())
		}
	}
	for _, m := range pending {
		if m.Version < maxApplied {
			return nil, fmt.Errorf("La migración %04d está pendiente por debajo de la %04d ya aplicada: renumérala",
				m.Version, maxApplied)
		}
	}
	return pending, nil
}

// Up aplica las pendientes, cada una en su transacción, y devuelve las aplicadas.
func (r *Runner) Up(ctx context.Context) ([]Migration, error) {
	var done []Migration
	err := r.withLock(ctx, func(conn *pgx.Conn) error {
		applied, err := readApplied(ctx, conn)
		if err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
		pending, err := r.plan(applied)
		if err != nil {
			return err
		}
		for _, m := range pending {
			err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, m.Up); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, "insert into schema_migrations (version, name, checksum) values ($1, $2, $3)",
					m.Version, m.Name, m.Checksum[:])
				return err
			})
			if err != nil {
				return fmt.Errorf("migrate: la migración %s falló y no se aplicó: %w", m.ID(), err)
			}
			done = append(done, m)
		}
		return nil
	})
	return done, err
}

// Down deshace las n mayores aplicadas, en orden inverso, y devuelve las deshechas. Se para sin
// tocar nada ante una irreversible o una aplicada que no está en este binario.
func (r *Runner) Down(ctx context.Context, n int) ([]Migration, error) {
	if n < 1 {
		return nil, errors.New("migrate: down necesita un número de migraciones mayor que 0")
	}
	byVersion := make(map[int]Migration, len(r.migrations))
	for _, m := range r.migrations {
		byVersion[m.Version] = m
	}
	var done []Migration
	err := r.withLock(ctx, func(conn *pgx.Conn) error {
		applied, err := readApplied(ctx, conn)
		if err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
		versions := make([]int, 0, len(applied))
		for v := range applied {
			versions = append(versions, v)
		}
		sort.Sort(sort.Reverse(sort.IntSlice(versions)))
		if n > len(versions) {
			return fmt.Errorf("migrate: solo hay %d migraciones aplicadas; no se pueden deshacer %d", len(versions), n)
		}
		targets := make([]Migration, 0, n)
		for _, v := range versions[:n] {
			m, ok := byVersion[v]
			switch {
			case !ok:
				return fmt.Errorf("La migración %04d_%s está aplicada pero no está en este binario: no se puede deshacer", v, applied[v].Name)
			case string(applied[v].Checksum) != string(m.Checksum[:]):
				return fmt.Errorf("La suma SHA-256 de la migración %s ha cambiado desde que se aplicó: no se deshace", m.ID())
			case m.Irreversible:
				return fmt.Errorf("La migración %s es irreversible: no se deshace (en staging y producción se restaura la copia previa)", m.ID())
			}
			targets = append(targets, m)
		}
		for _, m := range targets {
			err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, m.Down); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, "delete from schema_migrations where version = $1", m.Version)
				return err
			})
			if err != nil {
				return fmt.Errorf("migrate: no se pudo deshacer %s: %w", m.ID(), err)
			}
			done = append(done, m)
		}
		return nil
	})
	return done, err
}

// Status devuelve el estado de cada migración del binario y de las aplicadas que no conoce.
func (r *Runner) Status(ctx context.Context) ([]Status, error) {
	var out []Status
	err := r.withLock(ctx, func(conn *pgx.Conn) error {
		applied, err := readApplied(ctx, conn)
		if err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
		out = r.status(applied)
		return nil
	})
	return out, err
}

func (r *Runner) status(applied map[int]Applied) []Status {
	maxApplied := 0
	for v := range applied {
		maxApplied = max(maxApplied, v)
	}
	known := map[int]bool{}
	var out []Status
	for _, m := range r.migrations {
		known[m.Version] = true
		s := Status{Version: m.Version, Name: m.Name, State: StatePending}
		if a, ok := applied[m.Version]; ok {
			s.AppliedAt = a.AppliedAt
			s.State = StateApplied
			if string(a.Checksum) != string(m.Checksum[:]) {
				s.State = StateChanged
			}
		} else if m.Version < maxApplied {
			s.State = StateOutOfSeq
		}
		out = append(out, s)
	}
	for v, a := range applied {
		if !known[v] {
			out = append(out, Status{Version: v, Name: a.Name, State: StateUnknown, AppliedAt: a.AppliedAt})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	return out
}

// ErrNotMigrated es la causa de [Runner.Check] cuando falta alguna migración del binario.
var ErrNotMigrated = errors.New("el esquema no está al día")

// Check dice si todas las migraciones del binario están aplicadas con su misma suma (lo que exige
// serve y lo que mira /ready). Las posteriores no molestan. No toma el bloqueo ni crea nada.
func (r *Runner) Check(ctx context.Context) error {
	var exists bool
	if err := r.pool.QueryRow(ctx, "select to_regclass('schema_migrations') is not null").Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return fmt.Errorf("%w: la base no tiene migraciones; ejecuta «eldmark-platform migrate up»", ErrNotMigrated)
	}
	applied, err := readApplied(ctx, r.pool)
	if err != nil {
		return err
	}
	var pending, changed []string
	for _, m := range r.migrations {
		a, ok := applied[m.Version]
		switch {
		case !ok:
			pending = append(pending, m.ID())
		case string(a.Checksum) != string(m.Checksum[:]):
			changed = append(changed, m.ID())
		}
	}
	switch {
	case len(changed) > 0:
		return fmt.Errorf("%w: la suma de %s no es la de este binario", ErrNotMigrated, strings.Join(changed, ", "))
	case len(pending) > 0:
		return fmt.Errorf("%w: faltan por aplicar %s; ejecuta «eldmark-platform migrate up»", ErrNotMigrated, strings.Join(pending, ", "))
	}
	return nil
}
