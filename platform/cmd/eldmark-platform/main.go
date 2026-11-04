// The eldmark-platform command: the Eldmark platform service (docs/plataforma.md).
//
//	eldmark-platform serve                 starts the public and internal APIs (does not migrate)
//	eldmark-platform migrate up            applies the pending migrations
//	eldmark-platform migrate down N        reverts the N most recent applied ones (dev and test only)
//	eldmark-platform migrate status        status of each migration
//	eldmark-platform admin --actor <email> <command>
//	                                       moderation and accounts, with identity (plataforma.md §9.1)
//
// Configuration goes in environment variables (plataforma.md §2.3); admin uses the same as serve.
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"text/tabwriter"

	"eldmark/platform/internal/app"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/services"
)

// Exit codes.
const (
	exitOK    = 0
	exitError = 1
	exitUsage = 2
)

const usage = `Uso: eldmark-platform <orden>

Órdenes:
  serve              Arranca las API pública e interna. No migra: con migraciones
                     pendientes espera y /ready dice por qué.
  migrate up         Aplica las migraciones pendientes.
  migrate down N     Deshace las N migraciones mayores aplicadas (solo en dev y test).
  migrate status     Muestra el estado de cada migración.
  admin --actor <correo> <orden>
                     Moderación y cuentas: set-role, reports, audit, chat, sanction,
                     names, purge-now, create-account… («admin help» las lista).

La configuración va en variables de entorno ELDMARK_* (docs/plataforma.md §2.3).
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := run(ctx, os.Args[1:], os.LookupEnv, os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

func run(ctx context.Context, args []string, lookup config.Lookup, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	switch args[0] {
	case "serve":
		if len(args) != 1 {
			fmt.Fprint(stderr, usage)
			return exitUsage
		}
		return serve(ctx, lookup, stdout, stderr)
	case "migrate":
		return migrateCmd(ctx, args[1:], lookup, stdout, stderr)
	case "admin":
		return adminCmd(ctx, args[1:], lookup, stdout, stderr)
	case "help", "-h", "--help", "ayuda":
		fmt.Fprint(stdout, usage)
		return exitOK
	}
	fmt.Fprintf(stderr, "Orden desconocida: %q\n\n%s", args[0], usage)
	return exitUsage
}

func serve(ctx context.Context, lookup config.Lookup, stdout, stderr io.Writer) int {
	cfg, err := config.Load(lookup)
	if err != nil {
		fmt.Fprintf(stderr, "eldmark-platform no arranca: %v\n", err)
		return exitError
	}
	log := logx.New(stdout, slog.LevelInfo)
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("no arranca", "err", err)
		return exitError
	}
	defer pool.Close()
	a, err := app.New(cfg, pool, log, migrate.FS())
	if err != nil {
		log.Error("no arranca", "err", err)
		return exitError
	}
	closeServices, err := services.Mount(a, cfg, pool, log)
	if err != nil {
		log.Error("no arranca", "err", err)
		return exitError
	}
	defer closeServices()
	if err := a.Listen(); err != nil {
		log.Error("no arranca", "err", err)
		return exitError
	}
	if err := a.Serve(ctx); err != nil {
		log.Error("la plataforma se ha parado con un error", "err", err)
		return exitError
	}
	return exitOK
}

func migrateCmd(ctx context.Context, args []string, lookup config.Lookup, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	n := 0
	switch {
	case args[0] == "up" && len(args) == 1, args[0] == "status" && len(args) == 1:
	case args[0] == "down" && len(args) == 2:
		var err error
		n, err = strconv.Atoi(args[1])
		if err != nil || n < 1 {
			fmt.Fprintf(stderr, "migrate down necesita un número mayor que 0, no %q\n", args[1])
			return exitUsage
		}
	default:
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	cfg, err := config.LoadDatabase(lookup)
	if err != nil {
		fmt.Fprintf(stderr, "eldmark-platform migrate no arranca: %v\n", err)
		return exitError
	}
	if args[0] == "down" && cfg.Env.Deployed() {
		fmt.Fprintf(stderr, "migrate down solo se usa en desarrollo y CI. En %s se vuelve atrás restaurando la copia previa "+
			"o arreglando hacia delante (docs/plataforma.md §12).\n", cfg.Env)
		return exitError
	}
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		fmt.Fprintf(stderr, "Error: %v\n", err)
		return exitError
	}
	defer pool.Close()
	runner, err := migrate.New(pool, migrate.FS())
	if err != nil {
		fmt.Fprintf(stderr, "Error: %v\n", err)
		return exitError
	}
	switch args[0] {
	case "up":
		applied, err := runner.Up(ctx)
		for _, m := range applied {
			fmt.Fprintf(stdout, "Aplicada %s\n", m.ID())
		}
		if err != nil {
			fmt.Fprintf(stderr, "Error: %v\n", err)
			return exitError
		}
		if len(applied) == 0 {
			fmt.Fprintln(stdout, "No hay migraciones pendientes.")
		}
	case "down":
		undone, err := runner.Down(ctx, n)
		for _, m := range undone {
			fmt.Fprintf(stdout, "Deshecha %s\n", m.ID())
		}
		if err != nil {
			fmt.Fprintf(stderr, "Error: %v\n", err)
			return exitError
		}
	case "status":
		status, err := runner.Status(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "Error: %v\n", err)
			return exitError
		}
		w := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
		pending := 0
		for _, s := range status {
			when := ""
			if !s.AppliedAt.IsZero() {
				when = s.AppliedAt.UTC().Format("2006-01-02 15:04:05 UTC")
			}
			if s.State != migrate.StateApplied && s.State != migrate.StateUnknown {
				pending++
			}
			fmt.Fprintf(w, "%04d_%s\t%s\t%s\n", s.Version, s.Name, s.State, when)
		}
		_ = w.Flush()
		if pending > 0 {
			// Same as /ready: the schema is not up to date for this binary.
			return exitError
		}
	}
	return exitOK
}
