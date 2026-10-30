package progress

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"eldmark/platform/internal/jsonx"
	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/sanctions"
	"eldmark/platform/internal/zones"
)

// Las comprobaciones del guardado S2–S7 (progresion.md §13.3) sobre la sección ya leída (S1, section.go) y
// el estado del personaje en la base, bloqueado. Van en orden y la primera que falla da el check del
// *persistence.InvalidSaveError; S8 (write.go) escribe.

// Límites de S2, S5 y S7.
const (
	// atUnixSlack es cuánto puede ir detail.at_unix por delante de ahora o por detrás del granted_at de su
	// bloque (S2).
	atUnixSlack = 60
	// maxTimers son los temporizadores de un personaje como mucho (S7, ProgressRecord.MAX_TIMERS).
	maxTimers = 16
	// maxTimerAhead es lo más lejos que puede acabar un temporizador (S7).
	maxTimerAhead = 7 * 24 * time.Hour
	// maxNoteLen es la note más larga, en caracteres (economy_ops.note, EconomyOp.MAX_NOTE_LENGTH).
	maxNoteLen = 200
	// maxDurability es la durabilidad llena (por mil, §2.1).
	maxDurability = 1000
	// maxSeed es la mayor semilla de afijos (u32, item_instances.seed).
	maxSeed = 1<<32 - 1
	// maxCountDelta es el mayor count_delta en valor absoluto (item_events.count_delta int).
	maxCountDelta = 1<<31 - 1
	// maxRefKind es el mayor ref_kind de un apunte (LedgerEntry.RefKind.OP).
	maxRefKind = 4
	// maxArgs y maxArgLen acotan detail.args de una GM o una REVERSAL.
	maxArgs   = 32
	maxArgLen = 255
)

var (
	timerKeyPattern = regexp.MustCompile(`^[a-z0-9_:]{1,48}$`)
	// commandPattern es el command de una operación de la zona: el de su lote de auditoría
	// (social.commandPattern), así S8 nunca escribe uno de la CLI («set-role») ni de la plataforma.
	commandPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}$`)
	// detailKeys son las claves de detail de una GM o una REVERSAL (progresion.md §10); las de nivel y XP
	// solo cuando el comando los toca.
	detailKeys = map[string]bool{"command": true, "args": true, "source": true, "actor_character_id": true,
		"at_unix": true, "level_before": true, "level_after": true, "xp_before": true, "xp_after": true, "xp_delta": true}
	// detailColumns son las claves de detail que S8 pone en su propia columna de audit_log; el resto va en args.
	detailColumns = map[string]bool{"command": true, "source": true, "actor_character_id": true, "at_unix": true}
)

// Fuentes de detail.source (progresion.md §10) y su source en audit_log (plataforma.md §9.1).
const (
	sourceGM      = "gm"
	sourceConsole = "console"
	sourceDebug   = "debug"
)

// checkError es un error de la comprobación check.
func checkError(check, format string, args ...any) error {
	return &persistence.InvalidSaveError{Check: check, Detail: fmt.Sprintf(format, args...)}
}

// dbItem es un objeto vivo del personaje en la base.
type dbItem struct {
	defID           string
	count           int64
	durability      *int64
	rarity, seed    int64
	bound           bool
	affixes         []int64
	container, slot int64
}

// dbWallet es un saldo del personaje en la base.
type dbWallet struct{ balance, lastSeq int64 }

// block es un bloque de ids de la instancia que guarda.
type block struct {
	first   int64
	granted time.Time
}

// state es lo que el guardado mira en la base, leído con el progreso, los saldos y los objetos vivos del
// personaje bloqueados (for update): dos Apply del mismo personaje van en serie aunque quien llama no tenga
// su arrendamiento bloqueado.
type state struct {
	accountID      int64
	starterGranted bool
	xpTotal        int64
	realmPoints    int64
	playedSeconds  int64
	bagSlots       int64
	wallets        map[int64]dbWallet
	items          map[int64]dbItem
	blocks         []block
}

// gmDetail es el detail ya leído de una GM o una REVERSAL.
type gmDetail struct {
	command   string
	source    string
	actorChar *int64
	atUnix    int64
	auditArgs json.RawMessage // detail sin lo que va en columnas propias (S8)
}

// apply es un guardado en curso: la clave, la sección leída, el estado de la base y lo que las comprobaciones
// dejan para S8.
type apply struct {
	s     *Store
	key   persistence.SaveKey
	sec   *section
	db    *state
	now   time.Time
	gm    map[int64]*gmDetail // op_id → detail de las GM y REVERSAL
	newID map[int64]bool      // uids de la foto que no están vivos en la base (se insertan)
	// realmReverted son las operaciones que revierte el cuerpo con méritos de motivo 3–5 de este personaje: sus
	// REVERSAL bajan los puntos de reino (I9, S6).
	realmReverted map[int64]bool
}

// Apply implementa persistence.ProgressStore: S1 (la sección), S2–S7 (contra la base, con el estado del
// personaje bloqueado) y S8 (la escritura). Un fallo de S1–S7 es un *persistence.InvalidSaveError y no
// escribe nada; un error de la base en S8 lo clasifica quien llama (plataforma.md §7.3). Devuelve el
// save_version nuevo.
func (s *Store) Apply(ctx context.Context, tx pgx.Tx, key persistence.SaveKey, progress json.RawMessage) (int64, error) {
	sec, err := parseSection(progress, key.ZoneID)
	if err != nil {
		return 0, err
	}
	db, err := s.loadState(ctx, tx, key)
	if err != nil {
		return 0, err
	}
	a := &apply{s: s, key: key, sec: sec, db: db, now: s.now(), gm: map[int64]*gmDetail{}, newID: map[int64]bool{},
		realmReverted: map[int64]bool{}}
	if err := a.checkOps(ctx, tx); err != nil {
		return 0, err
	}
	for _, check := range []func() error{a.checkLedger, a.checkItems, a.checkSnapshot, a.checkProgress,
		a.checkTimers} {
		if err := check(); err != nil {
			return 0, err
		}
	}
	return a.write(ctx, tx)
}

// loadState lee y bloquea el estado del personaje y los bloques de ids de la instancia.
func (s *Store) loadState(ctx context.Context, tx pgx.Tx, key persistence.SaveKey) (*state, error) {
	st := &state{wallets: map[int64]dbWallet{}, items: map[int64]dbItem{}}
	var bagSlots int16
	err := tx.QueryRow(ctx, `select c.account_id, p.starter_granted, p.xp_total, p.realm_points, p.played_seconds,
			p.bag_slots
		from character_progress p join characters c using (character_id)
		where p.character_id = $1 for update of p`, key.CharacterID).Scan(&st.accountID, &st.starterGranted,
		&st.xpTotal, &st.realmPoints, &st.playedSeconds, &bagSlots)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, checkError("S1", "el personaje %d no tiene progreso", key.CharacterID)
	}
	if err != nil {
		return nil, err
	}
	st.bagSlots = int64(bagSlots)
	rows, err := tx.Query(ctx, `select currency, balance, last_seq from character_wallets where character_id = $1
		for update`, key.CharacterID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var currency int16
		var w dbWallet
		if err := rows.Scan(&currency, &w.balance, &w.lastSeq); err != nil {
			rows.Close()
			return nil, err
		}
		st.wallets[int64(currency)] = w
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows, err = tx.Query(ctx, `select uid, def_id, count, durability, rarity, seed, bound, affixes, container, slot
		from item_instances where character_id = $1 and retired_at is null for update`, key.CharacterID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var uid int64
		var it dbItem
		var count int32
		var durability *int16
		var rarity, container, slot int16
		var affixes []int32
		if err := rows.Scan(&uid, &it.defID, &count, &durability, &rarity, &it.seed, &it.bound, &affixes, &container,
			&slot); err != nil {
			rows.Close()
			return nil, err
		}
		it.count, it.rarity, it.container, it.slot = int64(count), int64(rarity), int64(container), int64(slot)
		if durability != nil {
			d := int64(*durability)
			it.durability = &d
		}
		for _, a := range affixes {
			it.affixes = append(it.affixes, int64(a))
		}
		st.items[uid] = it
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows, err = tx.Query(ctx, `select first_id, granted_at from id_blocks where zone_instance_id = $1 order by first_id`,
		key.InstanceID)
	if err != nil {
		return nil, err
	}
	st.blocks, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (block, error) {
		var b block
		err := row.Scan(&b.first, &b.granted)
		return b, err
	})
	return st, err
}

// blockOf devuelve el bloque de la instancia que contiene id.
func (st *state) blockOf(id int64) (block, bool) {
	for _, b := range st.blocks {
		if id >= b.first && id < b.first+zones.BlockSize {
			return b, true
		}
	}
	return block{}, false
}

// checkOps es S2: los op_id caen en los bloques de la instancia, no se repiten y no están ya guardados; cada
// tipo, con sus motivos y sus campos; GM y REVERSAL, con note, detail y un actor con rol en detail.at_unix (o
// desde la consola); STARTER_KIT solo una vez; REVERSAL de una operación guardada de este personaje que no es
// REVERSAL ni MIGRATION y que nadie ha revertido.
func (a *apply) checkOps(ctx context.Context, tx pgx.Tx) error {
	k := a.s.rules.kinds
	ids := make([]int64, 0, len(a.sec.ops))
	seen := map[int64]bool{}
	reverted := map[int64]bool{}
	kits := 0
	for _, o := range a.sec.ops {
		if seen[o.opID] {
			return checkError("S2", "la operación %d va dos veces en el cuerpo", o.opID)
		}
		seen[o.opID] = true
		ids = append(ids, o.opID)
		if _, ok := a.db.blockOf(o.opID); !ok {
			return checkError("S2", "la operación %d no cae en ningún bloque de ids de la instancia", o.opID)
		}
		kind := int(o.kind)
		reasons, known := a.s.rules.kindReasons[kind]
		switch {
		case kind == k.migration:
			return checkError("S2", "la operación %d es una MIGRATION: solo la crean las migraciones SQL", o.opID)
		case !known:
			return checkError("S2", "la operación %d es de un tipo que una zona no puede guardar (%d)", o.opID, kind)
		}
		for _, e := range o.ledger {
			if !reasons[int(e.reason)] {
				return checkError("S2", "la operación %d (tipo %d) lleva un apunte con el motivo %d", o.opID, kind,
					e.reason)
			}
		}
		for _, e := range o.items {
			if !reasons[int(e.reason)] {
				return checkError("S2", "la operación %d (tipo %d) lleva un evento con el motivo %d", o.opID, kind,
					e.reason)
			}
		}
		if o.note != nil {
			if n := *o.note; utf8.RuneCountInString(n) > maxNoteLen || strings.ContainsRune(n, 0) {
				return checkError("S2", "la note de la operación %d pasa de %d caracteres o lleva un NUL", o.opID,
					maxNoteLen)
			}
		}
		if kind == k.reversal {
			if o.refOp == nil {
				return checkError("S2", "la REVERSAL %d no dice qué operación revierte", o.opID)
			}
			if reverted[*o.refOp] {
				return checkError("S2", "la operación %d se revierte dos veces en el cuerpo", *o.refOp)
			}
			reverted[*o.refOp] = true
		} else if o.refOp != nil {
			return checkError("S2", "la operación %d no es una REVERSAL y lleva ref_op_id", o.opID)
		}
		if kind == k.gm || kind == k.reversal {
			if err := a.checkActor(ctx, tx, o); err != nil {
				return err
			}
			continue
		}
		if o.actor != nil {
			return checkError("S2", "la operación %d (tipo %d) lleva actor_account_id: solo GM y REVERSAL", o.opID, kind)
		}
		var detail map[string]json.RawMessage
		if json.Unmarshal(o.detail, &detail) != nil || len(detail) > 0 {
			return checkError("S2", "la operación %d (tipo %d) lleva detail: solo GM y REVERSAL", o.opID, kind)
		}
		if kind == k.starterKit {
			kits++
			if kits > 1 || a.db.starterGranted {
				return checkError("S2", "un STARTER_KIT con el kit ya dado (starter_granted en la base)")
			}
		}
	}
	if len(ids) > 0 {
		var saved []int64
		rows, err := tx.Query(ctx, `select op_id from economy_ops where op_id = any($1) order by op_id`, ids)
		if err != nil {
			return err
		}
		if saved, err = pgx.CollectRows(rows, pgx.RowTo[int64]); err != nil {
			return err
		}
		if len(saved) > 0 {
			return checkError("S2", "la operación %d ya está guardada", saved[0])
		}
	}
	for refOp := range reverted {
		if err := a.checkReverted(ctx, tx, refOp); err != nil {
			return err
		}
	}
	return nil
}

// checkActor es la parte de S2 de una GM o una REVERSAL: note, detail y actor.
func (a *apply) checkActor(ctx context.Context, tx pgx.Tx, o op) error {
	if o.note == nil || strings.TrimSpace(*o.note) == "" {
		return checkError("S2", "la operación %d es GM o REVERSAL y no lleva note", o.opID)
	}
	d, err := parseDetail(o)
	if err != nil {
		return err
	}
	a.gm[o.opID] = d
	b, _ := a.db.blockOf(o.opID)
	switch {
	case d.atUnix > a.now.Unix()+atUnixSlack:
		return checkError("S2", "detail.at_unix de la operación %d es del futuro (%d)", o.opID, d.atUnix)
	case d.atUnix < b.granted.Unix()-atUnixSlack:
		return checkError("S2", "detail.at_unix de la operación %d es anterior a su bloque de ids", o.opID)
	}
	if d.source == sourceConsole {
		if o.actor != nil || d.actorChar != nil {
			return checkError("S2", "la operación %d es de la consola y lleva actor", o.opID)
		}
		return nil
	}
	if o.actor == nil {
		return checkError("S2", "la operación %d no es de la consola y no lleva actor_account_id", o.opID)
	}
	if d.actorChar == nil {
		return checkError("S2", "la operación %d no lleva detail.actor_character_id", o.opID)
	}
	var owner int64
	err = tx.QueryRow(ctx, `select account_id from characters where character_id = $1`, *d.actorChar).Scan(&owner)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && owner != *o.actor) {
		return checkError("S2", "detail.actor_character_id de la operación %d no es de la cuenta del actor", o.opID)
	}
	if err != nil {
		return err
	}
	role, err := sanctions.RoleAt(ctx, tx, *o.actor, time.Unix(d.atUnix, 0))
	if err != nil {
		return err
	}
	if role != sanctions.RoleGM && role != sanctions.RoleAdmin {
		return checkError("S2", "el actor de la operación %d no tenía rol gm ni admin en detail.at_unix (%q)", o.opID, role)
	}
	if *o.actor == a.db.accountID && role != sanctions.RoleAdmin {
		return checkError("S2", "la operación %d es de un gm sobre un personaje de su cuenta: solo admin", o.opID)
	}
	return nil
}

// parseDetail lee el detail de una GM o una REVERSAL (progresion.md §10): command, args (cadenas), source
// (gm, console o debug), at_unix y, si lo hay, actor_character_id; las de nivel y XP, enteros.
func parseDetail(o op) (*gmDetail, error) {
	fail := func(format string, args ...any) error {
		return checkError("S2", "detail de la operación %d: %s", o.opID, fmt.Sprintf(format, args...))
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(o.detail, &fields); err != nil {
		return nil, fail("no es un objeto")
	}
	for k := range fields {
		if !detailKeys[k] {
			return nil, fail("clave desconocida %q", k)
		}
	}
	d := &gmDetail{}
	if err := json.Unmarshal(fields["command"], &d.command); err != nil || !commandPattern.MatchString(d.command) {
		return nil, fail("command no vale")
	}
	if err := json.Unmarshal(fields["source"], &d.source); err != nil ||
		(d.source != sourceGM && d.source != sourceConsole && d.source != sourceDebug) {
		return nil, fail("source tiene que ser gm, console o debug")
	}
	var args []string
	if raw, ok := fields["args"]; !ok || isNull(raw) || json.Unmarshal(raw, &args) != nil || len(args) > maxArgs {
		return nil, fail("args tiene que ser una lista de %d cadenas como mucho", maxArgs)
	}
	for _, arg := range args {
		if len(arg) > maxArgLen {
			return nil, fail("un argumento pasa de %d B", maxArgLen)
		}
	}
	raw, ok := fields["at_unix"]
	var at jsonx.Int
	if !ok || json.Unmarshal(raw, &at) != nil || at < 0 {
		return nil, fail("falta at_unix o no es un entero")
	}
	d.atUnix = int64(at)
	if raw, ok := fields["actor_character_id"]; ok && !isNull(raw) {
		var id jsonx.ID
		if json.Unmarshal(raw, &id) != nil || id < 1 || int64(id) > jsonx.MaxSafeInt {
			return nil, fail("actor_character_id no es un id")
		}
		v := int64(id)
		d.actorChar = &v
	}
	audit := map[string]json.RawMessage{}
	for k, raw := range fields {
		if detailColumns[k] {
			continue
		}
		if k != "args" {
			var v jsonx.Int
			if json.Unmarshal(raw, &v) != nil {
				return nil, fail("%s no es un entero", k)
			}
		}
		audit[k] = raw
	}
	b, err := json.Marshal(audit)
	if err != nil {
		return nil, err
	}
	d.auditArgs = b
	return d, nil
}

// checkReverted es la parte de S2 de la operación que revierte una REVERSAL: guardada, de este personaje, que
// no es REVERSAL ni MIGRATION y que no está en op_reversals. Anota también si dio puntos de reino a este
// personaje (méritos de motivo 3–5), para S6.
func (a *apply) checkReverted(ctx context.Context, tx pgx.Tx, refOp int64) error {
	var kind int16
	var mine, done, realm bool
	realmReasons := make([]int16, 0, len(a.s.rules.realmReasons))
	for r := range a.s.rules.realmReasons {
		realmReasons = append(realmReasons, int16(r))
	}
	err := tx.QueryRow(ctx, `select e.kind,
			exists (select 1 from op_participants p where p.op_id = e.op_id and p.character_id = $2),
			exists (select 1 from op_reversals r where r.op_id = e.op_id),
			exists (select 1 from ledger_entries l where l.op_id = e.op_id and l.character_id = $2
				and l.currency = $3 and l.reason = any($4))
		from economy_ops e where e.op_id = $1`, refOp, a.key.CharacterID, a.s.rules.merits, realmReasons).
		Scan(&kind, &mine, &done, &realm)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return checkError("S2", "la operación revertida %d no existe", refOp)
	case err != nil:
		return err
	case !mine:
		return checkError("S2", "la operación revertida %d no es de este personaje", refOp)
	case int(kind) == a.s.rules.kinds.reversal || int(kind) == a.s.rules.kinds.migration:
		return checkError("S2", "la operación %d es una REVERSAL o una MIGRATION: no se revierte", refOp)
	case done:
		return checkError("S2", "la operación %d ya está revertida", refOp)
	}
	a.realmReverted[refOp] = realm
	return nil
}

// checkLedger es S3: por moneda y en el orden del diario, balance_after = anterior + delta, entre 0 y el tope
// y con el signo del rango de su motivo; el saldo de la foto es el último (o el de la base, sin apuntes).
func (a *apply) checkLedger() error {
	rules := a.s.rules
	balances := map[int64]int64{}
	for code, w := range a.db.wallets {
		balances[code] = w.balance
	}
	for _, o := range a.sec.ops {
		for _, e := range o.ledger {
			limit, ok := rules.currencyCaps[int(e.currency)]
			switch {
			case !ok:
				return checkError("S3", "la operación %d apunta en una moneda que no existe (%d)", o.opID, e.currency)
			case !rules.signMatches(int(e.reason), e.delta):
				return checkError("S3", "la operación %d: el delta %d no tiene el signo del motivo %d", o.opID, e.delta,
					e.reason)
			case e.balanceAfter != balances[e.currency]+e.delta:
				return checkError("S3", "la operación %d: balance_after %d no es %d %+d", o.opID, e.balanceAfter,
					balances[e.currency], e.delta)
			case e.balanceAfter < 0 || e.balanceAfter > limit:
				return checkError("S3", "la operación %d deja la moneda %d en %d (0–%d)", o.opID, e.currency,
					e.balanceAfter, limit)
			case e.refKind < 0 || e.refKind > maxRefKind:
				return checkError("S3", "la operación %d: ref_kind fuera de rango (%d)", o.opID, e.refKind)
			}
			balances[e.currency] = e.balanceAfter
		}
	}
	photo := map[int64]int64{}
	for _, w := range a.sec.wallets {
		if _, ok := rules.currencyCaps[int(w.currency)]; !ok {
			return checkError("S3", "la foto tiene una moneda que no existe (%d)", w.currency)
		}
		if _, dup := photo[w.currency]; dup {
			return checkError("S3", "la foto repite la moneda %d", w.currency)
		}
		photo[w.currency] = w.balance
	}
	for _, c := range rules.Currencies {
		code := int64(c.Code)
		got, ok := photo[code]
		switch {
		case !ok:
			return checkError("S3", "a la foto le falta la moneda %d", code)
		case got != balances[code]:
			return checkError("S3", "el saldo de la moneda %d en la foto es %d y el libro dice %d", code, got,
				balances[code])
		}
	}
	return nil
}

// checkItems es S4 (I4): por definición, lo vivo en la base más los eventos es lo de la foto; un evento con
// uid que suma es de un uid que no estaba vivo en la base para este personaje, y uno que resta, de uno que sí
// (con la misma definición).
func (a *apply) checkItems() error {
	totals := map[string]int64{}
	for _, it := range a.db.items {
		totals[it.defID] += it.count
	}
	for _, o := range a.sec.ops {
		for _, e := range o.items {
			switch {
			case !itemIDPattern.MatchString(e.defID):
				return checkError("S4", "la operación %d tiene un evento con un def_id que no vale (%q)", o.opID, e.defID)
			case e.countDelta == 0 || e.countDelta > maxCountDelta || e.countDelta < -maxCountDelta:
				return checkError("S4", "la operación %d tiene un evento con count_delta %d", o.opID, e.countDelta)
			case !a.s.rules.signMatches(int(e.reason), e.countDelta):
				return checkError("S4", "la operación %d: el count_delta %d no tiene el signo del motivo %d", o.opID,
					e.countDelta, e.reason)
			}
			if e.uid != nil {
				alive, ok := a.db.items[*e.uid]
				if e.countDelta > 0 && ok {
					return checkError("S4", "la operación %d da %d de un uid que ya estaba vivo (%d)", o.opID,
						e.countDelta, *e.uid)
				}
				if e.countDelta < 0 && (!ok || alive.defID != e.defID) {
					return checkError("S4", "la operación %d quita de un uid que no estaba vivo con ese objeto (%d)",
						o.opID, *e.uid)
				}
			}
			totals[e.defID] += e.countDelta
		}
	}
	for _, it := range a.sec.items {
		totals[it.defID] -= it.count
	}
	for def, diff := range totals {
		if diff != 0 {
			return checkError("S4", "la cantidad de %s no cuadra: la base y los eventos dan %+d respecto a la foto",
				def, diff)
		}
	}
	return nil
}

// checkSnapshot es S5: la foto. Uids sin repetir, contenedor abierto, ranuras únicas y en rango, definición en
// las reglas, cantidad, durabilidad, rareza 0 y sin afijos (fase 5), solo armas en el equipo y la ranura
// activa con arma (I10); un uid que ya estaba vivo conserva def_id, semilla, rareza y afijos y no se desliga
// (I1, I12), y uno nuevo cae en un bloque de la instancia. Si ya existe (de otro personaje o retirado), la
// clave primaria lo para en S8.
func (a *apply) checkSnapshot() error {
	rules := a.s.rules
	uids := map[int64]bool{}
	slots := map[[2]int64]bool{}
	weapons := map[int64]bool{}
	bag, equipment := int64(rules.Containers.Bag.Code), int64(rules.Containers.Equipment.Code)
	bagLimit := min(a.sec.bagSlots, int64(rules.Containers.Bag.MaxSlots))
	for _, it := range a.sec.items {
		if uids[it.uid] {
			return checkError("S5", "el uid %d está dos veces en la foto", it.uid)
		}
		uids[it.uid] = true
		def, ok := rules.Item(it.defID)
		switch {
		case !containsInt(rules.Containers.Open, int(it.container)):
			return checkError("S5", "el uid %d está en el contenedor %d", it.uid, it.container)
		case slots[[2]int64{it.container, it.slot}]:
			return checkError("S5", "dos objetos en la ranura %d del contenedor %d", it.slot, it.container)
		case it.container == bag && (it.slot < 0 || it.slot >= bagLimit):
			return checkError("S5", "el uid %d está en la ranura %d de una bolsa de %d", it.uid, it.slot, a.sec.bagSlots)
		case it.container == equipment && (it.slot < 0 || it.slot >= int64(rules.Containers.Equipment.OpenSlots)):
			return checkError("S5", "el uid %d está en la ranura %d del equipo", it.uid, it.slot)
		case !ok:
			return checkError("S5", "el uid %d es de un objeto que no está en las reglas (%q)", it.uid, it.defID)
		case it.count < 1 || it.count > int64(def.MaxStack):
			return checkError("S5", "el uid %d tiene %d de %s (1–%d)", it.uid, it.count, it.defID, def.MaxStack)
		case def.HasDurability && (it.durability == nil || *it.durability < 0 || *it.durability > maxDurability):
			return checkError("S5", "el uid %d necesita durabilidad de 0 a %d", it.uid, maxDurability)
		case !def.HasDurability && it.durability != nil:
			return checkError("S5", "el uid %d lleva durabilidad y %s no tiene", it.uid, it.defID)
		case it.rarity != 0 || len(it.affixes) > 0:
			return checkError("S5", "el uid %d lleva rareza o afijos (en la fase 5, rareza 0 y sin afijos)", it.uid)
		case it.seed > maxSeed:
			return checkError("S5", "el uid %d tiene una semilla que no es u32", it.uid)
		case it.container == equipment && def.Category != CategoryWeapon:
			return checkError("S5", "el uid %d (%s) está en el equipo y no es un arma", it.uid, it.defID)
		}
		slots[[2]int64{it.container, it.slot}] = true
		if it.container == equipment {
			weapons[it.slot] = true
		}
		if old, alive := a.db.items[it.uid]; alive {
			switch {
			case old.defID != it.defID || old.seed != it.seed || old.rarity != it.rarity ||
				!equalInts(old.affixes, it.affixes):
				return checkError("S5", "el uid %d cambia de objeto, semilla, rareza o afijos (I1)", it.uid)
			case old.bound && !it.bound:
				return checkError("S5", "el uid %d deja de estar ligado (I12)", it.uid)
			}
			continue
		}
		if _, ok := a.db.blockOf(it.uid); !ok {
			return checkError("S5", "el uid nuevo %d no cae en ningún bloque de ids de la instancia", it.uid)
		}
		a.newID[it.uid] = true
	}
	if slot := a.sec.activeWeaponSlot; slot >= 0 && slot < int64(rules.Containers.Equipment.OpenSlots) && !weapons[slot] {
		return checkError("S5", "la ranura activa (%d) no tiene arma (I10)", slot)
	}
	return nil
}

// checkProgress es S6: nivel de la curva (I8), XP que no baja sin GM ni REVERSAL, puntos de reino (I9),
// bag_slots y starter_granted (I12), ranura activa, tiempo jugado que no baja y vida.
func (a *apply) checkProgress() error {
	rules := a.s.rules
	sec := a.sec
	levelCap := rules.LevelCurve.LevelCap
	switch {
	case sec.xpTotal < 0 || sec.xpTotal > rules.TotalTo(levelCap):
		return checkError("S6", "xp_total fuera de rango (0–%d): %d", rules.TotalTo(levelCap), sec.xpTotal)
	case sec.level < 1 || sec.level > int64(levelCap) || sec.level != int64(rules.LevelFor(sec.xpTotal)):
		return checkError("S6", "el nivel %d no es el de %d de XP (%d)", sec.level, sec.xpTotal,
			rules.LevelFor(sec.xpTotal))
	case sec.xpTotal < a.db.xpTotal && !a.hasKind(rules.kinds.gm, rules.kinds.reversal):
		return checkError("S6", "xp_total baja de %d a %d sin una GM ni una REVERSAL", a.db.xpTotal, sec.xpTotal)
	case sec.bagSlots != a.db.bagSlots:
		return checkError("S6", "bag_slots cambia de %d a %d (en la fase 5 no cambia)", a.db.bagSlots, sec.bagSlots)
	case a.db.starterGranted && !sec.starterGranted:
		return checkError("S6", "starter_granted vuelve a false (I12)")
	case sec.activeWeaponSlot < 0 || sec.activeWeaponSlot >= int64(rules.Containers.Equipment.OpenSlots):
		return checkError("S6", "active_weapon_slot fuera de rango: %d", sec.activeWeaponSlot)
	case sec.playedSeconds < a.db.playedSeconds:
		return checkError("S6", "played_seconds baja de %d a %d", a.db.playedSeconds, sec.playedSeconds)
	case sec.health != nil && (*sec.health < 0 || *sec.health > int64(rules.Combat.HealthMax)):
		return checkError("S6", "la vida %d no está entre 0 y %d", *sec.health, rules.Combat.HealthMax)
	}
	want := a.db.realmPoints
	merits := int64(rules.merits)
	for _, o := range a.sec.ops {
		for _, e := range o.ledger {
			if e.currency == merits && rules.realmReasons[int(e.reason)] {
				want += e.delta
			}
		}
	}
	for _, o := range a.sec.ops {
		if int(o.kind) != rules.kinds.reversal || !a.revertsRealmMerits(o) {
			continue
		}
		for _, e := range o.ledger {
			if e.currency == merits {
				want += e.delta
			}
		}
	}
	if sec.realmPoints != want || sec.realmPoints < 0 {
		return checkError("S6", "realm_points es %d y los méritos de juego dan %d (I9)", sec.realmPoints, want)
	}
	return nil
}

// hasKind dice si el cuerpo lleva alguna operación de esos tipos.
func (a *apply) hasKind(kinds ...int) bool {
	for _, o := range a.sec.ops {
		if containsInt(kinds, int(o.kind)) {
			return true
		}
	}
	return false
}

// revertsRealmMerits dice si la REVERSAL o revierte una operación con méritos que dieron puntos de reino a
// este personaje (lo anota checkReverted).
func (a *apply) revertsRealmMerits(o op) bool {
	return o.refOp != nil && a.realmReverted[*o.refOp]
}

// checkTimers es S7: como mucho 16, claves con formato y sin repetir, y ninguno acaba a más de 7 días. Las
// fechas pasadas valen (un reintento tardío; la zona descarta los vencidos al cargar).
func (a *apply) checkTimers() error {
	if len(a.sec.timers) > maxTimers {
		return checkError("S7", "%d temporizadores (%d como mucho)", len(a.sec.timers), maxTimers)
	}
	limit := a.now.Add(maxTimerAhead).Unix()
	seen := map[string]bool{}
	for _, t := range a.sec.timers {
		switch {
		case !timerKeyPattern.MatchString(t.key):
			return checkError("S7", "la clave %q no tiene el formato %s", t.key, timerKeyPattern)
		case seen[t.key]:
			return checkError("S7", "la clave %q está repetida", t.key)
		case t.endsAt < 0 || t.endsAt > limit:
			return checkError("S7", "el temporizador %q acaba a más de 7 días (%d)", t.key, t.endsAt)
		}
		seen[t.key] = true
	}
	return nil
}

func containsInt(list []int, v int) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func equalInts(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
