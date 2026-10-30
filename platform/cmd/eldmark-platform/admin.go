package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/admin"
	"eldmark/platform/internal/characters"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/migrate"
	"eldmark/platform/internal/names"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/legal"
)

const adminUsage = `Uso: eldmark-platform admin --actor <correo> <orden> [argumentos]

Toda orden lleva --actor con el correo de una cuenta admin (moderator basta para las de
lectura, marcadas con «L») y deja su fila en la auditoría (audit_log, source cli).

Cuentas y roles:
  set-role <correo> <rol>                  Cambia el rol (player, moderator, gm o admin) y
                                           revoca las sesiones de la cuenta.
  create-account <correo> --password-file <ruta> [--role player]
                                           Cuenta de prueba o del equipo, ya verificada.
  purge-now <correo> [--wait 30s]          Purga la cuenta ya (RGPD); revoca sus sesiones y
                                           espera a que sus personajes salgan del mundo.
  bootstrap <correo> --password-file <ruta>
                                           Crea la primera cuenta admin (sin --actor; solo si
                                           no hay ninguna).
  reapply-purges <purges.txt>              Tras restaurar una copia, con las zonas paradas y
                                           antes de arrancar serve: borra los arrendamientos y
                                           billetes de la copia y vuelve a purgar lo de
                                           purges.txt (el más reciente) con su fecha original.
Moderación:
  reports list [--status open|in_review|actioned|dismissed|all] [--limit N]      (L)
  reports show <id>                                                              (L)
  reports close <id> actioned|dismissed [--resolution <texto>]
  audit --since <fecha> [--until <fecha>] [--actor-name <nombre>]
        [--target <nombre>] [--command <orden>] [--world 1] [--limit N]          (L)
  chat --character <nombre> --from <fecha> --to <fecha> [--world 1] [--limit N]  (L)
  sanction add <nombre> warning|mute|suspension|ban|rename [--duration 1h|7d]
        --reason <texto> [--report <id>]... [--world 1]
  sanction revoke <id>
  sanction list <nombre> [--world 1]                                             (L)
  names block <nombre> [--reason <texto>]
  names unblock <nombre>

Un personaje se nombra por su nombre en el mundo (--world, 1 por defecto) o por «#<id>».
Las fechas, en UTC: 2026-11-01, 2026-11-01T18:00 o RFC 3339. Las duraciones: 30m, 24h, 7d.
La configuración es la de serve (variables ELDMARK_*, docs/plataforma.md §2.3).
`

// errAdminUsage es un error de uso de la orden admin (código 2).
type errAdminUsage struct{ msg string }

func (e *errAdminUsage) Error() string { return e.msg }

func usageErr(format string, args ...any) error {
	return &errAdminUsage{msg: fmt.Sprintf(format, args...)}
}

// adminEnv es lo que necesita una orden admin al correr.
type adminEnv struct {
	svc   *admin.Service
	actor *admin.Actor
	out   io.Writer
}

// adminOrder es una orden admin ya leída: el rol que pide y lo que hace.
type adminOrder struct {
	name string
	need string // sanctions.RoleModerator (lectura) o RoleAdmin; "" en bootstrap (sin --actor)
	run  func(ctx context.Context, e *adminEnv) error
}

func adminCmd(ctx context.Context, args []string, lookup config.Lookup, stdout, stderr io.Writer) int {
	global := flag.NewFlagSet("admin", flag.ContinueOnError)
	global.SetOutput(io.Discard)
	actorEmail := global.String("actor", "", "")
	if err := global.Parse(args); err != nil || global.NArg() == 0 {
		fmt.Fprint(stderr, adminUsage)
		return exitUsage
	}
	if global.Arg(0) == "help" || global.Arg(0) == "ayuda" {
		fmt.Fprint(stdout, adminUsage)
		return exitOK
	}
	order, err := parseAdmin(global.Args())
	if err != nil {
		fmt.Fprintf(stderr, "%v\n\n%s", err, adminUsage)
		return exitUsage
	}
	if order.need == "" && *actorEmail != "" {
		fmt.Fprintln(stderr, "bootstrap no lleva --actor: crea la primera cuenta admin")
		return exitUsage
	}
	if order.need != "" && strings.TrimSpace(*actorEmail) == "" {
		fmt.Fprintf(stderr, "No se ejecuta: «%s» necesita --actor <correo> de una cuenta %s (docs/plataforma.md §9.1)\n",
			order.name, order.need)
		return exitUsage
	}
	cfg, err := config.Load(lookup)
	if err != nil {
		fmt.Fprintf(stderr, "eldmark-platform admin no arranca: %v\n", err)
		return exitError
	}
	log := logx.New(stderr, slog.LevelWarn)
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		fmt.Fprintf(stderr, "Error: %v\n", err)
		return exitError
	}
	defer pool.Close()
	env, err := adminServices(ctx, cfg, pool, log, lookup)
	if err != nil {
		fmt.Fprintf(stderr, "Error: %v\n", err)
		return exitError
	}
	env.out = stdout
	if order.need != "" {
		env.actor, err = env.svc.Authorize(ctx, *actorEmail, order.need)
		if err != nil {
			return adminFail(stderr, order.name, err)
		}
	}
	if err := order.run(ctx, env); err != nil {
		return adminFail(stderr, order.name, err)
	}
	return exitOK
}

// adminFail escribe el error de una orden y devuelve su código: 2 si el --actor no vale, 1 si no.
func adminFail(stderr io.Writer, name string, err error) int {
	var actorErr *admin.ActorError
	if errors.As(err, &actorErr) {
		fmt.Fprintf(stderr, "No se ejecuta «%s»: %v\n", name, err)
		return exitUsage
	}
	fmt.Fprintf(stderr, "Error en «%s»: %v\n", name, err)
	return exitError
}

// adminServices monta lo que usan las órdenes admin con la configuración de serve: cuentas (con la
// purga de personajes sobre el almacén del progreso de progresion.md P7) y el servicio admin.
func adminServices(ctx context.Context, cfg *config.Config, pool *pgxpool.Pool, log *slog.Logger,
	lookup config.Lookup) (*adminEnv, error) {
	runner, err := migrate.New(pool, migrate.FS())
	if err != nil {
		return nil, err
	}
	if err := runner.Check(ctx); err != nil {
		return nil, err
	}
	rules, err := gamedata.Load()
	if err != nil {
		return nil, err
	}
	nameRules, err := names.New(rules.Names)
	if err != nil {
		return nil, err
	}
	var texts fs.FS = legal.Embedded()
	if cfg.LegalDir != "" {
		texts = os.DirFS(cfg.LegalDir)
	}
	documents, err := legal.Load(texts)
	if err != nil {
		return nil, err
	}
	env := &adminEnv{}
	progressRepo, _, err := progressStore()
	if err != nil {
		return nil, err
	}
	purger := characters.NewPurger(pool, progressRepo, clock.System{}, log)
	acc, err := accounts.New(accounts.Options{Config: cfg, Pool: pool, Log: log, Mail: &mail.LogSender{DB: pool, Log: log},
		Legal: documents, Characters: purger, MinProtocol: cfg.ResolveMinProtocol(rules.ProtocolVersion)})
	if err != nil {
		return nil, err
	}
	osUser, ok := lookup("SUDO_USER")
	if !ok || osUser == "" {
		osUser, _ = lookup("USER")
	}
	env.svc, err = admin.New(admin.Options{Pool: pool, Accounts: acc, Characters: purger, Legal: documents,
		StrictLegal: cfg.Env.Deployed(), Names: nameRules, Log: log, OSUser: osUser})
	return env, err
}

// parseAdmin lee la orden y sus argumentos (sin tocar la base: un error de uso sale con 2 antes de
// conectar).
func parseAdmin(args []string) (*adminOrder, error) {
	name, rest := args[0], args[1:]
	switch name {
	case "set-role":
		pos, err := parseFlags("set-role", rest, nil)
		if err != nil || len(pos) != 2 {
			return nil, usageErr("set-role necesita <correo> <rol>")
		}
		return &adminOrder{name: name, need: sanctions.RoleAdmin, run: func(ctx context.Context, e *adminEnv) error {
			res, err := e.svc.SetRole(ctx, e.actor, pos[0], pos[1])
			if err != nil {
				return err
			}
			if !res.Changed {
				fmt.Fprintf(e.out, "La cuenta %d ya tenía el rol %s: no se ha cambiado nada.\n", res.AccountID, res.To)
				return nil
			}
			fmt.Fprintf(e.out, "Rol de la cuenta %d: %s → %s. Sesiones revocadas (role_changed): %d; si estaba en el "+
				"mundo, sale con el próximo latido y vuelve a entrar con el rol nuevo.\n", res.AccountID, res.From, res.To, res.Revoked)
			return nil
		}}, nil
	case "create-account", "bootstrap":
		var passwordFile, role *string
		pos, err := parseFlags(name, rest, func(fs *flag.FlagSet) {
			passwordFile = fs.String("password-file", "", "")
			if name == "create-account" {
				role = fs.String("role", sanctions.RolePlayer, "")
			}
		})
		if err != nil || len(pos) != 1 || *passwordFile == "" {
			return nil, usageErr("%s necesita <correo> y --password-file <ruta> (la contraseña nunca va en la línea de órdenes)", name)
		}
		order := &adminOrder{name: name, need: sanctions.RoleAdmin}
		if name == "bootstrap" {
			order.need = ""
		}
		order.run = func(ctx context.Context, e *adminEnv) error {
			password, err := readPassword(*passwordFile)
			if err != nil {
				return err
			}
			var id int64
			r := sanctions.RoleAdmin
			if name == "bootstrap" {
				id, err = e.svc.Bootstrap(ctx, pos[0], password)
			} else {
				r = *role
				id, err = e.svc.CreateAccount(ctx, e.actor, pos[0], password, r)
			}
			if err != nil {
				return err
			}
			fmt.Fprintf(e.out, "Cuenta %d creada (rol %s, correo verificado y textos vigentes aceptados).\n", id, r)
			return nil
		}
		return order, nil
	case "purge-now":
		var wait *time.Duration
		pos, err := parseFlags(name, rest, func(fs *flag.FlagSet) {
			wait = fs.Duration("wait", admin.DefaultPurgeWait, "")
		})
		if err != nil || len(pos) != 1 || *wait < 0 {
			return nil, usageErr("purge-now necesita <correo> (y --wait, una duración)")
		}
		return &adminOrder{name: name, need: sanctions.RoleAdmin, run: func(ctx context.Context, e *adminEnv) error {
			res, err := e.svc.PurgeNow(ctx, e.actor, pos[0], *wait)
			if err != nil {
				return err
			}
			if !res.Purged {
				fmt.Fprintf(e.out, "La cuenta %d ya estaba purgada.\n", res.AccountID)
				return nil
			}
			fmt.Fprintf(e.out, "Cuenta %d purgada (sesiones revocadas: %d). Queda en purge_log.\n", res.AccountID, res.Revoked)
			return nil
		}}, nil
	case "reapply-purges":
		pos, err := parseFlags(name, rest, nil)
		if err != nil || len(pos) != 1 {
			return nil, usageErr("reapply-purges necesita <purges.txt> (el más reciente que dejó backup.sh)")
		}
		return &adminOrder{name: name, need: sanctions.RoleAdmin, run: func(ctx context.Context, e *adminEnv) error {
			entries, err := readPurges(pos[0])
			if err != nil {
				return err
			}
			res, err := e.svc.ReapplyPurges(ctx, e.actor, entries)
			if res != nil {
				fmt.Fprintf(e.out, "purges.txt: %d líneas. Borrados de la copia: %d arrendamientos y %d billetes. Purgados "+
					"ahora: %d cuentas y %d personajes; ya purgados o sin fila en la copia: %d.\n", res.Entries,
					res.LeasesDeleted, res.TicketsDeleted, res.Accounts, res.Characters, res.Unchanged)
			}
			if err != nil {
				return err
			}
			fmt.Fprintln(e.out, "Todo lo de purges.txt está purgado, con su fecha original. Ya se puede arrancar serve.")
			return nil
		}}, nil
	case "names":
		return parseNames(rest)
	case "reports":
		return parseReports(rest)
	case "audit":
		return parseAudit(rest)
	case "chat":
		return parseChat(rest)
	case "sanction":
		return parseSanction(rest)
	}
	return nil, usageErr("orden admin desconocida: %q", name)
}

func parseNames(args []string) (*adminOrder, error) {
	if len(args) == 0 || args[0] != "block" && args[0] != "unblock" {
		return nil, usageErr("names block|unblock <nombre>")
	}
	sub := args[0]
	var reason *string
	pos, err := parseFlags("names "+sub, args[1:], func(fs *flag.FlagSet) {
		if sub == "block" {
			reason = fs.String("reason", "", "")
		}
	})
	if err != nil || len(pos) != 1 {
		return nil, usageErr("names %s <nombre>", sub)
	}
	return &adminOrder{name: "names " + sub, need: sanctions.RoleAdmin, run: func(ctx context.Context, e *adminEnv) error {
		if sub == "unblock" {
			res, err := e.svc.UnblockName(ctx, e.actor, pos[0])
			if err != nil {
				return err
			}
			if res.Changed {
				fmt.Fprintf(e.out, "«%s» ya no está en la lista negra.\n", res.Key)
			} else {
				fmt.Fprintf(e.out, "«%s» no estaba en la lista negra.\n", res.Key)
			}
			return nil
		}
		res, err := e.svc.BlockName(ctx, e.actor, pos[0], *reason)
		if err != nil {
			return err
		}
		if res.Changed {
			fmt.Fprintf(e.out, "«%s» está en la lista negra: ningún personaje nuevo puede llamarse así.\n", res.Key)
		} else {
			fmt.Fprintf(e.out, "«%s» ya estaba en la lista negra.\n", res.Key)
		}
		for _, c := range res.Holders {
			fmt.Fprintf(e.out, "Aviso: %s (#%d, mundo %d) se llama así; para obligarle a cambiarlo: "+
				"sanction add '#%d' rename --reason …\n", c.Name, c.ID, c.WorldID, c.ID)
		}
		return nil
	}}, nil
}

func parseReports(args []string) (*adminOrder, error) {
	if len(args) == 0 {
		return nil, usageErr("reports list|show|close")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list":
		var status *string
		var n *int
		pos, err := parseFlags("reports list", rest, func(fs *flag.FlagSet) {
			status = fs.String("status", "open", "")
			n = fs.Int("limit", admin.DefaultLimit, "")
		})
		if err != nil || len(pos) != 0 {
			return nil, usageErr("reports list [--status …] [--limit N]")
		}
		return &adminOrder{name: "reports list", need: sanctions.RoleModerator, run: func(ctx context.Context, e *adminEnv) error {
			list, err := e.svc.Reports(ctx, e.actor, admin.ReportFilter{Status: *status, Limit: *n})
			if err != nil {
				return err
			}
			w := tabwriter.NewWriter(e.out, 0, 4, 2, ' ', 0)
			fmt.Fprintln(w, "ID\tFECHA\tMUNDO\tESTADO\tCATEGORÍA\tQUIEN REPORTA\tOBJETIVO\tPRUEBAS\tCOMENTARIO")
			for _, r := range list {
				fmt.Fprintf(w, "%d\t%s\t%d\t%s\t%s\t%s\t%s\t%d\t%s\n", r.ID, when(r.CreatedAt), r.WorldID, r.Status, r.Category,
					characterRef(r.ReporterName, r.ReporterCharacterID), r.TargetName, r.Evidence, oneLine(r.Comment, 60))
			}
			_ = w.Flush()
			fmt.Fprintf(e.out, "Reportes: %d.\n", len(list))
			return nil
		}}, nil
	case "show":
		pos, err := parseFlags("reports show", rest, nil)
		if err != nil || len(pos) != 1 {
			return nil, usageErr("reports show <id>")
		}
		id, err := parseID(pos[0])
		if err != nil {
			return nil, err
		}
		return &adminOrder{name: "reports show", need: sanctions.RoleModerator, run: func(ctx context.Context, e *adminEnv) error {
			d, err := e.svc.Report(ctx, e.actor, id)
			if err != nil {
				return err
			}
			printReport(e.out, d)
			return nil
		}}, nil
	case "close":
		var resolution *string
		pos, err := parseFlags("reports close", rest, func(fs *flag.FlagSet) {
			resolution = fs.String("resolution", "", "")
		})
		if err != nil || len(pos) != 2 {
			return nil, usageErr("reports close <id> actioned|dismissed [--resolution <texto>]")
		}
		id, err := parseID(pos[0])
		if err != nil {
			return nil, err
		}
		return &adminOrder{name: "reports close", need: sanctions.RoleAdmin, run: func(ctx context.Context, e *adminEnv) error {
			if err := e.svc.CloseReport(ctx, e.actor, id, pos[1], *resolution); err != nil {
				return err
			}
			fmt.Fprintf(e.out, "Reporte %d cerrado como %s.\n", id, pos[1])
			return nil
		}}, nil
	}
	return nil, usageErr("reports list|show|close")
}

func parseAudit(args []string) (*adminOrder, error) {
	var since, until, actorName, target, command *string
	var world, n *int
	pos, err := parseFlags("audit", args, func(fs *flag.FlagSet) {
		since = fs.String("since", "", "")
		until = fs.String("until", "", "")
		actorName = fs.String("actor-name", "", "")
		target = fs.String("target", "", "")
		command = fs.String("command", "", "")
		world = fs.Int("world", 1, "")
		n = fs.Int("limit", admin.DefaultLimit, "")
	})
	if err != nil || len(pos) != 0 || *since == "" {
		return nil, usageErr("audit --since <fecha> [--until <fecha>] [--actor-name <nombre>] [--target <nombre>]")
	}
	q := admin.AuditQuery{ActorName: *actorName, Target: *target, Command: *command, Limit: *n}
	if q.Since, err = parseWhen(*since); err != nil {
		return nil, err
	}
	if *until != "" {
		if q.Until, err = parseWhen(*until); err != nil {
			return nil, err
		}
	}
	if q.World, err = parseWorld(*world); err != nil {
		return nil, err
	}
	return &adminOrder{name: "audit", need: sanctions.RoleModerator, run: func(ctx context.Context, e *adminEnv) error {
		rows, err := e.svc.Audit(ctx, e.actor, q)
		if err != nil {
			return err
		}
		w := tabwriter.NewWriter(e.out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tFECHA\tMUNDO\tZONA\tORIGEN\tACTOR\tORDEN\tOBJETIVO\tARGUMENTOS")
		for _, r := range rows {
			fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", r.ID, when(r.At), optInt16(r.WorldID), optString(r.ZoneID),
				r.Source, who(r.ActorAccountID, r.ActorCharacterID, r.ActorName), r.Command,
				who(r.TargetAccountID, r.TargetCharacterID, r.TargetName), oneLine(string(r.Args), 120))
		}
		_ = w.Flush()
		fmt.Fprintf(e.out, "Filas: %d.\n", len(rows))
		return nil
	}}, nil
}

func parseChat(args []string) (*adminOrder, error) {
	var character, from, to *string
	var world, n *int
	pos, err := parseFlags("chat", args, func(fs *flag.FlagSet) {
		character = fs.String("character", "", "")
		from = fs.String("from", "", "")
		to = fs.String("to", "", "")
		world = fs.Int("world", 1, "")
		n = fs.Int("limit", admin.DefaultLimit, "")
	})
	if err != nil || len(pos) != 0 || *character == "" || *from == "" || *to == "" {
		return nil, usageErr("chat --character <nombre> --from <fecha> --to <fecha>")
	}
	q := admin.ChatQuery{Character: *character, Limit: *n}
	if q.From, err = parseWhen(*from); err != nil {
		return nil, err
	}
	if q.To, err = parseWhen(*to); err != nil {
		return nil, err
	}
	if q.World, err = parseWorld(*world); err != nil {
		return nil, err
	}
	return &adminOrder{name: "chat", need: sanctions.RoleModerator, run: func(ctx context.Context, e *adminEnv) error {
		c, lines, err := e.svc.Chat(ctx, e.actor, q)
		if err != nil {
			return err
		}
		fmt.Fprintf(e.out, "Chat de %s (#%d, cuenta %d, mundo %d), de %s a %s:\n", c.Name, c.ID, c.AccountID, c.WorldID,
			when(q.From), when(q.To))
		w := tabwriter.NewWriter(e.out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "FECHA\tZONA\tCANAL\tEMISOR\tDESTINATARIO\tTEXTO")
		for _, l := range lines {
			fmt.Fprintf(w, "%s\t%s:%d\t%d\t%s\t%s\t%s\n", when(l.SentAt), l.ZoneID, l.ZoneChannel, l.Channel,
				characterRef(l.SenderName, &l.SenderCharacterID), characterRef(l.TargetName, l.TargetCharacterID),
				oneLine(l.Text, 255))
		}
		_ = w.Flush()
		fmt.Fprintf(e.out, "Mensajes: %d.\n", len(lines))
		return nil
	}}, nil
}

func parseSanction(args []string) (*adminOrder, error) {
	if len(args) == 0 {
		return nil, usageErr("sanction add|revoke|list")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "add":
		var duration, reason *string
		var world *int
		var reports idList
		pos, err := parseFlags("sanction add", rest, func(fs *flag.FlagSet) {
			duration = fs.String("duration", "", "")
			reason = fs.String("reason", "", "")
			world = fs.Int("world", 1, "")
			fs.Var(&reports, "report", "")
		})
		if err != nil || len(pos) != 2 || *reason == "" {
			return nil, usageErr("sanction add <nombre> <tipo> [--duration …] --reason <texto> [--report <id>]...")
		}
		o := admin.SanctionOrder{Target: pos[0], Kind: pos[1], Reason: *reason, ReportIDs: reports}
		if *duration != "" {
			if o.Duration, err = parseSpan(*duration); err != nil {
				return nil, err
			}
		}
		if o.World, err = parseWorld(*world); err != nil {
			return nil, err
		}
		return &adminOrder{name: "sanction add", need: sanctions.RoleAdmin, run: func(ctx context.Context, e *adminEnv) error {
			created, target, err := e.svc.Sanction(ctx, e.actor, o)
			if err != nil {
				return err
			}
			end := "sin fin"
			if created.EndsAt != nil {
				end = "hasta el " + when(*created.EndsAt)
			}
			fmt.Fprintf(e.out, "Sanción %d (%s) a %s (#%d, cuenta %d), %s.\n", created.SanctionID, o.Kind, target.Name,
				target.ID, target.AccountID, end)
			return nil
		}}, nil
	case "revoke":
		pos, err := parseFlags("sanction revoke", rest, nil)
		if err != nil || len(pos) != 1 {
			return nil, usageErr("sanction revoke <id>")
		}
		id, err := parseID(pos[0])
		if err != nil {
			return nil, err
		}
		return &adminOrder{name: "sanction revoke", need: sanctions.RoleAdmin, run: func(ctx context.Context, e *adminEnv) error {
			info, err := e.svc.RevokeSanction(ctx, e.actor, id)
			if err != nil {
				return err
			}
			fmt.Fprintf(e.out, "Sanción %d (%s) revocada.\n", info.ID, info.Kind)
			return nil
		}}, nil
	case "list":
		var world *int
		pos, err := parseFlags("sanction list", rest, func(fs *flag.FlagSet) { world = fs.Int("world", 1, "") })
		if err != nil || len(pos) != 1 {
			return nil, usageErr("sanction list <nombre>")
		}
		w16, err := parseWorld(*world)
		if err != nil {
			return nil, err
		}
		return &adminOrder{name: "sanction list", need: sanctions.RoleModerator, run: func(ctx context.Context, e *adminEnv) error {
			c, list, err := e.svc.Sanctions(ctx, e.actor, w16, pos[0])
			if err != nil {
				return err
			}
			fmt.Fprintf(e.out, "Sanciones de la cuenta %d (la de %s, #%d):\n", c.AccountID, c.Name, c.ID)
			w := tabwriter.NewWriter(e.out, 0, 4, 2, ' ', 0)
			fmt.Fprintln(w, "ID\tTIPO\tESTADO\tDESDE\tHASTA\tPERSONAJE\tAUTOR\tREPORTES\tMOTIVO")
			for _, s := range list {
				end := "—"
				if s.EndsAt != nil {
					end = when(*s.EndsAt)
				}
				fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%v\t%s\n", s.ID, s.Kind, s.State, when(s.StartsAt), end,
					optInt64(s.CharacterID), optInt64(s.AuthorID), s.Reports, oneLine(s.Reason, 80))
			}
			_ = w.Flush()
			return nil
		}}, nil
	}
	return nil, usageErr("sanction add|revoke|list")
}

// parseFlags lee los argumentos con las opciones mezcladas entre los posicionales (el paquete flag
// para en el primero que no es una opción). define declara las opciones de la orden.
func parseFlags(name string, args []string, define func(*flag.FlagSet)) ([]string, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if define != nil {
		define(fs)
	}
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) == 0 {
			return pos, nil
		}
		pos = append(pos, args[0])
		args = args[1:]
	}
}

// idList es una opción repetible de ids (--report 1 --report 2, o --report 1,2).
type idList []int64

func (l *idList) String() string { return fmt.Sprint([]int64(*l)) }

func (l *idList) Set(v string) error {
	for _, part := range strings.Split(v, ",") {
		id, err := parseID(strings.TrimSpace(part))
		if err != nil {
			return err
		}
		*l = append(*l, id)
	}
	return nil
}

func parseID(s string) (int64, error) {
	id, err := strconv.ParseInt(s, 10, 64)
	if err != nil || id < 1 {
		return 0, usageErr("%q no es un id", s)
	}
	return id, nil
}

func parseWorld(w int) (int16, error) {
	if w < 1 || w > 32767 {
		return 0, usageErr("--world tiene que ser un mundo (1, 2…)")
	}
	return int16(w), nil
}

// parseWhen lee una fecha en UTC: 2026-11-01, 2026-11-01T18:00, 2026-11-01 18:00 o RFC 3339.
func parseWhen(s string) (time.Time, error) {
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02T15:04", "2006-01-02 15:04",
		"2006-01-02"} {
		if t, err := time.ParseInLocation(layout, s, time.UTC); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, usageErr("%q no es una fecha (2026-11-01, 2026-11-01T18:00 o RFC 3339)", s)
}

// parseSpan lee una duración: las de Go (30m, 24h) o días (7d).
func parseSpan(s string) (time.Duration, error) {
	if days, ok := strings.CutSuffix(s, "d"); ok {
		n, err := strconv.Atoi(days)
		if err != nil || n < 1 {
			return 0, usageErr("%q no es una duración", s)
		}
		return time.Duration(n) * 24 * time.Hour, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return 0, usageErr("%q no es una duración (30m, 24h, 7d)", s)
	}
	return d, nil
}

// readPurges lee purges.txt (admin.ParsePurges).
func readPurges(path string) ([]admin.PurgeEntry, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("no se puede leer purges.txt: %w", err)
	}
	defer f.Close()
	return admin.ParsePurges(f)
}

// readPassword lee la contraseña de un archivo (sin el salto de línea final).
func readPassword(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("no se puede leer --password-file: %w", err)
	}
	return strings.TrimSuffix(strings.TrimSuffix(string(data), "\n"), "\r"), nil
}

func printReport(out io.Writer, d *admin.ReportDetail) {
	fmt.Fprintf(out, "Reporte %d · %s · %s · mundo %d · %s\n", d.ID, d.Status, d.Category, d.WorldID, when(d.CreatedAt))
	fmt.Fprintf(out, "Quien reporta: %s (cuenta %s)\n", characterRef(d.ReporterName, d.ReporterCharacterID),
		optInt64(d.ReporterAccountID))
	fmt.Fprintf(out, "Objetivo: %s (#%s, cuenta %s)\n", d.TargetName, optInt64(d.TargetCharacterID), optInt64(d.TargetAccountID))
	if d.Comment != "" {
		fmt.Fprintf(out, "Comentario: %s\n", oneLine(d.Comment, 500))
	}
	fmt.Fprintf(out, "Contexto: %s\n", oneLine(string(d.Context), 500))
	if d.ClosedAt != nil {
		fmt.Fprintf(out, "Cerrado: %s por la cuenta %s: %s\n", when(*d.ClosedAt), optInt64(d.HandledBy),
			oneLine(optString(d.Resolution), 200))
	}
	fmt.Fprintf(out, "Pruebas (%d):\n", len(d.Evidence))
	for _, e := range d.Evidence {
		fmt.Fprintf(out, "  %s [canal %d] %s: %s\n", when(e.SentAt), e.Channel, e.SenderName, oneLine(e.Text, 255))
	}
	if len(d.Sanctions) > 0 {
		fmt.Fprintf(out, "Sanciones enlazadas: %v\n", d.Sanctions)
	}
}

func when(t time.Time) string { return t.UTC().Format("2006-01-02 15:04:05") }

func optString(s *string) string {
	if s == nil {
		return "—"
	}
	return *s
}

func optInt64(v *int64) string {
	if v == nil {
		return "—"
	}
	return strconv.FormatInt(*v, 10)
}

func optInt16(v *int16) string {
	if v == nil {
		return "—"
	}
	return strconv.Itoa(int(*v))
}

// characterRef es «Nombre (#id)», o «#id» sin nombre (purgado).
func characterRef(name *string, id *int64) string {
	switch {
	case id == nil:
		return "—"
	case name == nil:
		return "#" + strconv.FormatInt(*id, 10)
	}
	return *name + " (#" + strconv.FormatInt(*id, 10) + ")"
}

// who es el actor o el objetivo de una fila: el personaje si hay, si no la cuenta.
func who(account, character *int64, name *string) string {
	if character != nil {
		return characterRef(name, character)
	}
	if account != nil {
		return "cuenta " + strconv.FormatInt(*account, 10)
	}
	return "—"
}

// oneLine quita los saltos de línea y corta a max caracteres.
func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > max {
		return string(r[:max-1]) + "…"
	}
	return s
}
