package persistence_test

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"eldmark/platform/internal/platformtest"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

// La reclamación consume el billete, toma el arrendamiento y trae la cuenta, el personaje (con el
// reino en su código), la sección progress del almacén y los totales pvp.
func TestClaim(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "solmarch")
	p.Exec(`update accounts set role = 'gm' where account_id = $1`, pl.ID)
	p.Exec(`update character_pvp_stats set kills = 3, gate_damage = 450 where character_id = $1`, id)
	ticket, instance := p.MustEnter(pl, id)
	if instance != z.ID {
		t.Fatal(instance)
	}
	res := z.Claim(ticket, id)
	platformtest.Expect(t, res, 200, "")
	lease := res.String("lease_id")
	if len(lease) != 36 || res.String("instance_status") != "live" {
		t.Fatalf("claim: %s", res.Raw)
	}
	account := res.Body["account"].(map[string]any)
	if account["account_id"] != strconv.FormatInt(pl.ID, 10) || account["role"] != "gm" ||
		account["muted_until_unix"].(json.Number).String() != "0" || len(account["ignored_account_ids"].([]any)) != 0 {
		t.Fatalf("cuenta: %v", account)
	}
	c := res.Body["character"].(map[string]any)
	if c["character_id"] != strconv.FormatInt(id, 10) || c["world_id"].(json.Number).String() != "1" ||
		c["realm"].(json.Number).String() != "2" || c["name"] != "Aneira" {
		t.Fatalf("personaje: %v", c)
	}
	progress := res.Body["progress"].(map[string]any)
	if progress["race_id"] != "race_solmarch" || progress["appearance"] != platformtest.Appearance ||
		progress["progress_format"].(json.Number).String() != "1" {
		t.Fatalf("progress: %v", progress)
	}
	pvp := res.Body["pvp"].(map[string]any)
	if pvp["kills"].(json.Number).String() != "3" || pvp["gate_damage"].(json.Number).String() != "450" || len(pvp) != 6 {
		t.Fatalf("pvp: %v", pvp)
	}
	var consumed, entered bool
	p.Scalar(&consumed, `select consumed_at is not null from enter_tickets where ticket_id = $1`, ticket)
	p.Scalar(&entered, `select last_entered_at = $2 from characters where character_id = $1`, id, p.Clock.Now())
	if !consumed || !entered {
		t.Fatalf("billete consumido %v, last_entered_at %v", consumed, entered)
	}
	var stored string
	p.Scalar(&stored, `select lease_id::text from character_leases where character_id = $1 and zone_instance_id = $2
		and claimed_by = $2 and last_seq = 0`, id, z.ID)
	if stored != lease {
		t.Fatal(stored)
	}
	// Con el personaje dentro, enter da character_busy.
	platformtest.Expect(t, p.Enter(pl, id), 409, "character_busy")
}

// Billete consumido, caducado, de otra instancia y de una sesión revocada: ticket_invalid, y el
// billete que no se usó no queda consumido.
func TestClaimTicketInvalid(t *testing.T) {
	p := platformtest.New(t)
	z0 := p.NewZone(1, "vado_gris", 0).Start()
	z1 := p.NewZone(1, "vado_gris", 1).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	notConsumed := func(ticket int64) {
		t.Helper()
		if n := p.Count(`select count(*) from enter_tickets where ticket_id = $1 and consumed_at is null`, ticket); n != 1 {
			t.Fatal("el billete quedó consumido")
		}
	}

	// De otra instancia: el billete es de z0 (canal 0: los dos vacíos, gana el menor).
	ticket, instance := p.MustEnter(pl, id)
	if instance != z0.ID {
		t.Fatal(instance)
	}
	platformtest.Expect(t, z1.Claim(ticket, id), 409, "ticket_invalid")
	notConsumed(ticket)
	// De otro personaje.
	other := p.NewCharacter(pl, "Bran", "vardheim")
	platformtest.Expect(t, z0.Claim(ticket, other), 409, "ticket_invalid")
	notConsumed(ticket)
	// Caducado: a los 10 s y 5 de margen.
	p.Clock.Advance(15 * time.Second)
	platformtest.Expect(t, z0.Claim(ticket, id), 409, "ticket_invalid")
	notConsumed(ticket)
	// Uno que no existe.
	platformtest.Expect(t, z0.Claim(ticket+1, id), 409, "ticket_invalid")

	// De una sesión revocada: iniciar sesión otra vez revoca la del billete.
	p.Login(pl)
	ticket, _ = p.MustEnter(pl, id)
	p.Login(pl)
	platformtest.Expect(t, z0.Claim(ticket, id), 409, "ticket_invalid")
	notConsumed(ticket)

	// Consumido: el segundo uso falla.
	ticket, _ = p.MustEnter(pl, id)
	p.Clock.Advance(14 * time.Second) // dentro del margen de 5 s
	z0.MustClaim(ticket, id)
	platformtest.Expect(t, z0.Claim(ticket, id), 409, "ticket_invalid")
}

// character_busy no consume el billete: dos billetes del mismo personaje antes de reclamar; el
// segundo choca con el arrendamiento del primero.
func TestClaimBusyKeepsTheTicket(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	first, _ := p.MustEnter(pl, id)
	second, _ := p.MustEnter(pl, id)
	z.MustClaim(first, id)
	platformtest.Expect(t, z.Claim(second, id), 409, "character_busy")
	if n := p.Count(`select count(*) from enter_tickets where ticket_id = $1 and consumed_at is null`, second); n != 1 {
		t.Fatal("character_busy consumió el billete")
	}
}

func TestClaimOnStartingInstance(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	ticket, _ := p.MustEnter(pl, id)
	p.Exec(`update zone_instances set status = 'starting' where zone_instance_id = $1`, z.ID)
	platformtest.Expect(t, z.Claim(ticket, id), 409, "instance_not_live")
}

// Una reclamación con un ticket_id de más de 2^53 vale (viaja en cadena, §4.1).
func TestClaimBigTicketID(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	ticket, _ := p.MustEnter(pl, id)
	const big = int64(1)<<62 + 12345
	p.Exec(`update enter_tickets set ticket_id = $2 where ticket_id = $1`, ticket, big)
	res := z.Do("POST", "/internal/v1/claims", `{"zone_instance_id": "`+z.ID+`", "ticket_id": "`+
		strconv.FormatInt(big, 10)+`", "character_id": "`+strconv.FormatInt(id, 10)+`"}`)
	platformtest.Expect(t, res, 200, "")
	// Un id sin comillas es 400.
	res = z.Do("POST", "/internal/v1/claims", `{"zone_instance_id": "`+z.ID+`", "ticket_id": 5, "character_id": "1"}`)
	platformtest.Expect(t, res, 400, "bad_request")
}

func TestClaimDeletedCharacter(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	pl := p.NewPlayer("a@example.org")
	id := p.NewCharacter(pl, "Aneira", "vardheim")
	ticket, _ := p.MustEnter(pl, id)
	res := p.PublicDo("DELETE", "/v1/characters/"+strconv.FormatInt(id, 10), pl.Token, map[string]any{"confirm_name": "Aneira"})
	platformtest.Expect(t, res, 200, "")
	platformtest.Expect(t, z.Claim(ticket, id), 409, "ticket_invalid")
}

// Con la cuenta suspendida, expulsada o con el borrado pedido: 403 account_blocked con kind,
// until_unix, reason y un message de 255 B como mucho, que compone la plataforma.
func TestClaimAccountBlocked(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	now := p.Clock.Now()
	long := strings.Repeat("motivo largo con tildes: áéíóú ", 20)
	cases := []struct {
		kind  string
		setup func(account int64)
		until *time.Time
	}{
		{"suspension", func(a int64) {
			p.Exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', $2, $3, $4)`,
				a, long, now.Add(-time.Minute), now.Add(48*time.Hour))
		}, ptr(now.Add(48 * time.Hour))},
		{"ban", func(a int64) {
			p.Exec(`insert into sanctions (account_id, kind, reason, starts_at) values ($1, 'ban', 'bots', $2)`, a, now.Add(-time.Minute))
		}, nil},
		{"pending_deletion", func(a int64) {
			p.Exec(`update accounts set status = 'pending_deletion', deletion_requested_at = $2, purge_after = $3
				where account_id = $1`, a, now, now.Add(14*24*time.Hour))
		}, ptr(now.Add(14 * 24 * time.Hour))},
	}
	for i, c := range cases {
		pl := p.NewPlayer(strconv.Itoa(i) + "@example.org")
		id := p.NewCharacter(pl, []string{"Aneira", "Bran", "Cora"}[i], "vardheim")
		ticket, _ := p.MustEnter(pl, id)
		c.setup(pl.ID)
		res := z.Claim(ticket, id)
		platformtest.Expect(t, res, 403, "account_blocked")
		msg, _ := res.ErrValue("message").(string)
		if res.ErrValue("kind") != c.kind || msg == "" || len(msg) > 255 {
			t.Fatalf("%s: %s", c.kind, res.Raw)
		}
		until := res.ErrValue("until_unix")
		switch {
		case c.until == nil && until != nil:
			t.Fatalf("%s: until_unix %v", c.kind, until)
		case c.until != nil && (until == nil || until.(json.Number).String() != strconv.FormatInt(c.until.Unix(), 10)):
			t.Fatalf("%s: until_unix %v", c.kind, until)
		}
		if c.kind == "suspension" && !strings.HasPrefix(res.ErrValue("reason").(string), "motivo largo") {
			t.Fatal(res.Raw)
		}
		if n := p.Count(`select count(*) from enter_tickets where ticket_id = $1 and consumed_at is null`, ticket); n != 1 {
			t.Fatal("el billete quedó consumido")
		}
	}
}

func ptr(t time.Time) *time.Time { return &t }

// Un DELETE y una reclamación del mismo personaje a la vez dejan o un borrado sin arrendamiento o
// un vivo con él (bloquean los dos la fila de la cuenta).
func TestDeleteAndClaimAtOnce(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	outcomes := map[string]int{}
	for round := 0; round < 8; round++ {
		pl := p.NewPlayer("r" + strconv.Itoa(round) + "@example.org")
		id := p.NewCharacter(pl, "Ronda"+string(rune('a'+round)), "vardheim")
		ticket, _ := p.MustEnter(pl, id)
		var wg sync.WaitGroup
		var del, claim *platformtest.Response
		wg.Add(2)
		go func() {
			defer wg.Done()
			del = p.PublicDo("DELETE", "/v1/characters/"+strconv.FormatInt(id, 10), pl.Token,
				map[string]any{"confirm_name": "Ronda" + string(rune('a'+round))})
		}()
		go func() {
			defer wg.Done()
			claim = z.Claim(ticket, id)
		}()
		wg.Wait()
		var deleted, leased bool
		p.Scalar(&deleted, `select deleted_at is not null from characters where character_id = $1`, id)
		p.Scalar(&leased, `select exists (select 1 from character_leases where character_id = $1
			and zone_instance_id is not null and expires_at > $2)`, id, p.Clock.Now())
		switch {
		case deleted && !leased && del.Status == 200 && claim.Code() == "ticket_invalid":
			outcomes["borrado"]++
		case !deleted && leased && claim.Status == 200 && del.Code() == "character_busy":
			outcomes["reclamado"]++
		default:
			t.Fatalf("ronda %d: borrado=%v arrendado=%v; DELETE %d %s; claim %d %s", round, deleted, leased,
				del.Status, del.Raw, claim.Status, claim.Raw)
		}
	}
	t.Logf("resultados: %v", outcomes)
}

// Dos reclamaciones a la vez de dos personajes de la misma cuenta: solo una gana y la otra da
// character_busy; y enter del segundo con el primero dentro, también.
func TestOneCharacterPerAccountInTheWorld(t *testing.T) {
	p := platformtest.New(t)
	z0 := p.NewZone(1, "vado_gris", 0).Start()
	for round := 0; round < 5; round++ {
		pl := p.NewPlayer("c" + strconv.Itoa(round) + "@example.org")
		a := p.NewCharacter(pl, "Uno"+string(rune('a'+round)), "vardheim")
		b := p.NewCharacter(pl, "Dos"+string(rune('a'+round)), "vardheim")
		ticketA, _ := p.MustEnter(pl, a)
		ticketB, _ := p.MustEnter(pl, b)
		results := make([]*platformtest.Response, 2)
		var wg sync.WaitGroup
		for i, c := range []struct{ ticket, id int64 }{{ticketA, a}, {ticketB, b}} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				results[i] = z0.Claim(c.ticket, c.id)
			}()
		}
		wg.Wait()
		won := -1
		for i, r := range results {
			switch {
			case r.Status == 200:
				if won >= 0 {
					t.Fatalf("ronda %d: ganan los dos", round)
				}
				won = i
			case r.Code() != "character_busy":
				t.Fatalf("ronda %d: %d %s", round, r.Status, r.Raw)
			}
		}
		if won < 0 {
			t.Fatalf("ronda %d: no gana ninguno", round)
		}
		loser := []int64{a, b}[1-won]
		platformtest.Expect(t, p.Enter(pl, loser), 409, "character_busy")
	}
}

// Dos instancias reclaman a la vez el mismo personaje (con un billete cada una): una gana y la otra
// recibe character_busy.
func TestTwoInstancesClaimAtOnce(t *testing.T) {
	p := platformtest.New(t)
	z0 := p.NewZone(1, "vado_gris", 0).Start()
	z1 := p.NewZone(1, "vado_gris", 1).Start()
	for round := 0; round < 5; round++ {
		pl := p.NewPlayer("z" + strconv.Itoa(round) + "@example.org")
		id := p.NewCharacter(pl, "Doble"+string(rune('a'+round)), "vardheim")
		t0, inst := p.MustEnter(pl, id)
		if inst != z0.ID {
			t.Fatal(inst)
		}
		t1, _ := p.MustEnter(pl, id)
		p.Exec(`update enter_tickets set zone_instance_id = $2 where ticket_id = $1`, t1, z1.ID)
		results := make([]*platformtest.Response, 2)
		var wg sync.WaitGroup
		for i, c := range []struct {
			z      *platformtest.Zone
			ticket int64
		}{{z0, t0}, {z1, t1}} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				results[i] = c.z.Claim(c.ticket, id)
			}()
		}
		wg.Wait()
		ok := 0
		for _, r := range results {
			switch {
			case r.Status == 200:
				ok++
			case r.Code() != "character_busy":
				t.Fatalf("ronda %d: %d %s", round, r.Status, r.Raw)
			}
		}
		if ok != 1 {
			t.Fatalf("ronda %d: %d ganadoras", round, ok)
		}
	}
}
