class_name InventoryState
extends RefCounted
## A character's containers (docs/progresion.md §4.1, PRG-11): the bag ([code]BAG[/code],
## [member bag_slots] slots, 30 by default and 120 at most) and equipment ([code]EQUIPMENT[/code],
## 7 slots: the two weapons and five armor slots reserved in phase 5). The worn equipment [b]is[/b]
## the EQUIPMENT container. The bank (PRG-25) and container 3 do not exist yet: their slots do not
## exist.
## [br][br]
## It only stores instances: it knows nothing of rules (applied by [InventoryOps]) or of the active
## slot, which is bit0 of [code]combat_flags2[/code] in the [CombatState] and reaches each request
## in [member InventoryOps.Context.active_weapon_slot]. The [code]containers[/code] section of the
## exported rules ([ProgressionRulesExport]) comes from its constants. Shared: no clock, no
## randomness.

## Containers (in the database and on the wire, this number). In phase 5 only BAG and EQUIPMENT.
enum ContainerId { BAG = 0, EQUIPMENT = 1, BANK = 2 }
## Equipment slots. In phase 5 only the two weapon slots accept anything (CANNOT_EQUIP for the
## rest).
enum EquipmentSlot { WEAPON_1 = 0, WEAPON_2 = 1, HEAD = 2, CHEST = 3, HANDS = 4, LEGS = 5, FEET = 6 }

## Bag slots of a new character.
const BAG_SLOTS_DEFAULT: int = 30
## Cap on bag slots (INVENTORY_FULL carries them in a u8).
const BAG_SLOTS_MAX: int = 120
## Equipment slots.
const EQUIPMENT_SLOTS: int = 7
## Equipment slots that accept anything in phase 5: weapons only.
const OPEN_EQUIPMENT_SLOTS: int = 2
## Containers that exist in phase 5.
const OPEN_CONTAINERS: Array[int] = [ContainerId.BAG, ContainerId.EQUIPMENT]

## Bag slots (1 to [constant BAG_SLOTS_MAX]; in phase 5 it does not change, I12). Changing it
## keeps what fits; whatever falls outside when shrinking is lost, so it is only reduced with an
## empty bag.
var bag_slots: int = BAG_SLOTS_DEFAULT:
	set = _set_bag_slots

var _bag: Array[ItemInstance] = []
var _equipment: Array[ItemInstance] = []


func _init(slots: int = BAG_SLOTS_DEFAULT) -> void:
	_equipment.resize(EQUIPMENT_SLOTS)
	bag_slots = slots


## Slots of [param container]: [member bag_slots], [constant EQUIPMENT_SLOTS] or 0 if it does not
## exist.
func slot_count(container: int) -> int:
	match container:
		ContainerId.BAG:
			return bag_slots
		ContainerId.EQUIPMENT:
			return EQUIPMENT_SLOTS
	return 0


## true if the slot exists (container open in phase 5 and slot in range).
func has_slot(container: int, slot: int) -> bool:
	return slot >= 0 and slot < slot_count(container)


## The instance in the slot, or null if it is empty or does not exist.
func get_item(container: int, slot: int) -> ItemInstance:
	if not has_slot(container, slot):
		return null
	return _bag[slot] if container == ContainerId.BAG else _equipment[slot]


## Puts [param item] in the slot (null empties it). A slot that does not exist is a caller error:
## it is logged and nothing changes. It does not check rules: that is [InventoryOps]'s job.
func set_item(container: int, slot: int, item: ItemInstance) -> void:
	if not has_slot(container, slot):
		push_error("[Eldmark] Inventario: la ranura (%d, %d) no existe" % [container, slot])
		return
	if container == ContainerId.BAG:
		_bag[slot] = item
	else:
		_equipment[slot] = item


## The first empty slot of [param container], or −1 if none is left (or it does not exist).
func first_free(container: int) -> int:
	for slot: int in range(slot_count(container)):
		if get_item(container, slot) == null:
			return slot
	return -1


## How many empty slots [param container] has.
func free_count(container: int) -> int:
	var free: int = 0
	for slot: int in range(slot_count(container)):
		if get_item(container, slot) == null:
			free += 1
	return free


## Where the instance with [param uid] is: [code](container, slot)[/code], or
## [code](−1, −1)[/code].
func find_uid(uid: int) -> Vector2i:
	for container: int in OPEN_CONTAINERS:
		for slot: int in range(slot_count(container)):
			var item: ItemInstance = get_item(container, slot)
			if item != null and item.uid == uid:
				return Vector2i(container, slot)
	return Vector2i(-1, -1)


## Units of [param def_id] in the bag and equipment.
func count_of(def_id: StringName) -> int:
	var total: int = 0
	for item: ItemInstance in _bag:
		if item != null and item.def_id == def_id:
			total += item.count
	for item: ItemInstance in _equipment:
		if item != null and item.def_id == def_id:
			total += item.count
	return total


## All instances: the bag and then equipment, each in slot order.
func all_items() -> Array[ItemInstance]:
	var result: Array[ItemInstance] = []
	for item: ItemInstance in _bag:
		if item != null:
			result.append(item)
	for item: ItemInstance in _equipment:
		if item != null:
			result.append(item)
	return result


## The occupied slots as [code](container, slot)[/code], in the order of [method all_items].
func occupied_slots() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for container: int in OPEN_CONTAINERS:
		for slot: int in range(slot_count(container)):
			if get_item(container, slot) != null:
				result.append(Vector2i(container, slot))
	return result


## An independent copy (each instance too).
func duplicate_state() -> InventoryState:
	var copy := InventoryState.new(bag_slots)
	for slot: int in range(bag_slots):
		if _bag[slot] != null:
			copy._bag[slot] = _bag[slot].duplicate_instance()
	for slot: int in range(EQUIPMENT_SLOTS):
		if _equipment[slot] != null:
			copy._equipment[slot] = _equipment[slot].duplicate_instance()
	return copy


## true if [param other] has the same slots with the same instances (field by field).
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
