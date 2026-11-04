package accounts

import (
	"context"
	"encoding/hex"
	"strconv"
	"time"

	"eldmark/platform/internal/config"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/legal"
)

// AccountView is the account in JSON (GET /v1/account and the login response).
type AccountView struct {
	AccountID     jsonx.ID          `json:"account_id"`
	Email         string            `json:"email"`
	EmailVerified bool              `json:"email_verified"`
	Role          string            `json:"role"`
	Realms        map[string]string `json:"realms"` // world -> realm ("1" -> "vardheim")
	Slots         map[string]int    `json:"slots"`  // world -> character slots
	Consents      ConsentsView      `json:"consents"`
	Pending       PendingView       `json:"pending"`
	Restriction   *RestrictionView  `json:"restriction"`
}

// ConsentsView is the consents (§11.4).
type ConsentsView struct {
	CrashReports bool `json:"crash_reports"`
	Analytics    bool `json:"analytics"`
}

// PendingView is what the account has pending: texts to accept (and which) and the requested
// deletion (Unix date of the purge).
type PendingView struct {
	TermsRequired bool     `json:"terms_required"`
	Documents     []string `json:"documents"`
	DeletionAt    *int64   `json:"deletion_at"`
}

// accountView reads the account for the API.
func (s *Service) accountView(ctx context.Context, q querier, accountID int64, now time.Time) (*AccountView, error) {
	v := &AccountView{AccountID: jsonx.ID(accountID), Realms: map[string]string{}, Slots: map[string]int{},
		Pending: PendingView{Documents: []string{}}}
	var purgeAfter *time.Time
	var status string
	if err := q.QueryRow(ctx, `select email, email_verified_at is not null, role, status, purge_after
		from accounts where account_id = $1`, accountID).Scan(&v.Email, &v.EmailVerified, &v.Role, &status, &purgeAfter); err != nil {
		return nil, err
	}
	if status == "pending_deletion" {
		v.Pending.DeletionAt = unix(purgeAfter)
	}
	rows, err := q.Query(ctx, `select world_id, realm from account_realms where account_id = $1`, accountID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var world, realm int16
		if err := rows.Scan(&world, &realm); err != nil {
			rows.Close()
			return nil, err
		}
		v.Realms[strconv.Itoa(int(world))] = config.Realm(realm).String()
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	slots, err := s.Slots(ctx, q, accountID, now)
	if err != nil {
		return nil, err
	}
	for world, n := range slots {
		v.Slots[strconv.Itoa(int(world))] = n
	}
	rows, err = q.Query(ctx, `select purpose, granted from consents where account_id = $1`, accountID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var purpose string
		var granted bool
		if err := rows.Scan(&purpose, &granted); err != nil {
			rows.Close()
			return nil, err
		}
		switch purpose {
		case "crash_reports":
			v.Consents.CrashReports = granted
		case "analytics":
			v.Consents.Analytics = granted
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	missing, err := s.MissingAcceptances(ctx, q, accountID)
	if err != nil {
		return nil, err
	}
	v.Pending.Documents = missing
	v.Pending.TermsRequired = len(missing) > 0
	restriction, err := ActiveRestriction(ctx, q, accountID, now)
	if err != nil {
		return nil, err
	}
	v.Restriction = restriction.view()
	return v, nil
}

// Slots returns the account's character slots in each world: 6 plus the quantity of its valid
// character_slots entitlements for that world or for all of them (§4.4, §11.3).
func (s *Service) Slots(ctx context.Context, q querier, accountID int64, now time.Time) (map[int16]int, error) {
	rows, err := q.Query(ctx, `select w.world_id, coalesce(sum(e.quantity), 0)::int
		from worlds w left join entitlements e on e.account_id = $1 and e.kind = 'character_slots'
		  and e.revoked_at is null and (e.expires_at is null or e.expires_at > $2)
		  and (e.world_id is null or e.world_id = w.world_id)
		group by w.world_id`, accountID, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int16]int{}
	for rows.Next() {
		var world int16
		var extra int
		if err := rows.Scan(&world, &extra); err != nil {
			return nil, err
		}
		out[world] = BaseSlots + extra
	}
	return out, rows.Err()
}

// MissingAcceptances returns the text kinds whose current version the account has not accepted, in
// the order of legal.Kinds (§4.2: with one, enter answers terms_required).
func (s *Service) MissingAcceptances(ctx context.Context, q querier, accountID int64) ([]string, error) {
	rows, err := q.Query(ctx, `select kind, max(version) from legal_acceptances where account_id = $1 group by kind`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	accepted := map[string]int{}
	for rows.Next() {
		var kind string
		var version int
		if err := rows.Scan(&kind, &version); err != nil {
			return nil, err
		}
		accepted[kind] = version
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	missing := []string{}
	for _, kind := range legal.Kinds {
		if accepted[kind] < s.legal.Current(kind).Version {
			missing = append(missing, kind)
		}
	}
	return missing, nil
}

// Account returns the session's account.
func (s *Service) Account(ctx context.Context, sess *Session) (*AccountView, error) {
	return s.accountView(ctx, s.pool, sess.AccountID, s.clock.Now())
}

// LegalVersions are the versions of the three texts in a body ({terms, privacy, rules}).
type LegalVersions struct {
	Terms   *jsonx.Int `json:"terms"`
	Privacy *jsonx.Int `json:"privacy"`
	Rules   *jsonx.Int `json:"rules"`
}

func (l LegalVersions) byKind() map[string]*jsonx.Int {
	return map[string]*jsonx.Int{"terms": l.Terms, "privacy": l.Privacy, "rules": l.Rules}
}

// checkVersions requires the current versions of the three texts; prefix precedes the fields key
// ("accept." in registration).
func (s *Service) checkVersions(l LegalVersions, prefix string, fields map[string]string) {
	for kind, v := range l.byKind() {
		switch {
		case v == nil:
			fields[prefix+kind] = "required"
		case int(*v) != s.legal.Current(kind).Version:
			fields[prefix+kind] = "outdated"
		}
	}
}

// Accept records that the account accepts the current versions of the texts.
func (s *Service) Accept(ctx context.Context, sess *Session, l LegalVersions) error {
	fields := map[string]string{}
	s.checkVersions(l, "", fields)
	if len(fields) > 0 {
		return errValidation(fields)
	}
	now := s.clock.Now()
	for _, kind := range legal.Kinds {
		if _, err := s.pool.Exec(ctx, `insert into legal_acceptances (account_id, kind, version, accepted_at)
			values ($1, $2, $3, $4) on conflict do nothing`, sess.AccountID, kind, s.legal.Current(kind).Version, now); err != nil {
			return err
		}
	}
	return nil
}

// Consents are the consents of a body; both are required.
type Consents struct {
	CrashReports *bool `json:"crash_reports"`
	Analytics    *bool `json:"analytics"`
}

func (c Consents) check(prefix string, fields map[string]string) {
	if c.CrashReports == nil {
		fields[prefix+"crash_reports"] = "required"
	}
	if c.Analytics == nil {
		fields[prefix+"analytics"] = "required"
	}
}

func saveConsents(ctx context.Context, q execer, accountID int64, c Consents, now time.Time) error {
	for purpose, granted := range map[string]bool{"crash_reports": *c.CrashReports, "analytics": *c.Analytics} {
		if _, err := q.Exec(ctx, `insert into consents (account_id, purpose, granted, updated_at) values ($1, $2, $3, $4)
			on conflict (account_id, purpose) do update set granted = excluded.granted, updated_at = excluded.updated_at`,
			accountID, purpose, granted, now); err != nil {
			return err
		}
	}
	return nil
}

// PutConsents changes the consents (Settings).
func (s *Service) PutConsents(ctx context.Context, sess *Session, c Consents) error {
	fields := map[string]string{}
	c.check("", fields)
	if len(fields) > 0 {
		return errValidation(fields)
	}
	return saveConsents(ctx, s.pool, sess.AccountID, c, s.clock.Now())
}

// LegalIndex is GET /v1/legal: the current version of each text and its SHA-256 in hexadecimal.
func (s *Service) LegalIndex() map[string]any {
	out := map[string]any{}
	for _, kind := range legal.Kinds {
		d := s.legal.Current(kind)
		out[kind] = map[string]any{"version": d.Version, "sha256": hex.EncodeToString(d.SHA256[:])}
	}
	return out
}

// LegalText returns the current text of a kind, or nil.
func (s *Service) LegalText(kind string) *legal.Document { return s.legal.Current(kind) }

// StatusView is GET /v1/status.
type StatusView struct {
	Status        string      `json:"status"` // ok or maintenance
	Message       string      `json:"message"`
	MaintenanceAt *int64      `json:"maintenance_at"`
	MinProtocol   int         `json:"min_protocol"`
	Worlds        []WorldView `json:"worlds"`
	News          []NewsView  `json:"news"`
}

// WorldView is a world in /v1/status.
type WorldView struct {
	WorldID int16  `json:"world_id"`
	Name    string `json:"name"`
	Status  string `json:"status"`
	Load    string `json:"load"` // low, medium or high
}

// NewsView is a news item in /v1/status.
type NewsView struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	Date  int64  `json:"date"`
}

// Status is the public status: worlds with their load (players of the live instances against their
// cap). In phase 5 there are no news items or scheduled-maintenance announcement yet (the admin
// command maintenance is from TEC-28): status is maintenance if any world is.
func (s *Service) Status(ctx context.Context) (*StatusView, error) {
	rows, err := s.pool.Query(ctx, `select w.world_id, w.name, w.status,
		coalesce((select sum(z.players)::float8 / nullif(sum(z.max_players), 0) from zone_instances z
		          where z.world_id = w.world_id and z.status = 'live'), 0)
		from worlds w order by w.world_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	v := &StatusView{Status: "ok", MinProtocol: s.minProtocol, Worlds: []WorldView{}, News: []NewsView{}}
	for rows.Next() {
		var w WorldView
		var load float64
		if err := rows.Scan(&w.WorldID, &w.Name, &w.Status, &load); err != nil {
			return nil, err
		}
		switch {
		case load < 0.5:
			w.Load = "low"
		case load < 0.8:
			w.Load = "medium"
		default:
			w.Load = "high"
		}
		if w.Status == "maintenance" {
			v.Status = "maintenance"
		}
		v.Worlds = append(v.Worlds, w)
	}
	return v, rows.Err()
}
