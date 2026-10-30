package admin

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/sanctions"
)

// Tipos de una línea de purges.txt (los de purge_log.kind).
const (
	PurgeAccount   = "account"
	PurgeCharacter = "character"
)

// PurgeEntry es una línea de purges.txt: una fila de purge_log (§11.2).
type PurgeEntry struct {
	Kind     string // PurgeAccount o PurgeCharacter
	ID       int64
	PurgedAt time.Time
}

// purgeTimeLayouts son los formatos de purged_at que admite purges.txt: el de texto de PostgreSQL
// (el que escribe backup.sh con COPY y la zona horaria UTC: 2026-10-30 09:46:00.123456+00) y RFC 3339.
var purgeTimeLayouts = []string{
	"2006-01-02 15:04:05.999999999-07",
	"2006-01-02 15:04:05.999999999-07:00",
	"2006-01-02 15:04:05.999999999-07:00:00",
	time.RFC3339Nano,
}

// ParsePurges lee purges.txt: una línea por fila de purge_log, «kind<TAB>id<TAB>purged_at», como la
// escribe backup.sh (el formato de texto de COPY). Las líneas vacías no cuentan. Un error nombra la
// línea; el archivo no lleva datos personales (solo ids y fechas), así que se puede repetir.
func ParsePurges(r io.Reader) ([]PurgeEntry, error) {
	var entries []PurgeEntry
	scanner := bufio.NewScanner(r)
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimRight(scanner.Text(), "\r")
		if strings.TrimSpace(text) == "" {
			continue
		}
		fields := strings.Split(text, "\t")
		if len(fields) != 3 {
			return nil, fmt.Errorf("purges.txt, línea %d: tiene que ser «kind<TAB>id<TAB>purged_at»", line)
		}
		e := PurgeEntry{Kind: fields[0]}
		if e.Kind != PurgeAccount && e.Kind != PurgeCharacter {
			return nil, fmt.Errorf("purges.txt, línea %d: %q no es account ni character", line, e.Kind)
		}
		id, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || id < 1 {
			return nil, fmt.Errorf("purges.txt, línea %d: %q no es un id", line, fields[1])
		}
		e.ID = id
		parsed := false
		for _, layout := range purgeTimeLayouts {
			if t, err := time.Parse(layout, fields[2]); err == nil {
				e.PurgedAt, parsed = t.UTC(), true
				break
			}
		}
		if !parsed {
			return nil, fmt.Errorf("purges.txt, línea %d: %q no es una fecha (2026-10-30 09:46:00.123456+00 o RFC 3339)",
				line, fields[2])
		}
		entries = append(entries, e)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("purges.txt: %w", err)
	}
	return entries, nil
}

// CharacterReapplier vuelve a purgar un personaje con su purged_at original: characters.Purger.
type CharacterReapplier interface {
	ReapplyPurge(ctx context.Context, characterID int64, at time.Time) (bool, error)
}

// ReapplyResult es el resultado de reapply-purges.
type ReapplyResult struct {
	Entries        int   // líneas de purges.txt
	LeasesDeleted  int64 // arrendamientos de la copia que se borraron
	TicketsDeleted int64 // billetes de la copia que se borraron
	Accounts       int   // cuentas purgadas ahora
	Characters     int   // personajes purgados ahora (los de una cuenta que se purga, también)
	Unchanged      int   // líneas cuya cuenta o personaje ya estaba purgado, o no existe, en la copia
}

// UnpurgedError es un reapply-purges que deja algún id de purges.txt sin purgar (la orden sale
// con 1). Solo lleva ids.
type UnpurgedError struct {
	Accounts   []int64
	Characters []int64
}

func (e *UnpurgedError) Error() string {
	var parts []string
	if len(e.Accounts) > 0 {
		parts = append(parts, fmt.Sprintf("cuentas %v", e.Accounts))
	}
	if len(e.Characters) > 0 {
		parts = append(parts, fmt.Sprintf("personajes %v", e.Characters))
	}
	return "quedan sin purgar ids de purges.txt: " + strings.Join(parts, " y ")
}

// ErrNoCharacterPurger es reapply-purges sin quien purgue personajes.
var ErrNoCharacterPurger = errors.New("no hay quien purgue personajes (el almacén del progreso, docs/progresion.md P7)")

// ReapplyPurges vuelve a aplicar las purgas de purges.txt tras restaurar una copia (§11.2), con las
// zonas paradas y antes de arrancar serve: en una transacción borra todos los character_leases y
// enter_tickets de la copia (ya no son de nadie) y deja la fila reapply-purges (args con los
// recuentos, sin ids); después purga cada cuenta y cada personaje de entries, cada uno en su
// transacción y en el orden de purged_at, con su purged_at original y no con la hora: así no se
// alarga ninguna retención. Es idempotente: lo ya purgado no se toca. Al final comprueba que no
// queda ningún id de entries sin purgar; si queda alguno, [UnpurgedError].
func (s *Service) ReapplyPurges(ctx context.Context, actor *Actor, entries []PurgeEntry) (*ReapplyResult, error) {
	if s.characters == nil {
		return nil, ErrNoCharacterPurger
	}
	res := &ReapplyResult{Entries: len(entries)}
	ordered := append([]PurgeEntry(nil), entries...)
	sort.SliceStable(ordered, func(i, j int) bool {
		a, b := ordered[i], ordered[j]
		if !a.PurgedAt.Equal(b.PurgedAt) {
			return a.PurgedAt.Before(b.PurgedAt)
		}
		if a.Kind != b.Kind {
			return a.Kind == PurgeCharacter // a igual hora, el personaje antes que su cuenta
		}
		return a.ID < b.ID
	})
	accountsInFile, charactersInFile := 0, 0
	for _, e := range ordered {
		if e.Kind == PurgeAccount {
			accountsInFile++
		} else {
			charactersInFile++
		}
	}
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockActor(ctx, tx, actor, sanctions.RoleAdmin); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `delete from character_leases`)
		if err != nil {
			return err
		}
		res.LeasesDeleted = tag.RowsAffected()
		if tag, err = tx.Exec(ctx, `delete from enter_tickets`); err != nil {
			return err
		}
		res.TicketsDeleted = tag.RowsAffected()
		return s.audit(ctx, tx, actor, entry{command: "reapply-purges", args: map[string]any{
			"entries": len(entries), "accounts": accountsInFile, "characters": charactersInFile,
			"leases_deleted": res.LeasesDeleted, "tickets_deleted": res.TicketsDeleted,
		}}, s.clock.Now())
	})
	if err != nil {
		return nil, err
	}
	for _, e := range ordered {
		if ctx.Err() != nil {
			return res, ctx.Err()
		}
		switch e.Kind {
		case PurgeAccount:
			before, err := s.livingCharacters(ctx, e.ID)
			if err != nil {
				return res, err
			}
			done, err := s.accounts.ReapplyPurge(ctx, e.ID, e.PurgedAt)
			if errors.Is(err, accounts.ErrCharactersBusy) {
				return res, fmt.Errorf("la cuenta %d tiene un personaje con un arrendamiento vivo: ¿hay una zona o serve "+
					"en marcha contra esta base? (%w)", e.ID, err)
			}
			if err != nil {
				return res, fmt.Errorf("cuenta %d: %w", e.ID, err)
			}
			if done {
				res.Accounts++
				res.Characters += before
			} else {
				res.Unchanged++
			}
		case PurgeCharacter:
			done, err := s.characters.ReapplyPurge(ctx, e.ID, e.PurgedAt)
			if err != nil {
				return res, fmt.Errorf("personaje %d: %w", e.ID, err)
			}
			if done {
				res.Characters++
			} else {
				res.Unchanged++
			}
		}
	}
	if err := s.checkPurged(ctx, ordered); err != nil {
		return res, err
	}
	s.log.Info("purgas reaplicadas", "entries", res.Entries, "accounts", res.Accounts, "characters", res.Characters,
		"actor", actor.AccountID)
	return res, nil
}

// livingCharacters cuenta los personajes sin purgar de la cuenta (los que purgará su purga).
func (s *Service) livingCharacters(ctx context.Context, accountID int64) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `select count(*) from characters where account_id = $1 and purged_at is null`,
		accountID).Scan(&n)
	return n, err
}

// checkPurged comprueba que ninguna cuenta ni ningún personaje de entries sigue sin purgar (los que
// no tienen fila en la copia cuentan como purgados: no hay nada suyo).
func (s *Service) checkPurged(ctx context.Context, entries []PurgeEntry) error {
	var accountIDs, characterIDs []int64
	for _, e := range entries {
		if e.Kind == PurgeAccount {
			accountIDs = append(accountIDs, e.ID)
		} else {
			characterIDs = append(characterIDs, e.ID)
		}
	}
	unpurged := &UnpurgedError{}
	rows, err := s.pool.Query(ctx, `select account_id from accounts where account_id = any($1)
		and (status <> 'purged' or purged_at is null or email is not null or password_hash is not null)
		order by account_id`, accountIDs)
	if err != nil {
		return err
	}
	if unpurged.Accounts, err = pgx.CollectRows(rows, pgx.RowTo[int64]); err != nil {
		return err
	}
	rows, err = s.pool.Query(ctx, `select character_id from characters where character_id = any($1)
		and purged_at is null order by character_id`, characterIDs)
	if err != nil {
		return err
	}
	if unpurged.Characters, err = pgx.CollectRows(rows, pgx.RowTo[int64]); err != nil {
		return err
	}
	if len(unpurged.Accounts) > 0 || len(unpurged.Characters) > 0 {
		return unpurged
	}
	return nil
}
