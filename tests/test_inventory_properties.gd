extends TestCase
## Inventory properties (docs/progression.md §3.2 and §4, PRG-11): 20 seeds × 1000 random operations,
## valid and invalid (client requests, SWAP of the active slot, CAMP_REFILL, CONSUME and the GM
## changes), on an inventory that starts with the starter kit. No sequence creates or loses objects or
## repeats a uid.
## [br][br]
## [b]Incremental[/b], after each operation: a mirror of the slots is brought up to date with
## [member InventoryOps.Outcome.changed]; the quantity of each definition that changes in the mirror is the sum of
## the [member InventoryOps.Outcome.events] (I4), the uids that leave die forever and those that enter are
## new (I1); after CAMP_REFILL, [code]count_of(def) ≤ max(camp_refill, before)[/code].
## [b]Full[/b], every 100 operations and at the end: the mirror is the state (nothing changed outside
## [code]changed[/code]), the quantities are those of the events, no uid is repeated or is a dead one, every
## instance is valid (I3), binding never goes back (I12) and in the equipment there are only weapons at 0 and 1, with the
## active one occupied (I10).
## [br][br]
## The long version (20 × 5000) only runs with [code]--filter=inventory_properties_long[/code].

const BAG: int = InventoryState.ContainerId.BAG
const EQUIP: int = InventoryState.ContainerId.EQUIPMENT
const SEEDS: int = 20
const OPERATIONS: int = 1000
const LONG_OPERATIONS: int = 5000
const FULL_CHECK_EVERY: int = 100
const LONG_FILTER: String = "inventory_properties_long"
const ARMOR_FIXTURES: String = "res://tests/fixtures/items/armor"

var _db: ItemDatabase


func before_each() -> void:
	_db = _property_db()


func test_random_operations_keep_the_invariants() -> void:
	var started: int = Time.get_ticks_msec()
	var totals: Dictionary = {}
	for seed_index: int in range(SEEDS):
		var stats: Dictionary = _run(seed_index, OPERATIONS)
		for key: String in stats:
			totals[key] = totals.get(key, 0) + stats[key]
	var elapsed: int = Time.get_ticks_msec() - started
	print("    %d × %d operaciones en %d ms: %s" % [SEEDS, OPERATIONS, elapsed, totals])
	# Let the mix truly test: applied and rejected of each kind.
	for key: String in ["ok_move", "ok_split", "ok_destroy", "rejected", "refill", "consume", "gm_add",
			"gm_remove", "swap", "merge", "uid_died"]:
		assert_true(totals.get(key, 0) > 20, "the mix includes quite a few '%s' (%d)" % [key, totals.get(key, 0)])
	for code: int in [InventoryOps.Result.INVALID, InventoryOps.Result.STALE, InventoryOps.Result.NOT_NOW,
			InventoryOps.Result.CANNOT_EQUIP, InventoryOps.Result.WEAPON_REQUIRED, InventoryOps.Result.NO_ROOM,
			InventoryOps.Result.LOCKED]:
		assert_true(totals.get("code_%d" % code, 0) > 5, "code %d comes up (%d)" % [code,
				totals.get("code_%d" % code, 0)])


## The long version: 20 × 5000. Only with --filter=inventory_properties_long.
func test_inventory_properties_long() -> void:
	if not _long_requested():
		assert_true(true, "only with --filter=%s" % LONG_FILTER)
		return
	var started: int = Time.get_ticks_msec()
	for seed_index: int in range(SEEDS):
		_run(1000 + seed_index, LONG_OPERATIONS)
	print("    %d × %d operaciones en %d ms" % [SEEDS, LONG_OPERATIONS, Time.get_ticks_msec() - started])


## The split stack: CAMP_REFILL replenishes the definition's total, not each stack, so splitting gives no more.
func test_camp_refill_after_splitting_gives_nothing_extra() -> void:
	var state := InventoryState.new(8)
	var ids: Dictionary = {"next": 100}
	var context: InventoryOps.Context = _context(ids)
	var potion: ItemDefinition = _db.get_definition(&"potion_health")
	state.set_item(BAG, 0, ItemInstance.create(1, potion, 3))
	var first: InventoryOps.Outcome = InventoryOps.apply(state, InventoryOps.make_request(InventoryOps.Op.SPLIT,
			BAG, 0, BAG, 1, 1, 1), context)
	var second: InventoryOps.Outcome = InventoryOps.apply(state, InventoryOps.make_request(InventoryOps.Op.SPLIT,
			BAG, 0, BAG, 2, 1, 1), context)
	assert_true(first.is_ok() and second.is_ok(), "three stacks of 1")
	var refill: InventoryOps.Outcome = InventoryOps.camp_refill(state, context)
	assert_eq(state.count_of(&"potion_health"), 3, "the total is still 3: nothing to replenish")
	for event: ItemEvent in refill.events:
		assert_true(event.def_id != &"potion_health", "no health events")
	var drink: InventoryOps.Outcome = InventoryOps.remove_items(state, &"potion_health", 2, EconomyReason.CONSUME)
	assert_true(drink.is_ok(), "drinks 2")
	assert_eq(state.count_of(&"potion_health"), 1, "1 remains")
	assert_true(state.get_item(BAG, 0) == null and state.get_item(BAG, 1) == null,
			"from the stacks with the lowest slot first")
	InventoryOps.camp_refill(state, context)
	assert_eq(state.count_of(&"potion_health"), 3, "replenishes up to the total")
	assert_eq(state.get_item(BAG, 2).count, 3, "in the stack that remains")
	assert_true(state.get_item(BAG, 0) == null and state.get_item(BAG, 1) == null, "without opening a new stack")
	var many := InventoryState.new(8)
	many.set_item(BAG, 0, ItemInstance.create(7, potion, 15))
	InventoryOps.apply(many, InventoryOps.make_request(InventoryOps.Op.SPLIT, BAG, 0, BAG, 1, 7, 7), context)
	InventoryOps.camp_refill(many, context)
	assert_eq(many.count_of(&"potion_health"), 15, "with more than the total it neither replenishes nor removes anything")


# --- The simulation ------------------------------------------------------------------------------

## One seed: returns how many operations there were of each kind.
func _run(seed_value: int, operations: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED0000 + seed_value
	var stats: Dictionary = {}
	var state := InventoryState.new(rng.randi_range(4, 12))
	var ids: Dictionary = {"next": 1000, "exhausted": false}
	var template: StringName = [&"squire", &"marksman"][rng.randi_range(0, 1)]
	var kit: Array[ItemEvent] = StarterKit.grant(state, template, _db, _uid_source(ids))
	if not assert_false(kit.is_empty(), "seed %d: the kit fits" % seed_value):
		return stats
	var sim := {
		"state": state, "active": 0, "mirror": {}, "expected": {}, "live": {}, "dead": {}, "bound": {},
		"ids": ids, "label": "",
	}
	for event: ItemEvent in kit:
		sim["expected"][event.def_id] = sim["expected"].get(event.def_id, 0) + event.count_delta
	for position: Vector2i in state.occupied_slots():
		_note_slot(sim, position)
		var item: ItemInstance = state.get_item(position.x, position.y)
		sim["live"][item.uid] = position
	if not _full_check(sim, "semilla %d tras el kit" % seed_value):
		return stats
	for step: int in range(operations):
		sim["label"] = "semilla %d, paso %d" % [seed_value, step]
		# At times the zone runs out of ids for clients (the platform gives no blocks, §4.5).
		if rng.randf() < (0.2 if ids["exhausted"] else 0.02):
			ids["exhausted"] = not ids["exhausted"]
		if not _random_step(sim, rng, stats):
			return stats
		if (step + 1) % FULL_CHECK_EVERY == 0 and not _full_check(sim, sim["label"]):
			return stats
	_full_check(sim, "semilla %d al final" % seed_value)
	return stats


## A random operation with its incremental checks; false if something fails (to cut the seed short).
func _random_step(sim: Dictionary, rng: RandomNumberGenerator, stats: Dictionary) -> bool:
	var state: InventoryState = sim["state"]
	var roll: float = rng.randf()
	var outcome: InventoryOps.Outcome
	var kind: String
	var refill_before: Dictionary = {}
	if roll < 0.62:
		var request: InventoryOps.Request = _random_request(state, rng)
		var context: InventoryOps.Context = _context(sim["ids"])
		context.active_weapon_slot = sim["active"]
		context.level = 1 if rng.randf() < 0.9 else 40
		context.can_touch_equipment = rng.randf() < 0.85
		context.drinking = rng.randf() < 0.1
		var source: ItemInstance = state.get_item(request.from_container, request.from_slot)
		var target: ItemInstance = state.get_item(request.to_container, request.to_slot)
		outcome = InventoryOps.apply(state, request, context)
		kind = "client"
		if outcome.is_ok():
			stats["ok_%s" % ["", "move", "split", "destroy"][request.op]] = \
					stats.get("ok_%s" % ["", "move", "split", "destroy"][request.op], 0) + 1
			# Merging: the destination keeps its uid (in a swap it receives the source's).
			if request.op == InventoryOps.Op.MOVE and target != null \
					and state.get_item(request.to_container, request.to_slot).uid == target.uid:
				stats["merge"] = stats.get("merge", 0) + 1
			if request.op != InventoryOps.Op.DESTROY and not outcome.events.is_empty():
				fail("%s: MOVE and SPLIT give no events (%s)" % [sim["label"], outcome.events])
				return false
		else:
			stats["rejected"] = stats.get("rejected", 0) + 1
			stats["code_%d" % outcome.result] = stats.get("code_%d" % outcome.result, 0) + 1
	elif roll < 0.72:
		# SWAP (Q): changes the active slot if the other has a weapon, like the state machine.
		var other: int = 1 - int(sim["active"])
		if state.get_item(EQUIP, other) != null:
			sim["active"] = other
			stats["swap"] = stats.get("swap", 0) + 1
		return true
	elif roll < 0.82:
		for id: StringName in _db.all_ids():
			refill_before[id] = state.count_of(id)
		outcome = InventoryOps.camp_refill(state, _context(sim["ids"]))
		kind = "refill"
		stats["refill"] = stats.get("refill", 0) + 1
	elif roll < 0.9:
		var index: int = rng.randi_range(0, 1)
		var potion: ItemDefinition = _db.consumable_definition(index)
		if state.count_of(potion.id) == 0:
			return true
		outcome = InventoryOps.remove_items(state, potion.id, 1, EconomyReason.CONSUME)
		kind = "consume"
		stats["consume"] = stats.get("consume", 0) + 1
	elif roll < 0.96:
		var gifts: Array[StringName] = [&"potion_health", &"potion_stamina", &"test_ore", &"test_iron_helm"]
		var gift: StringName = gifts[rng.randi_range(0, gifts.size() - 1)]
		outcome = InventoryOps.add_items(state, gift, rng.randi_range(1, 30), EconomyReason.GM_GRANT,
				_context(sim["ids"]))
		kind = "gm_add"
		if outcome.is_ok():
			stats["gm_add"] = stats.get("gm_add", 0) + 1
	else:
		var takeable: Array[StringName] = [&"potion_health", &"potion_stamina", &"test_ore", &"test_iron_helm"]
		var taken: StringName = takeable[rng.randi_range(0, takeable.size() - 1)]
		var prefer: int = 0
		var occupied: Array[Vector2i] = state.occupied_slots()
		if not occupied.is_empty() and rng.randf() < 0.5:
			var pick: Vector2i = occupied[rng.randi_range(0, occupied.size() - 1)]
			prefer = state.get_item(pick.x, pick.y).uid
		outcome = InventoryOps.remove_items(state, taken, rng.randi_range(1, 20), EconomyReason.GM_REMOVE, prefer)
		kind = "gm_remove"
		if outcome.is_ok():
			stats["gm_remove"] = stats.get("gm_remove", 0) + 1
	if not _incremental_check(sim, outcome, stats):
		return false
	if kind == "refill":
		for id: StringName in refill_before:
			var definition: ItemDefinition = _db.get_definition(id)
			var after: int = state.count_of(id)
			var limit: int = maxi(definition.camp_refill, refill_before[id])
			if after > limit or after < refill_before[id]:
				fail("%s: after CAMP_REFILL, %s has %d (before %d, total %d)" % [sim["label"], id, after,
						refill_before[id], definition.camp_refill])
				return false
	if state.get_item(EQUIP, sim["active"]) == null:
		fail("%s: the active slot %d was left without a weapon" % [sim["label"], sim["active"]])
		return false
	return true


## A random request: almost always from an occupied slot and with the uid that is there, so that many are valid.
func _random_request(state: InventoryState, rng: RandomNumberGenerator) -> InventoryOps.Request:
	var op_roll: float = rng.randf()
	var op: int = InventoryOps.Op.MOVE
	if op_roll < 0.03:
		op = [0, 4, 255][rng.randi_range(0, 2)]
	elif op_roll < 0.25:
		op = InventoryOps.Op.SPLIT
	elif op_roll < 0.42:
		op = InventoryOps.Op.DESTROY
	var from := _random_slot(state, rng)
	var occupied: Array[Vector2i] = state.occupied_slots()
	if rng.randf() < 0.85 and not occupied.is_empty():
		from = occupied[rng.randi_range(0, occupied.size() - 1)]
	var to := _random_slot(state, rng)
	var source: ItemInstance = state.get_item(from.x, from.y)
	# Often, to the equipment slot it fits (weapons at 0 or 1, each armour at its own, closed in
	# phase 5): real equipping and unequipping, and so that a broken slot rule shows.
	if source != null and from.x == BAG and rng.randf() < 0.3:
		var definition: ItemDefinition = _db.get_definition(source.def_id)
		if definition.equip_slot == ItemDefinition.EquipSlot.WEAPON:
			to = Vector2i(EQUIP, rng.randi_range(0, 1))
		elif definition.equip_slot != ItemDefinition.EquipSlot.NONE:
			to = Vector2i(EQUIP, int(definition.equip_slot))
	var expected_uid: int = source.uid if source != null and rng.randf() < 0.9 else rng.randi_range(0, 2000)
	var count: int = 0
	var stack: int = source.count if source != null else 3
	match op:
		InventoryOps.Op.MOVE:
			count = 0 if rng.randf() < 0.95 else rng.randi_range(-1, 3)
		InventoryOps.Op.SPLIT:
			count = rng.randi_range(-1, stack + 1)
			if rng.randf() < 0.85:
				to = Vector2i(BAG, rng.randi_range(0, state.bag_slots - 1))
		InventoryOps.Op.DESTROY:
			count = rng.randi_range(-1, stack + 1)
			to = Vector2i(InventoryOps.NO_SLOT, InventoryOps.NO_SLOT)
	return InventoryOps.make_request(op, from.x, from.y, to.x, to.y, count, expected_uid)


func _random_slot(state: InventoryState, rng: RandomNumberGenerator) -> Vector2i:
	var roll: float = rng.randf()
	if roll < 0.65:
		return Vector2i(BAG, rng.randi_range(0, state.bag_slots - 1))
	if roll < 0.95:
		return Vector2i(EQUIP, rng.randi_range(0, InventoryState.EQUIPMENT_SLOTS - 1))
	return Vector2i(rng.randi_range(0, 3), rng.randi_range(-1, state.bag_slots + 1))


## Brings the mirror up to date with the [code]changed[/code] slots and checks I4 and I1 for this operation.
func _incremental_check(sim: Dictionary, outcome: InventoryOps.Outcome, stats: Dictionary) -> bool:
	var state: InventoryState = sim["state"]
	var mirror: Dictionary = sim["mirror"]
	var label: String = sim["label"]
	if not outcome.is_ok():
		# A rejection changes nothing: the slots it touched stay like the mirror.
		for position: Vector2i in outcome.changed:
			if not _same(mirror.get(position, []), _entry(state, position)):
				fail("%s: a rejection (%d) changed %s" % [label, outcome.result, position])
				return false
		if not outcome.events.is_empty():
			fail("%s: a rejection with events" % label)
			return false
		return true
	var delta_by_def: Dictionary = {}
	var removed: Dictionary = {}
	var added: Dictionary = {}
	for position: Vector2i in outcome.changed:
		var old: Array = mirror.get(position, [])
		var now: Array = _entry(state, position)
		if not old.is_empty():
			delta_by_def[old[1]] = delta_by_def.get(old[1], 0) - old[2]
			removed[old[0]] = position
		if not now.is_empty():
			delta_by_def[now[1]] = delta_by_def.get(now[1], 0) + now[2]
			added[now[0]] = position
		_note_slot(sim, position)
	var event_by_def: Dictionary = {}
	for event: ItemEvent in outcome.events:
		if not EconomyReason.sign_matches(event.reason, event.count_delta):
			fail("%s: event with the sign of another reason: %s" % [label, event])
			return false
		event_by_def[event.def_id] = event_by_def.get(event.def_id, 0) + event.count_delta
		sim["expected"][event.def_id] = sim["expected"].get(event.def_id, 0) + event.count_delta
	for def_id: Variant in delta_by_def.keys() + event_by_def.keys():
		if delta_by_def.get(def_id, 0) != event_by_def.get(def_id, 0):
			fail("%s: %s changed by %d and its events add up to %d" % [label, def_id, delta_by_def.get(def_id, 0),
					event_by_def.get(def_id, 0)])
			return false
	for uid: int in removed:
		if not added.has(uid):
			sim["live"].erase(uid)
			sim["dead"][uid] = true
			stats["uid_died"] = stats.get("uid_died", 0) + 1
	for uid: int in added:
		if removed.has(uid):
			sim["live"][uid] = added[uid]
			continue
		if sim["dead"].has(uid) or sim["live"].has(uid):
			fail("%s: uid %d returns or is repeated" % [label, uid])
			return false
		sim["live"][uid] = added[uid]
	return true


## Everything from scratch: mirror = state, quantities = events, unique live uids, valid instances, binding
## that never goes back and I10.
func _full_check(sim: Dictionary, label: String) -> bool:
	var state: InventoryState = sim["state"]
	var mirror: Dictionary = sim["mirror"]
	var ok: bool = true
	var counts: Dictionary = {}
	var seen: Dictionary = {}
	for container: int in InventoryState.OPEN_CONTAINERS:
		for slot: int in range(state.slot_count(container)):
			var position := Vector2i(container, slot)
			var now: Array = _entry(state, position)
			if not _same(mirror.get(position, []), now):
				ok = fail_and_false("%s: %s changed without being in changed (%s → %s)" % [label, position,
						mirror.get(position, []), now])
			var item: ItemInstance = state.get_item(container, slot)
			if item == null:
				continue
			counts[item.def_id] = counts.get(item.def_id, 0) + item.count
			if seen.has(item.uid):
				ok = fail_and_false("%s: uid %d is there twice" % [label, item.uid])
			seen[item.uid] = true
			if sim["dead"].has(item.uid):
				ok = fail_and_false("%s: the dead uid %d has come back" % [label, item.uid])
			if not item.is_valid(_db):
				ok = fail_and_false("%s: invalid instance in %s: uid %d, %s ×%d" % [label, position, item.uid,
						item.def_id, item.count])
			if sim["bound"].get(item.uid, false) and not item.bound:
				ok = fail_and_false("%s: uid %d stopped being bound" % [label, item.uid])
			sim["bound"][item.uid] = item.bound
			if container == EQUIP:
				var definition: ItemDefinition = _db.get_definition(item.def_id)
				if slot >= InventoryState.OPEN_EQUIPMENT_SLOTS \
						or definition.equip_slot != ItemDefinition.EquipSlot.WEAPON:
					ok = fail_and_false("%s: %s in equipment slot %d" % [label, item.def_id, slot])
	for def_id: Variant in counts.keys() + sim["expected"].keys():
		if counts.get(def_id, 0) != sim["expected"].get(def_id, 0):
			ok = fail_and_false("%s: there are %d of %s and the events say %d" % [label, counts.get(def_id, 0), def_id,
					sim["expected"].get(def_id, 0)])
	if seen.size() != sim["live"].size():
		ok = fail_and_false("%s: %d uids in the state and %d live ones recorded" % [label, seen.size(), sim["live"].size()])
	if state.get_item(EQUIP, sim["active"]) == null:
		ok = fail_and_false("%s: the active slot is empty" % label)
	assert_true(ok, "%s: full check" % label)
	return ok


func fail_and_false(message: String) -> bool:
	fail(message)
	return false


func _note_slot(sim: Dictionary, position: Vector2i) -> void:
	var entry: Array = _entry(sim["state"], position)
	if entry.is_empty():
		sim["mirror"].erase(position)
	else:
		sim["mirror"][position] = entry


## [uid, def_id, quantity, bound] of the slot, or empty.
func _entry(state: InventoryState, position: Vector2i) -> Array:
	var item: ItemInstance = state.get_item(position.x, position.y)
	return [] if item == null else [item.uid, item.def_id, item.count, item.bound]


func _same(a: Array, b: Array) -> bool:
	return a == b


func _context(ids: Dictionary) -> InventoryOps.Context:
	var context := InventoryOps.Context.new()
	context.db = _db
	context.new_uid = _uid_source(ids)
	return context


## Ids from [code]ids.next[/code]; 0 while [code]ids.exhausted[/code] (the platform gives no blocks).
func _uid_source(ids: Dictionary) -> Callable:
	return func() -> int:
		if ids.get("exhausted", false):
			return 0
		ids["next"] += 1
		return ids["next"]


func _long_requested() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--filter=") and arg.contains(LONG_FILTER):
			return true
	return false


## The objects from data/items, the armours of the cases (not equipped in phase 5) and a stackable ore.
func _property_db() -> ItemDatabase:
	var definitions: Array[ItemDefinition] = []
	var shared: ItemDatabase = ItemDatabase.shared()
	for id: StringName in shared.all_ids():
		definitions.append(shared.get_definition(id))
	for file_name: String in DirAccess.get_files_at(ARMOR_FIXTURES):
		if file_name.ends_with(".tres"):
			definitions.append(load(ARMOR_FIXTURES.path_join(file_name)) as ItemDefinition)
	var ore := ItemDefinition.new()
	ore.id = &"test_ore"
	ore.display_name = "Mineral de prueba"
	ore.category = ItemDefinition.Category.MATERIAL
	ore.max_stack = 20
	definitions.append(ore)
	var db: ItemDatabase = ItemDatabase.build_from_definitions(definitions)
	assert_eq(db.errors, PackedStringArray(), "the test base has no errors")
	return db
