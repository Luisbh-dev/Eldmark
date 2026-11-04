// Package app mounts the serve process (plataforma.md §2.5): the two HTTP APIs (public on
// ELDMARK_PUBLIC_ADDR and internal on ELDMARK_INTERNAL_ADDR), /health and /ready on both, and the
// startup.
//
// serve does not migrate. While any of the binary's migrations remains to be applied (or the
// database does not respond), the process stays alive: /health gives 200, /ready gives 503 with the
// reason and startup waits, checking every few seconds. With the schema up to date it does the
// startup grace period (§2.5) and /ready turns 200. The /v1 and /internal/v1 routes are added by
// the following packages with [App.HandlePublic] and [App.HandleInternal]; until startup finishes
// they answer 503. What has to be done at startup (the legal texts in legal_documents) goes in
// [App.OnBoot], and the periodic jobs (purges, retentions, lost zones) in [App.AddJob].
package app

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"hash/fnv"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/migrate"
)

// Startup and shutdown timeouts.
const (
	readyTimeout    = time.Second // /ready's select 1 (§2.5)
	schemaPoll      = 2 * time.Second
	shutdownTimeout = 10 * time.Second
)

// App is the serve process.
type App struct {
	cfg    *config.Config
	pool   *pgxpool.Pool
	log    *slog.Logger
	runner *migrate.Runner

	public   *http.ServeMux
	internal *http.ServeMux

	started  atomic.Bool
	listenMu sync.Mutex
	publicLn net.Listener
	intLn    net.Listener

	hooks []func(ctx context.Context) error
	jobs  []job

	// SchemaPoll is how often the schema is checked again while it is not up to date.
	SchemaPoll time.Duration
}

// New prepares the process with the migrations from migrations (normally migrate.FS()).
func New(cfg *config.Config, pool *pgxpool.Pool, log *slog.Logger, migrations fs.FS) (*App, error) {
	runner, err := migrate.New(pool, migrations)
	if err != nil {
		return nil, err
	}
	a := &App{cfg: cfg, pool: pool, log: log, runner: runner, SchemaPoll: schemaPoll,
		public: http.NewServeMux(), internal: http.NewServeMux()}
	for _, mux := range []*http.ServeMux{a.public, a.internal} {
		mux.Handle("GET /health", httpx.Health())
		mux.Handle("GET /ready", httpx.Ready(readyTimeout, a.Ready))
		mux.Handle("/", httpx.NotFound())
	}
	return a, nil
}

// HandlePublic adds a route to the public API ("POST /v1/sessions"). Until startup finishes, it
// answers 503.
func (a *App) HandlePublic(pattern string, h http.Handler) { a.public.Handle(pattern, a.gate(h)) }

// HandleInternal adds a route to the internal API ("POST /internal/v1/claims"). Until startup
// finishes, it answers 503.
func (a *App) HandleInternal(pattern string, h http.Handler) { a.internal.Handle(pattern, a.gate(h)) }

// gate answers 503 while startup has not finished: the schema may not be up to date and the legal
// texts unpublished.
func (a *App) gate(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.started.Load() {
			httpx.WriteError(w, &httpx.Error{Status: http.StatusServiceUnavailable, Code: "unavailable",
				Message: "La plataforma está arrancando; inténtalo en unos segundos", RetryAfter: 5})
			return
		}
		h.ServeHTTP(w, r)
	})
}

// OnBoot adds something to do at startup, with the schema up to date and after the §2.5 grace
// period (and before /ready gives 200 and the routes respond). If it fails, startup is retried in
// full, so it has to be repeatable.
func (a *App) OnBoot(fn func(ctx context.Context) error) { a.hooks = append(a.hooks, fn) }

// job is a periodic job.
type job struct {
	name  string
	every time.Duration
	fn    func(ctx context.Context) error
}

// AddJob adds a periodic job (§2.5): it runs when startup finishes and then every every, with
// pg_try_advisory_lock so that it never runs in two processes at once (if another holds it, that
// round is skipped). An error is logged and the job continues in the next round.
func (a *App) AddJob(name string, every time.Duration, fn func(ctx context.Context) error) {
	a.jobs = append(a.jobs, job{name: name, every: every, fn: fn})
}

// PublicHandler is the public API with request logging.
func (a *App) PublicHandler() http.Handler { return httpx.Middleware(a.log, a.public) }

// InternalHandler is the internal API with request logging.
func (a *App) InternalHandler() http.Handler {
	return httpx.Middleware(a.log.With("api", "internal"), a.internal)
}

// Started says whether startup finished (schema up to date and grace period done).
func (a *App) Started() bool { return a.started.Load() }

// Reasons for /ready, which is public: no database details.
var (
	errDBDown   = errors.New("La base de datos no responde")
	errStarting = errors.New("La plataforma está arrancando")
)

// Ready is the /ready check: select 1 in under 1 s, the binary's migrations up to date and startup
// done.
func (a *App) Ready(ctx context.Context) error {
	if err := db.Ping(ctx, a.pool, readyTimeout); err != nil {
		return errDBDown
	}
	if err := a.runner.Check(ctx); err != nil {
		if errors.Is(err, migrate.ErrNotMigrated) {
			return err
		}
		return errDBDown
	}
	if !a.started.Load() {
		return errStarting
	}
	return nil
}

// Listen opens the two ports. It is separate from Serve so that a busy port fails right away and so
// that the tests know the addresses (with ":0").
func (a *App) Listen() error {
	a.listenMu.Lock()
	defer a.listenMu.Unlock()
	pub, err := net.Listen("tcp", a.cfg.PublicAddr)
	if err != nil {
		return fmt.Errorf("no se puede escuchar en ELDMARK_PUBLIC_ADDR %s: %w", a.cfg.PublicAddr, err)
	}
	internal, err := net.Listen("tcp", a.cfg.InternalAddr)
	if err != nil {
		pub.Close()
		return fmt.Errorf("no se puede escuchar en ELDMARK_INTERNAL_ADDR %s: %w", a.cfg.InternalAddr, err)
	}
	a.publicLn, a.intLn = pub, internal
	return nil
}

// PublicAddr and InternalAddr return the addresses opened by Listen.
func (a *App) PublicAddr() string   { return a.publicLn.Addr().String() }
func (a *App) InternalAddr() string { return a.intLn.Addr().String() }

func newServer(h http.Handler) *http.Server {
	return &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
}

// Serve serves the two APIs until ctx is cancelled; then it shuts down in an orderly way. It calls
// Listen if it has not been called.
func (a *App) Serve(ctx context.Context) error {
	if a.publicLn == nil {
		if err := a.Listen(); err != nil {
			return err
		}
	}
	publicSrv := newServer(a.PublicHandler())
	internalSrv := newServer(a.InternalHandler())
	errs := make(chan error, 2)
	go func() {
		var err error
		if a.cfg.TLSCertFile != "" {
			publicSrv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
			err = publicSrv.ServeTLS(a.publicLn, a.cfg.TLSCertFile, a.cfg.TLSKeyFile)
		} else {
			err = publicSrv.Serve(a.publicLn)
		}
		errs <- fmt.Errorf("API pública: %w", err)
	}()
	go func() { errs <- fmt.Errorf("API interna: %w", internalSrv.Serve(a.intLn)) }()
	a.log.Info("plataforma escuchando", "public", a.PublicAddr(), "internal", a.InternalAddr(), "config", a.cfg)

	bootCtx, stopBoot := context.WithCancel(ctx)
	bootDone := make(chan struct{})
	go func() {
		defer close(bootDone)
		if !a.boot(bootCtx) {
			return
		}
		var wg sync.WaitGroup
		for _, j := range a.jobs {
			wg.Add(1)
			go func() {
				defer wg.Done()
				a.runJob(bootCtx, j)
			}()
		}
		wg.Wait()
	}()

	var serveErr error
	select {
	case <-ctx.Done():
	case serveErr = <-errs:
	}
	stopBoot()
	<-bootDone
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
	defer cancel()
	shutdownErr := errors.Join(publicSrv.Shutdown(shutdownCtx), internalSrv.Shutdown(shutdownCtx))
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return serveErr
	}
	if shutdownErr != nil {
		return fmt.Errorf("cierre: %w", shutdownErr)
	}
	a.log.Info("plataforma parada")
	return nil
}

// boot waits for the schema to be up to date and does the startup; it returns false if ctx is
// cancelled first. It logs each new reason why it cannot start, without repeating it on every round.
func (a *App) boot(ctx context.Context) bool {
	lastReason := ""
	for {
		err := a.tryBoot(ctx)
		if err == nil {
			a.started.Store(true)
			a.log.Info("plataforma lista")
			return true
		}
		if ctx.Err() != nil {
			return false
		}
		if reason := err.Error(); reason != lastReason {
			a.log.Error("la plataforma no puede arrancar todavía", "reason", reason)
			lastReason = reason
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(a.SchemaPoll):
		}
	}
}

func (a *App) tryBoot(ctx context.Context) error {
	checkCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := a.runner.Check(checkCtx); err != nil {
		return err
	}
	if err := a.startupGrace(ctx); err != nil {
		return err
	}
	for _, hook := range a.hooks {
		if err := hook(ctx); err != nil {
			return err
		}
	}
	return nil
}

// JobLockKey is a job's pg_try_advisory_lock key (different from migrate's).
func JobLockKey(name string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte("eldmark-job:" + name))
	return int64(h.Sum64())
}

func (a *App) runJob(ctx context.Context, j job) {
	ticker := time.NewTicker(j.every)
	defer ticker.Stop()
	for {
		a.runJobOnce(ctx, j)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (a *App) runJobOnce(ctx context.Context, j job) {
	ctx, cancel := context.WithTimeout(ctx, j.every)
	defer cancel()
	start := time.Now()
	conn, err := a.pool.Acquire(ctx)
	if err != nil {
		if ctx.Err() == nil {
			a.log.Error("trabajo periódico sin conexión", "job", j.name, "err", err.Error())
		}
		return
	}
	defer conn.Release()
	key := JobLockKey(j.name)
	var got bool
	if err := conn.QueryRow(ctx, `select pg_try_advisory_lock($1)`, key).Scan(&got); err != nil || !got {
		if err != nil && ctx.Err() == nil {
			a.log.Error("trabajo periódico sin bloqueo", "job", j.name, "err", err.Error())
		}
		return
	}
	defer func() {
		_, _ = conn.Exec(context.WithoutCancel(ctx), `select pg_advisory_unlock($1)`, key)
	}()
	if err := j.fn(ctx); err != nil && ctx.Err() == nil {
		a.log.Error("trabajo periódico con error", "job", j.name, "err", err.Error())
		return
	}
	a.log.Debug("trabajo periódico", "job", j.name, "ms", float64(time.Since(start).Microseconds())/1000)
}

// startupGrace gives the zones the §2.5 margin: a platform that comes back after going down does not
// consider the instances that could not heartbeat as lost nor their leases as free. It extends only
// the leases that were still alive at the last heartbeat of their instance (starting or live): one
// that had already expired before (the zone stopped renewing it because the character left) does not
// come back to life. That is why the leases go before the instances' heartbeat.
func (a *App) startupGrace(ctx context.Context) error {
	return db.InTx(ctx, a.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		res, err := tx.Exec(ctx, `update character_leases l
			set expires_at = greatest(l.expires_at, now() + make_interval(secs => $1))
			from zone_instances zi
			where zi.zone_instance_id = l.zone_instance_id and zi.status in ('starting', 'live')
			  and l.expires_at >= zi.last_heartbeat_at`, a.cfg.LeaseTTL.Seconds())
		if err != nil {
			return err
		}
		leases := res.RowsAffected()
		res, err = tx.Exec(ctx, `update zone_instances set last_heartbeat_at = greatest(last_heartbeat_at, now())
			where status in ('starting', 'live')`)
		if err != nil {
			return err
		}
		if instances := res.RowsAffected(); instances > 0 || leases > 0 {
			a.log.Info("gracia de arranque", "instances", instances, "leases", leases)
		}
		return nil
	})
}
