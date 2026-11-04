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

// Kinds of a purges.txt line (those of purge_log.kind).
const (
	PurgeAccount   = "account"
	PurgeCharacter = "character"
)

// PurgeEntry is a purges.txt line: a purge_log row (§11.2).
type PurgeEntry struct {
	Kind     string // PurgeAccount or PurgeCharacter
	ID       int64
	PurgedAt time.Time
}

// purgeTimeLayouts are the purged_at formats that purges.txt accepts: PostgreSQL's text one (the one
// backup.sh writes with COPY and the UTC time zone: 2026-10-30 09:46:00.123456+00) and RFC 3339.
var purgeTimeLayouts = []string{
	"2006-01-02 15:04:05.999999999-07",
	"2006-01-02 15:04:05.999999999-07:00",
	"2006-01-02 15:04:05.999999999-07:00:00",
	time.RFC3339Nano,
}

// ParsePurges reads purges.txt: one line per purge_log row, "kind<TAB>id<TAB>purged_at", as
// backup.sh writes it (COPY's text format). Empty lines do not count. An error names the line; the
// file carries no personal data (only ids and dates), so it can be repeated.
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

// CharacterReapplier purges a character again with its original purged_at: characters.Purger.
type CharacterReapplier interface {
	ReapplyPurge(ctx context.Context, characterID int64, at time.Time) (bool, error)
}

// ReapplyResult is the result of reapply-purges.
type ReapplyResult struct {
	Entries        int   // lines of purges.txt
	LeasesDeleted  int64 // leases from the backup that were deleted
	TicketsDeleted int64 // tickets from the backup that were deleted
	Accounts       int   // accounts purged now
	Characters     int   // characters purged now (those of a purged account too)
	Unchanged      int   // lines whose account or character was already purged, or does not exist, in the backup
}

// UnpurgedError is a reapply-purges that leaves some purges.txt id unpurged (the command exits with
// 1). It only carries ids.
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

// ErrNoCharacterPurger is reapply-purges without anything to purge characters.
var ErrNoCharacterPurger = errors.New("no hay quien purgue personajes (el almacén del progreso, docs/progresion.md P7)")

// ReapplyPurges applies the purges.txt purges again after restoring a backup (§11.2), with the zones
// stopped and before starting serve: in one transaction it deletes all the backup's
// character_leases and enter_tickets (they no longer belong to anyone) and leaves the
// reapply-purges row (args with the counts, without ids); afterwards it purges each account and
// each character of entries, each in its own transaction and in purged_at order, with its original
// purged_at and not the current time: that way no retention is extended. It is idempotent: what is
// already purged is not touched. At the end it checks that no id of entries is left unpurged; if
// any is, [UnpurgedError].
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
			return a.Kind == PurgeCharacter // at the same time, the character before its account
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

// livingCharacters counts the account's unpurged characters (those its purge will purge).
func (s *Service) livingCharacters(ctx context.Context, accountID int64) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `select count(*) from characters where account_id = $1 and purged_at is null`,
		accountID).Scan(&n)
	return n, err
}

// checkPurged checks that no account or character of entries is still unpurged (those with no row in
// the backup count as purged: there is nothing of theirs).
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
