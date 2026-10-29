// Package db abre la base de la plataforma y clasifica sus errores con la regla de plataforma.md
// §7.3: un error de integridad (SQLSTATE de clase 23, o P0001 del disparador de solo añadir) es
// determinista y no se reintenta; 40001 y 40P01 se reintentan con la transacción entera; sin
// conexión o con el plazo vencido, la base no está disponible (503).
package db

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ApplicationName es el application_name de las conexiones de la plataforma (pg_stat_activity).
const ApplicationName = "eldmark-platform"

// Open prepara el pool de conexiones. No conecta todavía: la primera petición abre la primera
// conexión, así que una base caída al arrancar no impide levantar /health y /ready.
func Open(ctx context.Context, url string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		// El error de pgx no repite la contraseña, pero tampoco hace falta la cadena.
		return nil, errors.New("db: la cadena de conexión no se entiende")
	}
	if _, ok := cfg.ConnConfig.RuntimeParams["application_name"]; !ok {
		cfg.ConnConfig.RuntimeParams["application_name"] = ApplicationName
	}
	// Las fechas salen siempre en UTC, sea cual sea la zona del servidor.
	cfg.ConnConfig.RuntimeParams["timezone"] = "UTC"
	return pgxpool.NewWithConfig(ctx, cfg)
}

// Ping comprueba que la base responde a «select 1» antes del plazo (/ready usa 1 s).
func Ping(ctx context.Context, pool *pgxpool.Pool, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var one int
	return pool.QueryRow(ctx, "select 1").Scan(&one)
}

// Kind es la clase de un error de la base según plataforma.md §7.3.
type Kind int

// Clases de error.
const (
	KindOther       Kind = iota // cualquier otro: 500 internal
	KindIntegrity               // clase 23 o P0001: determinista, 400 invalid_save en el guardado
	KindRetryable               // 40001 o 40P01: se reintenta la transacción; agotados, 503
	KindUnavailable             // sin conexión, plazo vencido, servidor parándose: 503
)

func (k Kind) String() string {
	switch k {
	case KindIntegrity:
		return "integridad"
	case KindRetryable:
		return "conflicto"
	case KindUnavailable:
		return "no disponible"
	}
	return "otro"
}

// SQLState devuelve el SQLSTATE de un error de PostgreSQL, o "".
func SQLState(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return ""
}

// Constraint devuelve la restricción que saltó, o "".
func Constraint(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.ConstraintName
	}
	return ""
}

// Classify devuelve la clase del error.
func Classify(err error) Kind {
	if err == nil {
		return KindOther
	}
	if code := SQLState(err); code != "" {
		switch {
		case code[:2] == "23" || code == "P0001":
			return KindIntegrity
		case code == "40001" || code == "40P01":
			return KindRetryable
		case code[:2] == "08" || code == "57014" || code == "57P01" || code == "57P02" || code == "57P03" ||
			code == "53300":
			return KindUnavailable
		}
		return KindOther
	}
	var connectErr *pgconn.ConnectError
	var netErr net.Error
	switch {
	case errors.As(err, &connectErr), errors.As(err, &netErr), pgconn.Timeout(err),
		errors.Is(err, context.DeadlineExceeded), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, io.EOF):
		return KindUnavailable
	}
	return KindOther
}

// MaxAttempts es cuántas veces corre como mucho una transacción de [InTx]: la primera y tres
// reintentos ante 40001 o 40P01.
const MaxAttempts = 4

// ErrConflict envuelve el último error de una transacción que chocó con otras [MaxAttempts]
// veces. [Classify] sigue dando [KindRetryable]: la respuesta es 503 db_unavailable.
var ErrConflict = errors.New("db: la transacción chocó con otras demasiadas veces")

// Beginner es lo que abre transacciones: *pgxpool.Pool, *pgx.Conn.
type Beginner interface {
	BeginTx(ctx context.Context, opts pgx.TxOptions) (pgx.Tx, error)
}

// InTx ejecuta fn en una transacción y la confirma. Si fn o el COMMIT fallan con 40001 o 40P01,
// repite la transacción entera hasta [MaxAttempts] veces; cualquier otro error la deshace y se
// devuelve tal cual (un error del COMMIT, como el de una restricción diferida, también).
func InTx(ctx context.Context, db Beginner, opts pgx.TxOptions, fn func(pgx.Tx) error) error {
	var last error
	for attempt := 1; attempt <= MaxAttempts; attempt++ {
		last = once(ctx, db, opts, fn)
		if last == nil || Classify(last) != KindRetryable {
			return last
		}
		if ctx.Err() != nil {
			return last
		}
	}
	return fmt.Errorf("%w (%d intentos): %w", ErrConflict, MaxAttempts, last)
}

func once(ctx context.Context, db Beginner, opts pgx.TxOptions, fn func(pgx.Tx) error) (err error) {
	tx, err := db.BeginTx(ctx, opts)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback(context.WithoutCancel(ctx))
		}
	}()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
