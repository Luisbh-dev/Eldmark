class_name InventoryOps
extends RefCounted
## The inventory operations (docs/progression.md §4.2–§4.4, PRG-11), pure and shared: the server
## uses them to decide and the client for its optimistic intent (§11.3), so both validate the same
## way.
## [br][br]
## [b]Client requests[/b] ([method apply]): MOVE (move, merge, swap, equip and unequip), SPLIT and
## DESTROY. They are validated in the order of §4.2 and the first failure gives the code; if
## everything is valid, it is written whole into the [InventoryState] and, if not, nothing
## changes. RATE does not come from here: the server checks it on receiving the request, before
## everything else. Neither do "no character or outside the world" (NOT_NOW) or the cap of 256
## unconfirmed DESTROY operations, which [code]PlayerProgress.apply_request[/code] checks.
## [br][br]
## [b]Server changes[/b] (§4.4): [method camp_refill] (CAMP_REFILL), [method add_items] (kit, GM)
## and [method remove_items] (CONSUME, GM, reversal). Their events always carry the [code]uid[/code]
## of the instance they touch; aggregating them (§5.2) is the server journal's job.
## [br][br]
## Only DESTROY and server changes produce events ([ItemEvent]): moving, splitting, merging,
## swapping and equipping do not change the quantity of any definition (I4). No function mutates an
## [ItemInstance] that is already in the state: those that change are replaced by copies, so the
## client can rebuild its view on a copy of the confirmed state without touching it. No clock, no
## randomness.

## Client operations (INVENTORY_REQUEST, §4.6).
enum Op { MOVE = 1, SPLIT = 2, DESTROY = 3 }
## Results (§4.2), in the order they are checked.
enum Result { OK = 0, INVALID = 1, STALE = 2, NOT_NOW = 3, CANNOT_EQUIP = 4,
		WEAPON_REQUIRED = 5, NO_ROOM = 6, LOCKED = 7, RATE = 8 }

## Destination of a DESTROY on the wire ([code]0xFF[/code]): [method apply] does not look at it.
const NO_SLOT: int = 0xFF


## A client request: the fields of INVENTORY_REQUEST (§4.6) without the [code]request_id[/code].
class Request:
	var op: int = 0
	var from_container: int = 0
	var from_slot: int = 0
	## In DESTROY they do not count ([constant InventoryOps.NO_SLOT] on the wire).
	var to_container: int = 0
	var to_slot: int = 0
	## MOVE: 0. SPLIT: the ones that leave (1 … count − 1). DESTROY: the ones destroyed (0 = the whole
	## stack).
	var count: int = 0
	## The [code]uid[/code] the client sees at the source.
	var expected_uid: int = 0


## What the request needs to know about the character.
class Context:
	## Definitions (null = [method ItemDatabase.shared]).
	var db: ItemDatabase
	## Character level, for [member ItemDefinition.required_level].
	var level: int = 1
	## Bit0 of [code]combat_flags2[/code]: from the server's [CombatState] or the one predicted on the
	## client.
	var active_weapon_slot: int = 0
	## false: dead, knocked down, in combat or with an action in progress (NOT_NOW if it touches
	## equipment).
	var can_touch_equipment: bool = true
	## Drinking a consumable (consumable ABILITY in progress): none is destroyed.
	var drinking: bool = false
	## [code]() -> int[/code]: a new id; 0 = no ids (for the client; the server hands out those of its
	## range, §4.5). Unassigned, there are no ids. SPLIT uses it for the [code]uid[/code] of the new
	## stack and DESTROY for its PLAYER operation; server changes, for their new stacks.
	var new_uid: Callable = Callable()


## The result of an operation.
class Outcome:
	var result: int = Result.OK
	## With OK, the [code](container, slot)[/code] slots that changed. Otherwise, those of the ones the
	## request touched that exist: the rejection delta carries their real content (§4.6).
	var changed: Array[Vector2i] = []
	## Only DESTROY and server changes.
	var events: Array[ItemEvent] = []
	## It touched EQUIPMENT 0 or 1: the weapons must be imposed ([method ActionMachine.set_weapons],
	## §4.1).
	var weapons_changed: bool = false
	## The id taken from [member Context.new_uid] (SPLIT: the [code]uid[/code] of the new stack;
	## DESTROY: the [code]op_id[/code] of its PLAYER operation); 0 if none.
	var new_id: int = 0
	## CANNOT_EQUIP due to level: the one the item requires ("Necesitas nivel N", i.e. "You need level
	## N"); 0 if not.
	var required_level: int = 0
	## [method camp_refill]: a new stack did not fit ("Bolsa llena", i.e. "Bag full", notice).
	var bag_full: bool = false

	## true if it was applied.
	func is_ok() -> bool:
		return result == Result.OK


## A request with those fields.
static func make_request(op: int, from_container: int, from_slot: int, to_container: int, to_slot: int,
		count: int, expected_uid: int) -> Request:
	var request := Request.new()
	request.op = op
	request.from_container = from_container
	request.from_slot = from_slot
	request.to_container = to_container
	request.to_slot = to_slot
	request.count = count
	request.expected_uid = expected_uid
	return request


## Validates [param request] against [param state] and [param context] in the order of §4.2 and,
## if everything is valid, applies it. [b]Order:[/b] INVALID (operation, containers and slots that
## do not exist, source equal to destination, MOVE with a quantity, SPLIT of less than 1 or outside
## the bag, negative quantity) → STALE (empty source or with another uid) → INVALID by quantity
## versus the stack (SPLIT of [code]count[/code] or more, DESTROY of more than there are: without
## the expected item there is no stack to measure against) → NOT_NOW (touches equipment when it
## cannot, or destroys a consumable while drinking) → CANNOT_EQUIP (slot that does not suit it, 2–6
## in phase 5, level) → WEAPON_REQUIRED (would leave the active weapon slot empty) → NO_ROOM (SPLIT
## to an occupied slot) → LOCKED (DESTROY of something equipped or indestructible) → NOT_NOW with
## no id for SPLIT or DESTROY: the id is requested last, so that a rejected request does not
## consume any.
static func apply(state: InventoryState, request: Request, context: Context) -> Outcome:
	var out := Outcome.new()
	var db: ItemDatabase = context.db if context.db != null else ItemDatabase.shared()
	var op: int = request.op
	var from := Vector2i(request.from_container, request.from_slot)
	var to := Vector2i(request.to_container, request.to_slot)
	var has_target: bool = op != Op.DESTROY
	var from_exists: bool = state.has_slot(from.x, from.y)
	var to_exists: bool = has_target and state.has_slot(to.x, to.y)
	if from_exists:
		out.changed.append(from)
	if to_exists and to != from:
		out.changed.append(to)
	# 1 · INVALID: the shape of the request.
	if op != Op.MOVE and op != Op.SPLIT and op != Op.DESTROY:
		return _fail(out, Result.INVALID)
	if not from_exists or (has_target and not to_exists) or (has_target and from == to):
		return _fail(out, Result.INVALID)
	match op:
		Op.MOVE:
			if request.count != 0:
				return _fail(out, Result.INVALID)
		Op.SPLIT:
			if request.count < 1 or to.x != InventoryState.ContainerId.BAG:
				return _fail(out, Result.INVALID)
		Op.DESTROY:
			if request.count < 0:
				return _fail(out, Result.INVALID)
	# 2 · STALE.
	var source: ItemInstance = state.get_item(from.x, from.y)
	if source == null or source.uid != request.expected_uid:
		return _fail(out, Result.STALE)
	# 1 · INVALID by quantity versus the stack.
	if op == Op.SPLIT and request.count >= source.count:
		return _fail(out, Result.INVALID)
	if op == Op.DESTROY and request.count > source.count:
		return _fail(out, Result.INVALID)
	var definition: ItemDefinition = db.get_definition(source.def_id)
	if definition == null:
		# An instance without a definition never reaches the state (decode and from_dictionary reject it).
		return _fail(out, Result.INVALID)
	var target: ItemInstance = state.get_item(to.x, to.y) if has_target else null
	# 3 · NOT_NOW.
	var touches_equipment: bool = from.x == InventoryState.ContainerId.EQUIPMENT \
			or (has_target and to.x == InventoryState.ContainerId.EQUIPMENT)
	if touches_equipment and not context.can_touch_equipment:
		return _fail(out, Result.NOT_NOW)
	if op == Op.DESTROY and context.drinking and definition.category == ItemDefinition.Category.CONSUMABLE:
		return _fail(out, Result.NOT_NOW)
	# What would remain at the source and at the destination.
	var new_from: ItemInstance = null
	var new_to: ItemInstance = null
	var destroyed: int = 0
	match op:
		Op.MOVE:
			if target == null:
				new_to = source
			elif _can_merge(source, target, definition):
				var moved: int = mini(source.count, definition.max_stack - target.count)
				new_to = _with_count(target, target.count + moved)
				new_from = _with_count(source, source.count - moved) if moved < source.count else null
			else:
				new_to = source
				new_from = target
		Op.SPLIT:
			new_from = _with_count(source, source.count - request.count)
			new_to = _with_count(source, request.count)
		Op.DESTROY:
			destroyed = request.count if request.count > 0 else source.count
			new_from = _with_count(source, source.count - destroyed) if destroyed < source.count else null
	# 4 · CANNOT_EQUIP: what enters an equipment slot from another one (what stays where it was is not
	# checked again).
	if from.x == InventoryState.ContainerId.EQUIPMENT and new_from != null and new_from.uid != source.uid:
		var code: int = _equip_check(out, new_from, from.y, db, context)
		if code != Result.OK:
			return _fail(out, code)
	if has_target and to.x == InventoryState.ContainerId.EQUIPMENT and new_to != null \
			and (target == null or new_to.uid != target.uid):
		var code: int = _equip_check(out, new_to, to.y, db, context)
		if code != Result.OK:
			return _fail(out, code)
	# 5 · WEAPON_REQUIRED.
	var active := Vector2i(InventoryState.ContainerId.EQUIPMENT, context.active_weapon_slot)
	if (from == active and new_from == null) or (has_target and to == active and new_to == null):
		return _fail(out, Result.WEAPON_REQUIRED)
	# 6 · NO_ROOM.
	if op == Op.SPLIT and target != null:
		return _fail(out, Result.NO_ROOM)
	# 7 · LOCKED.
	if op == Op.DESTROY and (from.x == InventoryState.ContainerId.EQUIPMENT or not definition.destroyable):
		return _fail(out, Result.LOCKED)
	# 3 · NOT_NOW with no id (it is requested now, when everything else is valid).
	if op == Op.SPLIT or op == Op.DESTROY:
		var id: int = _take_id(context)
		if id == 0:
			return _fail(out, Result.NOT_NOW)
		out.new_id = id
		if op == Op.SPLIT:
			new_to.uid = id
	# Bound on equip (§4.2): what enters equipment with ON_EQUIP.
	if from.x == InventoryState.ContainerId.EQUIPMENT:
		new_from = _bound_if_equipped(new_from, db)
	if has_target and to.x == InventoryState.ContainerId.EQUIPMENT:
		new_to = _bound_if_equipped(new_to, db)
	state.set_item(from.x, from.y, new_from)
	if has_target:
		state.set_item(to.x, to.y, new_to)
	if op == Op.DESTROY:
		out.events.append(ItemEvent.create(source.uid, source.def_id, -destroyed, EconomyReason.PLAYER_DESTROY))
	out.weapons_changed = _is_weapon_slot(from) or (has_target and _is_weapon_slot(to))
	return out


## Spanish text of [param result] (§4.2) for the client notice; empty with OK. With CANNOT_EQUIP
## and [param required_level] > 0, "Necesitas nivel N" (You need level N); with NOT_NOW and
## [param in_combat], the combat one.
static func result_text(result: int, required_level: int = 0, in_combat: bool = false) -> String:
	match result:
		Result.INVALID:
			return "Petición no válida"
		Result.STALE:
			return "Ese objeto ya no está ahí"
		Result.NOT_NOW:
			return "No puedes cambiar el equipo en combate" if in_combat else "Ahora no puedes hacerlo"
		Result.CANNOT_EQUIP:
			return "Necesitas nivel %d" % required_level if required_level > 0 else "No puedes equipar eso ahí"
		Result.WEAPON_REQUIRED:
			return "Necesitas un arma en la mano"
		Result.NO_ROOM:
			return "No cabe"
		Result.LOCKED:
			return "Ese objeto no se puede destruir"
		Result.RATE:
			return "Más despacio"
	return ""


## true if [param definition] goes in equipment slot [param slot] (both weapon slots for WEAPON and
## its own for each armor piece), without checking whether the slot is open in phase 5.
static func fits_slot(definition: ItemDefinition, slot: int) -> bool:
	if definition == null:
		return false
	if slot == InventoryState.EquipmentSlot.WEAPON_1 or slot == InventoryState.EquipmentSlot.WEAPON_2:
		return definition.equip_slot == ItemDefinition.EquipSlot.WEAPON
	return slot >= InventoryState.EquipmentSlot.HEAD and slot <= InventoryState.EquipmentSlot.FEET \
			and int(definition.equip_slot) == slot


## CAMP_REFILL (§4.4): for each definition with [member ItemDefinition.camp_refill], in id order,
## what is missing up to that total ([method InventoryState.count_of]: bag and equipment) is added
## to its stack in the bag with the lowest slot (with the same binding the new ones would have)
## until the stack is full, and the rest goes to a new stack in the first free slot with an id from
## [member Context.new_uid]. With no free slot that part is not replenished and
## [member Outcome.bag_full] says so; with no id, it waits for the next attempt. Replenishing looks
## at the [b]total[/b]: splitting the stack gives no more. Events with reason CAMP_REFILL, one per
## touched instance.
static func camp_refill(state: InventoryState, context: Context) -> Outcome:
	var out := Outcome.new()
	var db: ItemDatabase = context.db if context.db != null else ItemDatabase.shared()
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		var missing: int = definition.camp_refill - state.count_of(id)
		if definition.camp_refill <= 0 or missing <= 0:
			continue
		var bound: bool = definition.bind_rule == ItemDefinition.BindRule.ON_PICKUP
		var bag: int = InventoryState.ContainerId.BAG
		for slot: int in range(state.bag_slots):
			var item: ItemInstance = state.get_item(bag, slot)
			if item == null or item.def_id != id or item.bound != bound:
				continue
			var added: int = mini(missing, definition.max_stack - item.count)
			if added > 0:
				state.set_item(bag, slot, _with_count(item, item.count + added))
				out.changed.append(Vector2i(bag, slot))
				out.events.append(ItemEvent.create(item.uid, id, added, EconomyReason.CAMP_REFILL))
				missing -= added
			break
		if missing <= 0:
			continue
		var free: int = state.first_free(bag)
		if free < 0:
			out.bag_full = true
			continue
		var new_id: int = _take_id(context)
		if new_id == 0:
			continue
		state.set_item(bag, free, ItemInstance.create(new_id, definition, mini(missing, definition.max_stack)))
		out.changed.append(Vector2i(bag, free))
		out.events.append(ItemEvent.create(new_id, id, mini(missing, definition.max_stack),
				EconomyReason.CAMP_REFILL))
	return out


## Adds [param count] units of [param def_id] to the bag with reason [param reason] (a source or an
## internal one): first to its stacks with room (in slot order, with the same binding the new ones
## would have) and the rest in new stacks in the first free slots, with ids from
## [member Context.new_uid]. All or nothing: INVALID with a definition that does not exist or
## [param count] < 1; NO_ROOM if it does not fit; NOT_NOW if any id is missing (those already
## taken are lost: a gap in the ids does not matter, §4.5). One event per touched instance.
static func add_items(state: InventoryState, def_id: StringName, count: int, reason: int,
		context: Context) -> Outcome:
	var out := Outcome.new()
	var db: ItemDatabase = context.db if context.db != null else ItemDatabase.shared()
	var definition: ItemDefinition = db.get_definition(def_id)
	if definition == null or count < 1:
		return _fail(out, Result.INVALID)
	var bag: int = InventoryState.ContainerId.BAG
	var bound: bool = definition.bind_rule == ItemDefinition.BindRule.ON_PICKUP
	# Plan: [slot, existing instance or null, units].
	var plan: Array[Array] = []
	var left: int = count
	if definition.max_stack > 1:
		for slot: int in range(state.bag_slots):
			var item: ItemInstance = state.get_item(bag, slot)
			if left > 0 and item != null and item.def_id == def_id and item.bound == bound \
					and item.count < definition.max_stack:
				var added: int = mini(left, definition.max_stack - item.count)
				plan.append([slot, item, added])
				left -= added
	for slot: int in range(state.bag_slots):
		if left <= 0:
			break
		if state.get_item(bag, slot) == null:
			var added: int = mini(left, definition.max_stack)
			plan.append([slot, null, added])
			left -= added
	if left > 0:
		return _fail(out, Result.NO_ROOM)
	var new_ids: Dictionary[int, int] = {}
	for step: Array in plan:
		if step[1] == null:
			var new_id: int = _take_id(context)
			if new_id == 0:
				return _fail(out, Result.NOT_NOW)
			new_ids[step[0]] = new_id
	for step: Array in plan:
		var slot: int = step[0]
		var added: int = step[2]
		var item: ItemInstance = step[1]
		if item != null:
			state.set_item(bag, slot, _with_count(item, item.count + added))
			out.events.append(ItemEvent.create(item.uid, def_id, added, reason))
		else:
			state.set_item(bag, slot, ItemInstance.create(new_ids[slot], definition, added))
			out.events.append(ItemEvent.create(new_ids[slot], def_id, added, reason))
		out.changed.append(Vector2i(bag, slot))
	return out


## Removes [param count] units of [param def_id] with reason [param reason] (a sink or an internal
## one): first from instance [param prefer_uid] if it is of that definition, then from the bag in
## slot order (CONSUME: the stack with the lowest slot) and finally from equipment. A stack that
## drops to 0 disappears and its [code]uid[/code] dies. The slots in [param protected] are not
## touched (the reversal in progression.md §10 does not remove from the active equipment slot).
## All or nothing: INVALID with [param count] < 1, STALE if there are not that many outside the
## protected ones. It does not look at the active slot (I10): removing an equipped weapon is up to
## the caller ([member Outcome.weapons_changed]).
static func remove_items(state: InventoryState, def_id: StringName, count: int, reason: int,
		prefer_uid: int = 0, protected: Array[Vector2i] = []) -> Outcome:
	var out := Outcome.new()
	if count < 1:
		return _fail(out, Result.INVALID)
	if count_outside(state, def_id, protected) < count:
		return _fail(out, Result.STALE)
	var order: Array[Vector2i] = []
	if prefer_uid != 0:
		var preferred: Vector2i = state.find_uid(prefer_uid)
		if preferred.x >= 0 and state.get_item(preferred.x, preferred.y).def_id == def_id \
				and not protected.has(preferred):
			order.append(preferred)
	for container: int in InventoryState.OPEN_CONTAINERS:
		for slot: int in range(state.slot_count(container)):
			var position := Vector2i(container, slot)
			var item: ItemInstance = state.get_item(container, slot)
			if item != null and item.def_id == def_id and not order.has(position) and not protected.has(position):
				order.append(position)
	var left: int = count
	for position: Vector2i in order:
		if left <= 0:
			break
		var item: ItemInstance = state.get_item(position.x, position.y)
		var taken: int = mini(left, item.count)
		state.set_item(position.x, position.y, _with_count(item, item.count - taken) if taken < item.count else null)
		out.changed.append(position)
		out.events.append(ItemEvent.create(item.uid, def_id, -taken, reason))
		out.weapons_changed = out.weapons_changed or _is_weapon_slot(position)
		left -= taken
	return out


## The units of [param def_id] in the bag and equipment outside the [param protected] slots.
static func count_outside(state: InventoryState, def_id: StringName, protected: Array[Vector2i] = []) -> int:
	var total: int = state.count_of(def_id)
	var seen: Dictionary[Vector2i, bool] = {}
	for position: Vector2i in protected:
		if seen.has(position) or not state.has_slot(position.x, position.y):
			continue
		seen[position] = true
		var item: ItemInstance = state.get_item(position.x, position.y)
		if item != null and item.def_id == def_id:
			total -= item.count
	return total


## Creates [param count] units of [param def_id] in new stacks (up to
## [member ItemDefinition.max_stack] each) in the first free bag slots, with ids from
## [member Context.new_uid] and reason [param reason]: without merging with existing ones (the GM
## [code]item_give[/code] and the reversal in progression.md §10, which create "with other uids").
## With [param template], each stack copies its durability, rarity, binding, seed and affixes (the
## retired row of what is being reverted); without it, like [method ItemInstance.create]. All or
## nothing: INVALID with a definition that does not exist, [param count] < 1 or a template from
## another definition; NO_ROOM without enough free slots; NOT_NOW if any id is missing. One event
## per stack.
static func create_items(state: InventoryState, def_id: StringName, count: int, reason: int, context: Context,
		template: ItemInstance = null) -> Outcome:
	var out := Outcome.new()
	var db: ItemDatabase = context.db if context.db != null else ItemDatabase.shared()
	var definition: ItemDefinition = db.get_definition(def_id)
	if definition == null or count < 1 or (template != null and template.def_id != def_id):
		return _fail(out, Result.INVALID)
	var bag: int = InventoryState.ContainerId.BAG
	var stacks: int = ceili(float(count) / float(maxi(definition.max_stack, 1)))
	if state.free_count(bag) < stacks:
		return _fail(out, Result.NO_ROOM)
	var ids: Array[int] = []
	for _i: int in range(stacks):
		var new_id: int = _take_id(context)
		if new_id == 0:
			return _fail(out, Result.NOT_NOW)
		ids.append(new_id)
	var left: int = count
	for new_id: int in ids:
		var amount: int = mini(left, definition.max_stack)
		var item: ItemInstance = ItemInstance.create(new_id, definition, amount)
		if template != null:
			if definition.has_durability and template.durability >= 0:
				item.durability = template.durability
			item.rarity = template.rarity
			item.bound = template.bound
			item.seed = template.seed
			item.affixes = template.affixes.duplicate()
		var slot: int = state.first_free(bag)
		state.set_item(bag, slot, item)
		out.changed.append(Vector2i(bag, slot))
		out.events.append(ItemEvent.create(new_id, def_id, amount, reason))
		left -= amount
	return out


# --- Internal --------------------------------------------------------------------------------

static func _fail(out: Outcome, result: int) -> Outcome:
	out.result = result
	out.events.clear()
	out.weapons_changed = false
	out.new_id = 0
	return out


# Merging: same stackable definition, same binding and room at the destination.
static func _can_merge(source: ItemInstance, target: ItemInstance, definition: ItemDefinition) -> bool:
	return source.def_id == target.def_id and definition.max_stack > 1 and source.bound == target.bound \
			and target.count < definition.max_stack


# Copy of [param item] with [param count] units (the instance already in the state is never
# changed).
static func _with_count(item: ItemInstance, count: int) -> ItemInstance:
	var copy: ItemInstance = item.duplicate_instance()
	copy.count = count
	return copy


# CANNOT_EQUIP for what enters equipment slot [param slot]; OK if valid.
static func _equip_check(out: Outcome, item: ItemInstance, slot: int, db: ItemDatabase,
		context: Context) -> int:
	var definition: ItemDefinition = db.get_definition(item.def_id)
	if slot >= InventoryState.OPEN_EQUIPMENT_SLOTS or not fits_slot(definition, slot):
		return Result.CANNOT_EQUIP
	if definition.required_level > context.level:
		out.required_level = definition.required_level
		return Result.CANNOT_EQUIP
	return Result.OK


# What enters equipment with ON_EQUIP becomes bound (a copy if it changes).
static func _bound_if_equipped(item: ItemInstance, db: ItemDatabase) -> ItemInstance:
	if item == null or item.bound:
		return item
	var definition: ItemDefinition = db.get_definition(item.def_id)
	if definition == null or definition.bind_rule != ItemDefinition.BindRule.ON_EQUIP:
		return item
	var copy: ItemInstance = item.duplicate_instance()
	copy.bound = true
	return copy


static func _is_weapon_slot(position: Vector2i) -> bool:
	return position.x == InventoryState.ContainerId.EQUIPMENT \
			and position.y < InventoryState.OPEN_EQUIPMENT_SLOTS and position.y >= 0


# An id from [member Context.new_uid], or 0 if there is none.
static func _take_id(context: Context) -> int:
	if not context.new_uid.is_valid():
		return 0
	var value: Variant = context.new_uid.call()
	return value if typeof(value) == TYPE_INT else 0
