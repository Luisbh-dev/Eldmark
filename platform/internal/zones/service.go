package zones

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"log/slog"
	"net/netip"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"eldmark/platform/internal/clock"
	"eldmark/platform/internal/config"
	"eldmark/platform/internal/db"
	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/logx"
	"eldmark/platform/internal/sanctions"
)

// Progress record formats that this platform admits (record_format, §7.1).
var supportedRecordFormats = []int64{1}

// LostAfter is how many heartbeats can be missed before an instance is considered lost (§5.3).
const LostAfter = config.LostAfterHeartbeats

// Registration caps.
const (
	maxPlayersLimit = 1000
	maxBuildID      = 64
	maxDTLSName     = 253
	maxCertPEM      = 16 << 10
	maxHeartbeat    = 4 * maxPlayersLimit // characters in a heartbeat
)

var (
	zoneIDPattern  = regexp.MustCompile(`^[a-z0-9_]{1,64}$`)
	buildIDPattern = regexp.MustCompile(`^[\x21-\x7e]{1,64}$`)
)

// Options are the service's dependencies.
type Options struct {
	Config *config.Config
	Pool   *pgxpool.Pool
	Log    *slog.Logger
	Clock  clock.Clock // defaults to the system clock
	// MinProtocol is the clients' minimum protocol: a zone with a lower protocol_version does not
	// register (409 schema_mismatch), because those clients could not enter it.
	MinProtocol int
}

// Service is the zone instances service.
type Service struct {
	cfg         *config.Config
	pool        *pgxpool.Pool
	log         *slog.Logger
	clock       clock.Clock
	guard       *Guard
	minProtocol int
}

// New prepares the service.
func New(o Options) (*Service, error) {
	if o.Config == nil || o.Pool == nil {
		return nil, errors.New("zones: faltan dependencias")
	}
	if o.Log == nil {
		o.Log = logx.Discard()
	}
	if o.Clock == nil {
		o.Clock = clock.System{}
	}
	return &Service{cfg: o.Config, pool: o.Pool, log: o.Log, clock: o.Clock, minProtocol: o.MinProtocol,
		guard: NewGuard(NewRegistry(o.Config.ZoneTokens), o.Pool, o.Log)}, nil
}

// Guard returns the internal API's common checks, for the other packages.
func (s *Service) Guard() *Guard { return s.guard }

// LostEvery is how often the lost-instances job runs: min(5 s, HEARTBEAT_S) (§2.5).
func (s *Service) LostEvery() time.Duration { return s.cfg.LostEvery() }

// lostCutoff is the time before which the last heartbeat makes an instance count as lost.
func (s *Service) lostCutoff(now time.Time) time.Time { return now.Add(-LostAfter * s.cfg.Heartbeat) }

// RegisterRequest is the body of POST /internal/v1/zone-instances.
type RegisterRequest struct {
	WorldID         jsonx.Int   `json:"world_id"`
	ZoneID          string      `json:"zone_id"`
	Channel         jsonx.Int   `json:"channel"`
	PublicHost      string      `json:"public_host"`
	PublicPort      jsonx.Int   `json:"public_port"`
	Realms          []jsonx.Int `json:"realms"`
	BuildID         string      `json:"build_id"`
	ProtocolVersion jsonx.Int   `json:"protocol_version"`
	RecordFormat    jsonx.Int   `json:"record_format"`
	MaxPlayers      jsonx.Int   `json:"max_players"`
	DTLSCertPEM     *string     `json:"dtls_cert_pem"`
	DTLSName        *string     `json:"dtls_name"`
	Replace         bool        `json:"replace"`
}

// RegisterResult is the registration response.
type RegisterResult struct {
	ZoneInstanceID string `json:"zone_instance_id"`
	Env            string `json:"env"`
	HeartbeatS     int    `json:"heartbeat_s"`
	LeaseTTLS      int    `json:"lease_ttl_s"`
	NowUnix        int64  `json:"now_unix"`
}

func (s *Service) hostAllowed(host string) bool {
	for _, h := range s.cfg.ZoneHosts {
		if strings.EqualFold(h, host) {
			return true
		}
		if a, err := netip.ParseAddr(h); err == nil {
			if b, err := netip.ParseAddr(host); err == nil && a == b {
				return true
			}
		}
	}
	return false
}

// validCert says whether pem is an X.509 certificate in PEM format.
func validCert(data string) bool {
	if len(data) > maxCertPEM {
		return false
	}
	block, _ := pem.Decode([]byte(data))
	if block == nil || block.Type != "CERTIFICATE" {
		return false
	}
	_, err := x509.ParseCertificate(block.Bytes)
	return err == nil
}

// Register registers a new instance in starting (§5.3, §6, §8). It checks, in order: the token's
// scope and the public_host (403 forbidden), the fields (400 validation; in staging and
// production, the DTLS certificate is mandatory), the record_format and the protocol (409
// schema_mismatch). Then, in a transaction, it looks at the instance occupying that world, zone
// and channel: if it sent a heartbeat less than 3 × HEARTBEAT_S ago, 409 instance_alive unless
// with replace, which moves it to replaced (without releasing its leases: its final saves or the
// TTL release them) and leaves a row in audit_log; otherwise, it moves it to lost and releases
// its leases, like the lost-instances job.
func (s *Service) Register(ctx context.Context, scope Scope, req RegisterRequest) (*RegisterResult, error) {
	if int64(req.WorldID) != int64(scope.WorldID) || req.ZoneID != scope.ZoneID || int64(req.Channel) != int64(scope.Channel) {
		return nil, ErrForbidden()
	}
	if !s.hostAllowed(req.PublicHost) {
		return nil, ErrForbidden()
	}
	fields := map[string]string{}
	if !zoneIDPattern.MatchString(req.ZoneID) {
		fields["zone_id"] = "invalid"
	}
	if req.PublicPort < 1 || req.PublicPort > 65535 {
		fields["public_port"] = "invalid"
	}
	if len(req.Realms) == 0 || len(req.Realms) > 3 {
		fields["realms"] = "invalid"
	}
	realms := make([]int16, 0, len(req.Realms))
	for _, r := range req.Realms {
		if r < 1 || r > 3 || slices.Contains(realms, int16(r)) {
			fields["realms"] = "invalid"
			break
		}
		realms = append(realms, int16(r))
	}
	if !buildIDPattern.MatchString(req.BuildID) {
		fields["build_id"] = "invalid"
	}
	if req.ProtocolVersion < 1 || req.ProtocolVersion > 65535 {
		fields["protocol_version"] = "invalid"
	}
	if req.RecordFormat < 1 || req.RecordFormat > 32767 {
		fields["record_format"] = "invalid"
	}
	if req.MaxPlayers < 1 || req.MaxPlayers > maxPlayersLimit {
		fields["max_players"] = "invalid"
	}
	var certPEM, dtlsName *string
	if req.DTLSCertPEM != nil && *req.DTLSCertPEM != "" {
		if !validCert(*req.DTLSCertPEM) {
			fields["dtls_cert_pem"] = "invalid"
		}
		if req.DTLSName == nil || *req.DTLSName == "" || len(*req.DTLSName) > maxDTLSName {
			fields["dtls_name"] = "required"
		}
		certPEM, dtlsName = req.DTLSCertPEM, req.DTLSName
	} else if s.cfg.Env.Deployed() {
		// Without DTLS there are no public tests (§0, §10.2): in staging and production it is mandatory.
		fields["dtls_cert_pem"] = "required"
	}
	if len(fields) > 0 {
		return nil, Validation(fields)
	}
	if !slices.Contains(supportedRecordFormats, int64(req.RecordFormat)) || int(req.ProtocolVersion) < s.minProtocol {
		return nil, Conflict("schema_mismatch", "Esta plataforma no admite la versión de la zona")
	}

	now := s.clock.Now()
	id := NewUUID()
	var replaced, lost [][16]byte
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		replaced, lost = nil, nil
		rows, err := tx.Query(ctx, `select zone_instance_id, last_heartbeat_at from zone_instances
			where world_id = $1 and zone_id = $2 and channel = $3 and status in ('starting', 'live') for update`,
			scope.WorldID, scope.ZoneID, scope.Channel)
		if err != nil {
			return err
		}
		type old struct {
			id   [16]byte
			beat time.Time
		}
		olds, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (old, error) {
			var o old
			err := r.Scan(&o.id, &o.beat)
			return o, err
		})
		if err != nil {
			return err
		}
		for _, o := range olds {
			if o.beat.After(s.lostCutoff(now)) {
				if !req.Replace {
					return Conflict("instance_alive", "Hay otra instancia viva de esa zona y canal")
				}
				replaced = append(replaced, o.id)
			} else {
				lost = append(lost, o.id)
			}
		}
		if len(replaced) > 0 {
			if _, err := tx.Exec(ctx, `update zone_instances set status = 'replaced', ended_at = $2
				where zone_instance_id = any($1)`, replaced, now); err != nil {
				return err
			}
			for _, old := range replaced {
				args, _ := json.Marshal(map[string]any{"replaced": FormatUUID(old), "by": FormatUUID(id),
					"channel": scope.Channel})
				if _, err := tx.Exec(ctx, `insert into audit_log (world_id, source, zone_id, command, args, at)
					values ($1, 'platform', $2, 'zone_replace', $3, $4)`, scope.WorldID, scope.ZoneID, args, now); err != nil {
					return err
				}
			}
		}
		if len(lost) > 0 {
			if err := markLost(ctx, tx, lost, now); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `insert into zone_instances (zone_instance_id, world_id, zone_id, channel, public_host,
			public_port, realms, build_id, protocol_version, record_format, dtls_cert_pem, dtls_name, max_players,
			players, status, started_at, last_heartbeat_at)
			values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 0, 'starting', $14, $14)`,
			id, scope.WorldID, scope.ZoneID, scope.Channel, req.PublicHost, int(req.PublicPort), realms, req.BuildID,
			int(req.ProtocolVersion), int16(req.RecordFormat), certPEM, dtlsName, int(req.MaxPlayers), now)
		return err
	})
	if err != nil {
		if db.Constraint(err) == "zone_instances_world_id_zone_id_channel_idx" || db.SQLState(err) == "23505" {
			// Another instance of the same scope registered at the same time: the first one wins.
			return nil, Conflict("instance_alive", "Hay otra instancia viva de esa zona y canal")
		}
		return nil, err
	}
	for _, old := range replaced {
		s.log.Warn("instancia sustituida", "zone_instance", FormatUUID(old), "by", FormatUUID(id), "zone", scope.ZoneID,
			"channel", scope.Channel)
	}
	for _, old := range lost {
		s.log.Warn("instancia sin latido dada por perdida al registrar otra", "zone_instance", FormatUUID(old),
			"by", FormatUUID(id), "zone", scope.ZoneID, "channel", scope.Channel)
	}
	s.log.Info("instancia registrada", "zone_instance", FormatUUID(id), "world", scope.WorldID, "zone", scope.ZoneID,
		"channel", scope.Channel, "build", req.BuildID, "dtls", certPEM != nil)
	return &RegisterResult{ZoneInstanceID: FormatUUID(id), Env: string(s.cfg.Env),
		HeartbeatS: int(s.cfg.Heartbeat / time.Second), LeaseTTLS: int(s.cfg.LeaseTTL / time.Second),
		NowUnix: now.Unix()}, nil
}

// markLost moves the instances to lost and releases their leases (zone_instance_id = null;
// lease_id and claimed_by stay, §5.3).
func markLost(ctx context.Context, tx pgx.Tx, ids [][16]byte, now time.Time) error {
	if _, err := tx.Exec(ctx, `update zone_instances set status = 'lost', ended_at = $2 where zone_instance_id = any($1)`,
		ids, now); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `update character_leases set zone_instance_id = null, released_at = $2
		where zone_instance_id = any($1)`, ids, now)
	return err
}

// Live moves the instance from starting to live (enter already offers it). Repeated with live,
// nothing; with another state, its 409.
func (s *Service) Live(ctx context.Context, inst *Instance) error {
	now := s.clock.Now()
	var status string
	err := s.pool.QueryRow(ctx, `update zone_instances set status = 'live', live_at = coalesce(live_at, $2)
		where zone_instance_id = $1 and status in ('starting', 'live') returning status`, inst.ID, now).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		cur, err := LoadInstance(ctx, s.pool, inst.ID, false)
		if err != nil {
			return err
		}
		if cur == nil {
			return ErrForbidden()
		}
		return StatusError(cur.Status)
	}
	if err != nil {
		return err
	}
	if inst.Status == StatusStarting {
		s.log.Info("instancia en marcha", "zone_instance", inst.IDString(), "zone", inst.ZoneID, "channel", inst.Channel)
	}
	return nil
}

// Stop is an instance's deregistration (DELETE): starting or live move to stopped and their
// leases are left free. A replaced one that leaves releases any it has left (it already sent its
// final saves) and stays replaced; a stopped one, nothing; a lost one, 409 instance_lost (its
// leases are already free).
func (s *Service) Stop(ctx context.Context, inst *Instance) error {
	now := s.clock.Now()
	return db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		var status string
		err := tx.QueryRow(ctx, `select status from zone_instances where zone_instance_id = $1 for update`, inst.ID).
			Scan(&status)
		if err != nil {
			return err
		}
		switch status {
		case StatusLost:
			return StatusError(status)
		case StatusStopped:
			return nil
		case StatusStarting, StatusLive:
			if _, err := tx.Exec(ctx, `update zone_instances set status = 'stopped', ended_at = $2
				where zone_instance_id = $1`, inst.ID, now); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `update character_leases set zone_instance_id = null, released_at = $2
			where zone_instance_id = $1`, inst.ID, now)
		if err == nil {
			s.log.Info("instancia dada de baja", "zone_instance", inst.IDString(), "zone", inst.ZoneID, "status", status)
		}
		return err
	})
}

// MarkLost is the lost-instances job (§2.5, §5.3): the starting or live ones that have gone 3 ×
// HEARTBEAT_S without a heartbeat move to lost and their leases are left free.
func (s *Service) MarkLost(ctx context.Context) error {
	now := s.clock.Now()
	type gone struct {
		id      [16]byte
		zone    string
		channel int16
	}
	var lost []gone
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `select zone_instance_id, zone_id, channel from zone_instances
			where status in ('starting', 'live') and last_heartbeat_at <= $1 for update skip locked`, s.lostCutoff(now))
		if err != nil {
			return err
		}
		lost, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (gone, error) {
			var g gone
			err := r.Scan(&g.id, &g.zone, &g.channel)
			return g, err
		})
		if err != nil || len(lost) == 0 {
			return err
		}
		ids := make([][16]byte, len(lost))
		for i, g := range lost {
			ids[i] = g.id
		}
		return markLost(ctx, tx, ids, now)
	})
	if err != nil {
		return err
	}
	for _, g := range lost {
		s.log.Warn("instancia perdida: sin latido", "zone_instance", FormatUUID(g.id), "zone", g.zone, "channel", g.channel)
	}
	return nil
}

// IDBlock gives the instance a block of 1024 ids (§6, progresion.md §4.5): nextval of
// uid_block_seq and a row in id_blocks. It returns the first one.
func (s *Service) IDBlock(ctx context.Context, inst *Instance) (int64, error) {
	var first int64
	err := s.pool.QueryRow(ctx, `insert into id_blocks (first_id, zone_instance_id, granted_at)
		values (nextval('uid_block_seq'), $1, $2) returning first_id`, inst.ID, s.clock.Now()).Scan(&first)
	return first, err
}

// HeartbeatRequest is the heartbeat body: the players and the set of leases that the zone
// maintains (§5.3).
type HeartbeatRequest struct {
	Players    jsonx.Int            `json:"players"`
	Characters []HeartbeatCharacter `json:"characters"`
}

// HeartbeatCharacter is a character in the heartbeat with its lease.
type HeartbeatCharacter struct {
	CharacterID jsonx.ID `json:"character_id"`
	LeaseID     string   `json:"lease_id"`
}

// Revoked is a character that the zone must remove (§6): reason lease_lost, session_revoked,
// suspended, banned or pending_deletion, with the player-facing text.
type Revoked struct {
	CharacterID jsonx.ID `json:"character_id"`
	LeaseID     string   `json:"lease_id"`
	Reason      string   `json:"reason"`
	Text        string   `json:"text"`
}

// Mute is an active mute of an account with a character in the instance.
type Mute struct {
	AccountID jsonx.ID `json:"account_id"`
	UntilUnix int64    `json:"until_unix"`
}

// Maintenance is the announced maintenance (TEC-28).
type Maintenance struct {
	AtUnix  int64  `json:"at_unix"`
	Message string `json:"message"`
}

// HeartbeatResult is the heartbeat response.
type HeartbeatResult struct {
	NowUnix     int64        `json:"now_unix"`
	Revoked     []Revoked    `json:"revoked"`
	Mutes       []Mute       `json:"mutes"`
	Maintenance *Maintenance `json:"maintenance"`
}

// Texts for revoked.
const (
	textLeaseLost      = "Tu personaje ha entrado en otro servidor"
	textReplaced       = "Has iniciado sesión desde otro lugar"
	textLoggedOut      = "Has cerrado la sesión"
	textAdmin          = "Un administrador ha cerrado tu sesión"
	textAccountChanged = "Tu cuenta ha cambiado: vuelve a entrar"
)

func sessionText(reason *string) string {
	if reason == nil {
		return textAccountChanged
	}
	switch *reason {
	case "replaced":
		return textReplaced
	case "logout":
		return textLoggedOut
	case "admin":
		return textAdmin
	}
	return textAccountChanged
}

// Heartbeat is the heartbeat (§5.3, §6): it records the time and the players, renews the leases
// in the set that match a live lease of this instance (character_id, lease_id and expires_at >
// now: an expired one is already treated as free by the claim, enter and deletion, and renewing
// it would leave two characters of the account in the world or a deleted one inside) and returns
// in revoked those that do not match (lease_lost, with the heartbeat's lease_id) and the renewed
// ones whose account is suspended, banned or has deletion requested, or whose session is revoked
// (with the lease's lease_id); in mutes, the active mutes of their accounts. An instance that is
// no longer in starting or live gets its 409.
func (s *Service) Heartbeat(ctx context.Context, inst *Instance, req HeartbeatRequest) (*HeartbeatResult, error) {
	if req.Players < 0 || req.Players > maxPlayersLimit {
		return nil, Validation(map[string]string{"players": "invalid"})
	}
	if len(req.Characters) > maxHeartbeat {
		return nil, Validation(map[string]string{"characters": "too_many"})
	}
	charIDs := make([]int64, 0, len(req.Characters))
	leaseIDs := make([][16]byte, 0, len(req.Characters))
	for _, c := range req.Characters {
		lease, ok := ParseUUID(c.LeaseID)
		if !ok || c.CharacterID < 1 {
			return nil, Validation(map[string]string{"characters": "invalid"})
		}
		charIDs = append(charIDs, int64(c.CharacterID))
		leaseIDs = append(leaseIDs, lease)
	}
	now := s.clock.Now()
	res := &HeartbeatResult{NowUnix: now.Unix(), Revoked: []Revoked{}, Mutes: []Mute{}}
	err := db.InTx(ctx, s.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		res.Revoked, res.Mutes = []Revoked{}, []Mute{}
		var status string
		err := tx.QueryRow(ctx, `update zone_instances set last_heartbeat_at = $2, players = $3
			where zone_instance_id = $1 and status in ('starting', 'live') returning status`,
			inst.ID, now, int(req.Players)).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) {
			cur, err := LoadInstance(ctx, tx, inst.ID, false)
			if err != nil {
				return err
			}
			if cur == nil {
				return ErrForbidden()
			}
			return StatusError(cur.Status)
		}
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `update character_leases l set expires_at = $4
			from unnest($2::bigint[], $3::uuid[]) as h(character_id, lease_id)
			where l.character_id = h.character_id and l.lease_id = h.lease_id and l.zone_instance_id = $1
			  and l.expires_at > $5
			returning l.character_id`, inst.ID, charIDs, leaseIDs, now.Add(s.cfg.LeaseTTL), now)
		if err != nil {
			return err
		}
		renewedIDs, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		renewed := map[int64]bool{}
		for _, id := range renewedIDs {
			renewed[id] = true
		}
		seen := map[int64]bool{}
		for i, id := range charIDs {
			if !renewed[id] && !seen[id] {
				res.Revoked = append(res.Revoked, Revoked{CharacterID: jsonx.ID(id), LeaseID: FormatUUID(leaseIDs[i]),
					Reason: "lease_lost", Text: textLeaseLost})
			}
			seen[id] = true
		}
		if len(renewedIDs) == 0 {
			return nil
		}
		return s.accountState(ctx, tx, renewedIDs, now, res)
	})
	if err != nil {
		return nil, err
	}
	for _, r := range res.Revoked {
		s.log.Info("latido: personaje fuera", "zone_instance", inst.IDString(), "character", int64(r.CharacterID),
			"reason", r.Reason)
	}
	return res, nil
}

// accountState adds to the heartbeat response the removals due to the account or session and the
// mutes of the renewed characters.
func (s *Service) accountState(ctx context.Context, tx pgx.Tx, ids []int64, now time.Time, res *HeartbeatResult) error {
	rows, err := tx.Query(ctx, `select l.character_id, l.lease_id, c.account_id, a.status, a.purge_after,
			s.revoked_at is not null, s.revoke_reason
		from character_leases l join characters c using (character_id) join accounts a on a.account_id = c.account_id
		left join sessions s on s.session_id = l.session_id
		where l.character_id = any($1) order by l.character_id`, ids)
	if err != nil {
		return err
	}
	type state struct {
		character, account int64
		lease              [16]byte
		status             string
		purgeAfter         *time.Time
		revoked            bool
		reason             *string
	}
	states, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (state, error) {
		var st state
		err := r.Scan(&st.character, &st.lease, &st.account, &st.status, &st.purgeAfter, &st.revoked, &st.reason)
		return st, err
	})
	if err != nil {
		return err
	}
	accounts := make([]int64, 0, len(states))
	for _, st := range states {
		if !slices.Contains(accounts, st.account) {
			accounts = append(accounts, st.account)
		}
	}
	restrictions, err := sanctions.ActiveMany(ctx, tx, accounts, now)
	if err != nil {
		return err
	}
	for _, st := range states {
		rev := Revoked{CharacterID: jsonx.ID(st.character), LeaseID: FormatUUID(st.lease)}
		switch r := restrictions[st.account]; {
		case r != nil && r.Kind == sanctions.KindBan:
			rev.Reason, rev.Text = "banned", r.Message()
		case r != nil:
			rev.Reason, rev.Text = "suspended", r.Message()
		case st.status == "pending_deletion":
			rev.Reason, rev.Text = "pending_deletion", sanctions.PendingDeletionMessage(st.purgeAfter)
		case st.revoked:
			rev.Reason, rev.Text = "session_revoked", sessionText(st.reason)
		default:
			continue
		}
		res.Revoked = append(res.Revoked, rev)
	}
	mutes, err := sanctions.Mutes(ctx, tx, accounts, now)
	if err != nil {
		return err
	}
	for _, id := range accounts {
		if until, ok := mutes[id]; ok {
			res.Mutes = append(res.Mutes, Mute{AccountID: jsonx.ID(id), UntilUnix: until})
		}
	}
	return nil
}
