// Package app monta el proceso de serve (plataforma.md §2.5): las dos API HTTP (pública en
// ELDMARK_PUBLIC_ADDR e interna en ELDMARK_INTERNAL_ADDR), /health y /ready en las dos, y el
// arranque.
//
// serve no migra. Mientras falte por aplicar alguna migración del binario (o la base no responda),
// el proceso sigue vivo: /health da 200, /ready da 503 con el motivo y el arranque espera,
// mirando cada pocos segundos. Con el esquema al día hace la gracia de arranque (§2.5) y /ready
// pasa a 200. Las rutas de /v1 y de /internal/v1 las añaden los paquetes siguientes con
// [App.HandlePublic] y [App.HandleInternal].
package app

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
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

// HandlePublic añade una ruta a la API pública («POST /v1/sessions»).
func (a *App) HandlePublic(pattern string, h http.Handler) { a.public.Handle(pattern, h) }

// HandleInternal añade una ruta a la API interna («POST /internal/v1/claims»).
func (a *App) HandleInternal(pattern string, h http.Handler) { a.internal.Handle(pattern, h) }

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
		a.boot(bootCtx)
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

// boot espera a que el esquema esté al día y hace el arranque. Registra cada motivo nuevo por el
// que no puede arrancar, sin repetirlo en cada vuelta.
func (a *App) boot(ctx context.Context) {
	lastReason := ""
	for {
		err := a.tryBoot(ctx)
		if err == nil {
			a.started.Store(true)
			a.log.Info("plataforma lista")
			return
		}
		if ctx.Err() != nil {
			return
		}
		if reason := err.Error(); reason != lastReason {
			a.log.Error("la plataforma no puede arrancar todavía", "reason", reason)
			lastReason = reason
		}
		select {
		case <-ctx.Done():
			return
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
	return a.startupGrace(ctx)
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
