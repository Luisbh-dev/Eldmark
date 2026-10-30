class_name StarterKit
extends RefCounted
## El kit de inicio (docs/progresion.md §2.5, PRG-07): lo que recibe un personaje en su primera entrada al
## mundo, según su plantilla ([EquipmentTemplate] con [code]selectable = true[/code]):
## [br]1. cada arma de la plantilla → su objeto ([method ItemDatabase.for_ref]), en las ranuras de equipo 0 y 1
## por el orden de la plantilla;
## [br]2. cada objeto de inicio sin [member ItemDefinition.camp_refill] que no haya quedado puesto (las armas
## de las demás plantillas) → una unidad en la bolsa, desde la ranura 0 por orden de id;
## [br]3. cada objeto con [member ItemDefinition.camp_refill] > 0 → una pila con esa cantidad en la bolsa, a
## continuación y también por orden de id.
## [br][br]
## Así se conserva la libertad de la fase 4 (cambiar de estilo) dentro del inventario. Una plantilla que no
## existe o que no se puede elegir usa la primera elegible por orden de id, con aviso en el registro. Los
## objetos de inicio son [code]ON_PICKUP[/code]: salen ligados ([method ItemInstance.create]). Quien llama
## (el servidor) mete los eventos en una operación STARTER_KIT y marca [code]starter_granted[/code].
## Compartido: sin reloj ni azar.


## Coloca el kit de §2.5 de la plantilla [param template_id] en el inventario vacío [param state], con las
## definiciones de [param db] (null = [method ItemDatabase.shared]) y los ids de [param new_uid]
## ([code]() -> int[/code]; 0 = sin ids). Devuelve un evento por instancia (motivo STARTER_KIT, con su
## [code]uid[/code]) en el orden en que se colocan. Entero o nada: con el inventario no vacío, sin plantillas
## elegibles o sin sitio en la bolsa (los dos, errores de quien llama o de los datos: se registran), o sin
## algún id (los ya tomados se pierden), devuelve una lista vacía y no cambia nada.
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


## La plantilla que usa el kit para [param template_id]: la elegible con ese id o, si no la hay, la primera
## elegible por orden de id (con aviso en el registro). null si no hay ninguna elegible.
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


## Dónde va cada objeto del kit de [param template]: una lista de [code][contenedor, ranura, definición,
## cantidad][/code] en el orden de las tres reglas. Un arma sin objeto en [param db] se salta con aviso (las
## reglas exportadas y la plataforma ya lo impiden) y la siguiente ocupa su ranura: la 0 nunca queda vacía.
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
