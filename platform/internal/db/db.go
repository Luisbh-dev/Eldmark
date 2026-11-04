// Package db opens the platform's database and classifies its errors with the rule of
// platform.md §7.3: an integrity error (class 23 SQLSTATE, or P0001 from the append-only
// trigger) or a data error (class 22: a NUL in jsonb, a date or a number out of range) is
// deterministic and is not retried; 40001 and 40P01 are retried with the whole transaction; with
// no connection or with the deadline expired, the database is unavailable (503).
package db

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ApplicationName is the application_name of the platform's connections (pg_stat_activity).
const ApplicationName = "eldmark-platform"

// MinPoolConns is the pool's minimum size if the string does not carry pool_max_conns. pgx's
// (max(4, cores)) is not enough: each periodic job in app holds one connection with its
// pg_try_advisory_lock and another for its work, and with four jobs and four connections they block
// each other (and the APIs) until the shortest one's deadline expires.
const MinPoolConns = 16

// Open prepares the connection pool. It does not connect yet: the first request opens the first
// connection, so a database that is down at startup does not prevent bringing up /health and
// /ready.
func Open(ctx context.Context, url string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		// pgx's error does not repeat the password, but the string is not needed either.
		return nil, errors.New("db: la cadena de conexión no se entiende")
	}
	if !strings.Contains(url, "pool_max_conns") && cfg.MaxConns < MinPoolConns {
		cfg.MaxConns = MinPoolConns
	}
	if _, ok := cfg.ConnConfig.RuntimeParams["application_name"]; !ok {
		cfg.ConnConfig.RuntimeParams["application_name"] = ApplicationName
	}
	// Dates always come out in UTC, whatever the server's time zone.
	cfg.ConnConfig.RuntimeParams["timezone"] = "UTC"
	return pgxpool.NewWithConfig(ctx, cfg)
}

// Ping checks that the database responds to "select 1" before the deadline (/ready uses 1 s).
func Ping(ctx context.Context, pool *pgxpool.Pool, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var one int
	return pool.QueryRow(ctx, "select 1").Scan(&one)
}

// Kind is the class of a database error according to platform.md §7.3.
type Kind int

// Error classes.
const (
	KindOther       Kind = iota // any other: 500 internal
	KindIntegrity               // class 23 or P0001: deterministic, 400 invalid_save in the save
	KindRetryable               // 40001 or 40P01: the transaction is retried; once exhausted, 503
	KindUnavailable             // no connection, deadline expired, server shutting down: 503
	KindData                    // class 22 (data exception): deterministic, like the integrity one
)

func (k Kind) String() string {
	switch k {
	case KindIntegrity:
		return "integridad"
	case KindRetryable:
		return "conflicto"
	case KindUnavailable:
		return "no disponible"
	case KindData:
		return "datos"
	}
	return "otro"
}

// SQLState returns the SQLSTATE of a PostgreSQL error, or "".
func SQLState(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return ""
}

// Constraint returns the constraint that fired, or "".
func Constraint(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.ConstraintName
	}
	return ""
}

// Deterministic says whether the error is one that retrying does not fix: integrity or data (§7.3).
func Deterministic(err error) bool {
	k := Classify(err)
	return k == KindIntegrity || k == KindData
}

// Classify returns the error's class.
func Classify(err error) Kind {
	if err == nil {
		return KindOther
	}
	if code := SQLState(err); code != "" {
		switch {
		case code[:2] == "23" || code == "P0001":
			return KindIntegrity
		case code[:2] == "22":
			return KindData
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

// MaxAttempts is how many times a [InTx] transaction runs at most: the first and three retries on
// 40001 or 40P01.
const MaxAttempts = 4

// ErrConflict wraps the last error of a transaction that clashed with others [MaxAttempts] times.
// [Classify] still gives [KindRetryable]: the response is 503 db_unavailable.
var ErrConflict = errors.New("db: la transacción chocó con otras demasiadas veces")

// Beginner is what opens transactions: *pgxpool.Pool, *pgx.Conn.
type Beginner interface {
	BeginTx(ctx context.Context, opts pgx.TxOptions) (pgx.Tx, error)
}

// InTx runs fn in a transaction and commits it. If fn or the COMMIT fail with 40001 or 40P01, it
// repeats the whole transaction up to [MaxAttempts] times; any other error rolls it back and is
// returned as is (an error from the COMMIT, like a deferred constraint's, too).
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
