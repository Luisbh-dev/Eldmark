package persistence

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/internal/zones"
)

// SaveFormat is the version of the save envelope (§7.1, §7.3).
const SaveFormat = 1

// ticketGrace is the ticket expiry margin on claim (§5.3: expires_at > now − 5 s).
const ticketGrace = 5 * time.Second

// Store is the platform's character persistence (§5.3, §7.3, TEC-25): the claim that consumes
// the ticket and takes the lease, the save with its (lease_id, seq) idempotency, and the
// release. The progress contents are read and written by [ProgressStore].
type Store struct {
	pool     *pgxpool.Pool
	progress ProgressStore
	clock    clock.Clock
	leaseTTL time.Duration
	log      *slog.Logger
}

// StoreOptions are the store's dependencies.
type StoreOptions struct {
	Pool     *pgxpool.Pool
	Progress ProgressStore
	Clock    clock.Clock // defaults to the system clock
	LeaseTTL time.Duration
	Log      *slog.Logger
}

// NewStore prepares the store.
func NewStore(o StoreOptions) (*Store, error) {
	if o.Pool == nil || o.Progress == nil || o.LeaseTTL <= 0 {
		return nil, errors.New("persistence: faltan dependencias")
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	return &Store{pool: o.Pool, progress: o.Progress, clock: o.Clock, leaseTTL: o.LeaseTTL, log: o.Log}, nil
}

// PvP holds a character's GUE-19 totals (the pvp section, §7.1, §8).
type PvP struct {
	Kills      jsonx.Int `json:"kills"`
	Deaths     jsonx.Int `json:"deaths"`
	Assists    jsonx.Int `json:"assists"`
	Captures   jsonx.Int `json:"captures"`
	GateDamage jsonx.Int `json:"gate_damage"`
	DefendS    jsonx.Int `json:"defend_s"`
}

// Claim and save errors (§6.1).

func errTicketInvalid() *httpx.Error {
	return zones.Conflict("ticket_invalid", "El billete no vale")
}

func errCharacterBusy() *httpx.Error {
	e := zones.Conflict("character_busy", "Tu personaje sigue en el mundo: espera unos segundos")
	e.RetryAfter = 3
	return e
}

func errLeaseLost() *httpx.Error {
	return zones.Conflict("lease_lost", "El arrendamiento del personaje ya no es de esta instancia")
}

func errStaleSeq() *httpx.Error {
	return zones.Conflict("stale_seq", "Ese guardado es anterior al último aplicado")
}

func errSeqConflict() *httpx.Error {
	return zones.Conflict("seq_conflict", "Ese seq ya se aplicó con otro cuerpo")
}

// errAccountBlocked is the account_blocked 403 from §6.1 with kind, until_unix and reason, plus
// the player-facing text composed by the platform (255 B at most).
func errAccountBlocked(kind string, until *time.Time, reason, message string) *httpx.Error {
	var untilUnix *int64
	if until != nil {
		v := until.Unix()
		untilUnix = &v
	}
	return &httpx.Error{Status: http.StatusForbidden, Code: "account_blocked",
		Message: sanctions.Truncate(message, sanctions.MaxTextBytes),
		Extra:   map[string]any{"kind": kind, "until_unix": untilUnix, "reason": reason}}
}

// ClaimResult is what the claim returns (§6): the lease, the account, the character, the
// progress section (ProgressStore.Load, in the same transaction) and the pvp totals.
type ClaimResult struct {
	LeaseID         [16]byte
	InstanceStatus  string
	AccountID       int64
	Role            string
	MutedUntilUnix  int64 // 0: not muted
	IgnoredAccounts []int64
	Warnings        []sanctions.Warning // warnings the account has not yet seen in the world (§9.5)
	CharacterID     int64
	WorldID         int16
	Realm           int16
	Name            string
	Progress        json.RawMessage
	PvP             PvP
}

// Claim is the claim (§5.3): in one transaction, with the lock order instance (for share: the
// lost-instances job and the heartbeat wait) → account → ticket → lease,
//
//  1. the instance must still be live (otherwise its 409);
//  2. lock the character's account row and check whether it is suspended, banned or has
//     deletion requested, without answering yet;
//  3. the character must be alive and belong to the instance's world (otherwise 409
//     ticket_invalid);
//  4. lock the ticket: it must be for this instance and this character, unused, unexpired (with
//     a 5 s margin) and from a non-revoked session (otherwise 409 ticket_invalid);
//  5. only now, with the account locked from step 2, 403 account_blocked (with the reason and
//     the date): without a valid ticket nobody learns anything about the account (§5.3);
//     otherwise, consume the ticket;
//  6. no other character of the account in the world with a live lease (409 character_busy);
//  7. take the lease if it is free or expired (expires_at ≤ now, the opposite of "live";
//     otherwise 409 character_busy), with a new lease_id, seq at 0 and no hash;
//  8. read progress with ProgressStore.Load and the pvp totals in the same transaction, and
//     from the account the mute, the ignored list and the warnings it has not yet seen (those
//     after the last world entry of any of its characters, sanctions.PendingWarnings; that
//     entry is recorded by the lease's first save, not by the claim).
//
// Any error rolls back the transaction: the ticket is not left consumed.
func (s *Store) Claim(ctx context.Context, instance [16]byte, ticketID, characterID int64) (*ClaimResult, error) {
	now := s.clock.Now()
	var res *ClaimResult
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		res = nil
		inst, err := zones.LoadInstance(ctx, tx, instance, true)
		if err != nil {
			return err
		}
		if inst == nil {
			return zones.ErrForbidden()
		}
		if e := inst.Check(zones.OpClaim); e != nil {
			return e
		}
		r := &ClaimResult{CharacterID: characterID, InstanceStatus: inst.Status}
		err = tx.QueryRow(ctx, `select account_id from characters where character_id = $1`, characterID).Scan(&r.AccountID)
		if errors.Is(err, pgx.ErrNoRows) {
			return errTicketInvalid()
		}
		if err != nil {
			return err
		}
		var status string
		var purgeAfter *time.Time
		if err := tx.QueryRow(ctx, `select status, purge_after, role from accounts where account_id = $1
			for no key update`, r.AccountID).Scan(&status, &purgeAfter, &r.Role); err != nil {
			return err
		}
		if status == "purged" {
			return errTicketInvalid()
		}
		restriction, err := sanctions.Active(ctx, tx, r.AccountID, now)
		if err != nil {
			return err
		}
		var alive bool
		var name *string
		err = tx.QueryRow(ctx, `select world_id, realm, name, deleted_at is null and purged_at is null from characters
			where character_id = $1`, characterID).Scan(&r.WorldID, &r.Realm, &name, &alive)
		if err != nil {
			return err
		}
		if !alive || name == nil || r.WorldID != inst.WorldID {
			return errTicketInvalid()
		}
		r.Name = *name
		var sessionID int64
		err = tx.QueryRow(ctx, `select t.session_id from enter_tickets t join sessions s on s.session_id = t.session_id
			where t.ticket_id = $1 and t.character_id = $2 and t.zone_instance_id = $3 and t.consumed_at is null
			  and t.expires_at > $4 and s.revoked_at is null
			for update of t`, ticketID, characterID, instance, now.Add(-ticketGrace)).Scan(&sessionID)
		if errors.Is(err, pgx.ErrNoRows) {
			return errTicketInvalid()
		}
		if err != nil {
			return err
		}
		// The reason and date of a sanction are seen only by whoever brings a valid ticket for that
		// character and this instance; the error rolls back the transaction and the ticket stays unused.
		switch {
		case restriction != nil:
			return errAccountBlocked(restriction.Kind, restriction.Until, restriction.Reason, restriction.Message())
		case status == "pending_deletion":
			return errAccountBlocked("pending_deletion", purgeAfter, "", sanctions.PendingDeletionMessage(purgeAfter))
		case status != "active":
			return errTicketInvalid()
		}
		if _, err := tx.Exec(ctx, `update enter_tickets set consumed_at = $2 where ticket_id = $1`, ticketID, now); err != nil {
			return err
		}
		var busy bool
		if err := tx.QueryRow(ctx, `select exists (select 1 from character_leases l join characters c using (character_id)
			where c.account_id = $1 and c.world_id = $2 and l.character_id <> $3
			  and l.zone_instance_id is not null and l.expires_at > $4)`,
			r.AccountID, r.WorldID, characterID, now).Scan(&busy); err != nil {
			return err
		}
		if busy {
			return errCharacterBusy()
		}
		err = tx.QueryRow(ctx, `insert into character_leases (character_id, world_id, lease_id, zone_instance_id,
				claimed_by, session_id, expires_at, claimed_at)
			values ($1, $2, $3, $4, $4, $5, $6, $7)
			on conflict (character_id) do update set lease_id = excluded.lease_id,
				zone_instance_id = excluded.zone_instance_id, claimed_by = excluded.claimed_by,
				session_id = excluded.session_id, expires_at = excluded.expires_at, last_seq = 0,
				last_save_hash = null, claimed_at = excluded.claimed_at, released_at = null
			where character_leases.zone_instance_id is null or character_leases.expires_at <= $7
			returning lease_id`, characterID, r.WorldID, zones.NewUUID(), instance, sessionID,
			now.Add(s.leaseTTL), now).Scan(&r.LeaseID)
		if errors.Is(err, pgx.ErrNoRows) {
			return errCharacterBusy()
		}
		if err != nil {
			return err
		}
		if r.Progress, err = s.progress.Load(ctx, tx, characterID); err != nil {
			return fmt.Errorf("persistence: progreso del personaje %d: %w", characterID, err)
		}
		err = tx.QueryRow(ctx, `select kills, deaths, assists, captures, gate_damage, defend_s from character_pvp_stats
			where character_id = $1`, characterID).Scan(&r.PvP.Kills, &r.PvP.Deaths, &r.PvP.Assists, &r.PvP.Captures,
			&r.PvP.GateDamage, &r.PvP.DefendS)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		mutes, err := sanctions.Mutes(ctx, tx, []int64{r.AccountID}, now)
		if err != nil {
			return err
		}
		r.MutedUntilUnix = mutes[r.AccountID]
		rows, err := tx.Query(ctx, `select ignored_account_id from ignores where account_id = $1
			order by ignored_account_id`, r.AccountID)
		if err != nil {
			return err
		}
		if r.IgnoredAccounts, err = pgx.CollectRows(rows, pgx.RowTo[int64]); err != nil {
			return err
		}
		var lastEntered *time.Time
		if err := tx.QueryRow(ctx, `select max(last_entered_at) from characters where account_id = $1 and world_id = $2`,
			r.AccountID, r.WorldID).Scan(&lastEntered); err != nil {
			return err
		}
		if r.Warnings, err = sanctions.PendingWarnings(ctx, tx, r.AccountID, r.WorldID, lastEntered, now); err != nil {
			return err
		}
		res = r
		return nil
	})
	if err != nil {
		return nil, err
	}
	s.log.Info("personaje reclamado", "character", characterID, "account", res.AccountID,
		"zone_instance", zones.FormatUUID(instance))
	return res, nil
}

// SaveRequest is the envelope of an already parsed save (§7.3).
type SaveRequest struct {
	CharacterID  int64
	InstanceID   [16]byte
	LeaseID      [16]byte
	Seq          int64
	Reason       int
	ReleaseLease bool
	Progress     json.RawMessage
	PvP          *PvP
}

// SaveResult is the response to a save: {applied, duplicate, save_version, instance_status}.
type SaveResult struct {
	CharacterID    int64  `json:"-"`
	Applied        bool   `json:"applied"`
	Duplicate      bool   `json:"duplicate"`
	SaveVersion    int64  `json:"save_version"`
	InstanceStatus string `json:"instance_status"`
}

// envelope is the envelope as it arrives; pvp is read separately to require its six totals.
type envelope struct {
	SaveFormat     *jsonx.Int      `json:"save_format"`
	CharacterID    *jsonx.ID       `json:"character_id"`
	ZoneInstanceID *string         `json:"zone_instance_id"`
	LeaseID        *string         `json:"lease_id"`
	Seq            *jsonx.Int      `json:"seq"`
	Reason         *jsonx.Int      `json:"reason"`
	ReleaseLease   *bool           `json:"release_lease"`
	Progress       json.RawMessage `json:"progress"`
	PvP            json.RawMessage `json:"pvp"`
}

func envelopeError(detail string) error { return &InvalidSaveError{Check: "envelope", Detail: detail} }

// maxPvPInt4 is the cap on the pvp totals that character_pvp_stats stores as int (int4): kills,
// deaths, assists, captures and defend_s; gate_damage is bigint (up to jsonx.Int's 2^53 − 1).
const maxPvPInt4 = math.MaxInt32

// ParseEnvelope reads the strict save envelope (§7.3) without touching the database: known keys,
// save_format 1, character_id equal to routeID, valid ids and seq (≥ 1), reason from 1 to 5,
// progress present and, if present, pvp with its six integer totals ≥ 0 that fit their column
// (the int4 ones, up to 2^31 − 1: otherwise pgx could not encode them and the response was a 500
// that the zone retried endlessly). Any failure is an *InvalidSaveError with Check "envelope".
// routeID 0 skips the comparison (a save inside a batch).
func ParseEnvelope(raw []byte, routeID int64) (SaveRequest, error) {
	var env envelope
	if err := jsonx.DecodeBytes(raw, &env); err != nil {
		return SaveRequest{}, envelopeError("el sobre no se entiende: " + err.Error())
	}
	var req SaveRequest
	switch {
	case env.SaveFormat == nil || *env.SaveFormat != SaveFormat:
		return req, envelopeError("save_format distinto de 1")
	case env.CharacterID == nil || *env.CharacterID < 1:
		return req, envelopeError("falta character_id")
	case routeID != 0 && int64(*env.CharacterID) != routeID:
		return req, envelopeError("character_id distinto del de la ruta")
	case env.ZoneInstanceID == nil:
		return req, envelopeError("falta zone_instance_id")
	case env.LeaseID == nil:
		return req, envelopeError("falta lease_id")
	case env.Seq == nil || *env.Seq < 1:
		return req, envelopeError("seq tiene que ser un entero desde 1")
	case env.Reason == nil || *env.Reason < 1 || *env.Reason > 5:
		return req, envelopeError("reason tiene que ser de 1 a 5")
	case len(env.Progress) == 0 || string(env.Progress) == "null":
		return req, envelopeError("falta la sección progress")
	}
	var ok bool
	if req.InstanceID, ok = zones.ParseUUID(*env.ZoneInstanceID); !ok {
		return req, envelopeError("zone_instance_id no es un UUID")
	}
	if req.LeaseID, ok = zones.ParseUUID(*env.LeaseID); !ok {
		return req, envelopeError("lease_id no es un UUID")
	}
	req.CharacterID = int64(*env.CharacterID)
	req.Seq = int64(*env.Seq)
	req.Reason = int(*env.Reason)
	req.ReleaseLease = env.ReleaseLease != nil && *env.ReleaseLease
	req.Progress = env.Progress
	if len(env.PvP) > 0 && string(env.PvP) != "null" {
		var fields map[string]json.RawMessage
		if err := jsonx.DecodeBytes(env.PvP, &fields); err != nil {
			return req, envelopeError("pvp no es un objeto")
		}
		var pvp PvP
		if err := jsonx.DecodeBytes(env.PvP, &pvp); err != nil {
			return req, envelopeError("pvp no vale: " + err.Error())
		}
		for _, k := range []string{"kills", "deaths", "assists", "captures", "gate_damage", "defend_s"} {
			if _, ok := fields[k]; !ok {
				return req, envelopeError("a pvp le falta " + k)
			}
		}
		for _, v := range []jsonx.Int{pvp.Kills, pvp.Deaths, pvp.Assists, pvp.Captures, pvp.GateDamage, pvp.DefendS} {
			if v < 0 {
				return req, envelopeError("un total de pvp es negativo")
			}
		}
		for _, v := range []jsonx.Int{pvp.Kills, pvp.Deaths, pvp.Assists, pvp.Captures, pvp.DefendS} {
			if v > maxPvPInt4 {
				return req, envelopeError("un total de pvp no cabe en su columna (2147483647 como mucho; gate_damage, más)")
			}
		}
		req.PvP = &pvp
	}
	return req, nil
}

// lease is the locked character_leases row of a save.
type lease struct {
	worldID     int16
	leaseID     [16]byte
	claimedBy   [16]byte
	lastSeq     int64
	lastHash    []byte
	lastVersion int64
	claimedAt   time.Time
}

func lockLeases(ctx context.Context, tx pgx.Tx, ids []int64) (map[int64]*lease, error) {
	rows, err := tx.Query(ctx, `select character_id, world_id, lease_id, claimed_by, last_seq, last_save_hash,
		last_save_version, claimed_at from character_leases where character_id = any($1) order by character_id for update`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]*lease{}
	for rows.Next() {
		var id int64
		l := &lease{}
		if err := rows.Scan(&id, &l.worldID, &l.leaseID, &l.claimedBy, &l.lastSeq, &l.lastHash, &l.lastVersion,
			&l.claimedAt); err != nil {
			return nil, err
		}
		out[id] = l
	}
	return out, rows.Err()
}

// seqState is what step 3 of §7.3 says about a save.
type seqState int

const (
	seqNew seqState = iota
	seqDuplicate
)

// checkLease performs steps 2 and 3 of §7.3: lease (lease_lost) and seq (duplicate,
// seq_conflict or stale_seq).
func checkLease(l *lease, req SaveRequest, hash []byte) (seqState, error) {
	if l == nil || l.leaseID != req.LeaseID || l.claimedBy != req.InstanceID {
		return 0, errLeaseLost()
	}
	switch {
	case req.Seq == l.lastSeq && bytes.Equal(hash, l.lastHash):
		return seqDuplicate, nil
	case req.Seq == l.lastSeq:
		return 0, errSeqConflict()
	case req.Seq < l.lastSeq:
		return 0, errStaleSeq()
	}
	return seqNew, nil
}

// apply performs step 4 of §7.3 for a new save: ProgressStore.Apply (S1–S8), the pvp totals
// with greatest, and the lease (last_seq, hash, last_save_version and, with release_lease, free).
// The lease's first save (last_seq 0) also records the world entry:
// characters.last_entered_at = the time of its claim. This way a warning (§9.5) counts as seen
// when the character reached the world, not when the zone claimed it and released it without
// letting it in.
func (s *Store) apply(ctx context.Context, tx pgx.Tx, inst *zones.Instance, l *lease, req SaveRequest, hash []byte,
	now time.Time) (int64, error) {
	key := SaveKey{WorldID: l.worldID, CharacterID: req.CharacterID, InstanceID: req.InstanceID, ZoneID: inst.ZoneID}
	version, err := s.progress.Apply(ctx, tx, key, req.Progress)
	if err != nil {
		return 0, err
	}
	if p := req.PvP; p != nil {
		if _, err := tx.Exec(ctx, `insert into character_pvp_stats as p (character_id, world_id, kills, deaths, assists,
				captures, gate_damage, defend_s, updated_at)
			values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
			on conflict (character_id) do update set kills = greatest(p.kills, excluded.kills),
				deaths = greatest(p.deaths, excluded.deaths), assists = greatest(p.assists, excluded.assists),
				captures = greatest(p.captures, excluded.captures),
				gate_damage = greatest(p.gate_damage, excluded.gate_damage),
				defend_s = greatest(p.defend_s, excluded.defend_s), updated_at = excluded.updated_at`,
			req.CharacterID, l.worldID, int64(p.Kills), int64(p.Deaths), int64(p.Assists), int64(p.Captures),
			int64(p.GateDamage), int64(p.DefendS), now); err != nil {
			return 0, err
		}
	}
	if l.lastSeq == 0 {
		if _, err := tx.Exec(ctx, `update characters set last_entered_at = greatest(last_entered_at, $2)
			where character_id = $1`, req.CharacterID, l.claimedAt); err != nil {
			return 0, err
		}
	}
	_, err = tx.Exec(ctx, `update character_leases set last_seq = $2, last_save_hash = $3, last_save_version = $4,
			zone_instance_id = case when $5 then null else zone_instance_id end,
			released_at = case when $5 and zone_instance_id is not null then $6 else released_at end
		where character_id = $1`, req.CharacterID, req.Seq, hash, version, req.ReleaseLease, now)
	return version, err
}

// Save is a character's save (§7.3). raw is the envelope's bytes as they arrived (their
// SHA-256 is the fingerprint of step 3) and req the envelope already parsed with
// [ParseEnvelope]. In one transaction: lock the lease; with no row, another lease_id or another
// claimed_by, 409 lease_lost; with the same seq and the same body, duplicate with the
// save_version from when it was applied (without calling Apply); with the same seq and another
// body, seq_conflict; with a lower one, stale_seq; otherwise, apply. If anything fails nothing
// is written; errors follow the rule of §7.3 ([SaveError]).
func (s *Store) Save(ctx context.Context, characterID int64, raw []byte, req SaveRequest) (SaveResult, error) {
	results, err := s.save(ctx, req.InstanceID, [][]byte{raw}, []SaveRequest{req})
	if err != nil {
		return SaveResult{}, err
	}
	return results[0], nil
}

// SaveMany saves several characters in one transaction (§6: trade and mail, phase 6): all or
// none. All envelopes belong to instance instance; either all are new or all are repeats (a
// mix is 409 seq_conflict). Leases are locked in character_id order.
func (s *Store) SaveMany(ctx context.Context, instance [16]byte, raws [][]byte, reqs []SaveRequest) ([]SaveResult, error) {
	return s.save(ctx, instance, raws, reqs)
}

func (s *Store) save(ctx context.Context, instance [16]byte, raws [][]byte, reqs []SaveRequest) ([]SaveResult, error) {
	if len(raws) != len(reqs) || len(reqs) == 0 {
		return nil, envelopeError("el lote no tiene guardados")
	}
	order := make([]int, len(reqs))
	ids := make([]int64, len(reqs))
	hashes := make([][]byte, len(reqs))
	for i, req := range reqs {
		if req.InstanceID != instance {
			return nil, envelopeError("zone_instance_id distinto del del lote")
		}
		if slices.Contains(ids[:i], req.CharacterID) {
			return nil, envelopeError("el personaje " + strconv.FormatInt(req.CharacterID, 10) + " va dos veces")
		}
		order[i], ids[i] = i, req.CharacterID
		sum := sha256.Sum256(raws[i])
		hashes[i] = sum[:]
	}
	sort.Slice(order, func(a, b int) bool { return reqs[order[a]].CharacterID < reqs[order[b]].CharacterID })
	var results []SaveResult
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		now := s.clock.Now()
		results = make([]SaveResult, len(reqs))
		leases, err := lockLeases(ctx, tx, ids)
		if err != nil {
			return err
		}
		inst, err := zones.LoadInstance(ctx, tx, instance, false)
		if err != nil {
			return err
		}
		if inst == nil {
			return zones.ErrForbidden()
		}
		states := make([]seqState, len(reqs))
		for _, i := range order {
			if states[i], err = checkLease(leases[reqs[i].CharacterID], reqs[i], hashes[i]); err != nil {
				return withCharacter(err, reqs[i].CharacterID, len(reqs) > 1)
			}
		}
		if slices.Contains(states, seqDuplicate) && slices.Contains(states, seqNew) {
			return errSeqConflict()
		}
		for _, i := range order {
			req, l := reqs[i], leases[reqs[i].CharacterID]
			results[i] = SaveResult{CharacterID: req.CharacterID, InstanceStatus: inst.Status}
			if states[i] == seqDuplicate {
				results[i].Duplicate, results[i].SaveVersion = true, l.lastVersion
				continue
			}
			version, err := s.apply(ctx, tx, inst, l, req, hashes[i], now)
			if err != nil {
				return withCharacter(err, req.CharacterID, len(reqs) > 1)
			}
			results[i].Applied, results[i].SaveVersion = true, version
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	for _, r := range results {
		if r.Applied {
			s.log.Debug("guardado aplicado", "character", r.CharacterID, "save_version", r.SaveVersion)
		}
	}
	return results, nil
}

// characterError is an error of a save within a batch, with the character in the body.
type characterError struct {
	err         error
	characterID int64
}

func (e *characterError) Error() string {
	return "personaje " + strconv.FormatInt(e.characterID, 10) + ": " + e.err.Error()
}

func (e *characterError) Unwrap() error { return e.err }

func withCharacter(err error, characterID int64, many bool) error {
	if !many {
		return err
	}
	return &characterError{err: err, characterID: characterID}
}

// SaveError converts a save error into its response using the rule of §7.3: the envelope error
// and *InvalidSaveError, 400 invalid_save with check and detail; SQLSTATE of class 22 or 23 or
// P0001 (also on COMMIT), 400 invalid_save with check S8 and the SQLSTATE and constraint in
// detail; 40001 and 40P01 after the retries, no connection or expired deadline, 503
// db_unavailable; an *httpx.Error, as is; any other, nil (500 internal, which the caller logs).
// In a batch, the body also carries the character_id of the save that failed.
func SaveError(err error) *httpx.Error {
	var resp *httpx.Error
	var invalid *InvalidSaveError
	switch {
	case errors.As(err, &resp):
		resp = cloneError(resp)
	case errors.As(err, &invalid):
		resp = invalidSave(invalid.Check, invalid.Detail)
	case db.Deterministic(err):
		detail := "SQLSTATE " + db.SQLState(err)
		if c := db.Constraint(err); c != "" {
			detail += " (" + c + ")"
		}
		resp = invalidSave("S8", detail)
	case db.Classify(err) == db.KindRetryable || db.Classify(err) == db.KindUnavailable:
		return zones.ErrDBUnavailable()
	default:
		return nil
	}
	var ce *characterError
	if errors.As(err, &ce) {
		if resp.Extra == nil {
			resp.Extra = map[string]any{}
		}
		resp.Extra["character_id"] = strconv.FormatInt(ce.characterID, 10)
	}
	return resp
}

func cloneError(e *httpx.Error) *httpx.Error {
	c := *e
	if e.Extra != nil {
		c.Extra = make(map[string]any, len(e.Extra))
		for k, v := range e.Extra {
			c.Extra[k] = v
		}
	}
	return &c
}

func invalidSave(check, detail string) *httpx.Error {
	return &httpx.Error{Status: http.StatusBadRequest, Code: "invalid_save", Message: "Guardado no válido",
		Fields: map[string]string{"check": check, "detail": sanctions.Truncate(detail, 500)}}
}

// Release frees the lease without saving (§6: the client never showed up, or after an
// invalid_save). With another lease_id or claimed_by, 409 lease_lost; one already free with the
// same lease_id, nothing (204).
func (s *Store) Release(ctx context.Context, characterID int64, instance, leaseID [16]byte) error {
	now := s.clock.Now()
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		leases, err := lockLeases(ctx, tx, []int64{characterID})
		if err != nil {
			return err
		}
		l := leases[characterID]
		if l == nil || l.leaseID != leaseID || l.claimedBy != instance {
			return errLeaseLost()
		}
		_, err = tx.Exec(ctx, `update character_leases set zone_instance_id = null, released_at = $2
			where character_id = $1 and zone_instance_id is not null`, characterID, now)
		return err
	})
}
