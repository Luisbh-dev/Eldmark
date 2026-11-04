package characters

import (
	"context"
	"encoding/base64"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/accounts"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/names"
	"eldmark/platform/internal/persistence"
)

// CharacterView is a character in the API (§4.4). Race, appearance (base64 of the 8 B), level, last
// zone and play time come from ProgressStore.Summaries; if the store does not have the character,
// race_id, appearance and last_zone_id go to null and the level to 1. Dates, in Unix.
type CharacterView struct {
	CharacterID   jsonx.ID `json:"character_id"`
	Name          string   `json:"name"`
	Realm         string   `json:"realm"`
	RaceID        *string  `json:"race_id"`
	Appearance    *string  `json:"appearance"`
	Level         int      `json:"level"`
	LastZoneID    *string  `json:"last_zone_id"`
	PlayedSeconds int64    `json:"played_seconds"`
	CreatedAt     int64    `json:"created_at"`
	DeletedAt     *int64   `json:"deleted_at"`
	RestoreUntil  *int64   `json:"restore_until"`
	MustRename    bool     `json:"must_rename"`
}

// characterRow is a character's identity (the characters row).
type characterRow struct {
	ID           int64
	WorldID      int16
	Name         string
	NameKey      string
	Realm        config.Realm
	CreatedAt    time.Time
	DeletedAt    *time.Time
	RestoreUntil *time.Time
	MustRename   bool
}

const characterColumns = `character_id, world_id, name, name_key, realm, created_at, deleted_at, restore_until, must_rename`

func scanCharacter(row pgx.Row) (*characterRow, error) {
	c := &characterRow{}
	if err := row.Scan(&c.ID, &c.WorldID, &c.Name, &c.NameKey, &c.Realm, &c.CreatedAt, &c.DeletedAt, &c.RestoreUntil,
		&c.MustRename); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *characterRow) view(sum persistence.Summary, ok bool) CharacterView {
	v := CharacterView{CharacterID: jsonx.ID(c.ID), Name: c.Name, Realm: c.Realm.String(), Level: 1,
		CreatedAt: c.CreatedAt.Unix(), DeletedAt: unix(c.DeletedAt), RestoreUntil: unix(c.RestoreUntil),
		MustRename: c.MustRename}
	if ok {
		race := sum.RaceID
		appearance := base64.StdEncoding.EncodeToString(sum.Appearance[:])
		v.RaceID, v.Appearance, v.Level, v.PlayedSeconds = &race, &appearance, sum.Level, sum.PlayedSeconds
		if sum.LastZoneID != "" {
			zone := sum.LastZoneID
			v.LastZoneID = &zone
		}
	}
	return v
}

// viewOf builds a character's view with its summary.
func (s *Service) viewOf(ctx context.Context, q persistence.Querier, c *characterRow) (*CharacterView, error) {
	sums, err := s.summaries(ctx, q, []int64{c.ID})
	if err != nil {
		return nil, err
	}
	sum, ok := sums[c.ID]
	v := c.view(sum, ok)
	return &v, nil
}

// ListView is GET /v1/worlds/{w}/characters: the account's realm in that world (null if it does not
// have one yet) and when it is freed, the slots, the occupied ones and the characters (live and
// deleted ones that can still be restored, which occupy a slot), by creation date.
type ListView struct {
	Realm      *string         `json:"realm"`
	UnlockAt   *int64          `json:"unlock_at"`
	Slots      int             `json:"slots"`
	Used       int             `json:"used"`
	Characters []CharacterView `json:"characters"`
}

// occupiesSlot is the condition of a character that occupies a slot at time $now: alive, or deleted
// and still restorable (§4.4 step 3).
const occupiesSlot = `purged_at is null and (deleted_at is null or restore_until > `

// List returns the account's characters in a world.
func (s *Service) List(ctx context.Context, sess *accounts.Session, worldID int16) (*ListView, error) {
	if _, err := s.checkWorld(ctx, s.pool, worldID); err != nil {
		return nil, err
	}
	now := s.clock.Now()
	v := &ListView{Characters: []CharacterView{}}
	var realm config.Realm
	var unlockAt *time.Time
	err := s.pool.QueryRow(ctx, `select realm, unlock_at from account_realms where account_id = $1 and world_id = $2`,
		sess.AccountID, worldID).Scan(&realm, &unlockAt)
	switch {
	case err == nil:
		name := realm.String()
		v.Realm, v.UnlockAt = &name, unix(unlockAt)
	case !errors.Is(err, pgx.ErrNoRows):
		return nil, err
	}
	slots, err := s.accounts.Slots(ctx, s.pool, sess.AccountID, now)
	if err != nil {
		return nil, err
	}
	v.Slots = slots[worldID]
	rows, err := s.pool.Query(ctx, `select `+characterColumns+` from characters
		where account_id = $1 and world_id = $2 and `+occupiesSlot+`$3)
		order by created_at, character_id`, sess.AccountID, worldID, now)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (*characterRow, error) { return scanCharacter(r) })
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(list))
	for i, c := range list {
		ids[i] = c.ID
	}
	sums, err := s.summaries(ctx, s.pool, ids)
	if err != nil {
		return nil, err
	}
	for _, c := range list {
		sum, ok := sums[c.ID]
		v.Characters = append(v.Characters, c.view(sum, ok))
	}
	v.Used = len(list)
	return v, nil
}

// NameCheckView is GET /v1/worlds/{w}/name-check: available, or the code (name_invalid or
// name_taken) and, for name_invalid, the reason from NameRules.
type NameCheckView struct {
	Available bool   `json:"available"`
	Code      string `json:"code"`
	Reason    string `json:"reason"`
}

// NameCheck says whether a name can be used in the world (30 per minute and session).
func (s *Service) NameCheck(ctx context.Context, sess *accounts.Session, worldID int16, name string) (*NameCheckView, error) {
	now := s.clock.Now()
	if ok, wait := s.limits.nameCheck.Allow("s:"+itoa(sess.ID), now); !ok {
		return nil, errRateLimited(wait)
	}
	if _, err := s.checkWorld(ctx, s.pool, worldID); err != nil {
		return nil, err
	}
	reason, key, err := s.checkName(ctx, s.pool, name)
	if err != nil {
		return nil, err
	}
	if reason != names.OK {
		return &NameCheckView{Code: "name_invalid", Reason: reason.String()}, nil
	}
	var taken bool
	if err := s.pool.QueryRow(ctx, `select exists (select 1 from character_names where world_id = $1 and name_key = $2
		and (status = 'active' or reserved_until > $3))`, worldID, key, now).Scan(&taken); err != nil {
		return nil, err
	}
	if taken {
		return &NameCheckView{Code: "name_taken"}, nil
	}
	return &NameCheckView{Available: true}, nil
}

// checkName applies NameRules and the blacklist: it returns the reason (Reserved if it is in the
// blacklist) and the normalized key.
func (s *Service) checkName(ctx context.Context, q persistence.Querier, name string) (names.Reason, string, error) {
	if reason := s.names.Validate(name); reason != names.OK {
		return reason, "", nil
	}
	key := s.names.NormalizeKey(name)
	var blocked bool
	if err := q.QueryRow(ctx, `select exists (select 1 from name_blacklist where name_key = $1)`, key).Scan(&blocked); err != nil {
		return 0, "", err
	}
	if blocked {
		return names.Reserved, "", nil
	}
	return names.OK, key, nil
}

// claimName gives the name's key to the character (character_names with status active). A reserved
// and expired row is reused; an active one or one reserved within its window gives name_taken. Two
// simultaneous creations with the same name: one waits for the other and finds no row (or clashes
// with the primary key): name_taken.
func claimName(ctx context.Context, tx pgx.Tx, worldID int16, key string, characterID int64, now time.Time) error {
	var got int64
	err := tx.QueryRow(ctx, `insert into character_names (world_id, name_key, character_id, status, reserved_until)
		values ($1, $2, $3, 'active', null)
		on conflict (world_id, name_key) do update set character_id = excluded.character_id, status = 'active',
		  reserved_until = null
		where character_names.status = 'reserved' and character_names.reserved_until <= $4
		returning character_id`, worldID, key, characterID, now).Scan(&got)
	switch {
	case errors.Is(err, pgx.ErrNoRows), db.Constraint(err) == "character_names_pkey":
		return errNameTaken()
	}
	return err
}

// CreateRequest is the body of POST /v1/worlds/{w}/characters: the realm in its text id and the
// appearance in base64 of 8 B.
type CreateRequest struct {
	Name              *string `json:"name"`
	Realm             *string `json:"realm"`
	RaceID            *string `json:"race_id"`
	Appearance        *string `json:"appearance"`
	StarterTemplateID *string `json:"starter_template_id"`
}

// parse checks that the body brings everything and in its shape: if not, 400 validation with the
// fields.
func (r CreateRequest) parse() (name string, realm config.Realm, raceID string, appearance [8]byte, template string,
	err error) {
	fields := map[string]string{}
	for field, v := range map[string]*string{"name": r.Name, "realm": r.Realm, "race_id": r.RaceID,
		"appearance": r.Appearance, "starter_template_id": r.StarterTemplateID} {
		if v == nil {
			fields[field] = "required"
		}
	}
	if r.Realm != nil {
		var ok bool
		if realm, ok = config.ParseRealm(*r.Realm); !ok {
			fields["realm"] = "invalid"
		}
	}
	if r.Appearance != nil {
		b, decErr := base64.StdEncoding.Strict().DecodeString(*r.Appearance)
		if decErr != nil || len(b) != len(appearance) {
			fields["appearance"] = "invalid"
		} else {
			copy(appearance[:], b)
		}
	}
	if len(fields) > 0 {
		return "", 0, "", appearance, "", errValidation(fields)
	}
	return *r.Name, realm, *r.RaceID, appearance, *r.StarterTemplateID, nil
}

// Create creates a character (§4.4) in a transaction that locks the account's row first, so an
// account's creations (and deletions) run in series: realm, slots and daily limit do not cross, and
// the name is decided by character_names' primary key. It is not serializable, as §4.4 said: with
// SSI, different accounts creating at the same time clashed for no reason (predicate locks on small
// tables) and exhausted the retries (plataforma.md §19.3). Steps:
//  1. active account with no pending deletion (403 account_pending_deletion), open realm (409
//     realm_closed) and fewer than 5 creations in 24 h (429);
//  2. the account's realm in the world: it is set if it has none, or if its own was freed and it has
//     no living character left; if it is another, 409 realm_locked;
//  3. slots: 6 plus the entitlements; living ones and those deleted within the window occupy them
//     (409 slots_full);
//  4. name: NameRules (422 name_invalid), blacklist (422 reserved) and the key in
//     character_names (409 name_taken);
//  5. race, appearance and template with the CreateValidator (400 validation);
//  6. the characters row, the character_pvp_stats row, ProgressStore.Create and auth_events.
func (s *Service) Create(ctx context.Context, sess *accounts.Session, worldID int16, req CreateRequest,
	meta accounts.ClientMeta) (*CharacterView, error) {
	name, realm, raceID, appearance, template, err := req.parse()
	if err != nil {
		return nil, err
	}
	if _, err := s.checkWorld(ctx, s.pool, worldID); err != nil {
		return nil, err
	}
	now := s.clock.Now()
	var view *CharacterView
	err = db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		view = nil
		// 1. The account, the realm and the daily limit.
		status, purgeAfter, err := lockAccount(ctx, tx, sess.AccountID)
		if err != nil {
			return err
		}
		if status != "active" {
			return errPendingDeletion(purgeAfter)
		}
		if !s.openRealm(realm) {
			return errRealmClosed()
		}
		if err := dailyLimit(ctx, tx, sess.AccountID, "character_create", now); err != nil {
			return err
		}
		// 2. The account's realm in this world.
		if err := s.fixAccountRealm(ctx, tx, sess.AccountID, worldID, realm, now); err != nil {
			return err
		}
		// 3. Slots.
		slots, err := s.accounts.Slots(ctx, tx, sess.AccountID, now)
		if err != nil {
			return err
		}
		var used int
		if err := tx.QueryRow(ctx, `select count(*) from characters where account_id = $1 and world_id = $2 and `+
			occupiesSlot+`$3)`, sess.AccountID, worldID, now).Scan(&used); err != nil {
			return err
		}
		if used >= slots[worldID] {
			return errSlotsFull()
		}
		// 4. The name.
		reason, key, err := s.checkName(ctx, tx, name)
		if err != nil {
			return err
		}
		if reason != names.OK {
			return s.errNameInvalid(reason)
		}
		c := &characterRow{WorldID: worldID, Name: name, NameKey: key, Realm: realm, CreatedAt: now}
		if err := tx.QueryRow(ctx, `insert into characters (world_id, account_id, name, name_key, realm, created_at)
			values ($1, $2, $3, $4, $5, $6) returning character_id`, worldID, sess.AccountID, name, key, realm, now).
			Scan(&c.ID); err != nil {
			return err
		}
		if err := claimName(ctx, tx, worldID, key, c.ID, now); err != nil {
			return err
		}
		// 5. Race, appearance and template.
		if err := s.validator.ValidateCreate(int16(realm), raceID, appearance, template); err != nil {
			var ve *persistence.ValidationError
			if errors.As(err, &ve) {
				return errValidation(ve.Fields)
			}
			return err
		}
		// 6. The rest of the identity, the progression and the limit entry.
		if _, err := tx.Exec(ctx, `insert into character_pvp_stats (character_id, world_id, updated_at) values ($1, $2, $3)`,
			c.ID, worldID, now); err != nil {
			return err
		}
		if err := s.progress.Create(ctx, tx, worldID, c.ID, persistence.CreateParams{RaceID: raceID,
			Appearance: appearance, StarterTemplateID: template}); err != nil {
			return err
		}
		if err := s.accounts.Event(ctx, tx, sess.AccountID, "character_create", meta, now); err != nil {
			return err
		}
		view, err = s.viewOf(ctx, tx, c)
		return err
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// fixAccountRealm applies step 2 of creation: the account's realm in the world.
func (s *Service) fixAccountRealm(ctx context.Context, tx pgx.Tx, accountID int64, worldID int16, realm config.Realm,
	now time.Time) error {
	var current config.Realm
	var unlockAt *time.Time
	err := tx.QueryRow(ctx, `select realm, unlock_at from account_realms where account_id = $1 and world_id = $2 for update`,
		accountID, worldID).Scan(&current, &unlockAt)
	if errors.Is(err, pgx.ErrNoRows) {
		_, err = tx.Exec(ctx, `insert into account_realms (account_id, world_id, realm) values ($1, $2, $3)`,
			accountID, worldID, realm)
		return err
	}
	if err != nil {
		return err
	}
	if current != realm {
		var alive int
		if err := tx.QueryRow(ctx, `select count(*) from characters where account_id = $1 and world_id = $2
			and deleted_at is null and purged_at is null`, accountID, worldID).Scan(&alive); err != nil {
			return err
		}
		if unlockAt == nil || unlockAt.After(now) || alive > 0 {
			return errRealmLocked(current, unlockAt)
		}
	}
	// The realm is this one (or is changed to this one): with a new character it is no longer about to
	// be freed.
	_, err = tx.Exec(ctx, `update account_realms set realm = $3, unlock_at = null where account_id = $1 and world_id = $2`,
		accountID, worldID, realm)
	return err
}
