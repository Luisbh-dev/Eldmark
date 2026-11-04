extends TestCase
## Pure inventory (docs/progresion.md §2.5, §4.1–§4.4, PRG-11): [InventoryState], [InventoryOps],
## [ItemEvent] and [StarterKit]. A table of cases with each operation and each code of §4.2 in their order (the
## first failure gives the code, and a rejection changes nothing); partial merge, full destination stack →
## swap, bound on equip, slots 2–6 → CANNOT_EQUIP, DESTROY of a consumable while drinking → NOT_NOW,
## only DESTROY gives events and, with slot 2 active (after a SWAP), unequipping WEAPON_2 → WEAPON_REQUIRED and
## unequipping WEAPON_1, OK. Also, the server's changes (§4.4) and the §2.5 kit.

const Op = InventoryOps.Op
const R = InventoryOps.Result
const BAG: int = InventoryState.ContainerId.BAG
const EQUIP: int = InventoryState.ContainerId.EQUIPMENT
const ARMOR_FIXTURES: String = "res://tests/fixtures/items/armor"

## Ids of the objects in the test state ([method _standard]).
const SWORD_UID: int = 1
const BOW_UID: int = 2
const HEALTH_A: int = 10
const HEALTH_B: int = 11
const STAMINA: int = 12
const HEALTH_FULL: int = 13
const HELM: int = 20
const ORE_LOOSE: int = 30
const ORE_BOUND: int = 31

var _db: ItemDatabase
## Next id of [method _context] (a dictionary: the lambdas share it).
var _ids: Dictionary = {"next": 5000, "taken": 0}


func before_each() -> void:
	_db = _test_db()
	_ids = {"next": 5000, "taken": 0}


# --- InventoryState ------------------------------------------------------------------------------

func test_state_slots_lookups_and_copies() -> void:
	var state := InventoryState.new()
	assert_eq(state.bag_slots, 30, "30 bag slots by default")
	assert_eq([state.slot_count(BAG), state.slot_count(EQUIP), state.slot_count(InventoryState.ContainerId.BANK),
			state.slot_count(3)], [30, 7, 0, 0], "bag, equipment and nothing else in phase 5")
	assert_false(state.has_slot(BAG, 30) or state.has_slot(BAG, -1) or state.has_slot(EQUIP, 7), "out of range")
	assert_eq(state.first_free(BAG), 0, "empty")
	assert_eq(state.find_uid(1), Vector2i(-1, -1), "without the uid")
	state = _standard()
	assert_eq(state.first_free(BAG), 7, "the first free one")
	assert_eq(state.first_free(EQUIP), 2, "in the equipment, 2 (reserved, but exists)")
	assert_eq(state.free_count(BAG), 3, "three free")
	assert_eq(state.find_uid(BOW_UID), Vector2i(EQUIP, 1), "the bow in WEAPON_2")
	assert_eq(state.find_uid(ORE_BOUND), Vector2i(BAG, 6), "the bound ore")
	assert_eq(state.count_of(&"potion_health"), 37, "10 + 12 + 15 in the bag")
	assert_eq(state.count_of(&"bow_vado"), 1, "equipment counts too")
	assert_eq(state.all_items().size(), 9, "nine instances")
	assert_eq(state.all_items()[0].uid, HEALTH_A, "the bag first")
	assert_eq(state.all_items()[8].uid, BOW_UID, "and the equipment afterwards")
	assert_eq(state.occupied_slots()[7], Vector2i(EQUIP, 0), "the occupied slots, in the same order")
	var copy: InventoryState = state.duplicate_state()
	assert_true(copy.equals(state), "the copy is equal")
	copy.get_item(BAG, 0).count = 1
	assert_eq(state.get_item(BAG, 0).count, 10, "and shares no instances")
	assert_false(copy.equals(state), "no longer equal")
	state.bag_slots = 500
	assert_eq(state.bag_slots, InventoryState.BAG_SLOTS_MAX, "cap of 120")
	state.bag_slots = 0
	assert_eq(state.bag_slots, 1, "at least one")
	assert_eq([InventoryState.OPEN_EQUIPMENT_SLOTS, InventoryState.EQUIPMENT_SLOTS], [2, 7], "two of seven open")


# --- The §4.2 table, in its order ----------------------------------------------------------------

## INVALID: the shape of the request, before anything else (also before STALE).
func test_invalid_requests() -> void:
	var cases: Array[Array] = [
		["operación 0", _req(0, BAG, 0, BAG, 7, 0, HEALTH_A)],
		["operación 4", _req(4, BAG, 0, BAG, 7, 0, HEALTH_A)],
		["el banco no existe en la fase 5", _req(Op.MOVE, InventoryState.ContainerId.BANK, 0, BAG, 7, 0, HEALTH_A)],
		["ni el contenedor 3", _req(Op.MOVE, BAG, 0, 3, 0, 0, HEALTH_A)],
		["ranura de bolsa fuera de rango", _req(Op.MOVE, BAG, 10, BAG, 7, 0, HEALTH_A)],
		["ranura negativa", _req(Op.MOVE, BAG, 0, BAG, -1, 0, HEALTH_A)],
		["ranura de equipo 7", _req(Op.MOVE, BAG, 0, EQUIP, 7, 0, HEALTH_A)],
		["origen igual a destino", _req(Op.MOVE, BAG, 0, BAG, 0, 0, HEALTH_A)],
		["MOVE con cantidad", _req(Op.MOVE, BAG, 0, BAG, 7, 1, HEALTH_A)],
		["SPLIT de 0", _req(Op.SPLIT, BAG, 0, BAG, 7, 0, HEALTH_A)],
		["SPLIT al equipo", _req(Op.SPLIT, BAG, 0, EQUIP, 3, 1, HEALTH_A)],
		["SPLIT de toda la pila", _req(Op.SPLIT, BAG, 0, BAG, 7, 10, HEALTH_A)],
		["SPLIT de más de la pila", _req(Op.SPLIT, BAG, 0, BAG, 7, 11, HEALTH_A)],
		["DESTROY negativo", _req(Op.DESTROY, BAG, 0, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, -1, HEALTH_A)],
		["DESTROY de más de la pila", _req(Op.DESTROY, BAG, 0, InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 11, HEALTH_A)],
		["la forma antes que STALE: MOVE con cantidad desde una vacía", _req(Op.MOVE, BAG, 8, BAG, 9, 3, 0)],
		["la forma antes que STALE: SPLIT al equipo desde una vacía", _req(Op.SPLIT, BAG, 8, EQUIP, 1, 1, 0)],
	]
	for entry: Array in cases:
		_expect_rejected(_standard(), entry[1], _context(), R.INVALID, entry[0])


## STALE: the source empty or with another uid; before the quantity against the stack and before NOT_NOW.
func test_stale_requests() -> void:
	_expect_rejected(_standard(), _req(Op.MOVE, BAG, 8, BAG, 9, 0, HEALTH_A), _context(), R.STALE, "origen vacío")
	_expect_rejected(_standard(), _req(Op.MOVE, BAG, 0, BAG, 9, 0, 99), _context(), R.STALE, "otro uid")
	_expect_rejected(_standard(), _req(Op.SPLIT, BAG, 0, BAG, 9, 50, 99), _context(), R.STALE,
			"sin el objeto esperado no hay pila contra la que medir la cantidad")
	var busy: InventoryOps.Context = _context()
	busy.can_touch_equipment = false
	_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 3, BAG, 9, 0, 1), busy, R.STALE, "antes que NOT_NOW")


## NOT_NOW: touching equipment when unable, destroying a consumable while drinking and SPLIT or DESTROY without ids.
func test_not_now_requests() -> void:
	var busy: InventoryOps.Context = _context()
	busy.can_touch_equipment = false
	_expect_rejected(_standard(), _req(Op.MOVE, BAG, 4, EQUIP, 2, 0, HELM), busy, R.NOT_NOW,
			"equipar en combate, antes que CANNOT_EQUIP")
	_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 1, BAG, 9, 0, BOW_UID), busy, R.NOT_NOW, "desequipar en combate")
	_expect_rejected(_standard(), _req(Op.DESTROY, EQUIP, 1, 0xFF, 0xFF, 0, BOW_UID), busy, R.NOT_NOW,
			"destruir algo equipado en combate, antes que LOCKED")
	_expect_applied(_standard(), _req(Op.MOVE, BAG, 0, BAG, 9, 0, HEALTH_A), busy, "en combate, la bolsa sí")
	var drinking: InventoryOps.Context = _context()
	drinking.drinking = true
	_expect_rejected(_standard(), _req(Op.DESTROY, BAG, 2, 0xFF, 0xFF, 1, STAMINA), drinking, R.NOT_NOW,
			"destruir un consumible bebiendo")
	_expect_applied(_standard(), _req(Op.DESTROY, BAG, 5, 0xFF, 0xFF, 1, ORE_LOOSE), drinking,
			"bebiendo, lo que no es consumible sí")
	_expect_applied(_standard(), _req(Op.SPLIT, BAG, 0, BAG, 9, 2, HEALTH_A), drinking, "y dividir también")
	var no_ids := InventoryOps.Context.new()
	no_ids.db = _db
	_expect_rejected(_standard(), _req(Op.SPLIT, BAG, 0, BAG, 9, 2, HEALTH_A), no_ids, R.NOT_NOW, "SPLIT sin ids")
	_expect_rejected(_standard(), _req(Op.DESTROY, BAG, 0, 0xFF, 0xFF, 2, HEALTH_A), no_ids, R.NOT_NOW,
			"DESTROY sin ids")
	var exhausted: InventoryOps.Context = _context()
	exhausted.new_uid = func() -> int: return 0
	_expect_rejected(_standard(), _req(Op.SPLIT, BAG, 0, BAG, 9, 2, HEALTH_A), exhausted, R.NOT_NOW,
			"new_uid que da 0")
	_expect_applied(_standard(), _req(Op.MOVE, BAG, 0, BAG, 9, 0, HEALTH_A), no_ids, "mover no necesita ids")


## CANNOT_EQUIP: a slot it does not fit, 2–6 closed in phase 5 and the level; before WEAPON_REQUIRED.
func test_cannot_equip_requests() -> void:
	var one_weapon: InventoryState = _standard()
	one_weapon.set_item(EQUIP, 1, null)
	_expect_rejected(one_weapon, _req(Op.MOVE, BAG, 0, EQUIP, 1, 0, HEALTH_A), _context(), R.CANNOT_EQUIP,
			"una poción en una ranura de arma")
	_expect_rejected(_standard(), _req(Op.MOVE, BAG, 4, EQUIP, 2, 0, HELM), _context(), R.CANNOT_EQUIP,
			"un yelmo en HEAD: cerrada en la fase 5")
	_expect_rejected(_standard(), _req(Op.MOVE, BAG, 4, EQUIP, 1, 0, HELM), _context(), R.CANNOT_EQUIP,
			"un yelmo en una ranura de arma")
	for slot: int in range(2, 7):
		_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 1, EQUIP, slot, 0, BOW_UID), _context(), R.CANNOT_EQUIP,
				"el arco a la ranura %d" % slot)
	_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 1, BAG, 0, 0, BOW_UID), _context(), R.CANNOT_EQUIP,
			"desequipar sobre una poción la metería en el equipo")
	_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 0, BAG, 0, 0, SWORD_UID), _context(), R.CANNOT_EQUIP,
			"lo mismo con el arma activa: la poción entraría en su ranura")
	_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 0, EQUIP, 3, 0, SWORD_UID), _context(), R.CANNOT_EQUIP,
			"el arma activa a una ranura cerrada la deja vacía, pero CANNOT_EQUIP va antes que WEAPON_REQUIRED")
	# Level: a bow that requires level 5.
	var leveled: ItemDatabase = _leveled_db()
	var state := InventoryState.new(10)
	state.set_item(EQUIP, 0, ItemInstance.create(SWORD_UID, leveled.get_definition(&"sword_shield_vado"), 1))
	state.set_item(BAG, 0, ItemInstance.create(77, leveled.get_definition(&"test_bow_level5"), 1))
	var low: InventoryOps.Context = _context(leveled)
	var outcome: InventoryOps.Outcome = _expect_rejected(state, _req(Op.MOVE, BAG, 0, EQUIP, 1, 0, 77), low,
			R.CANNOT_EQUIP, "nivel 1 para un arco de nivel 5")
	assert_eq(outcome.required_level, 5, "it states the level it requires")
	assert_eq(InventoryOps.result_text(outcome.result, outcome.required_level), "Necesitas nivel 5", "its text")
	var high: InventoryOps.Context = _context(leveled)
	high.level = 5
	outcome = _expect_applied(state, _req(Op.MOVE, BAG, 0, EQUIP, 1, 0, 77), high, "con nivel 5, sí")
	assert_true(state.get_item(EQUIP, 1).bound, "ON_EQUIP: it becomes bound when equipped")
	assert_true(outcome.weapons_changed, "and swaps the weapons")
	outcome = _expect_applied(state, _req(Op.MOVE, EQUIP, 1, BAG, 3, 0, 77), high, "desequipar")
	assert_true(state.get_item(BAG, 3).bound, "and stays bound")


## WEAPON_REQUIRED: it would leave the active weapon slot empty; with 2 active (after a SWAP), slot 2.
func test_weapon_required_follows_the_active_slot() -> void:
	_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 0, BAG, 9, 0, SWORD_UID), _context(), R.WEAPON_REQUIRED,
			"desequipar el arma activa")
	var one_weapon: InventoryState = _standard()
	one_weapon.set_item(EQUIP, 1, null)
	_expect_rejected(one_weapon, _req(Op.MOVE, EQUIP, 0, EQUIP, 1, 0, SWORD_UID), _context(), R.WEAPON_REQUIRED,
			"pasarla a la otra ranura vacía")
	_expect_rejected(_standard(), _req(Op.DESTROY, EQUIP, 0, 0xFF, 0xFF, 0, SWORD_UID), _context(),
			R.WEAPON_REQUIRED, "destruirla: WEAPON_REQUIRED va antes que LOCKED")
	var swapped: InventoryOps.Context = _context()
	swapped.active_weapon_slot = 1
	_expect_rejected(_standard(), _req(Op.MOVE, EQUIP, 1, BAG, 9, 0, BOW_UID), swapped, R.WEAPON_REQUIRED,
			"con la 2 activa, desequipar WEAPON_2")
	var state: InventoryState = _standard()
	var outcome: InventoryOps.Outcome = _expect_applied(state, _req(Op.MOVE, EQUIP, 0, BAG, 9, 0, SWORD_UID),
			swapped, "con la 2 activa, desequipar WEAPON_1 vale")
	assert_null(state.get_item(EQUIP, 0), "WEAPON_1 empty")
	assert_eq(state.get_item(BAG, 9).uid, SWORD_UID, "the sword in the bag")
	assert_true(outcome.weapons_changed, "the weapons swap")
	_expect_applied(_standard(), _req(Op.MOVE, EQUIP, 0, EQUIP, 1, 0, SWORD_UID), _context(),
			"intercambiar las dos armas deja la activa con arma")


## NO_ROOM and LOCKED; the id is requested last, so a rejection spends none.
func test_no_room_and_locked() -> void:
	var context: InventoryOps.Context = _context()
	_expect_rejected(_standard(), _req(Op.SPLIT, BAG, 0, BAG, 1, 3, HEALTH_A), context, R.NO_ROOM,
			"dividir a una ranura ocupada")
	_expect_rejected(_standard(), _req(Op.DESTROY, EQUIP, 1, 0xFF, 0xFF, 0, BOW_UID), context, R.LOCKED,
			"destruir algo equipado")
	var bow_in_bag: InventoryState = _standard()
	bow_in_bag.set_item(EQUIP, 1, null)
	bow_in_bag.set_item(BAG, 9, ItemInstance.create(BOW_UID, _db.get_definition(&"bow_vado"), 1))
	_expect_rejected(bow_in_bag, _req(Op.DESTROY, BAG, 9, 0xFF, 0xFF, 0, BOW_UID), context, R.LOCKED,
			"destruir un objeto indestructible")
	assert_eq(_ids["taken"], 0, "no rejection has spent an id")
	var no_ids := InventoryOps.Context.new()
	no_ids.db = _db
	_expect_rejected(bow_in_bag, _req(Op.DESTROY, BAG, 9, 0xFF, 0xFF, 0, BOW_UID), no_ids, R.LOCKED,
			"sin ids y bloqueado: LOCKED (el id se pide cuando todo lo demás vale)")


# --- What gets applied ---------------------------------------------------------------------------

func test_move_to_an_empty_slot() -> void:
	var state: InventoryState = _standard()
	var original: ItemInstance = state.get_item(BAG, 0)
	var outcome: InventoryOps.Outcome = _expect_applied(state, _req(Op.MOVE, BAG, 0, BAG, 9, 0, HEALTH_A), _context(),
			"mover")
	assert_null(state.get_item(BAG, 0), "the source ends up empty")
	assert_eq(state.get_item(BAG, 9).uid, HEALTH_A, "with the same uid")
	assert_eq(state.get_item(BAG, 9).count, 10, "and the same quantity")
	assert_eq(outcome.changed, [Vector2i(BAG, 0), Vector2i(BAG, 9)] as Array[Vector2i], "the two slots")
	assert_eq(original.count, 10, "the previous instance does not change")


func test_partial_and_full_merge() -> void:
	var state: InventoryState = _standard()
	var target_before: ItemInstance = state.get_item(BAG, 1)
	_expect_applied(state, _req(Op.MOVE, BAG, 0, BAG, 1, 0, HEALTH_A), _context(), "juntar 10 sobre 12")
	assert_eq(state.get_item(BAG, 1).count, 15, "the destination fills up")
	assert_eq(state.get_item(BAG, 1).uid, HEALTH_B, "and keeps its uid")
	assert_eq(state.get_item(BAG, 0).count, 7, "what does not fit stays")
	assert_eq(state.get_item(BAG, 0).uid, HEALTH_A, "with its uid")
	assert_eq(state.count_of(&"potion_health"), 37, "without changing the total")
	assert_eq(target_before.count, 12, "without touching the previous instance")
	var small: InventoryState = _standard()
	small.set_item(BAG, 0, _item(HEALTH_A, &"potion_health", 2))
	small.set_item(BAG, 1, _item(HEALTH_B, &"potion_health", 5))
	_expect_applied(small, _req(Op.MOVE, BAG, 0, BAG, 1, 0, HEALTH_A), _context(), "juntar 2 sobre 5")
	assert_null(small.get_item(BAG, 0), "the source empties: its uid dies")
	assert_eq(small.get_item(BAG, 1).count, 7, "7 in the destination")
	assert_eq(small.find_uid(HEALTH_A), Vector2i(-1, -1), "the merged uid is no longer there")


func test_swaps() -> void:
	var state: InventoryState = _standard()
	_expect_applied(state, _req(Op.MOVE, BAG, 0, BAG, 3, 0, HEALTH_A), _context(), "sobre una pila llena")
	assert_eq([state.get_item(BAG, 0).uid, state.get_item(BAG, 3).uid], [HEALTH_FULL, HEALTH_A], "swaps")
	assert_eq([state.get_item(BAG, 0).count, state.get_item(BAG, 3).count], [15, 10], "with their quantities")
	state = _standard()
	_expect_applied(state, _req(Op.MOVE, BAG, 5, BAG, 6, 0, ORE_LOOSE), _context(), "otro ligado")
	assert_eq([state.get_item(BAG, 5).uid, state.get_item(BAG, 6).uid], [ORE_BOUND, ORE_LOOSE], "swaps")
	state = _standard()
	_expect_applied(state, _req(Op.MOVE, BAG, 0, BAG, 2, 0, HEALTH_A), _context(), "otra definición")
	assert_eq([state.get_item(BAG, 0).uid, state.get_item(BAG, 2).uid], [STAMINA, HEALTH_A], "swaps")
	state = _standard()
	state.set_item(BAG, 9, ItemInstance.create(BOW_UID, _db.get_definition(&"bow_vado"), 1))
	state.set_item(EQUIP, 1, null)
	var outcome: InventoryOps.Outcome = _expect_applied(state, _req(Op.MOVE, EQUIP, 0, BAG, 9, 0, SWORD_UID),
			_context(), "desequipar la activa sobre otra arma: se cambian")
	assert_eq([state.get_item(EQUIP, 0).uid, state.get_item(BAG, 9).uid], [BOW_UID, SWORD_UID], "the bow in hand")
	assert_true(outcome.weapons_changed, "the weapons swap")


func test_split_takes_one_id() -> void:
	var state: InventoryState = _standard()
	var outcome: InventoryOps.Outcome = _expect_applied(state, _req(Op.SPLIT, BAG, 0, BAG, 9, 4, HEALTH_A),
			_context(), "dividir 4")
	assert_eq(outcome.new_id, 5001, "takes an id")
	assert_eq(_ids["taken"], 1, "just one")
	assert_eq(state.get_item(BAG, 0).count, 6, "6 remain")
	var split: ItemInstance = state.get_item(BAG, 9)
	assert_eq([split.uid, split.def_id, split.count, split.bound], [5001, &"potion_health", 4, true],
			"the new stack, with its uid and the same binding")
	assert_eq(state.count_of(&"potion_health"), 37, "the total does not change")
	assert_false(outcome.weapons_changed, "does not touch the weapons")


func test_destroy_gives_the_only_event() -> void:
	var state: InventoryState = _standard()
	var outcome: InventoryOps.Outcome = _expect_applied(state, _req(Op.DESTROY, BAG, 0, 0xFF, 0xFF, 4, HEALTH_A),
			_context(), "destruir 4")
	assert_eq(state.get_item(BAG, 0).count, 6, "6 remain")
	assert_eq(outcome.events.size(), 1, "one event")
	assert_true(outcome.events[0].equals(ItemEvent.create(HEALTH_A, &"potion_health", -4,
			EconomyReason.PLAYER_DESTROY)), "of the uid, −4, PLAYER_DESTROY: %s" % outcome.events[0])
	assert_eq(outcome.new_id, 5001, "and the id of its PLAYER operation")
	assert_eq(outcome.changed, [Vector2i(BAG, 0)] as Array[Vector2i], "only the source")
	outcome = _expect_applied(state, _req(Op.DESTROY, BAG, 5, 0xFF, 0xFF, 0, ORE_LOOSE), _context(),
			"0 = toda la pila")
	assert_null(state.get_item(BAG, 5), "the uid dies")
	assert_eq(outcome.events[0].count_delta, -7, "−7")
	# No other operation gives events.
	for request: InventoryOps.Request in [_req(Op.MOVE, BAG, 0, BAG, 9, 0, HEALTH_A),
			_req(Op.MOVE, BAG, 1, BAG, 9, 0, HEALTH_B), _req(Op.SPLIT, BAG, 3, BAG, 5, 5, HEALTH_FULL),
			_req(Op.MOVE, EQUIP, 0, EQUIP, 1, 0, SWORD_UID)]:
		var other: InventoryOps.Outcome = InventoryOps.apply(state, request, _context())
		assert_eq(other.result, R.OK, "op %d applied" % request.op)
		assert_true(other.events.is_empty(), "op %d without events" % request.op)


func test_binding_rules_when_equipping() -> void:
	var leveled: ItemDatabase = _leveled_db()
	var state := InventoryState.new(10)
	var sword := ItemInstance.create(SWORD_UID, leveled.get_definition(&"sword_shield_vado"), 1)
	state.set_item(EQUIP, 0, sword)
	var loose_bow := ItemInstance.create(78, leveled.get_definition(&"test_bow_level5"), 1)
	assert_false(loose_bow.bound, "ON_EQUIP: unbound until equipped")
	state.set_item(BAG, 0, loose_bow)
	var context: InventoryOps.Context = _context(leveled)
	context.level = 40
	_expect_applied(state, _req(Op.MOVE, BAG, 0, EQUIP, 1, 0, 78), context, "equipar")
	assert_true(state.get_item(EQUIP, 1).bound, "bound on equipping")
	assert_false(loose_bow.bound, "on a copy: the previous instance does not change")
	assert_true(state.get_item(EQUIP, 0).bound, "ON_PICKUP was already bound")


func test_rejections_leave_everything_and_report_the_touched_slots() -> void:
	var state: InventoryState = _standard()
	var before: InventoryState = state.duplicate_state()
	var outcome: InventoryOps.Outcome = InventoryOps.apply(state,
			_req(Op.MOVE, BAG, 0, EQUIP, 0, 0, HEALTH_A), _context())
	assert_eq(outcome.result, R.CANNOT_EQUIP, "rejected")
	assert_true(state.equals(before), "no changes")
	assert_eq(outcome.changed, [Vector2i(BAG, 0), Vector2i(EQUIP, 0)] as Array[Vector2i],
			"the slots it touched, for the delta with their real content")
	assert_true(outcome.events.is_empty() and not outcome.weapons_changed and outcome.new_id == 0, "nothing else")
	outcome = InventoryOps.apply(state, _req(Op.MOVE, BAG, 0, BAG, 40, 0, HEALTH_A), _context())
	assert_eq(outcome.changed, [Vector2i(BAG, 0)] as Array[Vector2i], "only those that exist")


func test_result_texts() -> void:
	var texts: Dictionary[int, String] = {
		R.OK: "", R.INVALID: "Petición no válida", R.STALE: "Ese objeto ya no está ahí",
		R.NOT_NOW: "Ahora no puedes hacerlo", R.CANNOT_EQUIP: "No puedes equipar eso ahí",
		R.WEAPON_REQUIRED: "Necesitas un arma en la mano", R.NO_ROOM: "No cabe",
		R.LOCKED: "Ese objeto no se puede destruir", R.RATE: "Más despacio",
	}
	for result: int in texts:
		assert_eq(InventoryOps.result_text(result), texts[result], "text of %d" % result)
	assert_eq(InventoryOps.result_text(R.NOT_NOW, 0, true), "No puedes cambiar el equipo en combate", "in combat")
	assert_eq(InventoryOps.result_text(R.CANNOT_EQUIP, 12), "Necesitas nivel 12", "by level")


# --- Server changes (§4.4) -----------------------------------------------------------------------

func test_server_add_and_remove() -> void:
	var state: InventoryState = _standard()
	var outcome: InventoryOps.Outcome = InventoryOps.add_items(state, &"potion_health", 20, EconomyReason.GM_GRANT,
			_context())
	assert_eq(outcome.result, R.OK, "fits")
	assert_eq(state.count_of(&"potion_health"), 57, "+20")
	assert_eq(state.get_item(BAG, 0).count, 15, "first fills the stacks with room (10 → 15)")
	assert_eq(state.get_item(BAG, 1).count, 15, "(12 → 15)")
	assert_eq(state.get_item(BAG, 7).count, 12, "and the rest, in a new stack")
	assert_eq(state.get_item(BAG, 7).uid, 5001, "with a new id")
	var deltas: Array[int] = []
	for event: ItemEvent in outcome.events:
		deltas.append(event.count_delta)
		assert_eq(event.reason, EconomyReason.GM_GRANT, "with its reason")
	assert_eq(deltas, [5, 3, 12] as Array[int], "one event per instance")
	var before: InventoryState = state.duplicate_state()
	outcome = InventoryOps.add_items(state, &"potion_health", 50, EconomyReason.GM_GRANT, _context())
	assert_eq(outcome.result, R.NO_ROOM, "does not fit: nothing")
	assert_true(state.equals(before), "all or nothing")
	outcome = InventoryOps.remove_items(state, &"potion_health", 16, EconomyReason.GM_REMOVE, 5001)
	assert_eq(outcome.result, R.OK, "removes")
	assert_null(state.get_item(BAG, 7), "first the preferred one (12)")
	assert_eq(state.get_item(BAG, 0).count, 11, "and then the one in the lowest slot")
	assert_eq(state.count_of(&"potion_health"), 41, "−16")
	outcome = InventoryOps.remove_items(state, &"potion_health", 1000, EconomyReason.GM_REMOVE)
	assert_eq(outcome.result, R.STALE, "there are not that many: nothing")
	assert_eq(state.count_of(&"potion_health"), 41, "no changes")
	outcome = InventoryOps.remove_items(state, &"potion_health", 1, EconomyReason.CONSUME)
	assert_eq(state.get_item(BAG, 0).count, 10, "CONSUME: from the stack with the lowest slot")
	assert_eq(outcome.events[0].count_delta, -1, "−1")
	assert_eq(InventoryOps.add_items(state, &"no_such_item", 1, EconomyReason.GM_GRANT, _context()).result, R.INVALID,
			"a definition that does not exist")


func test_camp_refill_tops_up_the_total() -> void:
	var state := InventoryState.new(6)
	state.set_item(BAG, 0, _item(100, &"potion_health", 1))
	state.set_item(BAG, 2, _item(101, &"potion_health", 1))
	var outcome: InventoryOps.Outcome = InventoryOps.camp_refill(state, _context())
	assert_eq(state.count_of(&"potion_health"), 3, "replenishes the health total to 3")
	assert_eq(state.get_item(BAG, 0).count, 2, "in the stack of the lowest slot")
	assert_eq(state.get_item(BAG, 2).count, 1, "without touching the other")
	assert_eq(state.count_of(&"potion_stamina"), 2, "and the stamina one to 2, in a new stack")
	assert_eq(state.get_item(BAG, 1).uid, 5001, "with a server id, in the first free one")
	assert_eq(outcome.events.size(), 2, "one event per instance")
	for event: ItemEvent in outcome.events:
		assert_eq(event.reason, EconomyReason.CAMP_REFILL, "CAMP_REFILL")
	outcome = InventoryOps.camp_refill(state, _context())
	assert_true(outcome.events.is_empty() and outcome.changed.is_empty(), "full: nothing")
	var full := InventoryState.new(1)
	full.set_item(BAG, 0, _item(102, &"test_ore", 3))
	outcome = InventoryOps.camp_refill(full, _context())
	assert_true(outcome.bag_full, "no room for a new stack: \"Bolsa llena\" (bag full)")
	assert_eq(full.count_of(&"potion_health"), 0, "and does not replenish")
	var no_ids := InventoryOps.Context.new()
	no_ids.db = _db
	var empty := InventoryState.new(4)
	outcome = InventoryOps.camp_refill(empty, no_ids)
	assert_true(outcome.events.is_empty() and not outcome.bag_full, "without an id, the new stack waits")


# --- ItemEvent in JSON (§9.3) --------------------------------------------------------------------

func test_item_event_json() -> void:
	var event := ItemEvent.create(1027, &"potion_health", -1, EconomyReason.CONSUME)
	assert_eq(event.to_dictionary(), {"uid": "1027", "def_id": "potion_health", "count_delta": -1, "reason": 65},
			"the §9.3 shape")
	var aggregated := ItemEvent.create(0, &"potion_health", -1, EconomyReason.CONSUME)
	assert_eq(aggregated.to_dictionary()["uid"], null, "aggregated: uid null")
	for original: ItemEvent in [event, aggregated, ItemEvent.create(9007199254740991, &"bow_vado", 1, 1),
			ItemEvent.create(5, &"sword_shield_vado", -1, EconomyReason.REVERSAL)]:
		var text: String = JSON.stringify(original.to_dictionary())
		var back: ItemEvent = ItemEvent.from_dictionary(JSON.parse_string(text))
		assert_true(original.equals(back), "round trip through text: %s" % text)
	var rewritten: Dictionary = event.to_dictionary()
	rewritten["count_delta"] = -1.0
	assert_not_null(ItemEvent.from_dictionary(rewritten), "an integer such as -1.0 is valid")
	var broken: Array[Dictionary] = [
		{"def_id": "potion_health", "count_delta": -1, "reason": 65},
		{"uid": "1", "def_id": "potion_health", "count_delta": -1, "reason": 65, "extra": 1},
		{"uid": 1027, "def_id": "potion_health", "count_delta": -1, "reason": 65},
		{"uid": "0", "def_id": "potion_health", "count_delta": -1, "reason": 65},
		{"uid": "9007199254740992", "def_id": "potion_health", "count_delta": -1, "reason": 65},
		{"uid": "1", "def_id": "Potion", "count_delta": -1, "reason": 65},
		{"uid": "1", "def_id": 5, "count_delta": -1, "reason": 65},
		{"uid": "1", "def_id": "potion_health", "count_delta": 0, "reason": 128},
		{"uid": "1", "def_id": "potion_health", "count_delta": 1.5, "reason": 7},
		{"uid": "1", "def_id": "potion_health", "count_delta": -1, "reason": 1},
		{"uid": "1", "def_id": "potion_health", "count_delta": 1, "reason": 65},
		{"uid": "1", "def_id": "potion_health", "count_delta": 1, "reason": 200},
		{"uid": "1", "def_id": "potion_health", "count_delta": 1, "reason": "7"},
	]
	for entry: Dictionary in broken:
		assert_null(ItemEvent.from_dictionary(entry), "not valid: %s" % entry)


# --- Starter kit (§2.5) --------------------------------------------------------------------------

func test_starter_kit_of_each_template() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	var state := InventoryState.new()
	var events: Array[ItemEvent] = StarterKit.grant(state, &"squire", db, _counter_from(1025))
	assert_eq(_layout(state), [
		[EQUIP, 0, &"sword_shield_vado", 1, 1025], [BAG, 0, &"bow_vado", 1, 1026],
		[BAG, 1, &"potion_health", 3, 1027], [BAG, 2, &"potion_stamina", 2, 1028],
	], "squire: its sword equipped, the other template's bow and the potions (the §3.4 example)")
	assert_eq(events.size(), 4, "one event per instance")
	for event: ItemEvent in events:
		assert_eq(event.reason, EconomyReason.STARTER_KIT, "STARTER_KIT")
		assert_true(event.uid > 0 and event.count_delta > 0, "with uid and quantity: %s" % event)
	for item: ItemInstance in state.all_items():
		assert_true(item.bound, "%s, bound (ON_PICKUP)" % item.def_id)
		assert_true(item.is_valid(db), "%s is valid" % item.def_id)
	state = InventoryState.new()
	StarterKit.grant(state, &"marksman", db, _counter_from(1))
	assert_eq(_layout(state), [
		[EQUIP, 0, &"bow_vado", 1, 1], [EQUIP, 1, &"sword_shield_vado", 1, 2],
		[BAG, 0, &"potion_health", 3, 3], [BAG, 1, &"potion_stamina", 2, 4],
	], "marksman: bow and sword equipped and the potions (3 and 2 for them too)")


func test_starter_kit_fallbacks_and_failures() -> void:
	var db: ItemDatabase = ItemDatabase.shared()
	assert_eq(StarterKit.template_for(&"squire").id, &"squire", "the requested template")
	var state := InventoryState.new()
	StarterKit.grant(state, &"no_such_template", db, _counter_from(1))
	assert_eq(state.get_item(EQUIP, 0).def_id, &"bow_vado", "an unknown one uses the first eligible by id (marksman)")
	var npc: EquipmentTemplate = null
	for template: EquipmentTemplate in CombatCatalog.tables().templates:
		if not template.selectable:
			npc = template
	if npc != null:
		assert_eq(StarterKit.template_for(npc.id).id, &"marksman", "one that cannot be chosen, too")
	# Without ids halfway: nothing.
	state = InventoryState.new()
	var limited: Dictionary = {"left": 2}
	var two_ids: Callable = func() -> int:
		limited["left"] -= 1
		return 7000 + limited["left"] if limited["left"] >= 0 else 0
	var events: Array[ItemEvent] = StarterKit.grant(state, &"squire", db, two_ids)
	assert_true(events.is_empty(), "without enough ids it gives nothing")
	assert_true(state.all_items().is_empty(), "and the inventory stays empty")
	allow_logged_errors()
	state = InventoryState.new(2)
	assert_true(StarterKit.grant(state, &"squire", db, _counter_from(1)).is_empty(), "does not fit in 2 slots")
	assert_true(state.all_items().is_empty(), "nothing")
	state = _standard()
	var before: InventoryState = state.duplicate_state()
	assert_true(StarterKit.grant(state, &"squire", db, _counter_from(1)).is_empty(), "only in an empty inventory")
	assert_true(state.equals(before), "no changes")


# --- Helpers -------------------------------------------------------------------------------------

## Checks that the request is rejected with [param expected] and that the state does not change.
func _expect_rejected(state: InventoryState, request: InventoryOps.Request, context: InventoryOps.Context,
		expected: int, label: String) -> InventoryOps.Outcome:
	var before: InventoryState = state.duplicate_state()
	var outcome: InventoryOps.Outcome = InventoryOps.apply(state, request, context)
	assert_eq(outcome.result, expected, label)
	assert_true(state.equals(before), "%s: the state does not change" % label)
	assert_true(outcome.events.is_empty() and not outcome.weapons_changed, "%s: no events" % label)
	return outcome


## Checks that the request is applied and that only MOVE/SPLIT/DESTROY change what they say.
func _expect_applied(state: InventoryState, request: InventoryOps.Request, context: InventoryOps.Context,
		label: String) -> InventoryOps.Outcome:
	var before: InventoryState = state.duplicate_state()
	var outcome: InventoryOps.Outcome = InventoryOps.apply(state, request, context)
	assert_eq(outcome.result, InventoryOps.Result.OK, label)
	for position: Vector2i in before.occupied_slots() + state.occupied_slots():
		if not outcome.changed.has(position):
			var old: ItemInstance = before.get_item(position.x, position.y)
			var now: ItemInstance = state.get_item(position.x, position.y)
			assert_true(old != null and old.equals(now), "%s: %s was not in changed and it changed" % [label, position])
	return outcome


## Bag of 10: two health stacks (10 and 12), stamina, full health, a helmet and loose and bound ore;
## sword in WEAPON_1 and bow in WEAPON_2.
func _standard() -> InventoryState:
	var state := InventoryState.new(10)
	state.set_item(BAG, 0, _item(HEALTH_A, &"potion_health", 10))
	state.set_item(BAG, 1, _item(HEALTH_B, &"potion_health", 12))
	state.set_item(BAG, 2, _item(STAMINA, &"potion_stamina", 2))
	state.set_item(BAG, 3, _item(HEALTH_FULL, &"potion_health", 15))
	state.set_item(BAG, 4, _item(HELM, &"test_iron_helm", 1))
	state.set_item(BAG, 5, _item(ORE_LOOSE, &"test_ore", 7))
	var bound_ore: ItemInstance = _item(ORE_BOUND, &"test_ore", 5)
	bound_ore.bound = true
	state.set_item(BAG, 6, bound_ore)
	state.set_item(EQUIP, 0, _item(SWORD_UID, &"sword_shield_vado", 1))
	state.set_item(EQUIP, 1, _item(BOW_UID, &"bow_vado", 1))
	return state


func _item(uid: int, def_id: StringName, count: int) -> ItemInstance:
	return ItemInstance.create(uid, _db.get_definition(def_id), count)


func _req(op: int, from_container: int, from_slot: int, to_container: int, to_slot: int, count: int,
		expected_uid: int) -> InventoryOps.Request:
	return InventoryOps.make_request(op, from_container, from_slot, to_container, to_slot, count, expected_uid)


## Normal context (level 1, slot 1 active, out of combat) with ids from 5001.
func _context(db: ItemDatabase = null) -> InventoryOps.Context:
	var context := InventoryOps.Context.new()
	context.db = db if db != null else _db
	var ids: Dictionary = _ids
	context.new_uid = func() -> int:
		ids["next"] += 1
		ids["taken"] += 1
		return ids["next"]
	return context


func _counter_from(first: int) -> Callable:
	var counter: Dictionary = {"next": first}
	return func() -> int:
		counter["next"] += 1
		return counter["next"] - 1


## [container, slot, def_id, quantity, uid] of each occupied slot.
func _layout(state: InventoryState) -> Array:
	var result: Array = []
	for position: Vector2i in state.occupied_slots():
		var item: ItemInstance = state.get_item(position.x, position.y)
		result.append([position.x, position.y, item.def_id, item.count, item.uid])
	result.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	return result


## The objects from data/items, the armours of the cases and a stackable ore with no binding.
func _test_db() -> ItemDatabase:
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


## The sword and potions from data/items and a level 5 bow that becomes bound when equipped.
func _leveled_db() -> ItemDatabase:
	var shared: ItemDatabase = ItemDatabase.shared()
	var bow := ItemDefinition.new()
	bow.id = &"test_bow_level5"
	bow.display_name = "Arco de prueba"
	bow.category = ItemDefinition.Category.WEAPON
	bow.equip_slot = ItemDefinition.EquipSlot.WEAPON
	bow.ref_id = &"bow"
	bow.required_level = 5
	bow.bind_rule = ItemDefinition.BindRule.ON_EQUIP
	var definitions: Array[ItemDefinition] = [shared.get_definition(&"sword_shield_vado"),
			shared.get_definition(&"potion_health"), shared.get_definition(&"potion_stamina"), bow]
	var db: ItemDatabase = ItemDatabase.build_from_definitions(definitions)
	assert_eq(db.errors, PackedStringArray(), "the base with the level 5 bow has no errors")
	return db
