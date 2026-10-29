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
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/mail"
	"eldmark/platform/legal"
)

// Cada cuánto corre la purga de cuentas (§2.5: retenciones y purgas, cada hora).
const purgeEvery = time.Hour

// mountServices monta en el proceso los servicios de los paquetes: por ahora, cuentas y sesiones
// (P1). Devuelve lo que hay que cerrar al parar (la cola de correo).
func mountServices(a *app.App, cfg *config.Config, pool *pgxpool.Pool, log *slog.Logger) (func(), error) {
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
		// Hasta que exista progression_rules.json (P2), en dev y test sin ELDMARK_MIN_PROTOCOL
		// basta con que el cliente mande la cabecera.
		MinProtocol: cfg.ResolveMinProtocol(0)})
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
	accounts.NewAPI(svc).Mount(a)
	a.AddJob("accounts_purge", purgeEvery, svc.PurgeDue)
	return func() { mail.Close(sender) }, nil
}
