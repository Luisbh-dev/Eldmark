// Package services mounts the packages' services in the serve process (plataforma.md §14.1):
// accounts and sessions (P1), characters (P2), the internal API (P3, with war and the social part
// from P7a) and the retention jobs (P9a), with the progress store from progresion.md P7. It is
// used by the serve command and the end-to-end tests (platform/e2e, P10), which start the real
// platform inside the test's process.
package services

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

// How often the account and character purges and the retention jobs run (§2.5: retention and
// purges, every hour).
const purgeEvery = time.Hour

// ProgressStore provides the progress store and the creation validation (plataforma.md §7.5):
// those of progresion.md P7 (internal/progress, over 0010_progress) with the rules exported from
// progression_rules.json, in all environments. The in-memory fake and the provisional validation
// remain for the tests.
func ProgressStore() (*progress.Store, *progress.Rules, error) {
	rules, err := progress.LoadRules(gamedata.Raw())
	if err != nil {
		return nil, nil, err
	}
	return progress.New(rules, nil), rules, nil
}

// Mount mounts the packages' services in the process: accounts and sessions (P1), characters
// (P2), the internal API (P3) and the retention jobs (P9a). It returns what must be closed on
// shutdown (the mail queue).
func Mount(a *app.App, cfg *config.Config, pool *pgxpool.Pool, log *slog.Logger) (func(), error) {
	rules, err := gamedata.Load()
	if err != nil {
		return nil, err
	}
	nameRules, err := names.New(rules.Names)
	if err != nil {
		return nil, err
	}
	progressRepo, validator, err := ProgressStore()
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
		svc.Wait() // password recoveries in progress send their email before the queue is closed
		mail.Close(sender)
	}, nil
}

// mountInternal mounts the internal API (P3, §6): zone instances and id blocks, the claim, the
// save and the release, operation and ledger, the forts and the war events, and the chat and
// audit batches with ignores, reports and sanctions; the lost-instances job, every min(5 s,
// HEARTBEAT_S), and the chat retention (30 days), every hour.
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
