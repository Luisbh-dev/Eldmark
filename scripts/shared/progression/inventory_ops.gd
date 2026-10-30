class_name InventoryOps
extends RefCounted
## Las operaciones del inventario (docs/progresion.md §4.2–§4.4, PRG-11), puras y compartidas: el servidor
## las usa para decidir y el cliente para su intención optimista (§11.3), así que las dos validan igual.
## [br][br]
## [b]Peticiones del cliente[/b] ([method apply]): MOVE (mover, juntar, intercambiar, equipar y desequipar),
## SPLIT y DESTROY. Se validan en el orden de §4.2 y el primer fallo da el código; si todo vale, se escribe
## entera en el [InventoryState] y, si no, no cambia nada. RATE no sale de aquí: lo mira el servidor al
## recibir la petición, antes que todo lo demás. Tampoco «sin personaje o fuera del mundo» (NOT_NOW) ni el
## tope de 256 operaciones sin confirmar de DESTROY, que mira [code]PlayerProgress.apply_request[/code].
## [br][br]
## [b]Cambios del servidor[/b] (§4.4): [method camp_refill] (CAMP_REFILL), [method add_items] (kit, GM) y
## [method remove_items] (CONSUME, GM, reversión). Sus eventos llevan siempre el [code]uid[/code] de la
## instancia que tocan; agregarlos (§5.2) es cosa del diario del servidor.
## [br][br]
## Solo DESTROY y los cambios del servidor dan eventos ([ItemEvent]): mover, dividir, juntar, intercambiar y
## equipar no cambian la cantidad de ninguna definición (I4). Ninguna función cambia una [ItemInstance] que ya
## está en el estado: las que cambian se sustituyen por copias, así que el cliente puede rehacer su vista
## sobre una copia del confirmado sin tocarlo. Sin reloj ni azar.

## Operaciones del cliente (INVENTORY_REQUEST, §4.6).
enum Op { MOVE = 1, SPLIT = 2, DESTROY = 3 }
## Resultados (§4.2), en el orden en que se comprueban.
enum Result { OK = 0, INVALID = 1, STALE = 2, NOT_NOW = 3, CANNOT_EQUIP = 4,
		WEAPON_REQUIRED = 5, NO_ROOM = 6, LOCKED = 7, RATE = 8 }

## Destino de un DESTROY en el cable ([code]0xFF[/code]): [method apply] no lo mira.
const NO_SLOT: int = 0xFF


## Una petición del cliente: los campos de INVENTORY_REQUEST (§4.6) sin el [code]request_id[/code].
class Request:
	var op: int = 0
	var from_container: int = 0
	var from_slot: int = 0
	## En DESTROY no cuentan ([constant InventoryOps.NO_SLOT] en el cable).
	var to_container: int = 0
	var to_slot: int = 0
	## MOVE: 0. SPLIT: las que salen (1 … count − 1). DESTROY: las que se destruyen (0 = toda la pila).
	var count: int = 0
	## El [code]uid[/code] que el cliente ve en el origen.
	var expected_uid: int = 0


## Lo que la petición necesita saber del personaje.
class Context:
	## Definiciones (null = [method ItemDatabase.shared]).
	var db: ItemDatabase
	## Nivel del personaje, para [member ItemDefinition.required_level].
	var level: int = 1
	## Bit0 de [code]combat_flags2[/code]: del [CombatState] del servidor o del predicho en el cliente.
	var active_weapon_slot: int = 0
	## false: muerto, derribado, en combate o con una acción en curso (NOT_NOW si toca el equipo).
	var can_touch_equipment: bool = true
	## Bebiendo un consumible (ABILITY de consumible en curso): no se destruye ninguno.
	var drinking: bool = false
	## [code]() -> int[/code]: un id nuevo; 0 = sin ids (para el cliente, el servidor da los de su tramo,
	## §4.5). Sin asignar, no hay ids. SPLIT lo usa para el [code]uid[/code] de la pila nueva y DESTROY para
	## su operación PLAYER; los cambios del servidor, para sus pilas nuevas.
	var new_uid: Callable = Callable()


## El resultado de una operación.
class Outcome:
	var result: int = Result.OK
	## Con OK, las ranuras [code](contenedor, ranura)[/code] que cambiaron. Si no, las que existen de las que
	## tocaba la petición: el delta del rechazo lleva su contenido real (§4.6).
	var changed: Array[Vector2i] = []
	## Solo DESTROY y los cambios del servidor.
	var events: Array[ItemEvent] = []
	## Tocó EQUIPMENT 0 o 1: hay que imponer las armas ([method ActionMachine.set_weapons], §4.1).
	var weapons_changed: bool = false
	## El id que tomó de [member Context.new_uid] (SPLIT: el [code]uid[/code] de la pila nueva; DESTROY: el
	## [code]op_id[/code] de su operación PLAYER); 0 si ninguno.
	var new_id: int = 0
	## CANNOT_EQUIP por nivel: el que pide el objeto («Necesitas nivel N»); 0 si no.
	var required_level: int = 0
	## [method camp_refill]: una pila nueva no cupo (aviso «Bolsa llena»).
	var bag_full: bool = false

	## true si se aplicó.
	func is_ok() -> bool:
		return result == Result.OK


## Una petición con esos campos.
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


## Valida [param request] contra [param state] y [param context] en el orden de §4.2 y, si todo vale, la
## aplica. [b]Orden:[/b] INVALID (operación, contenedores y ranuras que no existen, origen igual a destino,
## MOVE con cantidad, SPLIT de menos de 1 o fuera de la bolsa, cantidad negativa) → STALE (origen vacío o con
## otro uid) → INVALID por la cantidad frente a la pila (SPLIT de [code]count[/code] o más, DESTROY de más de
## las que hay: sin el objeto que se esperaba no hay pila contra la que medirla) → NOT_NOW (toca el equipo sin
## poder, o destruye un consumible bebiendo) → CANNOT_EQUIP (ranura que no le va, 2–6 en la fase 5, nivel) →
## WEAPON_REQUIRED (dejaría vacía la ranura de arma activa) → NO_ROOM (SPLIT a una ranura ocupada) → LOCKED
## (DESTROY de algo equipado o indestructible) → NOT_NOW sin id para SPLIT o DESTROY: el id se pide al final,
## para que una petición rechazada no gaste ninguno.
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
	# 1 · INVALID: la forma de la petición.
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
	# 1 · INVALID por la cantidad frente a la pila.
	if op == Op.SPLIT and request.count >= source.count:
		return _fail(out, Result.INVALID)
	if op == Op.DESTROY and request.count > source.count:
		return _fail(out, Result.INVALID)
	var definition: ItemDefinition = db.get_definition(source.def_id)
	if definition == null:
		# Una instancia sin definición no llega al estado (decode y from_dictionary la rechazan).
		return _fail(out, Result.INVALID)
	var target: ItemInstance = state.get_item(to.x, to.y) if has_target else null
	# 3 · NOT_NOW.
	var touches_equipment: bool = from.x == InventoryState.ContainerId.EQUIPMENT \
			or (has_target and to.x == InventoryState.ContainerId.EQUIPMENT)
	if touches_equipment and not context.can_touch_equipment:
		return _fail(out, Result.NOT_NOW)
	if op == Op.DESTROY and context.drinking and definition.category == ItemDefinition.Category.CONSUMABLE:
		return _fail(out, Result.NOT_NOW)
	# Lo que quedaría en el origen y en el destino.
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
	# 4 · CANNOT_EQUIP: lo que entra en una ranura del equipo desde otra (lo que se queda donde estaba no
	# se vuelve a mirar).
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
	# 3 · NOT_NOW sin id (se pide ahora, cuando todo lo demás vale).
	if op == Op.SPLIT or op == Op.DESTROY:
		var id: int = _take_id(context)
		if id == 0:
			return _fail(out, Result.NOT_NOW)
		out.new_id = id
		if op == Op.SPLIT:
			new_to.uid = id
	# Ligado al equipar (§4.2): lo que entra en el equipo con ON_EQUIP.
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


## Texto en español de [param result] (§4.2) para el aviso del cliente; vacío con OK. Con CANNOT_EQUIP y
## [param required_level] > 0, «Necesitas nivel N»; con NOT_NOW y [param in_combat], el de combate.
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


## true si [param definition] va en la ranura [param slot] del equipo (las dos de arma para WEAPON y la suya
## para cada armadura), sin mirar si la ranura está abierta en la fase 5.
static func fits_slot(definition: ItemDefinition, slot: int) -> bool:
	if definition == null:
		return false
	if slot == InventoryState.EquipmentSlot.WEAPON_1 or slot == InventoryState.EquipmentSlot.WEAPON_2:
		return definition.equip_slot == ItemDefinition.EquipSlot.WEAPON
	return slot >= InventoryState.EquipmentSlot.HEAD and slot <= InventoryState.EquipmentSlot.FEET \
			and int(definition.equip_slot) == slot


## CAMP_REFILL (§4.4): por cada definición con [member ItemDefinition.camp_refill], en orden de id, lo que
## falta hasta ese total ([method InventoryState.count_of]: bolsa y equipo) se suma a su pila de la bolsa con
## la ranura más baja (con el mismo ligado que tendrían las nuevas) hasta la pila llena, y el resto va a una
## pila nueva en la primera ranura libre con un id de [member Context.new_uid]. Sin ranura libre esa parte no
## se repone y [member Outcome.bag_full] lo dice; sin id, espera al siguiente intento. Reponer mira el
## [b]total[/b]: dividir la pila no da más. Eventos con motivo CAMP_REFILL, uno por instancia tocada.
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


## Suma [param count] unidades de [param def_id] a la bolsa con el motivo [param reason] (una fuente o un
## interno): primero a sus pilas con hueco (en orden de ranura, con el mismo ligado que tendrían las nuevas) y
## el resto en pilas nuevas en las primeras ranuras libres, con ids de [member Context.new_uid]. Entera o
## nada: INVALID con una definición que no existe o [param count] < 1; NO_ROOM si no cabe; NOT_NOW si falta
## algún id (los ya tomados se pierden: un hueco en los ids no importa, §4.5). Un evento por instancia tocada.
static func add_items(state: InventoryState, def_id: StringName, count: int, reason: int,
		context: Context) -> Outcome:
	var out := Outcome.new()
	var db: ItemDatabase = context.db if context.db != null else ItemDatabase.shared()
	var definition: ItemDefinition = db.get_definition(def_id)
	if definition == null or count < 1:
		return _fail(out, Result.INVALID)
	var bag: int = InventoryState.ContainerId.BAG
	var bound: bool = definition.bind_rule == ItemDefinition.BindRule.ON_PICKUP
	# Plan: [ranura, instancia existente o null, unidades].
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


## Quita [param count] unidades de [param def_id] con el motivo [param reason] (un sumidero o un interno):
## primero de la instancia [param prefer_uid] si es de esa definición, después de la bolsa en orden de ranura
## (CONSUME: la pila con la ranura más baja) y por último del equipo. Una pila que se queda en 0 desaparece y
## su [code]uid[/code] muere. Las ranuras de [param protected] no se tocan (la reversión de progresion.md §10 no
## quita de la ranura activa del equipo). Entera o nada: INVALID con [param count] < 1, STALE si no hay tantas
## fuera de las protegidas. No mira la ranura activa (I10): quitar un arma equipada es cosa de quien llama
## ([member Outcome.weapons_changed]).
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


## Las unidades de [param def_id] en la bolsa y el equipo fuera de las ranuras de [param protected].
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


## Crea [param count] unidades de [param def_id] en pilas nuevas (hasta [member ItemDefinition.max_stack] cada una)
## en las primeras ranuras libres de la bolsa, con ids de [member Context.new_uid] y el motivo [param reason]: sin
## juntar con las que ya hay (el [code]item_give[/code] de GM y la reversión de progresion.md §10, que crean «con
## otros uid»). Con [param template], cada pila copia su durabilidad, rareza, ligado, semilla y afijos (la fila
## retirada de lo que se revierte); sin ella, como [method ItemInstance.create]. Entera o nada: INVALID con una
## definición que no existe, [param count] < 1 o una plantilla de otra definición; NO_ROOM sin ranuras libres
## bastantes; NOT_NOW si falta algún id. Un evento por pila.
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


# --- Interno ---------------------------------------------------------------------------------

static func _fail(out: Outcome, result: int) -> Outcome:
	out.result = result
	out.events.clear()
	out.weapons_changed = false
	out.new_id = 0
	return out


# Juntar: misma definición apilable, mismo ligado y hueco en el destino.
static func _can_merge(source: ItemInstance, target: ItemInstance, definition: ItemDefinition) -> bool:
	return source.def_id == target.def_id and definition.max_stack > 1 and source.bound == target.bound \
			and target.count < definition.max_stack


# Copia de [param item] con [param count] unidades (nunca se cambia la instancia que ya está en el estado).
static func _with_count(item: ItemInstance, count: int) -> ItemInstance:
	var copy: ItemInstance = item.duplicate_instance()
	copy.count = count
	return copy


# CANNOT_EQUIP de lo que entra en la ranura [param slot] del equipo; OK si vale.
static func _equip_check(out: Outcome, item: ItemInstance, slot: int, db: ItemDatabase,
		context: Context) -> int:
	var definition: ItemDefinition = db.get_definition(item.def_id)
	if slot >= InventoryState.OPEN_EQUIPMENT_SLOTS or not fits_slot(definition, slot):
		return Result.CANNOT_EQUIP
	if definition.required_level > context.level:
		out.required_level = definition.required_level
		return Result.CANNOT_EQUIP
	return Result.OK


# Lo que entra en el equipo con ON_EQUIP queda ligado (una copia si cambia).
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


# Un id de [member Context.new_uid], o 0 si no hay.
static func _take_id(context: Context) -> int:
	if not context.new_uid.is_valid():
		return 0
	var value: Variant = context.new_uid.call()
	return value if typeof(value) == TYPE_INT else 0
