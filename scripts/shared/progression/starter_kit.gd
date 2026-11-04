class_name StarterKit
extends RefCounted
## The starter kit (docs/progresion.md §2.5, PRG-07): what a character receives on first entering
## the world, according to its template ([EquipmentTemplate] with [code]selectable = true[/code]):
## [br]1. each weapon of the template → its item ([method ItemDatabase.for_ref]), in equipment slots
## 0 and 1 in the template's order;
## [br]2. each starter item without [member ItemDefinition.camp_refill] that was not left equipped
## (the weapons of the other templates) → one unit in the bag, from slot 0 in id order;
## [br]3. each item with [member ItemDefinition.camp_refill] > 0 → a stack with that quantity in the
## bag, after those and also in id order.
## [br][br]
## This preserves the phase 4 freedom (switching style) within the inventory. A template that does
## not exist or cannot be chosen uses the first selectable one in id order, with a log warning.
## Starter items are [code]ON_PICKUP[/code]: they come out bound ([method ItemInstance.create]).
## The caller (the server) puts the events in a STARTER_KIT operation and sets
## [code]starter_granted[/code]. Shared: no clock, no randomness.


## Places the §2.5 kit of template [param template_id] in the empty inventory [param state], with
## the definitions of [param db] (null = [method ItemDatabase.shared]) and the ids of
## [param new_uid] ([code]() -> int[/code]; 0 = no ids). Returns one event per instance (reason
## STARTER_KIT, with its [code]uid[/code]) in the order they are placed. All or nothing: with a
## non-empty inventory, with no selectable templates or with no room in the bag (both are caller or
## data errors: they are logged), or missing an id (those already taken are lost), it returns an
## empty list and changes nothing.
static func grant(state: InventoryState, template_id: StringName, db: ItemDatabase,
		new_uid: Callable) -> Array[ItemEvent]:
	var events: Array[ItemEvent] = []
	if db == null:
		db = ItemDatabase.shared()
	if not state.all_items().is_empty():
		push_error("[Eldmark] Kit de inicio: el inventario no está vacío")
		return events
	var template: EquipmentTemplate = template_for(template_id)
	if template == null:
		push_error("[Eldmark] Kit de inicio: no hay ninguna plantilla elegible")
		return events
	var placements: Array[Array] = plan(template, db)
	var bag_needed: int = 0
	for placement: Array in placements:
		if placement[0] == InventoryState.ContainerId.BAG:
			bag_needed += 1
	if bag_needed > state.bag_slots:
		push_error("[Eldmark] Kit de inicio: hacen falta %d ranuras de bolsa y hay %d" % [bag_needed,
				state.bag_slots])
		return events
	var ids: Array[int] = []
	for _placement: Array in placements:
		var id: int = 0
		if new_uid.is_valid():
			var value: Variant = new_uid.call()
			id = value if typeof(value) == TYPE_INT else 0
		if id == 0:
			return events
		ids.append(id)
	for i: int in range(placements.size()):
		var container: int = placements[i][0]
		var slot: int = placements[i][1]
		var definition: ItemDefinition = placements[i][2]
		var count: int = placements[i][3]
		var item: ItemInstance = ItemInstance.create(ids[i], definition, count)
		if container == InventoryState.ContainerId.EQUIPMENT \
				and definition.bind_rule == ItemDefinition.BindRule.ON_EQUIP:
			item.bound = true
		state.set_item(container, slot, item)
		events.append(ItemEvent.create(item.uid, item.def_id, count, EconomyReason.STARTER_KIT))
	return events


## The template the kit uses for [param template_id]: the selectable one with that id or, if there
## is none, the first selectable one in id order (with a log warning). null if none is selectable.
static func template_for(template_id: StringName) -> EquipmentTemplate:
	var first: EquipmentTemplate = null
	for template: EquipmentTemplate in CombatCatalog.tables().templates:
		if template == null or not template.selectable:
			continue
		if template.id == template_id:
			return template
		if first == null or String(template.id) < String(first.id):
			first = template
	if first != null:
		push_warning("[Eldmark] Kit de inicio: la plantilla '%s' no existe o no se puede elegir; se usa '%s'"
				% [template_id, first.id])
	return first


## Where each item of the kit of [param template] goes: a list of [code][container, slot,
## definition, quantity][/code] in the order of the three rules. A weapon without an item in
## [param db] is skipped with a warning (the exported rules and the platform already prevent it)
## and the next one takes its slot: slot 0 is never left empty.
static func plan(template: EquipmentTemplate, db: ItemDatabase) -> Array[Array]:
	var placements: Array[Array] = []
	var placed: Dictionary[StringName, bool] = {}
	var equipment_slot: int = 0
	for weapon: WeaponDefinition in template.weapons:
		if equipment_slot >= InventoryState.OPEN_EQUIPMENT_SLOTS:
			break
		var definition: ItemDefinition = db.for_ref(ItemDefinition.Category.WEAPON, weapon.id) \
				if weapon != null else null
		if definition == null:
			push_warning("[Eldmark] Kit de inicio: el arma '%s' de la plantilla '%s' no tiene objeto"
					% [weapon.id if weapon != null else &"", template.id])
			continue
		placements.append([InventoryState.ContainerId.EQUIPMENT, equipment_slot, definition, 1])
		placed[definition.id] = true
		equipment_slot += 1
	var bag_slot: int = 0
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		if definition.starter and definition.camp_refill == 0 and not placed.has(id):
			placements.append([InventoryState.ContainerId.BAG, bag_slot, definition, 1])
			bag_slot += 1
	for id: StringName in db.all_ids():
		var definition: ItemDefinition = db.get_definition(id)
		if definition.camp_refill > 0 and not placed.has(id):
			placements.append([InventoryState.ContainerId.BAG, bag_slot, definition, definition.camp_refill])
			bag_slot += 1
	return placements
