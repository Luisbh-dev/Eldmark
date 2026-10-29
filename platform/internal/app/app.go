// Package app monta el proceso de serve (plataforma.md §2.5): las dos API HTTP (pública en
// ELDMARK_PUBLIC_ADDR e interna en ELDMARK_INTERNAL_ADDR), /health y /ready en las dos, y el
// arranque.
//
// serve no migra. Mientras falte por aplicar alguna migración del binario (o la base no responda),
// el proceso sigue vivo: /health da 200, /ready da 503 con el motivo y el arranque espera,
// mirando cada pocos segundos. Con el esquema al día hace la gracia de arranque (§2.5) y /ready
// pasa a 200. Las rutas de /v1 y de /internal/v1 las añaden los paquetes siguientes con
// [App.HandlePublic] y [App.HandleInternal]; hasta que el arranque termina responden 503. Lo que
// hay que hacer al arrancar (los textos legales en legal_documents) va en [App.OnBoot], y los
// trabajos periódicos (purgas, retenciones, zonas perdidas) en [App.AddJob].
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

// Plazos del arranque y del cierre.
const (
	readyTimeout    = time.Second // select 1 de /ready (§2.5)
	schemaPoll      = 2 * time.Second
	shutdownTimeout = 10 * time.Second
)

// App es el proceso de serve.
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

	// SchemaPoll es cada cuánto se vuelve a mirar el esquema mientras no está al día.
	SchemaPoll time.Duration
}

// New prepara el proceso con las migraciones de migrations (normalmente migrate.FS()).
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

// HandlePublic añade una ruta a la API pública («POST /v1/sessions»). Hasta que el arranque
// termina, responde 503.
func (a *App) HandlePublic(pattern string, h http.Handler) { a.public.Handle(pattern, a.gate(h)) }

// HandleInternal añade una ruta a la API interna («POST /internal/v1/claims»). Hasta que el
// arranque termina, responde 503.
func (a *App) HandleInternal(pattern string, h http.Handler) { a.internal.Handle(pattern, a.gate(h)) }

// gate responde 503 mientras el arranque no ha terminado: el esquema puede no estar al día y los
// textos legales, sin publicar.
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

// OnBoot añade algo que hacer al arrancar, con el esquema al día y tras la gracia de §2.5 (y antes
// de que /ready dé 200 y las rutas respondan). Si falla, el arranque se reintenta entero, así que
// tiene que poder repetirse.
func (a *App) OnBoot(fn func(ctx context.Context) error) { a.hooks = append(a.hooks, fn) }

// job es un trabajo periódico.
type job struct {
	name  string
	every time.Duration
	fn    func(ctx context.Context) error
}

// AddJob añade un trabajo periódico (§2.5): corre al terminar el arranque y después cada every,
// con pg_try_advisory_lock para que nunca corra en dos procesos a la vez (si otro lo tiene, esa
// vuelta se salta). Un error se registra y el trabajo sigue en la vuelta siguiente.
func (a *App) AddJob(name string, every time.Duration, fn func(ctx context.Context) error) {
	a.jobs = append(a.jobs, job{name: name, every: every, fn: fn})
}

// PublicHandler es la API pública con el registro de peticiones.
func (a *App) PublicHandler() http.Handler { return httpx.Middleware(a.log, a.public) }

// InternalHandler es la API interna con el registro de peticiones.
func (a *App) InternalHandler() http.Handler {
	return httpx.Middleware(a.log.With("api", "internal"), a.internal)
}

// Started dice si el arranque terminó (esquema al día y gracia hecha).
func (a *App) Started() bool { return a.started.Load() }

// Motivos de /ready, que es público: sin detalles de la base.
var (
	errDBDown   = errors.New("La base de datos no responde")
	errStarting = errors.New("La plataforma está arrancando")
)

// Ready es la comprobación de /ready: select 1 en menos de 1 s, las migraciones del binario al
// día y el arranque hecho.
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

// Listen abre los dos puertos. Va aparte de Serve para que un puerto ocupado falle enseguida y
// para que las pruebas sepan las direcciones (con «:0»).
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

// PublicAddr y InternalAddr devuelven las direcciones abiertas por Listen.
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

// Serve atiende las dos API hasta que ctx se cancela; entonces cierra ordenadamente. Llama a
// Listen si no se ha llamado.
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

// boot espera a que el esquema esté al día y hace el arranque; devuelve false si ctx se cancela
// antes. Registra cada motivo nuevo por el que no puede arrancar, sin repetirlo en cada vuelta.
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

// JobLockKey es la clave de pg_try_advisory_lock de un trabajo (distinta de la de migrate).
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

// startupGrace da a las zonas el margen de §2.5: una plataforma que vuelve tras caerse no da por
// perdidas a las instancias que no pudieron latir ni por libres a sus arrendamientos.
func (a *App) startupGrace(ctx context.Context) error {
	return db.InTx(ctx, a.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		res, err := tx.Exec(ctx, `update zone_instances set last_heartbeat_at = greatest(last_heartbeat_at, now())
			where status in ('starting', 'live')`)
		if err != nil {
			return err
		}
		instances := res.RowsAffected()
		res, err = tx.Exec(ctx, `update character_leases
			set expires_at = greatest(expires_at, now() + make_interval(secs => $1))
			where zone_instance_id is not null`, a.cfg.LeaseTTL.Seconds())
		if err != nil {
			return err
		}
		if instances > 0 || res.RowsAffected() > 0 {
			a.log.Info("gracia de arranque", "instances", instances, "leases", res.RowsAffected())
		}
		return nil
	})
}
