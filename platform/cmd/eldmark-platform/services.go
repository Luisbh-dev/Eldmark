package main

import (
	"context"
	"io/fs"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/app"
	"eldmark/platform/internal/characters"
	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/gamedata"
	"eldmark/platform/internal/mail"
	"eldmark/platform/internal/names"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/privacy"
	"eldmark/platform/internal/progress"
	"eldmark/platform/internal/social"
	"eldmark/platform/internal/war"
	"eldmark/platform/internal/zones"
	"eldmark/platform/legal"
)

// Cada cuánto corren las purgas de cuentas y de personajes y las retenciones (§2.5: retenciones y
// purgas, cada hora).
const purgeEvery = time.Hour

// progressStore da el almacén del progreso y la validación de la creación (plataforma.md §7.5): los de
// progresion.md P7 (internal/progress, sobre 0010_progress) con las reglas exportadas de
// progression_rules.json, en todos los entornos. El falso en memoria y la validación provisional
// quedan para las pruebas.
func progressStore() (*progress.Store, *progress.Rules, error) {
	rules, err := progress.LoadRules(gamedata.Raw())
	if err != nil {
		return nil, nil, err
	}
	return progress.New(rules, nil), rules, nil
}

// mountServices monta en el proceso los servicios de los paquetes: cuentas y sesiones (P1),
// personajes (P2), la API interna (P3) y las retenciones (P9a). Devuelve lo que hay que cerrar al parar
// (la cola de correo).
func mountServices(a *app.App, cfg *config.Config, pool *pgxpool.Pool, log *slog.Logger) (func(), error) {
	rules, err := gamedata.Load()
	if err != nil {
		return nil, err
	}
	nameRules, err := names.New(rules.Names)
	if err != nil {
		return nil, err
	}
	progressRepo, validator, err := progressStore()
	if err != nil {
		return nil, err
	}
	minProtocol := cfg.ResolveMinProtocol(rules.ProtocolVersion)
	purger := characters.NewPurger(pool, progressRepo, clock.System{}, log)
	var texts fs.FS = legal.Embedded()
	if cfg.LegalDir != "" {
		texts = os.DirFS(cfg.LegalDir)
	}
	documents, err := legal.Load(texts)
	if err != nil {
		return nil, err
	}
	var sender mail.Sender = &mail.LogSender{DB: pool, Log: log}
	if cfg.Mail == config.MailSMTP {
		smtp, err := mail.NewSMTP(cfg.SMTPURL, cfg.MailFrom, log)
		if err != nil {
			return nil, err
		}
		smtp.Start()
		sender = smtp
	}
	svc, err := accounts.New(accounts.Options{Config: cfg, Pool: pool, Log: log, Mail: sender, Legal: documents,
		Characters: purger, Progress: progressRepo, MinProtocol: minProtocol})
	if err != nil {
		mail.Close(sender)
		return nil, err
	}
	retention, err := privacy.New(privacy.Options{Pool: pool, Progress: progressRepo, Log: log})
	if err != nil {
		mail.Close(sender)
		return nil, err
	}
	chars, err := characters.New(characters.Options{Config: cfg, Pool: pool, Log: log, Accounts: svc, Progress: progressRepo,
		Validator: validator, Names: nameRules, Purger: purger, MinProtocol: minProtocol})
	if err != nil {
		mail.Close(sender)
		return nil, err
	}
	a.OnBoot(func(ctx context.Context) error {
		changed, err := documents.Sync(ctx, pool, cfg.Env.Deployed())
		for _, name := range changed {
			log.Warn("un texto legal publicado ha cambiado; en staging y production no arrancaría", "file", name)
		}
		return err
	})
	auth := accounts.NewAPI(svc)
	auth.Mount(a)
	characters.NewAPI(chars).Mount(a, auth)
	if err := mountInternal(a, cfg, pool, log, progressRepo, nameRules, minProtocol); err != nil {
		mail.Close(sender)
		return nil, err
	}
	a.AddJob("accounts_purge", purgeEvery, svc.PurgeDue)
	a.AddJob("characters_purge", purgeEvery, purger.PurgeExpired)
	a.AddJob("privacy_retention", purgeEvery, retention.Job)
	return func() {
		svc.Wait() // las recuperaciones de contraseña en curso mandan su correo antes de cerrar la cola
		mail.Close(sender)
	}, nil
}

// mountInternal monta la API interna (P3, §6): las instancias de zona y los bloques de ids, la
// reclamación, el guardado y la liberación, operación y libro, las fortalezas y los eventos de
// guerra, y los lotes de chat y auditoría con ignorados, reportes y sanciones; el trabajo de
// instancias perdidas, cada min(5 s, HEARTBEAT_S), y la retención del chat (30 días), cada hora.
func mountInternal(a *app.App, cfg *config.Config, pool *pgxpool.Pool, log *slog.Logger,
	progressRepo persistence.ProgressStore, nameRules *names.Rules, minProtocol int) error {
	zoneSvc, err := zones.New(zones.Options{Config: cfg, Pool: pool, Log: log, MinProtocol: minProtocol})
	if err != nil {
		return err
	}
	store, err := persistence.NewStore(persistence.StoreOptions{Pool: pool, Progress: progressRepo, LeaseTTL: cfg.LeaseTTL,
		Log: log})
	if err != nil {
		return err
	}
	warSvc, err := war.New(war.Options{Pool: pool, Guard: zoneSvc.Guard(), Log: log})
	if err != nil {
		return err
	}
	socialSvc, err := social.New(social.Options{Pool: pool, Guard: zoneSvc.Guard(), Log: log, Names: nameRules})
	if err != nil {
		return err
	}
	zones.NewAPI(zoneSvc).Mount(a)
	persistence.NewAPI(store, zoneSvc.Guard()).Mount(a)
	warSvc.Mount(a)
	socialSvc.Mount(a)
	a.AddJob("zones_lost", zoneSvc.LostEvery(), zoneSvc.MarkLost)
	a.AddJob("chat_retention", purgeEvery, socialSvc.ChatRetentionJob)
	return nil
}
