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

// The claim consumes the ticket, takes the lease and brings the account, the character (with the
// realm in its code), the store's progress section and the pvp totals.
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
	claimedAt := p.Clock.Now()
	p.Scalar(&consumed, `select consumed_at is not null from enter_tickets where ticket_id = $1`, ticket)
	p.Scalar(&entered, `select last_entered_at is not null from characters where character_id = $1`, id)
	if !consumed || entered {
		t.Fatalf("billete consumido %v, last_entered_at %v (la reclamación no lo escribe)", consumed, entered)
	}
	var stored string
	p.Scalar(&stored, `select lease_id::text from character_leases where character_id = $1 and zone_instance_id = $2
		and claimed_by = $2 and last_seq = 0`, id, z.ID)
	if stored != lease {
		t.Fatal(stored)
	}
	// With the character inside, enter gives character_busy.
	platformtest.Expect(t, p.Enter(pl, id), 409, "character_busy")
	// The first save records the entry into the world with the claim's time (the notices, §9.5).
	p.Clock.Advance(time.Minute)
	platformtest.Expect(t, z.Save(id, z.SaveBody(id, lease, 1)), 200, "")
	p.Scalar(&entered, `select last_entered_at = $2 from characters where character_id = $1`, id, claimedAt)
	if !entered {
		t.Fatal("last_entered_at tras el primer guardado")
	}
}

// Consumed, expired, from another instance and from a revoked session ticket: ticket_invalid, and
// the ticket that was not used is not left consumed.
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

	// From another instance: the ticket is z0's (channel 0: both empty, the lower wins).
	ticket, instance := p.MustEnter(pl, id)
	if instance != z0.ID {
		t.Fatal(instance)
	}
	platformtest.Expect(t, z1.Claim(ticket, id), 409, "ticket_invalid")
	notConsumed(ticket)
	// From another character.
	other := p.NewCharacter(pl, "Bran", "vardheim")
	platformtest.Expect(t, z0.Claim(ticket, other), 409, "ticket_invalid")
	notConsumed(ticket)
	// Expired: after 10 s and 5 of margin.
	p.Clock.Advance(15 * time.Second)
	platformtest.Expect(t, z0.Claim(ticket, id), 409, "ticket_invalid")
	notConsumed(ticket)
	// One that does not exist.
	platformtest.Expect(t, z0.Claim(ticket+1, id), 409, "ticket_invalid")

	// From a revoked session: logging in again revokes the ticket's one.
	p.Login(pl)
	ticket, _ = p.MustEnter(pl, id)
	p.Login(pl)
	platformtest.Expect(t, z0.Claim(ticket, id), 409, "ticket_invalid")
	notConsumed(ticket)

	// Consumed: the second use fails.
	ticket, _ = p.MustEnter(pl, id)
	p.Clock.Advance(14 * time.Second) // within the 5 s margin
	z0.MustClaim(ticket, id)
	platformtest.Expect(t, z0.Claim(ticket, id), 409, "ticket_invalid")
}

// character_busy does not consume the ticket: two tickets of the same character before claiming; the
// second clashes with the first's lease.
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

// A claim with a ticket_id above 2^53 is valid (it travels as a string, §4.1).
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
	// An unquoted id is 400.
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

// With the account suspended, banned or with deletion requested: 403 account_blocked with kind,
// until_unix, reason and a message of 255 B at most, composed by the platform.
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

// Without a valid ticket, the claim says nothing about the account (§5.3): with an invented
// ticket_id or another character's ticket, one suspended or with deletion requested, from this world
// or another, it gives the same 409 ticket_invalid as one that does not exist, without kind,
// until_unix or reason. With its ticket, 403 account_blocked, and the ticket is still unconsumed.
func TestClaimRevealsNothingWithoutATicket(t *testing.T) {
	p := platformtest.New(t)
	z := p.NewZone(1, "vado_gris", 0).Start()
	now := p.Clock.Now()
	suspended := p.NewPlayer("s@example.org")
	idS := p.NewCharacter(suspended, "Aneira", "vardheim")
	ticket, _ := p.MustEnter(suspended, idS)
	p.Exec(`insert into sanctions (account_id, kind, reason, starts_at, ends_at) values ($1, 'suspension', 'motivo privado', $2, $3)`,
		suspended.ID, now.Add(-time.Minute), now.Add(48*time.Hour))
	elsewhere := p.NewPlayer("w@example.org")
	idW := p.NewCharacterIn(elsewhere, 2, "Bran", 1)
	p.Exec(`insert into sanctions (account_id, kind, reason, starts_at) values ($1, 'ban', 'otro motivo privado', $2)`,
		elsewhere.ID, now.Add(-time.Minute))
	leaving := p.NewPlayer("l@example.org")
	idL := p.NewCharacter(leaving, "Cora", "vardheim")
	p.Exec(`update accounts set status = 'pending_deletion', deletion_requested_at = $2, purge_after = $3
		where account_id = $1`, leaving.ID, now, now.Add(14*24*time.Hour))
	nobody := z.Claim(1, 999999)
	for _, c := range []struct{ ticket, id int64 }{{1, idS}, {1, idW}, {1, idL}, {ticket, idW}, {ticket, idL}} {
		res := z.Claim(c.ticket, c.id)
		platformtest.Expect(t, res, 409, "ticket_invalid")
		if res.Raw != nobody.Raw || strings.Contains(res.Raw, "motivo") || res.ErrValue("kind") != nil ||
			res.ErrValue("until_unix") != nil {
			t.Fatalf("billete %d, personaje %d: %s", c.ticket, c.id, res.Raw)
		}
	}
	platformtest.Expect(t, z.Claim(ticket, idS), 403, "account_blocked")
	if n := p.Count(`select count(*) from enter_tickets where ticket_id = $1 and consumed_at is null`, ticket); n != 1 {
		t.Fatal("el billete quedó consumido")
	}
}

// A DELETE and a claim of the same character at once leave either a deletion without a lease or a
// living character with one (both lock the account's row).
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

// Two simultaneous claims of two characters of the same account: only one wins and the other gives
// character_busy; and enter of the second with the first inside, too.
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

// Two instances claim the same character at once (with one ticket each): one wins and the other
// receives character_busy.
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
