package zones_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"eldmark/platform/internal/config"
	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/testdb"
	"eldmark/platform/internal/zones"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func TestUUID(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		u := zones.NewUUID()
		s := zones.FormatUUID(u)
		if s[14] != '4' || !strings.ContainsRune("89ab", rune(s[19])) || seen[s] {
			t.Fatalf("UUID v4: %s", s)
		}
		seen[s] = true
		back, ok := zones.ParseUUID(s)
		if !ok || back != u {
			t.Fatalf("ida y vuelta de %s", s)
		}
	}
	for _, bad := range []string{"", "0123", "01234567-89ab-cdef-0123-456789ABCDEF", "01234567-89ab-cdef-0123_456789abcdef",
		"01234567089ab-cdef-0123-456789abcdef", "0123456g-89ab-cdef-0123-456789abcdef"} {
		if _, ok := zones.ParseUUID(bad); ok {
			t.Errorf("%q no vale", bad)
		}
	}
}

func TestRegistryAuthenticate(t *testing.T) {
	r := zones.NewRegistry(platformtest.Config().ZoneTokens)
	for _, s := range platformtest.Scopes {
		got, ok := r.Authenticate(platformtest.Token(s))
		if !ok || got != s {
			t.Errorf("%v: %v %v", s, got, ok)
		}
	}
	for _, bad := range []string{"", "tok-1-vado_gris-9", "Tok-1-vado_gris-0"} {
		if _, ok := r.Authenticate(bad); ok {
			t.Errorf("%q no es un token", bad)
		}
	}
}

// El token de 1:vado_gris:0 no registra vado_gris:1 ni un host fuera de la lista, ni late por otra
// instancia (403); sin token o con uno que no casa, 401 bad_token.
func TestTokenScope(t *testing.T) {
	p := platformtest.New(t)
	z0 := p.NewZone(1, "vado_gris", 0)
	z1 := p.NewZone(1, "vado_gris", 1).Start()

	platformtest.Expect(t, z0.Register(map[string]any{"channel": 1}), 403, "forbidden")
	platformtest.Expect(t, z0.Register(map[string]any{"zone_id": "test_world"}), 403, "forbidden")
	platformtest.Expect(t, z0.Register(map[string]any{"world_id": 2}), 403, "forbidden")
	platformtest.Expect(t, z0.Register(map[string]any{"public_host": "198.51.100.7"}), 403, "forbidden")

	// Con el token de z0, el latido, live, los bloques y la baja de la instancia de z1: 403.
	z0.ID = z1.ID
	platformtest.Expect(t, z0.Heartbeat(0), 403, "forbidden")
	platformtest.Expect(t, z0.Live(), 403, "forbidden")
	platformtest.Expect(t, z0.Do("POST", "/internal/v1/id-blocks", map[string]any{"zone_instance_id": z1.ID}), 403, "forbidden")
	platformtest.Expect(t, z0.Do("DELETE", "/internal/v1/zone-instances/"+z1.ID, nil), 403, "forbidden")
	// Una instancia que no existe tampoco es del alcance.
	z0.ID = zones.FormatUUID(zones.NewUUID())
	platformtest.Expect(t, z0.Heartbeat(0), 403, "forbidden")
	z0.ID = "no-es-un-uuid"
	platformtest.Expect(t, z0.Heartbeat(0), 400, "validation")

	bad := &platformtest.Zone{P: p, Scope: z1.Scope, Token: "otro", ID: z1.ID}
	platformtest.Expect(t, bad.Heartbeat(0), 401, "bad_token")
	bad.Token = ""
	platformtest.Expect(t, bad.Register(nil), 401, "bad_token")
	if got := p.Count(`select count(*) from zone_instances`); got != 1 {
		t.Fatalf("solo se registró z1: %d", got)
	}
	// La propia zona sí.
	platformtest.Expect(t, z0Fresh(p).Register(nil), 200, "")
}

func z0Fresh(p *platformtest.Platform) *platformtest.Zone { return p.NewZone(1, "vado_gris", 0) }

func TestRegisterValidation(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0)
	for _, c := range []struct {
		override map[string]any
		field    string
	}{
		{map[string]any{"realms": []int{4}}, "realms"},
		{map[string]any{"realms": []int{}}, "realms"},
		{map[string]any{"realms": []int{1, 1}}, "realms"},
		{map[string]any{"max_players": 0}, "max_players"},
		{map[string]any{"public_port": 0}, "public_port"},
		{map[string]any{"build_id": ""}, "build_id"},
		{map[string]any{"dtls_cert_pem": "-----BEGIN CERTIFICATE-----\nno\n-----END CERTIFICATE-----\n",
			"dtls_name": "x"}, "dtls_cert_pem"},
	} {
		res := z.Register(c.override)
		platformtest.Expect(t, res, 400, "validation")
		if res.Field(c.field) == "" {
			t.Errorf("%v: %s", c.override, res.Raw)
		}
	}
	platformtest.Expect(t, z.Register(map[string]any{"world_id": "1"}), 400, "bad_request")
	platformtest.Expect(t, z.Register(map[string]any{"desconocido": true}), 400, "bad_request")
	// Un record_format que no se admite o un protocolo por debajo del mínimo: 409 schema_mismatch.
	platformtest.Expect(t, z.Register(map[string]any{"record_format": 2}), 409, "schema_mismatch")
	platformtest.Expect(t, z.Register(map[string]any{"protocol_version": platformtest.Protocol - 1}), 409, "schema_mismatch")
	platformtest.Expect(t, z.Register(map[string]any{"channel": 0.0, "max_players": 64.0}), 200, "")
}

// selfSigned es un certificado de prueba en PEM.
func selfSigned(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "vado-gris.eldmark"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

// En staging (y production) el registro sin certificado DTLS da 400; con uno, vale y enter lo da.
func TestRegisterInStagingNeedsCertificate(t *testing.T) {
	p := platformtest.New(t, func(c *config.Config) { c.Env = config.EnvStaging })
	z := p.NewZone(1, "vado_gris", 0)
	res := z.Register(nil)
	platformtest.Expect(t, res, 400, "validation")
	if res.Field("dtls_cert_pem") != "required" {
		t.Fatal(res.Raw)
	}
	cert := selfSigned(t)
	platformtest.Expect(t, z.Register(map[string]any{"dtls_cert_pem": cert}), 400, "validation") // sin dtls_name
	res = z.Register(map[string]any{"dtls_cert_pem": cert, "dtls_name": "vado-gris.eldmark"})
	platformtest.Expect(t, res, 200, "")
	if res.String("env") != "staging" || res.Int("heartbeat_s") != 5 || res.Int("lease_ttl_s") != 30 ||
		res.Int("now_unix") != p.Clock.Now().Unix() {
		t.Fatalf("respuesta del registro: %s", res.Raw)
	}
	var stored string
	p.Scalar(&stored, `select dtls_cert_pem from zone_instances where zone_instance_id = $1`, z.ID)
	if stored != cert {
		t.Fatal("certificado guardado")
	}
}

// Registro sin replace con la vieja latiendo: 409 instance_alive; con replace, la vieja pasa a
// replaced (sin liberar sus arrendamientos) y queda una fila en la auditoría; la vieja recibe
// instance_replaced en el latido.
func TestRegisterAliveAndReplace(t *testing.T) {
	p := platformtest.New(t)
	old := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	lease := old.Join(pl, id)

	p.Clock.Advance(14 * time.Second) // aún no lleva 3 × 5 s sin latir
	fresh := p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, fresh.Register(nil), 409, "instance_alive")
	res := fresh.Register(map[string]any{"replace": true})
	platformtest.Expect(t, res, 200, "")
	var status string
	p.Scalar(&status, `select status from zone_instances where zone_instance_id = $1`, old.ID)
	if status != "replaced" {
		t.Fatal(status)
	}
	if n := p.Count(`select count(*) from audit_log where source = 'platform' and command = 'zone_replace'
		and args->>'replaced' = $1 and args->>'by' = $2`, old.ID, fresh.ID); n != 1 {
		t.Fatalf("fila de la auditoría: %d", n)
	}
	if n := p.Count(`select count(*) from character_leases where character_id = $1 and zone_instance_id = $2`,
		id, old.ID); n != 1 {
		t.Fatal("la sustitución no libera los arrendamientos de la vieja")
	}
	platformtest.Expect(t, old.Heartbeat(1, platformtest.Lease{CharacterID: id, LeaseID: lease}), 409, "instance_replaced")
	platformtest.Expect(t, old.Live(), 409, "instance_replaced")
	platformtest.Expect(t, old.Do("POST", "/internal/v1/id-blocks", map[string]any{"zone_instance_id": old.ID}), 409,
		"instance_replaced")
}

// Con la vieja aún live pero sin latir desde hace 3 × HEARTBEAT_S, el registro la pasa a lost,
// libera sus arrendamientos y registra la nueva (sin 500).
func TestRegisterOverASilentInstance(t *testing.T) {
	p := platformtest.New(t)
	old := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	old.Join(pl, id)
	p.Clock.Advance(15 * time.Second)
	fresh := p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, fresh.Register(nil), 200, "")
	var status string
	p.Scalar(&status, `select status from zone_instances where zone_instance_id = $1`, old.ID)
	if status != "lost" {
		t.Fatal(status)
	}
	var free bool
	p.Scalar(&free, `select zone_instance_id is null and released_at is not null from character_leases
		where character_id = $1`, id)
	if !free {
		t.Fatal("arrendamiento libre")
	}
	platformtest.Expect(t, old.Heartbeat(0), 409, "instance_lost")
	if n := p.Count(`select count(*) from audit_log where command = 'zone_replace'`); n != 0 {
		t.Fatal("perder no es sustituir")
	}
}

// Dos registros a la vez del mismo alcance: uno gana y el otro recibe instance_alive.
func TestTwoRegistrationsAtOnce(t *testing.T) {
	p := platformtest.New(t)
	for round := 0; round < 5; round++ {
		zs := []*platformtest.Zone{p.NewZone(1, "test_world", 0), p.NewZone(1, "test_world", 0)}
		var wg sync.WaitGroup
		results := make([]*platformtest.Response, 2)
		for i := range zs {
			wg.Add(1)
			go func() {
				defer wg.Done()
				results[i] = zs[i].Register(nil)
			}()
		}
		wg.Wait()
		ok := 0
		for _, r := range results {
			switch {
			case r.Status == 200:
				ok++
			case r.Status != 409 || r.Code() != "instance_alive":
				t.Fatalf("ronda %d: %d %s", round, r.Status, r.Raw)
			}
		}
		if ok != 1 {
			t.Fatalf("ronda %d: %d ganadores", round, ok)
		}
		if n := p.Count(`select count(*) from zone_instances where zone_id = 'test_world' and status in ('starting', 'live')`); n != 1 {
			t.Fatalf("ronda %d: %d vivas", round, n)
		}
		p.Exec(`update zone_instances set status = 'stopped' where zone_id = 'test_world'`)
	}
}

func TestLiveAndStop(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, z.Register(nil), 200, "")
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	platformtest.Expect(t, p.Enter(pl, id), 503, "zone_unavailable") // starting: enter no la ofrece
	platformtest.Expect(t, z.Live(), 204, "")
	platformtest.Expect(t, z.Live(), 204, "") // repetida
	lease := z.Join(pl, id)
	platformtest.Expect(t, z.Do("DELETE", "/internal/v1/zone-instances/"+z.ID, nil), 204, "")
	var status string
	p.Scalar(&status, `select status from zone_instances where zone_instance_id = $1`, z.ID)
	var free bool
	p.Scalar(&free, `select zone_instance_id is null from character_leases where character_id = $1`, id)
	if status != "stopped" || !free {
		t.Fatalf("baja: %s libre=%v", status, free)
	}
	platformtest.Expect(t, z.Do("DELETE", "/internal/v1/zone-instances/"+z.ID, nil), 204, "")
	platformtest.Expect(t, z.Heartbeat(0, platformtest.Lease{CharacterID: id, LeaseID: lease}), 409, "instance_stopped")
	platformtest.Expect(t, z.Live(), 409, "instance_stopped")
}

// La tabla de estados de §6.1: cada petición en cada estado.
func TestInstanceStateTable(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, z.Register(nil), 200, "")
	ticket := map[string]any{"zone_instance_id": z.ID, "ticket_id": "1", "character_id": "1"}
	type route struct {
		name         string
		call         func() *platformtest.Response
		startingCode string // "" = pasa la comprobación de estado
		notLiveOK    bool
	}
	routes := []route{
		{name: "latido", call: func() *platformtest.Response { return z.Heartbeat(0) }},
		{name: "bloque", call: func() *platformtest.Response {
			return z.Do("POST", "/internal/v1/id-blocks", map[string]any{"zone_instance_id": z.ID})
		}},
		{name: "GET fortalezas", call: func() *platformtest.Response {
			return z.Do("GET", "/internal/v1/fortresses?zone_instance_id="+z.ID, nil)
		}},
		{name: "reclamación", startingCode: "instance_not_live", call: func() *platformtest.Response {
			return z.Do("POST", "/internal/v1/claims", ticket)
		}},
		{name: "operación", startingCode: "instance_not_live", call: func() *platformtest.Response {
			return z.Do("GET", "/internal/v1/ops/5?zone_instance_id="+z.ID, nil)
		}},
		{name: "libro", startingCode: "instance_not_live", call: func() *platformtest.Response {
			return z.Do("GET", "/internal/v1/characters/1/ledger?zone_instance_id="+z.ID, nil)
		}},
		{name: "PUT fortaleza", startingCode: "instance_not_live", call: func() *platformtest.Response {
			return z.Do("PUT", "/internal/v1/fortresses/fuerte", map[string]any{"zone_instance_id": z.ID,
				"expected_version": 0, "record": map[string]any{"schema": 1}})
		}},
		{name: "ignorar", startingCode: "instance_not_live", call: func() *platformtest.Response {
			return z.Do("POST", "/internal/v1/ignores", map[string]any{"zone_instance_id": z.ID, "character_id": "1",
				"target_name": "Bran"})
		}},
	}
	batches := []func() *platformtest.Response{
		func() *platformtest.Response {
			return z.Do("POST", "/internal/v1/chat", map[string]any{"zone_instance_id": z.ID, "messages": []any{}})
		},
		func() *platformtest.Response {
			return z.Do("POST", "/internal/v1/audit", map[string]any{"zone_instance_id": z.ID, "entries": []any{}})
		},
		func() *platformtest.Response {
			return z.Do("POST", "/internal/v1/war-events", map[string]any{"zone_instance_id": z.ID, "events": []any{}})
		},
	}
	for _, status := range []string{"starting", "live", "lost", "replaced", "stopped"} {
		p.Exec(`update zone_instances set status = $2 where zone_instance_id = $1`, z.ID, status)
		for _, r := range routes {
			res := r.call()
			switch status {
			case "starting", "live":
				if status == "starting" && r.startingCode != "" {
					platformtest.Expect(t, res, 409, r.startingCode)
				} else if res.Status == 409 && strings.HasPrefix(res.Code(), "instance_") {
					t.Errorf("%s en %s: %s", r.name, status, res.Raw)
				}
			default:
				platformtest.Expect(t, res, 409, "instance_"+status)
			}
		}
		// Los lotes valen en todos los estados.
		for i, b := range batches {
			if res := b(); res.Status != 204 {
				t.Errorf("lote %d en %s: %d %s", i, status, res.Status, res.Raw)
			}
		}
	}
}

// Bloques de ids: 1024 cada uno, de la secuencia común; en starting y live.
func TestIDBlocks(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0)
	platformtest.Expect(t, z.Register(nil), 200, "")
	other := p.NewZone(1, "test_world", 0).Start()
	var firsts []string
	for i, zone := range []*platformtest.Zone{z, other, z} {
		res := zone.Do("POST", "/internal/v1/id-blocks", map[string]any{"zone_instance_id": zone.ID})
		platformtest.Expect(t, res, 200, "")
		if res.Int("count") != 1024 {
			t.Fatal(res.Raw)
		}
		first := res.String("first")
		if first == "" || (i > 0 && first == firsts[i-1]) {
			t.Fatalf("first en cadena: %s", res.Raw)
		}
		firsts = append(firsts, first)
	}
	if firsts[0] != "1" || firsts[1] != "1025" || firsts[2] != "2049" {
		t.Fatalf("bloques %v", firsts)
	}
	if n := p.Count(`select count(*) from id_blocks where zone_instance_id = $1`, z.ID); n != 2 {
		t.Fatal(n)
	}
}

// El latido renueva solo lo que casa: un lease_id viejo vuelve en revoked con lease_lost (y su
// lease_id) y no se renueva; uno que casa se renueva hasta ahora + TTL; uno que no va en el
// latido caduca solo a los 30 s.
func TestHeartbeatRenewsOnlyMatchingLeases(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	a := p.NewPlayer("a@example.org")
	b := p.NewPlayer("b@example.org")
	idA := p.NewCharacter(a, "Aneira", "vardheim")
	idB := p.NewCharacter(b, "Bran", "vardheim")
	leaseA := z.Join(a, idA)
	z.Join(b, idB)

	p.Clock.Advance(20 * time.Second)
	stale := zones.FormatUUID(zones.NewUUID())
	res := z.Heartbeat(2, platformtest.Lease{CharacterID: idA, LeaseID: leaseA}, platformtest.Lease{CharacterID: idB,
		LeaseID: stale})
	platformtest.Expect(t, res, 200, "")
	revoked := res.Body["revoked"].([]any)
	if len(revoked) != 1 {
		t.Fatalf("revoked: %s", res.Raw)
	}
	r := revoked[0].(map[string]any)
	if r["character_id"] != strconv.FormatInt(idB, 10) || r["lease_id"] != stale || r["reason"] != "lease_lost" ||
		r["text"] == "" {
		t.Fatalf("lease_lost con el lease_id del latido: %v", r)
	}
	var expiresA, expiresB time.Time
	p.Scalar(&expiresA, `select expires_at from character_leases where character_id = $1`, idA)
	p.Scalar(&expiresB, `select expires_at from character_leases where character_id = $1`, idB)
	if !expiresA.Equal(p.Clock.Now().Add(30*time.Second)) || !expiresB.Before(p.Clock.Now().Add(15*time.Second)) {
		t.Fatalf("renovación: A %s, B %s (ahora %s)", expiresA, expiresB, p.Clock.Now())
	}
	if n := p.Count(`select players from zone_instances where zone_instance_id = $1`, z.ID); n != 2 {
		t.Fatalf("jugadores: %d", n)
	}
	// B no va en los latidos: a los 30 s de su reclamación caduca y puede volver a entrar.
	platformtest.Expect(t, p.Enter(b, idB), 409, "character_busy")
	p.Clock.Advance(11 * time.Second)
	platformtest.Expect(t, z.Heartbeat(1, platformtest.Lease{CharacterID: idA, LeaseID: leaseA}), 200, "")
	p.Login(b)
	if res := p.Enter(b, idB); res.Status != 200 {
		t.Fatalf("B tras el TTL: %d %s", res.Status, res.Raw)
	}
	if res := p.Enter(a, idA); res.Code() != "character_busy" {
		t.Fatalf("A sigue dentro: %s", res.Raw)
	}
	if !json.Valid([]byte(res.Raw)) {
		t.Fatal("JSON")
	}
}

// Expulsiones del latido por la cuenta y la sesión: la sesión revocada (otro inicio de sesión),
// suspendida, expulsada y con el borrado pedido; refrescar la sesión no expulsa. Cada entrada lleva
// el lease_id del arrendamiento y su texto.
func TestHeartbeatRevocations(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	type who struct {
		pl    *platformtest.Player
		id    int64
		lease string
	}
	var all []who
	for i, name := range []string{"Aneira", "Bran", "Cora", "Dalla", "Eiric"} {
		pl := p.NewPlayer(strconv.Itoa(i) + "@example.org")
		id := p.NewCharacter(pl, name, "vardheim")
		all = append(all, who{pl: pl, id: id, lease: z.Join(pl, id)})
	}
	leases := make([]platformtest.Lease, len(all))
	for i, w := range all {
		leases[i] = platformtest.Lease{CharacterID: w.id, LeaseID: w.lease}
	}
	res := z.Heartbeat(5, leases...)
	platformtest.Expect(t, res, 200, "")
	if len(res.Body["revoked"].([]any)) != 0 || len(res.Body["mutes"].([]any)) != 0 || res.Body["maintenance"] != nil {
		t.Fatalf("latido limpio: %s", res.Raw)
	}

	// 0: refresca la sesión del billete, la que guarda el arrendamiento (no expulsa: el refresco
	// rota en la misma fila, §4.2), dos veces; después inicia otra (replaced: sí).
	var session int64
	p.Scalar(&session, `select session_id from character_leases where character_id = $1`, all[0].id)
	for i := 0; i < 2; i++ {
		platformtest.Expect(t, p.RefreshSession(all[0].pl), 200, "")
		res = z.Heartbeat(5, leases...)
		if len(res.Body["revoked"].([]any)) != 0 {
			t.Fatalf("refrescar no expulsa: %s", res.Raw)
		}
	}
	var rotated int
	p.Scalar(&rotated, `select count(*) from sessions where session_id = $1 and rotated_at is not null and revoked_at is null`, session)
	if rotated != 1 || p.Count(`select count(*) from character_leases where character_id = $1 and session_id = $2`,
		all[0].id, session) != 1 {
		t.Fatal("el refresco tenía que rotar la sesión del arrendamiento sin cambiarla")
	}
	if res := p.PublicDo("GET", "/v1/account", all[0].pl.Token, nil); res.Status != 200 {
		t.Fatalf("el acceso refrescado vale: %s", res.Raw)
	}
	p.Login(all[0].pl)
	// 1: suspendida con un motivo largo; 2: expulsada; 3: borrado pedido; 4: silenciada.
	now := p.Clock.Now()
	long := strings.Repeat("ñ", 300)
	p.Exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', $2, $3, $4)`,
		all[1].pl.ID, long, now.Add(-time.Minute), now.Add(time.Hour))
	p.Exec(`insert into sanctions (account_id, kind, reason, starts_at) values ($1, 'ban', 'trampas', $2)`,
		all[2].pl.ID, now.Add(-time.Minute))
	p.Exec(`update accounts set status = 'pending_deletion', deletion_requested_at = $2, purge_after = $3
		where account_id = $1`, all[3].pl.ID, now, now.Add(14*24*time.Hour))
	p.Exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'mute', 'gritos', $2, $3)`,
		all[4].pl.ID, now.Add(-time.Minute), now.Add(10*time.Minute))
	res = z.Heartbeat(5, leases...)
	platformtest.Expect(t, res, 200, "")
	got := map[string]map[string]any{}
	for _, r := range res.Body["revoked"].([]any) {
		m := r.(map[string]any)
		got[m["character_id"].(string)] = m
	}
	want := map[int]string{0: "session_revoked", 1: "suspended", 2: "banned", 3: "pending_deletion"}
	if len(got) != len(want) {
		t.Fatalf("revoked: %s", res.Raw)
	}
	for i, reason := range want {
		m := got[strconv.FormatInt(all[i].id, 10)]
		if m == nil || m["reason"] != reason || m["lease_id"] != all[i].lease {
			t.Fatalf("%d: %v", i, m)
		}
		text := m["text"].(string)
		if text == "" || len(text) > 255 {
			t.Fatalf("%d: texto %q", i, text)
		}
	}
	if !strings.Contains(got[strconv.FormatInt(all[0].id, 10)]["text"].(string), "otro lugar") ||
		!strings.Contains(got[strconv.FormatInt(all[1].id, 10)]["text"].(string), "suspendida hasta el") ||
		!strings.Contains(got[strconv.FormatInt(all[2].id, 10)]["text"].(string), "expulsada: trampas") ||
		!strings.Contains(got[strconv.FormatInt(all[3].id, 10)]["text"].(string), "se borrará el") {
		t.Fatalf("textos: %s", res.Raw)
	}
	mutes := res.Body["mutes"].([]any)
	if len(mutes) != 1 {
		t.Fatalf("mutes: %s", res.Raw)
	}
	m := mutes[0].(map[string]any)
	if m["account_id"] != strconv.FormatInt(all[4].pl.ID, 10) || m["until_unix"].(json.Number).String() !=
		strconv.FormatInt(now.Add(10*time.Minute).Unix(), 10) {
		t.Fatalf("silencio: %v", m)
	}
	// Los expulsados siguen renovados: la zona aún manda su guardado final.
	var alive int
	p.Scalar(&alive, `select count(*) from character_leases where zone_instance_id = $1 and expires_at > $2`,
		z.ID, p.Clock.Now())
	if alive != 5 {
		t.Fatalf("renovados: %d", alive)
	}
}

// Un latido tardío no resucita un arrendamiento caducado (§5.3: renueva solo lo vivo). Caducado, la
// reclamación, enter y el borrado lo dan por libre; si el latido lo renovara, la cuenta tendría dos
// personajes en el mundo, o uno borrado seguiría dentro. Sale en revoked con lease_lost.
func TestLateHeartbeatDoesNotRenewExpiredLeases(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	idA := p.NewCharacter(pl, "Aneira", "vardheim")
	idB := p.NewCharacter(pl, "Bran", "vardheim")
	leaseA := z.Join(pl, idA)
	// La zona no late a tiempo y el trabajo de perdidas no pasa (se retrasa): A caduca con la instancia viva.
	p.Clock.Advance(31 * time.Second)
	leaseB := z.Join(pl, idB)
	res := z.Heartbeat(2, platformtest.Lease{CharacterID: idA, LeaseID: leaseA}, platformtest.Lease{CharacterID: idB, LeaseID: leaseB})
	platformtest.Expect(t, res, 200, "")
	revoked := res.Body["revoked"].([]any)
	if len(revoked) != 1 || revoked[0].(map[string]any)["character_id"] != strconv.FormatInt(idA, 10) ||
		revoked[0].(map[string]any)["reason"] != "lease_lost" || revoked[0].(map[string]any)["lease_id"] != leaseA {
		t.Fatalf("revoked: %s", res.Raw)
	}
	alive := func() int {
		t.Helper()
		return p.Count(`select count(*) from character_leases l join characters c using (character_id)
			where c.account_id = $1 and l.zone_instance_id is not null and l.expires_at > $2`, pl.ID, p.Clock.Now())
	}
	if n := alive(); n != 1 {
		t.Fatalf("arrendamientos vivos de la cuenta: %d", n)
	}
	// Con B fuera del latido y caducado, se puede borrar; el latido tardío no lo devuelve al mundo.
	p.Clock.Advance(31 * time.Second)
	res = p.PublicDo("DELETE", "/v1/characters/"+strconv.FormatInt(idB, 10), pl.Token, map[string]any{"confirm_name": "Bran"})
	platformtest.Expect(t, res, 200, "")
	res = z.Heartbeat(1, platformtest.Lease{CharacterID: idB, LeaseID: leaseB})
	if revoked := res.Body["revoked"].([]any); len(revoked) != 1 || revoked[0].(map[string]any)["reason"] != "lease_lost" {
		t.Fatalf("el borrado sigue en el mundo: %s", res.Raw)
	}
	if n := alive(); n != 0 {
		t.Fatalf("arrendamientos vivos tras el borrado: %d", n)
	}
}

// Sin latido durante 3 × HEARTBEAT_S, el trabajo de perdidas pasa la instancia a lost y libera sus
// arrendamientos: el personaje vuelve a entrar en 15 s como mucho. La instancia perdida que late
// recibe instance_lost.
func TestLostInstance(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	lease := z.Join(pl, id)
	ctx := context.Background()

	p.Clock.Advance(14 * time.Second)
	if err := p.Zones.MarkLost(ctx); err != nil {
		t.Fatal(err)
	}
	var status string
	p.Scalar(&status, `select status from zone_instances where zone_instance_id = $1`, z.ID)
	if status != "live" {
		t.Fatal("a los 14 s sigue viva")
	}
	p.Clock.Advance(time.Second)
	if err := p.Zones.MarkLost(ctx); err != nil {
		t.Fatal(err)
	}
	p.Scalar(&status, `select status from zone_instances where zone_instance_id = $1`, z.ID)
	var free bool
	p.Scalar(&free, `select zone_instance_id is null from character_leases where character_id = $1`, id)
	if status != "lost" || !free {
		t.Fatalf("perdida: %s libre=%v", status, free)
	}
	platformtest.Expect(t, z.Heartbeat(1, platformtest.Lease{CharacterID: id, LeaseID: lease}), 409, "instance_lost")
	platformtest.Expect(t, z.Live(), 409, "instance_lost")
	platformtest.Expect(t, z.Do("DELETE", "/internal/v1/zone-instances/"+z.ID, nil), 409, "instance_lost")
	if !strings.Contains(p.Logs.String(), "instancia perdida") {
		t.Fatal("registro")
	}
	// Otra instancia de la zona y el personaje entra en ella.
	fresh := p.NewZone(1, "vado_gris", 0).Start()
	p.Login(pl)
	fresh.Join(pl, id)
	if every := p.Zones.LostEvery(); every != 5*time.Second {
		t.Fatal(every)
	}
}

// InsertEach: si una fila choca con una restricción, ninguna queda a medias y se insertan de una en
// una para rechazar solo esa.
func TestInsertEachIsolatesTheBadRow(t *testing.T) {
	p := platformtest.New(t)
	p.Exec(`create table lote (k text primary key, n int check (n >= 0))`)
	sql := `insert into lote (k, n) values ($1, $2) on conflict (k) do nothing`
	ctx := context.Background()
	rejected, err := zones.InsertEach(ctx, p.Pool, sql, [][]any{{"a", 1}, {"b", -1}, {"c", 3}}, []string{"a", "b", "c"})
	if err != nil || len(rejected) != 1 || rejected[0] != "b" {
		t.Fatalf("%v %v", rejected, err)
	}
	if n := p.Count(`select count(*) from lote`); n != 2 {
		t.Fatal(n)
	}
	// Todo bien: una ida y vuelta, nada rechazado; repetido, sin duplicar.
	rejected, err = zones.InsertEach(ctx, p.Pool, sql, [][]any{{"a", 1}, {"d", 4}}, []string{"a", "d"})
	if err != nil || len(rejected) != 0 || p.Count(`select count(*) from lote`) != 3 {
		t.Fatalf("%v %v", rejected, err)
	}
	// Un dato que PostgreSQL rechaza (SQLSTATE de clase 22: un NUL en jsonb, una fecha fuera de rango)
	// es tan determinista como una restricción: se rechaza esa fila y no el lote (antes, 500 y la zona
	// reintentaba el mismo lote sin fin).
	p.Exec(`create table lote_datos (k text primary key, j jsonb, at timestamptz)`)
	sql = `insert into lote_datos (k, j, at) values ($1, $2, to_timestamp($3)) on conflict (k) do nothing`
	rows := [][]any{{"x", `{"n": 1}`, 1800000000}, {"nul", `{"n": "\u0000"}`, 1800000000}, {"fecha", `{}`, 9e15},
		{"y", `{}`, 1800000000}}
	rejected, err = zones.InsertEach(ctx, p.Pool, sql, rows, []string{"x", "nul", "fecha", "y"})
	if err != nil || len(rejected) != 2 || rejected[0] != "nul" || rejected[1] != "fecha" ||
		p.Count(`select count(*) from lote_datos`) != 2 {
		t.Fatalf("%v %v", rejected, err)
	}
}

// IsJSONObject: lo que jsonb guarda y lo que no (PostgreSQL rechaza \u0000, los suplentes sueltos y
// el UTF-8 roto, que encoding/json deja pasar).
func TestIsJSONObject(t *testing.T) {
	cases := map[string]bool{
		`{}`:                             true,
		` {"a": [1, {"b": "ñ"}]} `:       true,
		`{"cara": "\ud83d\ude00"}`:       true, // un par de suplentes
		`{"barra": "\\u0000"}`:           true, // una barra escapada y el texto u0000
		`{"a": "\"\u00e9"}`:              true,
		`[]`:                             false,
		`{"a": 1`:                        false,
		`{"nul": "a\u0000b"}`:            false,
		`{"a\u0000": 1}`:                 false,
		`{"suelto": "\ud800"}`:           false,
		`{"bajo": "\udc00"}`:             false,
		`{"alto, alto": "\ud800\ud800"}`: false,
		"{\"roto\": \"a\xffb\"}":         false,
	}
	for raw, want := range cases {
		if got := zones.IsJSONObject([]byte(raw)); got != want {
			t.Errorf("%q: %v", raw, got)
		}
	}
}

// Un error de datos (clase 22) que llega a la respuesta de una ruta interna es un 400 validation,
// definitivo, y no un 500 que la zona reintenta.
func TestFailDataErrorIs400(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/internal/v1/reports", nil)
	zones.Fail(rec, req, nil, fmt.Errorf("insertar: %w", &pgconn.PgError{Code: "22P05", Message: "unsupported Unicode escape sequence"}))
	if rec.Code != 400 || !strings.Contains(rec.Body.String(), `"validation"`) {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
}
