class_name InventoryState
extends RefCounted
## Los contenedores de un personaje (docs/progresion.md §4.1, PRG-11): la bolsa ([code]BAG[/code],
## [member bag_slots] ranuras, 30 por defecto y 120 como mucho) y el equipo ([code]EQUIPMENT[/code], 7
## ranuras: las dos armas y cinco de armadura reservadas en la fase 5). El equipo puesto [b]es[/b] el
## contenedor EQUIPMENT. El banco (PRG-25) y el contenedor 3 no existen todavía: sus ranuras no existen.
## [br][br]
## Solo guarda instancias: no sabe de reglas (las aplica [InventoryOps]) ni de la ranura activa, que es el
## bit0 de [code]combat_flags2[/code] del [CombatState] y llega a cada petición en
## [member InventoryOps.Context.active_weapon_slot]. La sección [code]containers[/code] de las reglas
## exportadas ([ProgressionRulesExport]) sale de sus constantes. Compartido: sin reloj ni azar.

## Contenedores (en la base de datos y en el cable, este número). En la fase 5 solo BAG y EQUIPMENT.
enum ContainerId { BAG = 0, EQUIPMENT = 1, BANK = 2 }
## Ranuras del equipo. En la fase 5 solo las dos de arma admiten algo (CANNOT_EQUIP en el resto).
enum EquipmentSlot { WEAPON_1 = 0, WEAPON_2 = 1, HEAD = 2, CHEST = 3, HANDS = 4, LEGS = 5, FEET = 6 }

## Ranuras de la bolsa de un personaje nuevo.
const BAG_SLOTS_DEFAULT: int = 30
## Tope de las ranuras de la bolsa (INVENTORY_FULL las lleva en un u8).
const BAG_SLOTS_MAX: int = 120
## Ranuras del equipo.
const EQUIPMENT_SLOTS: int = 7
## Ranuras del equipo que admiten algo en la fase 5: solo las armas.
const OPEN_EQUIPMENT_SLOTS: int = 2
## Contenedores que existen en la fase 5.
const OPEN_CONTAINERS: Array[int] = [ContainerId.BAG, ContainerId.EQUIPMENT]

## Ranuras de la bolsa (1 a [constant BAG_SLOTS_MAX]; en la fase 5 no cambia, I12). Cambiarlo conserva lo
## que cabe; lo que quede fuera al reducirla se pierde, así que solo se reduce con la bolsa vacía.
var bag_slots: int = BAG_SLOTS_DEFAULT:
	set = _set_bag_slots

var _bag: Array[ItemInstance] = []
var _equipment: Array[ItemInstance] = []


func _init(slots: int = BAG_SLOTS_DEFAULT) -> void:
	_equipment.resize(EQUIPMENT_SLOTS)
	bag_slots = slots


## Ranuras de [param container]: [member bag_slots], [constant EQUIPMENT_SLOTS] o 0 si no existe.
func slot_count(container: int) -> int:
	match container:
		ContainerId.BAG:
			return bag_slots
		ContainerId.EQUIPMENT:
			return EQUIPMENT_SLOTS
	return 0


## true si la ranura existe (contenedor abierto en la fase 5 y ranura en rango).
func has_slot(container: int, slot: int) -> bool:
	return slot >= 0 and slot < slot_count(container)


## La instancia de la ranura, o null si está vacía o no existe.
func get_item(container: int, slot: int) -> ItemInstance:
	if not has_slot(container, slot):
		return null
	return _bag[slot] if container == ContainerId.BAG else _equipment[slot]


## Pone [param item] en la ranura (null la vacía). Una ranura que no existe es un error de quien llama: se
## registra y no cambia nada. No comprueba reglas: eso es de [InventoryOps].
func set_item(container: int, slot: int, item: ItemInstance) -> void:
	if not has_slot(container, slot):
		push_error("[Eldmark] Inventario: la ranura (%d, %d) no existe" % [container, slot])
		return
	if container == ContainerId.BAG:
		_bag[slot] = item
	else:
		_equipment[slot] = item


## La primera ranura vacía de [param container], o −1 si no queda ninguna (o no existe).
func first_free(container: int) -> int:
	for slot: int in range(slot_count(container)):
		if get_item(container, slot) == null:
			return slot
	return -1


## Cuántas ranuras vacías tiene [param container].
func free_count(container: int) -> int:
	var free: int = 0
	for slot: int in range(slot_count(container)):
		if get_item(container, slot) == null:
			free += 1
	return free


## Dónde está la instancia con [param uid]: [code](contenedor, ranura)[/code], o [code](−1, −1)[/code].
func find_uid(uid: int) -> Vector2i:
	for container: int in OPEN_CONTAINERS:
		for slot: int in range(slot_count(container)):
			var item: ItemInstance = get_item(container, slot)
			if item != null and item.uid == uid:
				return Vector2i(container, slot)
	return Vector2i(-1, -1)


## Unidades de [param def_id] en la bolsa y el equipo.
func count_of(def_id: StringName) -> int:
	var total: int = 0
	for item: ItemInstance in _bag:
		if item != null and item.def_id == def_id:
			total += item.count
	for item: ItemInstance in _equipment:
		if item != null and item.def_id == def_id:
			total += item.count
	return total


## Todas las instancias: la bolsa y después el equipo, cada uno en orden de ranura.
func all_items() -> Array[ItemInstance]:
	var result: Array[ItemInstance] = []
	for item: ItemInstance in _bag:
		if item != null:
			result.append(item)
	for item: ItemInstance in _equipment:
		if item != null:
			result.append(item)
	return result


## Las ranuras ocupadas como [code](contenedor, ranura)[/code], en el orden de [method all_items].
func occupied_slots() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for container: int in OPEN_CONTAINERS:
		for slot: int in range(slot_count(container)):
			if get_item(container, slot) != null:
				result.append(Vector2i(container, slot))
	return result


## Una copia independiente (también cada instancia).
func duplicate_state() -> InventoryState:
	var copy := InventoryState.new(bag_slots)
	for slot: int in range(bag_slots):
		if _bag[slot] != null:
			copy._bag[slot] = _bag[slot].duplicate_instance()
	for slot: int in range(EQUIPMENT_SLOTS):
		if _equipment[slot] != null:
			copy._equipment[slot] = _equipment[slot].duplicate_instance()
	return copy


## true si [param other] tiene las mismas ranuras con las mismas instancias (campo a campo).
func equals(other: InventoryState) -> bool:
	if other == null or other.bag_slots != bag_slots:
		return false
	for container: int in OPEN_CONTAINERS:
		for slot: int in range(slot_count(container)):
			var mine: ItemInstance = get_item(container, slot)
			var theirs: ItemInstance = other.get_item(container, slot)
			if (mine == null) != (theirs == null) or (mine != null and not mine.equals(theirs)):
				return false
	return true


func _set_bag_slots(value: int) -> void:
	bag_slots = clampi(value, 1, BAG_SLOTS_MAX)
	_bag.resize(bag_slots)
