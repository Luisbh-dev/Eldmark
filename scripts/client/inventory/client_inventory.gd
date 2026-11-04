class_name ClientInventory
extends RefCounted
## The local player's inventory on the client (docs/progresion.md §11.3, UI-26): optimistic intent and its
## rollback. It keeps the [b]confirmed state[/b] (the latest the server said), the list of [b]pending
## requests[/b] (those sent without a response, at most [constant MAX_PENDING]) and a [b]view[/b], which is the
## confirmed state with the pending ones applied by [method InventoryOps.apply], the same function the server uses
## to decide: both validate identically.
## [br][br]
## [b]Flow.[/b]
## [br]1. [method request]: validated locally against the view with the character's [InventoryOps.Context]
## ([member context_provider]: level, active slot, "can touch equipment" and "drinking" from the predicted state).
## If it fails, [signal request_rejected] with the code's text and nothing is sent.
## [br]2. If valid, an INVENTORY_REQUEST goes out with the next [code]request_id[/code] ([member send_request]),
## is added to pending and the view changes instantly. The new stack from a SPLIT carries a provisional
## negative [code]uid[/code] (−[code]request_id[/code]) and cannot be touched until the delta brings the real one.
## [br]3. [method on_delta]: its entries are applied to the confirmed state in arrival order; if it answers a
## request, that one leaves pending. The view is rebuilt; a pending one that is no longer valid locally stops being applied
## (its response will arrive anyway).
## [br]4. A rejection brings the real contents of the slots: applied to the confirmed state, the item returns to its
## slot and [signal request_rejected] fires with the code's text.
## [br]5. [method tick]: with no response within [constant RESPONSE_TIMEOUT_MSEC] ms the pending ones are cleared and an
## INVENTORY_SYNC_REQUEST is made ([member send_sync]); the FULL rebuilds everything.
## [br][br]
## [b]Revision.[/b] An applied delta ([code]result[/code] 0) whose revision is not confirmed + 1 triggers a sync
## request. The pages of INVENTORY_FULL ([method on_full_page]) are gathered by revision
## ([method ProgressMessages.InventoryFull.assemble]) and only then replace the confirmed state. Sync requests
## go at most one every [constant SYNC_INTERVAL_MSEC] ms (more, and the server adds a warning).
## [br][br]
## [b]Not optimistic[/b] are the weapon in hand, the action bar and the charges: they change with the confirmed
## combat state (LOADOUT and the own state), one RTT later, so a rejection never makes the
## weapon flicker. This class does not touch the [CombatState].
## [br][br]
## [b]Gestures[/b] (§11.2): [method make_move], [method make_split], [method make_destroy] and [method equip_target]
## build the request for each gesture with the [code]uid[/code] seen at the source.
## [br][br]
## No network or nodes: [NetClient] feeds it and gives it a way to send; tests use their own functions. The clock
## arrives in [method tick]. Client only.

## The view changed (request sent, delta, full page, timeout expired).
signal view_changed
## The confirmed state changed (delta or FULL).
signal confirmed_changed
## A request was not sent (fails locally) or the server rejected it: [param text] is the notice in Spanish.
signal request_rejected(result: int, text: String)

## Maximum requests without a response: with this many in flight, the UI waits.
const MAX_PENDING: int = 8
## Timeout for a response (ms). On a reliable channel it should never expire.
const RESPONSE_TIMEOUT_MSEC: int = 5000
## Minimum time (ms) between two INVENTORY_SYNC_REQUESTs (docs/progresion.md §4.6).
const SYNC_INTERVAL_MSEC: int = 5000
## Highest [code]request_id[/code] (u16); after that it wraps back to 1 (0 means "server change").
const MAX_REQUEST_ID: int = 0xFFFF
## Inventory revision: a u32 that wraps around.
const REVISION_MASK: int = 0xFFFFFFFF


## A request sent without a response.
class Pending:
	var id: int = 0
	var request: InventoryOps.Request = null
	## Definition of the source item when it was sent (for the "Necesitas nivel N" (You need level N) of a rejection).
	var def_id: StringName = &""
	var sent_msec: int = 0
	## Still applied in the view (false: no longer valid locally and only its response is awaited).
	var active: bool = true


## [code](ProgressMessages.InventoryRequest) -> bool[/code]: sends the message; false if it could not be sent.
var send_request: Callable = Callable()
## [code]() -> bool[/code]: sends an INVENTORY_SYNC_REQUEST; false if it could not be sent.
var send_sync: Callable = Callable()
## [code]() -> InventoryOps.Context[/code]: the character's context now (without it, the default one: level 1,
## WEAPON_1 active and free to touch equipment). [member InventoryOps.Context.new_uid] is set by this class.
var context_provider: Callable = Callable()
## [code]() -> bool[/code]: whether the character is in combat (the NOT_NOW text changes).
var in_combat_provider: Callable = Callable()
## Definitions (null = [method ItemDatabase.shared]).
var db: ItemDatabase = null

var _confirmed: InventoryState = null
var _view: InventoryState = null
var _revision: int = 0
var _pending: Array[Pending] = []
var _next_request_id: int = 1
# Pages of the INVENTORY_FULL being gathered (by index) and its revision (−1 = none).
var _pages: Dictionary[int, ProgressMessages.InventoryFull] = {}
var _pages_revision: int = -1
var _now_msec: int = 0
var _sync_wanted: bool = false
var _awaiting_full: bool = false
var _last_sync_msec: int = -SYNC_INTERVAL_MSEC
# Counters for tests and debugging.
var _requests_sent: int = 0
var _local_rejections: int = 0
var _server_rejections: int = 0
var _syncs_sent: int = 0
var _timeouts: int = 0
var _revision_gaps: int = 0
var _deltas_ignored: int = 0


# --- Queries --------------------------------------------------------------------------------------

## true once the first complete INVENTORY_FULL arrives (before that there is no inventory to show).
func has_inventory() -> bool:
	return _confirmed != null


## The view: the confirmed state with the pending ones applied (null without an inventory). It must not be changed.
func get_view() -> InventoryState:
	return _view


## The latest the server said (null without an inventory). It must not be changed.
func get_confirmed() -> InventoryState:
	return _confirmed


## Revision of the confirmed state.
func get_revision() -> int:
	return _revision


## Requests sent without a response (including those no longer applied in the view).
func get_pending_count() -> int:
	return _pending.size()


## The [code]request_id[/code]s of the pending ones, in send order.
func get_pending_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for pending: Pending in _pending:
		ids.append(pending.id)
	return ids


## true while waiting for the INVENTORY_FULL of a sync (or one is wanted).
func is_syncing() -> bool:
	return _awaiting_full or _sync_wanted


## true if the instance [param item] is a locally created stack that does not yet have its real [code]uid[/code].
static func is_provisional(item: ItemInstance) -> bool:
	return item != null and item.uid < 0


## Counters: [code]requests_sent[/code], [code]local_rejections[/code], [code]server_rejections[/code],
## [code]syncs_sent[/code], [code]timeouts[/code], [code]revision_gaps[/code] and [code]deltas_ignored[/code]
## (before the first FULL).
func get_stats() -> Dictionary:
	return {
		"requests_sent": _requests_sent, "local_rejections": _local_rejections,
		"server_rejections": _server_rejections, "syncs_sent": _syncs_sent, "timeouts": _timeouts,
		"revision_gaps": _revision_gaps, "deltas_ignored": _deltas_ignored,
	}


## The character's context now, without ids (that of [member context_provider] or the default one).
func current_context() -> InventoryOps.Context:
	var context: InventoryOps.Context = null
	if context_provider.is_valid():
		context = context_provider.call() as InventoryOps.Context
	if context == null:
		context = InventoryOps.Context.new()
	context.db = _db()
	context.new_uid = Callable()
	return context


# --- Gestures -----------------------------------------------------------------------------------

## MOVE from [param from] to [param to] ([code](container, slot)[/code]) with the [code]uid[/code] seen at
## the source (0 if empty: the server would say STALE and here it is not sent).
func make_move(from: Vector2i, to: Vector2i) -> InventoryOps.Request:
	return InventoryOps.make_request(InventoryOps.Op.MOVE, from.x, from.y, to.x, to.y, 0, _uid_at(from))


## SPLIT of [param count] units from [param from] into the empty bag slot [param to].
func make_split(from: Vector2i, to: Vector2i, count: int) -> InventoryOps.Request:
	return InventoryOps.make_request(InventoryOps.Op.SPLIT, from.x, from.y, to.x, to.y, count, _uid_at(from))


## DESTROY of [param count] units from [param from] (0 = the whole stack).
func make_destroy(from: Vector2i, count: int = 0) -> InventoryOps.Request:
	return InventoryOps.make_request(InventoryOps.Op.DESTROY, from.x, from.y, InventoryOps.NO_SLOT,
			InventoryOps.NO_SLOT, count, _uid_at(from))


## Where the item at [param from] goes on a double click or right click (§11.2): from the bag, a weapon goes to
## WEAPON_2 if it is empty and otherwise to the weapon slot that is not active, and armor to its slot; from
## equipment, to the first free slot of the bag. [code](−1, −1)[/code] if there is nowhere to go (an item that is not
## equippable, the empty slot or a full bag).
func equip_target(from: Vector2i) -> Vector2i:
	var none := Vector2i(-1, -1)
	if _view == null:
		return none
	var item: ItemInstance = _view.get_item(from.x, from.y)
	if item == null:
		return none
	if from.x == InventoryState.ContainerId.EQUIPMENT:
		var free: int = _view.first_free(InventoryState.ContainerId.BAG)
		return Vector2i(InventoryState.ContainerId.BAG, free) if free >= 0 else none
	var definition: ItemDefinition = _db().get_definition(item.def_id)
	if definition == null or not definition.is_equipable():
		return none
	var equipment: int = InventoryState.ContainerId.EQUIPMENT
	if definition.equip_slot != ItemDefinition.EquipSlot.WEAPON:
		return Vector2i(equipment, int(definition.equip_slot))
	if _view.get_item(equipment, InventoryState.EquipmentSlot.WEAPON_2) == null:
		return Vector2i(equipment, InventoryState.EquipmentSlot.WEAPON_2)
	var active: int = clampi(current_context().active_weapon_slot, 0, 1)
	return Vector2i(equipment, 1 - active)


# --- Requests -------------------------------------------------------------------------------------

## Validates [param op] locally and, if valid, sends it and applies it to the view. Returns the local result
## ([enum InventoryOps.Result]; OK = sent). Without an inventory, NOT_NOW; with [constant MAX_PENDING] in flight,
## RATE; touching a provisional stack, NOT_NOW; if it cannot be sent, NOT_NOW. Everything that is not OK emits
## [signal request_rejected] with its text.
func request(op: InventoryOps.Request) -> int:
	if op == null or _view == null:
		return _reject_locally(InventoryOps.Result.NOT_NOW)
	if _pending.size() >= MAX_PENDING:
		return _reject_locally(InventoryOps.Result.RATE)
	if _touches_provisional(op):
		return _reject_locally(InventoryOps.Result.NOT_NOW)
	var id: int = _next_request_id
	var trial: InventoryState = _view.duplicate_state()
	var outcome: InventoryOps.Outcome = InventoryOps.apply(trial, op, _context_for(id))
	if not outcome.is_ok():
		return _reject_locally(outcome.result, outcome.required_level)
	var message: ProgressMessages.InventoryRequest = ProgressMessages.InventoryRequest.from_request(id, op)
	if not send_request.is_valid() or not bool(send_request.call(message)):
		return _reject_locally(InventoryOps.Result.NOT_NOW)
	_next_request_id = id + 1 if id < MAX_REQUEST_ID else 1
	var pending := Pending.new()
	pending.id = id
	pending.request = op
	var source: ItemInstance = _view.get_item(op.from_container, op.from_slot)
	pending.def_id = source.def_id if source != null else &""
	pending.sent_msec = _now_msec
	_pending.append(pending)
	_requests_sent += 1
	_view = trial
	view_changed.emit()
	return InventoryOps.Result.OK


## What [method request] would say about [param op] now, without sending anything, without changing the view and without notifying (so
## that a gesture with a dialog, such as splitting or destroying, does not open it if the request is not going to be valid).
func validate(op: InventoryOps.Request) -> int:
	if op == null or _view == null:
		return InventoryOps.Result.NOT_NOW
	if _pending.size() >= MAX_PENDING:
		return InventoryOps.Result.RATE
	if _touches_provisional(op):
		return InventoryOps.Result.NOT_NOW
	return InventoryOps.apply(_view.duplicate_state(), op, _context_for(_next_request_id)).result


## Notifies [param result] as a local rejection ([signal request_rejected] with its text) without sending anything: for
## a gesture that does not become a request (unequipping with a full bag). Returns [param result].
func notify_rejected(result: int) -> int:
	return _reject_locally(result)


## An INVENTORY_DELTA: its entries into the confirmed state (slots this client does not have are ignored), the
## revision, the pending request it answers and, if it is a rejection, the notice. Before the first FULL it does nothing
## (the FULL will bring everything).
func on_delta(delta: ProgressMessages.InventoryDelta) -> void:
	if delta == null:
		return
	if _confirmed == null:
		_deltas_ignored += 1
		return
	for entry: ProgressMessages.Entry in delta.entries:
		if _confirmed.has_slot(entry.container, entry.slot):
			_confirmed.set_item(entry.container, entry.slot, entry.item)
	if delta.result == InventoryOps.Result.OK:
		if delta.revision != (_revision + 1) & REVISION_MASK:
			_revision_gaps += 1
			_want_sync()
		_revision = delta.revision
	if delta.request_id != 0:
		var index: int = _pending_index(delta.request_id)
		var pending: Pending = _pending[index] if index >= 0 else null
		if index >= 0:
			_pending.remove_at(index)
		if delta.result != InventoryOps.Result.OK:
			_server_rejections += 1
			var level: int = _required_level_of(pending.def_id) if pending != null else 0
			request_rejected.emit(delta.result, _text(delta.result, level))
	confirmed_changed.emit()
	_rebuild_view()


## A page of INVENTORY_FULL. Gathers those of the same revision (one of another revision starts over) and,
## once complete, they replace the confirmed state; if they cannot be gathered, another sync is requested.
func on_full_page(page: ProgressMessages.InventoryFull) -> void:
	if page == null:
		return
	if page.revision != _pages_revision:
		_pages.clear()
		_pages_revision = page.revision
	_pages[page.page_index] = page
	if _pages.size() < page.page_count:
		return
	var pages: Array[ProgressMessages.InventoryFull] = []
	for index: int in _pages:
		pages.append(_pages[index])
	_pages.clear()
	_pages_revision = -1
	var state: InventoryState = ProgressMessages.InventoryFull.assemble(pages)
	if state == null:
		_want_sync()
		return
	_confirmed = state
	_revision = page.revision
	_awaiting_full = false
	_sync_wanted = false
	confirmed_changed.emit()
	_rebuild_view()


## Advances the clock to [param now_msec] (ms): expires the pending ones' timeouts and sends the sync that is waiting.
func tick(now_msec: int) -> void:
	_now_msec = now_msec
	if not _pending.is_empty() and now_msec - _pending[0].sent_msec >= RESPONSE_TIMEOUT_MSEC:
		_timeouts += 1
		_pending.clear()
		_want_sync()
		if _confirmed != null:
			_rebuild_view()
	if _awaiting_full and now_msec - _last_sync_msec >= RESPONSE_TIMEOUT_MSEC:
		# The FULL did not arrive: it is requested again.
		_sync_wanted = true
	_flush_sync()


## Forgets the inventory (end of the session).
func clear() -> void:
	_confirmed = null
	_view = null
	_revision = 0
	_pending.clear()
	_pages.clear()
	_pages_revision = -1
	_sync_wanted = false
	_awaiting_full = false
	view_changed.emit()


# --- Internal -------------------------------------------------------------------------------------

func _db() -> ItemDatabase:
	return db if db != null else ItemDatabase.shared()


func _uid_at(position: Vector2i) -> int:
	if _view == null:
		return 0
	var item: ItemInstance = _view.get_item(position.x, position.y)
	return item.uid if item != null else 0


# The context of request [param id]: the character's with the provisional ids −id.
func _context_for(id: int) -> InventoryOps.Context:
	var context: InventoryOps.Context = current_context()
	context.new_uid = func() -> int: return -id
	return context


func _touches_provisional(op: InventoryOps.Request) -> bool:
	if is_provisional(_view.get_item(op.from_container, op.from_slot)):
		return true
	return op.op != InventoryOps.Op.DESTROY and is_provisional(_view.get_item(op.to_container, op.to_slot))


func _reject_locally(result: int, required_level: int = 0) -> int:
	_local_rejections += 1
	request_rejected.emit(result, _text(result, required_level))
	return result


func _text(result: int, required_level: int) -> String:
	var in_combat: bool = in_combat_provider.is_valid() and bool(in_combat_provider.call())
	return InventoryOps.result_text(result, required_level, in_combat)


# Level that definition [param def_id] requires if the character does not reach it (for "Necesitas nivel N", You need level N); 0 if it does.
func _required_level_of(def_id: StringName) -> int:
	var definition: ItemDefinition = _db().get_definition(def_id) if def_id != &"" else null
	if definition == null:
		return 0
	return definition.required_level if definition.required_level > current_context().level else 0


func _pending_index(id: int) -> int:
	for index: int in range(_pending.size()):
		if _pending[index].id == id:
			return index
	return -1


# The view anew: the confirmed state with the pending ones that are still valid, in send order.
func _rebuild_view() -> void:
	var view: InventoryState = _confirmed.duplicate_state()
	for pending: Pending in _pending:
		if not pending.active:
			continue
		var outcome: InventoryOps.Outcome = InventoryOps.apply(view, pending.request, _context_for(pending.id))
		if not outcome.is_ok():
			pending.active = false
	_view = view
	view_changed.emit()


func _want_sync() -> void:
	_sync_wanted = true
	_flush_sync()


func _flush_sync() -> void:
	if not _sync_wanted or _now_msec - _last_sync_msec < SYNC_INTERVAL_MSEC:
		return
	if not send_sync.is_valid() or not bool(send_sync.call()):
		return
	_sync_wanted = false
	_awaiting_full = true
	_last_sync_msec = _now_msec
	_syncs_sent += 1
