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

// Formatos del registro de progreso que admite esta plataforma (record_format, §7.1).
var supportedRecordFormats = []int64{1}

// LostAfter es cuántos latidos se pueden perder antes de dar una instancia por perdida (§5.3).
const LostAfter = 3

// Topes del registro.
const (
	maxPlayersLimit = 1000
	maxBuildID      = 64
	maxDTLSName     = 253
	maxCertPEM      = 16 << 10
	maxHeartbeat    = 4 * maxPlayersLimit // personajes en un latido
)

var (
	zoneIDPattern  = regexp.MustCompile(`^[a-z0-9_]{1,64}$`)
	buildIDPattern = regexp.MustCompile(`^[\x21-\x7e]{1,64}$`)
)

// Options son las dependencias del servicio.
type Options struct {
	Config *config.Config
	Pool   *pgxpool.Pool
	Log    *slog.Logger
	Clock  clock.Clock // por defecto, el del sistema
	// MinProtocol es el protocolo mínimo de los clientes: una zona con un protocol_version menor no
	// se registra (409 schema_mismatch), porque esos clientes no podrían entrar en ella.
	MinProtocol int
}

// Service es el servicio de las instancias de zona.
type Service struct {
	cfg         *config.Config
	pool        *pgxpool.Pool
	log         *slog.Logger
	clock       clock.Clock
	guard       *Guard
	minProtocol int
}

// New prepara el servicio.
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

// Guard devuelve las comprobaciones comunes de la API interna, para los demás paquetes.
func (s *Service) Guard() *Guard { return s.guard }

// LostEvery es cada cuánto corre el trabajo de instancias perdidas: min(5 s, HEARTBEAT_S) (§2.5).
func (s *Service) LostEvery() time.Duration { return min(5*time.Second, s.cfg.Heartbeat) }

// lostCutoff es la hora antes de la cual el último latido deja a una instancia por perdida.
func (s *Service) lostCutoff(now time.Time) time.Time { return now.Add(-LostAfter * s.cfg.Heartbeat) }

// RegisterRequest es el cuerpo de POST /internal/v1/zone-instances.
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

// RegisterResult es la respuesta del registro.
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

// validCert dice si pem es un certificado X.509 en PEM.
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

// Register registra una instancia nueva en starting (§5.3, §6, §8). Comprueba, en orden: el
// alcance del token y el public_host (403 forbidden), los campos (400 validation; en staging y
// production, el certificado DTLS es obligatorio), el record_format y el protocolo (409
// schema_mismatch). Después, en una transacción, mira la instancia que ocupa ese mundo, zona y
// canal: si latió hace menos de 3 × HEARTBEAT_S, 409 instance_alive salvo con replace, que la pasa a
// replaced (sin liberar sus arrendamientos: los liberan sus guardados finales o el TTL) y deja una
// fila en audit_log; si no, la pasa a lost y libera sus arrendamientos, como el trabajo de perdidas.
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
		// Sin DTLS no hay pruebas públicas (§0, §10.2): en staging y production es obligatorio.
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
			// Otra instancia del mismo alcance se registró a la vez: gana la primera.
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

// markLost pasa las instancias a lost y libera sus arrendamientos (zone_instance_id = null;
// lease_id y claimed_by se quedan, §5.3).
func markLost(ctx context.Context, tx pgx.Tx, ids [][16]byte, now time.Time) error {
	if _, err := tx.Exec(ctx, `update zone_instances set status = 'lost', ended_at = $2 where zone_instance_id = any($1)`,
		ids, now); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `update character_leases set zone_instance_id = null, released_at = $2
		where zone_instance_id = any($1)`, ids, now)
	return err
}

// Live pasa la instancia de starting a live (enter ya la ofrece). Repetida con live, nada; con
// otro estado, su 409.
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

// Stop es la baja de una instancia (DELETE): starting o live pasan a stopped y sus arrendamientos
// quedan libres. Una sustituida que se va libera los que le queden (ya mandó sus finales) y sigue
// replaced; una parada, nada; una perdida, 409 instance_lost (los suyos ya están libres).
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

// MarkLost es el trabajo de instancias perdidas (§2.5, §5.3): las starting o live que llevan 3 ×
// HEARTBEAT_S sin latir pasan a lost y sus arrendamientos quedan libres.
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

// IDBlock da a la instancia un bloque de 1024 ids (§6, progresion.md §4.5): nextval de
// uid_block_seq y una fila en id_blocks. Devuelve el primero.
func (s *Service) IDBlock(ctx context.Context, inst *Instance) (int64, error) {
	var first int64
	err := s.pool.QueryRow(ctx, `insert into id_blocks (first_id, zone_instance_id, granted_at)
		values (nextval('uid_block_seq'), $1, $2) returning first_id`, inst.ID, s.clock.Now()).Scan(&first)
	return first, err
}

// HeartbeatRequest es el cuerpo del latido: los jugadores y el conjunto de arrendamientos que la
// zona mantiene (§5.3).
type HeartbeatRequest struct {
	Players    jsonx.Int            `json:"players"`
	Characters []HeartbeatCharacter `json:"characters"`
}

// HeartbeatCharacter es un personaje del latido con su arrendamiento.
type HeartbeatCharacter struct {
	CharacterID jsonx.ID `json:"character_id"`
	LeaseID     string   `json:"lease_id"`
}

// Revoked es un personaje que la zona tiene que sacar (§6): reason lease_lost, session_revoked,
// suspended, banned o pending_deletion, con el texto para el jugador.
type Revoked struct {
	CharacterID jsonx.ID `json:"character_id"`
	LeaseID     string   `json:"lease_id"`
	Reason      string   `json:"reason"`
	Text        string   `json:"text"`
}

// Mute es un silencio vigente de una cuenta con un personaje en la instancia.
type Mute struct {
	AccountID jsonx.ID `json:"account_id"`
	UntilUnix int64    `json:"until_unix"`
}

// Maintenance es el mantenimiento anunciado (TEC-28).
type Maintenance struct {
	AtUnix  int64  `json:"at_unix"`
	Message string `json:"message"`
}

// HeartbeatResult es la respuesta del latido.
type HeartbeatResult struct {
	NowUnix     int64        `json:"now_unix"`
	Revoked     []Revoked    `json:"revoked"`
	Mutes       []Mute       `json:"mutes"`
	Maintenance *Maintenance `json:"maintenance"`
}

// Textos de revoked.
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

// Heartbeat es el latido (§5.3, §6): apunta la hora y los jugadores, renueva los arrendamientos del
// conjunto que casan con un arrendamiento de esta instancia (character_id y lease_id) y devuelve en
// revoked los que no casan (lease_lost, con el lease_id del latido) y los renovados cuya cuenta
// está suspendida, expulsada o con el borrado pedido, o cuya sesión está revocada (con el lease_id
// del arrendamiento); en mutes, los silencios vigentes de sus cuentas. Una instancia que ya no está
// en starting ni live recibe su 409.
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
			returning l.character_id`, inst.ID, charIDs, leaseIDs, now.Add(s.cfg.LeaseTTL))
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

// accountState añade a la respuesta del latido las expulsiones por la cuenta o la sesión y los
// silencios de los personajes renovados.
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
