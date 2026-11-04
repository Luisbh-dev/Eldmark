class_name PlayerProgress
extends RefCounted
## The authoritative progress state of a character in the zone (docs/progression.md §4, §5, §6 and §9): its
## [ProgressRecord] (inventory, currencies, level, timers…), the journal of operations that no save has confirmed
## yet, and the aggregate of in-game gains and spends. It is created by [method ProgressService.prepare] (with a
## platform) or by the registration of an ephemeral character (P5b), and discarded by [method ProgressService.on_departure].
## [br][br]
## [b]Operations[/b] (§5.2): standalone ones ([method begin_op]: player DESTROY, kit, GM, reversal) go to the journal
## with their ledger entries and events, and before each one the aggregate is closed as a GAMEPLAY operation, so the
## journal is always in application order and each [code]balance_after[/code] comes from the balance already recorded.
## Gameplay ones ([method gain_currency], [method gain_items], [method lose_items], [method camp_refill]) change the
## balance or the bag immediately and are recorded when the save is built: one entry per (currency, reason,
## [code]ref_kind[/code], [code]ref_id[/code]) and one event without [code]uid[/code] per (definition, reason).
## [br][br]
## [b]The [code]progress[/code] section[/b] (§9.2): [method build_section] closes the aggregate with an id from the
## saves range (without one it returns [code]{}[/code] and touches nothing), takes the snapshot and returns only the
## operations with [member EconomyOp.save_seq] 0, to which it assigns the [code]seq[/code]; [method acknowledge]
## removes from the journal those with [code]save_seq ≤ seq[/code]; [method is_dirty] tells whether there is anything
## to save at the checkpoint.
## [br][br]
## [b]Ids[/b] ([IdAllocator], §4.5): client requests take from the clients range, server changes from the server's
## own, and closing the aggregate when building takes from the saves range. Server only: no clock (Unix time arrives
## in [member Live.now_unix], from [method ZonePlatform.now_unix]).

## Unconfirmed journal operations from which a DESTROY returns NOT_NOW (with a platform, §4.2); without a platform,
## the journal keeps the latest ones (§9.4).
const JOURNAL_LIMIT: int = 256
## How far the position must move to count as a change in [method is_dirty] (m).
const MOVE_EPSILON_M: float = 0.1
## Ticks per second of the timers (§8).
const TICKS_PER_SECOND: int = 60


## What the in-world body contributes to the snapshot: provided by [member live_source] (set by
## [method ProgressService.on_arrival]; by hand in tests).
class Live:
	extends RefCounted
	## [code]zone_id[/code], [code]channel[/code], [code]x[/code], [code]y[/code], [code]z[/code],
	## [code]yaw[/code] and [code]in_combat[/code] (§3.4); empty = no position.
	var location: Dictionary = {}
	## Health of the [Combatant]; −1 = full.
	var health: int = -1
	## Bit0 of [code]combat_flags2[/code] (the only source of the active slot, §4.1).
	var active_weapon_slot: int = 0
	## The loaded time plus the time played since registration.
	var played_seconds: int = 0
	## Unix time from the platform (0 = no clock: timers are left untouched).
	var now_unix: int = 0


## The live record: what operations change and what goes into each snapshot.
var record: ProgressRecord
## true with a platform (it is saved); false for an ephemeral character (§9.4).
var persistent: bool = false
## 0 for an ephemeral character.
var character_id: int = 0
var account_id: int = 0
## Tick of registration ([method ProgressService.on_arrival]); −1 before that.
var arrival_tick: int = -1
## The loaded played time (the record's at registration): time played is added to this, not to that of the last snapshot.
var played_base: int = 0
## [code]() -> Live[/code] (or null without a body): what the body contributes to the snapshot. Without it, the snapshot
## uses the record's values.
var live_source: Callable = Callable()
## Inventory revision of this session (§4.6): starts at 1 and increases with every applied change. It is not saved.
var revision: int = 1
## XP gained since the last PROGRESS_UPDATE and its source ([enum ProgressMessages.XpSource]; P5c sends them and
## resets them to 0).
var pending_xp_gain: int = 0
var pending_xp_source: int = 0
## Reason ([EconomyReason]) of the last change of each currency (index = currency; 0 = none): the one for WALLET_UPDATE
## ([method ProgressService.flush]).
var last_currency_reasons: PackedInt32Array = PackedInt32Array()

var _ids: IdAllocator = null
var _db: ItemDatabase = null
var _journal: Array[EconomyOp] = []
## Balance of each currency after the last journal entry (what the platform will see recorded).
var _ledger_balance: PackedInt64Array = PackedInt64Array()
## The unclosed aggregate: key → ledger entry (its balance_after is computed on closing) and key → event without uid.
var _pending_ledger: Dictionary[String, LedgerEntry] = {}
var _pending_items: Dictionary[String, ItemEvent] = {}
## Cooldowns of a weapon that is not equipped (§4.1), by [CombatCatalog] id.
var _stashed: Dictionary[int, PackedInt64Array] = {}
## The snapshot of the last confirmed save (or of registration) and those of bodies built but not yet confirmed, by seq.
var _confirmed: Dictionary = {}
var _built: Dictionary[int, Dictionary] = {}
## What was in place at the last operation opened with [method begin_op], for [method abort_op].
var _open_mark: Dictionary = {}
## The live uids (uid → def_id) the platform will have when the next body reaches it: those of the loaded record
## and, after each [method build_section], those of its snapshot (a character's bodies are applied in order).
var _saved_uids: Dictionary[int, StringName] = {}


func _init(p_record: ProgressRecord, p_persistent: bool, ids: IdAllocator, db: ItemDatabase) -> void:
	record = p_record if p_record != null else ProgressRecord.new_character()
	persistent = p_persistent
	_ids = ids if ids != null else IdAllocator.local()
	_db = db if db != null else ItemDatabase.shared()
	_ledger_balance = record.wallets.duplicate()
	last_currency_reasons.resize(Currency.WALLET_SIZE)
	_confirmed = _snapshot(null)
	_saved_uids = _live_uids()


## The id generator it uses.
func get_ids() -> IdAllocator:
	return _ids


## The snapshot of the current body is the confirmed one: called by registration (entering without changing anything
## does not make it dirty, §9.2).
func confirm_current() -> void:
	_confirmed = _snapshot(_live())


# --- Client requests ----------------------------------------------------------------------------

## A client request ([InventoryOps.Request]) with [param context], where the server has already set the active slot
## of the [CombatState], [code]can_touch_equipment[/code] and [code]drinking[/code]; here the level, the definitions
## and the ids from the clients range are set. First, the DESTROY cap: with a platform and [constant JOURNAL_LIMIT]
## or more unconfirmed operations, NOT_NOW (the platform is not responding: the body must not grow without limit,
## §4.2). An applied DESTROY creates its PLAYER operation with the PLAYER_DESTROY event and
## [member InventoryOps.Outcome.new_id] as [code]op_id[/code] (after closing the aggregate).
func apply_request(request: InventoryOps.Request, context: InventoryOps.Context) -> InventoryOps.Outcome:
	if request.op == InventoryOps.Op.DESTROY and persistent and unconfirmed_count() >= JOURNAL_LIMIT:
		var refused := InventoryOps.Outcome.new()
		refused.result = InventoryOps.Result.NOT_NOW
		if record.inventory.has_slot(request.from_container, request.from_slot):
			refused.changed.append(Vector2i(request.from_container, request.from_slot))
		return refused
	context.db = _db
	context.level = record.level
	context.new_uid = _ids.next_for_client
	var outcome: InventoryOps.Outcome = InventoryOps.apply(record.inventory, request, context)
	if not outcome.is_ok():
		return outcome
	revision += 1
	if request.op == InventoryOps.Op.DESTROY:
		# Closing the aggregate goes first in the journal (§5.2); if there were no server id (does not happen: one from the
		# clients range was left), the aggregate is closed afterwards, and DESTROY carries no entries to order.
		_close_aggregate(_ids.next_for_server)
		var op: EconomyOp = EconomyOp.create(outcome.new_id, EconomyOp.Kind.PLAYER)
		op.items.assign(outcome.events)
		_append(op)
	return outcome


# --- Standalone operations ---------------------------------------------------------------------

## Opens a standalone operation of [param kind] (kit, GM, reversal) with the actor, the [param note] and the
## [param detail] of the trail (§10), after closing the aggregate as a GAMEPLAY operation. It goes into the journal
## right away: whatever is added to it ([method add_items], [method remove_items], [method change_currency]) goes out
## with it. null if there are no ids in the server range (to close or for it; what was closed stays in the journal).
## Saves the state from right after closing the aggregate for [method abort_op] (P5d: "all or nothing" from §10).
func begin_op(kind: int, actor_account_id: int, note: String, detail: Dictionary) -> EconomyOp:
	if not _close_aggregate(_ids.next_for_server):
		return null
	var id: int = _ids.next_for_server()
	if id == 0:
		return null
	var op: EconomyOp = EconomyOp.create(id, kind, actor_account_id, note, detail)
	_append(op)
	_open_mark = {
		"op": op, "inventory": record.inventory.duplicate_state(), "wallets": record.wallets.duplicate(),
		"ledger_balance": _ledger_balance.duplicate(), "realm_points": record.realm_points, "level": record.level,
		"xp_total": record.xp_total, "reasons": last_currency_reasons.duplicate(), "revision": revision,
		"pending_xp_gain": pending_xp_gain, "pending_xp_source": pending_xp_source,
	}
	return op


## Removes [param op] from the journal if it is the last one, has not yet gone out in any body and carries nothing (an
## operation that could not be completed: "all or nothing" from §10). Its id is lost (a gap does not matter, §4.5).
## true if it removes it.
func discard_op(op: EconomyOp) -> bool:
	if op == null or _journal.is_empty() or _journal[-1] != op or op.save_seq != 0 or not op.is_empty():
		return false
	_journal.pop_back()
	return true


## Undoes [param op] entirely (P5d, "all or nothing" from §10): if it is the last one in the journal, has not yet gone
## out in any body and is the last one opened with [method begin_op], the inventory, balances, realm points, level and
## XP from right after opening it are restored and the operation leaves the journal (the aggregate it closed stays).
## Its id and those of the stacks it created are lost. true if it undoes it.
func abort_op(op: EconomyOp) -> bool:
	if op == null or _open_mark.get("op") != op or _journal.is_empty() or _journal[-1] != op or op.save_seq != 0:
		return false
	record.inventory = _open_mark["inventory"]
	record.wallets = _open_mark["wallets"]
	_ledger_balance = _open_mark["ledger_balance"]
	record.realm_points = _open_mark["realm_points"]
	record.level = _open_mark["level"]
	record.xp_total = _open_mark["xp_total"]
	last_currency_reasons = _open_mark["reasons"]
	revision = _open_mark["revision"]
	pending_xp_gain = _open_mark["pending_xp_gain"]
	pending_xp_source = _open_mark["pending_xp_source"]
	_open_mark = {}
	_journal.pop_back()
	return true


## Creates [param count] units of [param def_id] in the bag within [param op] (source or internal): into stacks with
## room first and the rest into new stacks with ids from the server range. false if it does not fit, ids are missing or
## the operation has already gone out in a body: then nothing changes.
func add_items(op: EconomyOp, def_id: StringName, count: int, reason: int) -> bool:
	return op_add_items(op, def_id, count, reason).is_ok()


## [method add_items] with its [InventoryOps.Outcome] (the slots of the INVENTORY_DELTA). A closed operation returns
## NOT_NOW.
func op_add_items(op: EconomyOp, def_id: StringName, count: int, reason: int) -> InventoryOps.Outcome:
	if not _is_open(op):
		return _refused(InventoryOps.Result.NOT_NOW)
	return _record_in(op, InventoryOps.add_items(record.inventory, def_id, count, reason, _server_context()))


## Creates [param count] units of [param def_id] within [param op] in new stacks in the first free slots of the bag,
## without merging ([method InventoryOps.create_items]: the GM [code]item_give[/code] and what a reversal recreates),
## copying the fields of [param template] if there is one.
func op_create_items(op: EconomyOp, def_id: StringName, count: int, reason: int,
		template: ItemInstance = null) -> InventoryOps.Outcome:
	if not _is_open(op):
		return _refused(InventoryOps.Result.NOT_NOW)
	return _record_in(op, InventoryOps.create_items(record.inventory, def_id, count, reason, _server_context(),
			template))


## Removes [param count] units of [param def_id] within [param op] (sink or internal), first from
## [param prefer_uid]. false if there are not that many or the operation has already gone out in a body: then nothing
## changes. It does not look at the active slot (I10): removing an equipped weapon is the caller's business.
func remove_items(op: EconomyOp, def_id: StringName, count: int, reason: int,
		prefer_uid: int = 0) -> bool:
	return op_remove_items(op, def_id, count, reason, prefer_uid).is_ok()


## [method remove_items] with its [InventoryOps.Outcome], without touching the slots of [param protected] (the equipment's
## active one in a reversal, §10).
func op_remove_items(op: EconomyOp, def_id: StringName, count: int, reason: int, prefer_uid: int = 0,
		protected: Array[Vector2i] = []) -> InventoryOps.Outcome:
	if not _is_open(op):
		return _refused(InventoryOps.Result.NOT_NOW)
	return _record_in(op, InventoryOps.remove_items(record.inventory, def_id, count, reason, prefer_uid, protected))


## A ledger entry of [param delta] in [param currency] within [param op], with its [code]balance_after[/code]. All or
## nothing (§5.4): false if the currency does not exist, the sign does not match the reason, the balance would fall
## outside 0 … cap or the operation has already gone out in a body. Merit entries with reason 3–5 raise realm points (I9).
func change_currency(op: EconomyOp, currency: int, delta: int, reason: int, ref_kind: int,
		ref_id: int) -> bool:
	if not _is_open(op) or not Currency.is_valid(currency) or not EconomyReason.sign_matches(reason, delta):
		return false
	if not CurrencyRules.can_apply(record.wallets[currency], delta) \
			or not CurrencyRules.can_apply(_ledger_balance[currency], delta):
		return false
	record.wallets[currency] += delta
	_ledger_balance[currency] += delta
	last_currency_reasons[currency] = reason
	op.ledger.append(LedgerEntry.create(currency, delta, _ledger_balance[currency], reason, ref_kind, ref_id))
	if currency == Currency.Code.MERITS and EconomyReason.gives_realm_points(reason):
		record.realm_points = maxi(record.realm_points + delta, 0)
	return true


# --- The aggregate -----------------------------------------------------------------------------------

## An in-game gain (merits, NPC gold and captures): changes the balance immediately, clamped to the cap (§5.4), and is
## recorded when the save is built. Merits with reason 3–5 raise realm points. Returns what was applied (0 if the
## currency does not exist, the reason is not a source or the balance is already at the cap).
func gain_currency(currency: int, amount: int, reason: int, ref_kind: int, ref_id: int) -> int:
	if not Currency.is_valid(currency) or not EconomyReason.is_source(reason):
		return 0
	var applied: int = CurrencyRules.clamp_gain(record.wallets[currency], amount)
	if applied <= 0:
		return 0
	record.wallets[currency] += applied
	last_currency_reasons[currency] = reason
	var key: String = "%d:%d:%d:%d" % [currency, reason, ref_kind, ref_id]
	if _pending_ledger.has(key):
		_pending_ledger[key].delta += applied
	else:
		_pending_ledger[key] = LedgerEntry.create(currency, applied, 0, reason, ref_kind, ref_id)
	if currency == Currency.Code.MERITS and EconomyReason.gives_realm_points(reason):
		record.realm_points += applied
	return applied


## Adds [param count] units of [param def_id] to the bag from gameplay (aggregate, with ids from the server range for
## new stacks). false if it does not fit or ids are missing: nothing changes.
func gain_items(def_id: StringName, count: int, reason: int) -> bool:
	var outcome: InventoryOps.Outcome = InventoryOps.add_items(record.inventory, def_id, count, reason,
			_server_context())
	if not outcome.is_ok():
		return false
	_aggregate(outcome.events)
	revision += 1
	return true


## Removes [param count] units of [param def_id] from gameplay (CONSUME: from the bag stack with the lowest slot),
## aggregate. false if there are not that many: nothing changes.
func lose_items(def_id: StringName, count: int, reason: int) -> bool:
	return take_items(def_id, count, reason).is_ok()


## [method lose_items] with its [InventoryOps.Outcome]: the slots that changed, for the server's INVENTORY_DELTA (P5b).
func take_items(def_id: StringName, count: int, reason: int) -> InventoryOps.Outcome:
	var outcome: InventoryOps.Outcome = InventoryOps.remove_items(record.inventory, def_id, count, reason)
	if outcome.is_ok():
		_aggregate(outcome.events)
		revision += 1
	return outcome


## Aggregate CAMP_REFILL (§4.4): restocks the total of each definition with [member ItemDefinition.camp_refill]; a new
## stack takes an id from the server range and, without one, that part waits for the next attempt. Returns the result of
## [method InventoryOps.camp_refill] ([code]changed[/code] and [code]bag_full[/code], for the delta and the P5b
## notice).
func camp_refill() -> InventoryOps.Outcome:
	var outcome: InventoryOps.Outcome = InventoryOps.camp_refill(record.inventory, _server_context())
	if not outcome.events.is_empty():
		_aggregate(outcome.events)
		revision += 1
	return outcome


## Unclosed aggregate entries and events (tests and metrics).
func pending_aggregate_count() -> int:
	return _pending_ledger.size() + _pending_items.size()


# --- Kit, XP and combat -----------------------------------------------------------------------------

## The starter kit (§2.5) of [param template_id] in a STARTER_KIT operation (ids from the server range), if
## [member ProgressRecord.starter_granted] is false; the caller marks the save as critical. false if it was already
## given, if the inventory is not empty or if ids are missing: then nothing changes ([code]starter_granted[/code]
## stays false and arrives on the next entry, §4.5). A template that does not exist or cannot be chosen uses the first
## eligible one by id, with a warning ([method StarterKit.template_for]).
func grant_starter_kit(template_id: StringName) -> bool:
	if record.starter_granted:
		return false
	if not record.inventory.all_items().is_empty():
		push_warning("[Eldmark] Progreso: el personaje %d no tiene el kit pero su inventario no está vacío"
				% character_id)
		return false
	var op: EconomyOp = begin_op(EconomyOp.Kind.STARTER_KIT, 0, "", {})
	if op == null:
		return false
	var events: Array[ItemEvent] = StarterKit.grant(record.inventory, template_id, _db, _ids.next_for_server)
	if events.is_empty():
		discard_op(op)
		return false
	op.items.assign(events)
	record.starter_granted = true
	revision += 1
	return true


## Adds [param amount] of XP ([method ProgressionRules.add_xp], I8) from [param source]
## ([enum ProgressMessages.XpSource]); what is applied accumulates in [member pending_xp_gain] for PROGRESS_UPDATE.
func add_xp(amount: int, source: int) -> ProgressionRules.XpResult:
	var result: ProgressionRules.XpResult = ProgressionRules.add_xp(LevelCurve.shared(), record.level,
			record.xp_total, amount)
	record.level = result.level
	record.xp_total = result.xp_total
	if result.applied > 0:
		pending_xp_gain += result.applied
		pending_xp_source = source
	return result


## The consumable charges (§4.4): [code]min(15, count_of(def))[/code] of each one from
## [method ItemDatabase.consumable_definition], packed as [member CombatState.consumable_charges].
func charges() -> int:
	var counts: Array[int] = [0, 0]
	for index: int in range(CombatState.CONSUMABLE_SLOTS):
		var definition: ItemDefinition = _db.consumable_definition(index)
		if definition != null:
			counts[index] = mini(record.inventory.count_of(definition.id), CombatState.MAX_CHARGES)
	return CombatState.pack_charges(counts[0], counts[1])


## The active slot it enters with (§8): the record's and, if it has no weapon and the other slot does, the other (I10).
func saved_active_slot() -> int:
	return _effective_active_slot(record.active_weapon_slot)


## The equipment's weapons (slots 0 and 1) as [CombatCatalog] ids; 0 = empty.
func weapons() -> PackedInt32Array:
	var result := PackedInt32Array([0, 0])
	for slot: int in range(InventoryState.OPEN_EQUIPMENT_SLOTS):
		var item: ItemInstance = record.inventory.get_item(InventoryState.ContainerId.EQUIPMENT, slot)
		var definition: ItemDefinition = _db.get_definition(item.def_id) if item != null else null
		if definition != null and definition.category == ItemDefinition.Category.WEAPON:
			result[slot] = CombatCatalog.weapon_id(definition.ref_id)
	return result


## Stores in memory the cooldowns (absolute ticks) of the weapon [param weapon_id] being removed (§4.1).
func stash_ready(weapon_id: int, ready: PackedInt64Array) -> void:
	if weapon_id != 0:
		_stashed[weapon_id] = ready.duplicate()


## The stored cooldowns of the weapon [param weapon_id] (empty if there are none).
func stashed_ready(weapon_id: int) -> PackedInt64Array:
	return (_stashed.get(weapon_id, PackedInt64Array()) as PackedInt64Array).duplicate()


## The end in Unix time of a cooldown that finishes at tick [param ready_tick], seen at tick [param s] with the time
## [param now_unix] (§8): [code]now_unix + ceili((ready_tick − s) / 60.0)[/code], an integer rounded up (it never
## expires early); one already expired gives [param now_unix].
static func ends_at_unix_for(ready_tick: int, s: int, now_unix: int,
		ticks_per_second: int = TICKS_PER_SECOND) -> int:
	return now_unix + maxi(ceili(float(ready_tick - s) / float(ticks_per_second)), 0)


## The tick at which a stored cooldown with end [param ends_at_unix] finishes, seen at tick [param s] with the time
## [param now_unix] (§8): [code]s + max(0, ends_at_unix − now_unix) · 60[/code].
static func ready_tick_for(ends_at_unix: int, now_unix: int, s: int,
		ticks_per_second: int = TICKS_PER_SECOND) -> int:
	return s + maxi(ends_at_unix - now_unix, 0) * ticks_per_second


# --- The progress section ----------------------------------------------------------------------------

## The [code]progress[/code] section of save [param seq] (§9.3): closes the aggregate as a GAMEPLAY operation with an id
## from the saves range, takes the snapshot (position, yaw, health, "in combat", played time and the body's active
## slot; expired timers dropped) and returns the record without the read-only fields with
## [code]ops[/code]: only the operations with [member EconomyOp.save_seq] 0, to which it assigns [param seq]. Without an
## id to close the aggregate it returns [code]{}[/code] and touches nothing (§4.5).
## [br][br]
## [b]Event uids[/b] (S4, §13.3: an event with a [code]uid[/code] that adds belongs to one that was not alive in the
## base, and one that subtracts, to one that was): the body carries an event's [code]uid[/code] only if it meets that
## with what the base will have on receiving it (the previous body's snapshot or the loaded record); otherwise,
## [code]null[/code], like an aggregate event. This happens when destroying or removing a stack that has not been saved
## yet (half of a SPLIT) or when adding to one that was already saved (the GM 16, which merges). Quantities do not
## change, and the journal keeps the real [code]uid[/code].
func build_section(seq: int) -> Dictionary:
	if not _close_aggregate(_ids.next_for_build):
		return {}
	var live: Live = _live()
	_apply_live(live)
	var ops: Array = []
	for op: EconomyOp in _journal:
		if op.save_seq == 0:
			op.save_seq = seq
			ops.append(_saved_form(op))
	var data: Dictionary = record.to_dictionary()
	data["ops"] = ops
	_built[seq] = _snapshot(live)
	_saved_uids = _live_uids()
	return data


## After a 200 [code]applied[/code] or [code]duplicate[/code] for save [param seq]: removes from the journal the
## operations with [code]save_seq ≤ seq[/code] and its snapshot becomes the confirmed one. Those of a later in-flight
## body stay.
func acknowledge(seq: int) -> void:
	var kept: Array[EconomyOp] = []
	for op: EconomyOp in _journal:
		if op.save_seq == 0 or op.save_seq > seq:
			kept.append(op)
	_journal = kept
	if _built.has(seq):
		_confirmed = _built[seq]
	for built_seq: int in _built.keys():
		if built_seq <= seq:
			_built.erase(built_seq)


## true if there is anything to save at the checkpoint (§9.2): an operation with [code]save_seq[/code] 0 or something
## aggregated, a record field different from the last confirmed one (level, XP, realm points, currencies, inventory,
## active slot, timers…), the position moved at least [constant MOVE_EPSILON_M] or a different health. Played time
## alone does not make it dirty: it goes with the next save.
func is_dirty() -> bool:
	if not _pending_ledger.is_empty() or not _pending_items.is_empty():
		return true
	for op: EconomyOp in _journal:
		if op.save_seq == 0:
			return true
	return _differs(_snapshot(_live()), _confirmed)


## The journal: with a platform, the unconfirmed operations (in application order); without one, the latest
## [constant JOURNAL_LIMIT] (§9.4).
func journal() -> Array[EconomyOp]:
	return _journal.duplicate()


## Unconfirmed journal operations (with a platform, the DESTROY cap).
func unconfirmed_count() -> int:
	return _journal.size()


# --- Internal -----------------------------------------------------------------------------------

func _server_context() -> InventoryOps.Context:
	var context := InventoryOps.Context.new()
	context.db = _db
	context.level = record.level
	context.new_uid = _ids.next_for_server
	return context


# A journal operation that has not yet gone out in any body (what was already sent does not change).
func _is_open(op: EconomyOp) -> bool:
	return op != null and op.save_seq == 0 and _journal.has(op)


# The inventory's live uids (uid → def_id).
func _live_uids() -> Dictionary[int, StringName]:
	var uids: Dictionary[int, StringName] = {}
	for item: ItemInstance in record.inventory.all_items():
		uids[item.uid] = item.def_id
	return uids


# The ops entry of [param op] in the body: without the uid of events that S4 would not accept given what is saved
# (see build_section).
func _saved_form(op: EconomyOp) -> Dictionary:
	var data: Dictionary = op.to_dictionary()
	var events: Array = data["items"]
	for i: int in range(op.items.size()):
		var event: ItemEvent = op.items[i]
		if event.uid == 0:
			continue
		var saved: bool = _saved_uids.get(event.uid, &"") == event.def_id
		if (event.count_delta > 0 and _saved_uids.has(event.uid)) or (event.count_delta < 0 and not saved):
			(events[i] as Dictionary)["uid"] = null
	return data


static func _refused(result: int) -> InventoryOps.Outcome:
	var outcome := InventoryOps.Outcome.new()
	outcome.result = result
	return outcome


# The events of [param outcome], if it was applied, pass to [param op] and the revision increases.
func _record_in(op: EconomyOp, outcome: InventoryOps.Outcome) -> InventoryOps.Outcome:
	if outcome.is_ok():
		op.items.append_array(outcome.events)
		revision += 1
	return outcome


func _append(op: EconomyOp) -> void:
	_journal.append(op)
	if not persistent:
		while _journal.size() > JOURNAL_LIMIT:
			_journal.pop_front()


func _aggregate(events: Array[ItemEvent]) -> void:
	for event: ItemEvent in events:
		var key: String = "%s:%d" % [event.def_id, event.reason]
		if _pending_items.has(key):
			_pending_items[key].count_delta += event.count_delta
		else:
			_pending_items[key] = ItemEvent.create(0, event.def_id, event.count_delta, event.reason)


# Closes the aggregate into a GAMEPLAY operation with an id from [param take]. true if there was nothing or it was
# closed; false (touching nothing) if there is no id.
func _close_aggregate(take: Callable) -> bool:
	if _pending_ledger.is_empty() and _pending_items.is_empty():
		return true
	var id: int = take.call()
	if id == 0:
		return false
	var op: EconomyOp = EconomyOp.create(id, EconomyOp.Kind.GAMEPLAY)
	for key: String in _pending_ledger:
		var entry: LedgerEntry = _pending_ledger[key]
		_ledger_balance[entry.currency] += entry.delta
		entry.balance_after = _ledger_balance[entry.currency]
		op.ledger.append(entry)
	for key: String in _pending_items:
		if _pending_items[key].count_delta != 0:
			op.items.append(_pending_items[key])
	_pending_ledger.clear()
	_pending_items.clear()
	if not op.is_empty():
		_append(op)
	return true


func _live() -> Live:
	if not live_source.is_valid():
		return null
	var value: Variant = live_source.call()
	return value as Live if value is Live else null


# What the body holds goes into the record (the snapshot of this save).
func _apply_live(live: Live) -> void:
	if live != null:
		if not live.location.is_empty():
			record.location = live.location.duplicate()
		record.health = live.health
		record.active_weapon_slot = live.active_weapon_slot
		record.played_seconds = maxi(record.played_seconds, live.played_seconds)
		if live.now_unix > 0:
			for key: String in record.timers.keys():
				if record.timers[key] <= live.now_unix:
					record.timers.erase(key)
	record.active_weapon_slot = _effective_active_slot(record.active_weapon_slot)


# The active slot that is saved (§8): the body's and, if it has no weapon and the other slot does, the other (I10).
func _effective_active_slot(slot: int) -> int:
	slot = clampi(slot, 0, InventoryState.OPEN_EQUIPMENT_SLOTS - 1)
	var equipment: int = InventoryState.ContainerId.EQUIPMENT
	if record.inventory.get_item(equipment, slot) == null and record.inventory.get_item(equipment, 1 - slot) != null:
		return 1 - slot
	return slot


# What is_dirty compares: the record's fields, the inventory revision and the body's values.
func _snapshot(live: Live) -> Dictionary:
	var location: Dictionary = record.location
	var health: int = record.health
	var slot: int = record.active_weapon_slot
	if live != null:
		if not live.location.is_empty():
			location = live.location
		health = live.health
		slot = live.active_weapon_slot
	return {
		"level": record.level, "xp_total": record.xp_total, "realm_points": record.realm_points,
		"starter_granted": record.starter_granted, "bag_slots": record.bag_slots,
		"active_weapon_slot": _effective_active_slot(slot), "wallets": record.wallets.duplicate(),
		"revision": revision, "timers": record.timers.duplicate(), "location": location.duplicate(),
		"health": health,
	}


static func _differs(now: Dictionary, confirmed: Dictionary) -> bool:
	for key: String in ["level", "xp_total", "realm_points", "starter_granted", "bag_slots", "active_weapon_slot",
			"wallets", "revision", "timers", "health"]:
		if now.get(key) != confirmed.get(key):
			return true
	var here: Dictionary = now.get("location", {})
	var there: Dictionary = confirmed.get("location", {})
	if here.is_empty() or there.is_empty():
		return here.is_empty() != there.is_empty()
	if here.get("zone_id") != there.get("zone_id") or here.get("channel") != there.get("channel"):
		return true
	var a := Vector3(float(here.get("x", 0.0)), float(here.get("y", 0.0)), float(here.get("z", 0.0)))
	var b := Vector3(float(there.get("x", 0.0)), float(there.get("y", 0.0)), float(there.get("z", 0.0)))
	return a.distance_to(b) >= MOVE_EPSILON_M
