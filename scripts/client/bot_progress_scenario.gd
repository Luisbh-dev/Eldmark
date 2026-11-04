class_name BotProgressScenario
extends RefCounted
## The bot's [code]progress[/code] scenario ([code]--bot-scenario=progress[/code],
## docs/progresion.md §15 P8): what a player does with their inventory and wallet, through the same
## paths as the windowed client, so that end-to-end tests afterwards compare what the bot saw with
## what the platform saved ([code]platform/e2e/progress_test.go[/code]). In order:
## [br]1. [b]equip[/b]: the kit's bow ([code]bow_vado[/code]) is equipped from the bag, with the
## same request as the double click in [InventoryWindow] ([method ClientInventory.equip_target]).
## If it is already wearing it, it does nothing.
## [br]2. [b]gold[/b]: [constant GOLD_AMOUNT] gold is given with DEBUG_COMMAND 41 and it waits for its WALLET_UPDATE.
## [br]3. [b]potion[/b]: a health potion is given with DEBUG_COMMAND 40 and it waits for its INVENTORY_DELTA.
## [br]With the platform, the two commands require [code]--debug-commands[/code] on the zone and an
## [code]admin[/code] account (docs/progresion.md §10). Each step starts [constant PAUSE_TICKS]
## ticks after the previous one ends (so a test can act between two steps: the crash test kills
## the zone after the gold and before the potion) and fails if it is not completed within
## [member step_timeout_ticks]. A rejected equip (in combat, with an action) is retried every
## [constant RETRY_TICKS] ticks, [constant MAX_TRIES] times at most.
## [br][br]
## It does not move the bot: whoever drives it leaves it standing still ([OnlineMain] puts the
## brain at rest on startup). It is advanced by [method step], once per physics tick; [signal phase_completed] fires when each step ends (and with [code]done[/code] when all end) and
## [method to_report] is the report's [code]scenario[/code] key. Client only.

## Step [param phase] ([code]equip[/code], [code]gold[/code], [code]potion[/code]) or all
## ([code]done[/code]) finished.
signal phase_completed(phase: String)

enum Step { WAITING, EQUIP, GOLD, POTION, DONE, FAILED }

const NAME: String = "progress"
const PHASE_NAMES: Dictionary[int, String] = {
	Step.EQUIP: "equip", Step.GOLD: "gold", Step.POTION: "potion", Step.DONE: "done",
}
const BOW: StringName = &"bow_vado"
const POTION: StringName = &"potion_health"
const GOLD_AMOUNT: int = 50
## Ticks between the end of one step and the start of the next.
const PAUSE_TICKS: int = 60
## Ticks between two equip attempts.
const RETRY_TICKS: int = 30
const MAX_TRIES: int = 5
## Ticks a step may last (not counting the pause) before being declared failed.
const DEFAULT_STEP_TIMEOUT_TICKS: int = 600

## Ticks a step may last; tests lower it.
var step_timeout_ticks: int = DEFAULT_STEP_TIMEOUT_TICKS

var _client: NetClient = null
var _step: Step = Step.WAITING
var _ticks_in_step: int = 0
var _pause_left: int = 0
var _sent: bool = false
var _awaiting_answer: bool = false
var _tries: int = 0
var _gold_before: int = 0
var _potions_before: int = 0
var _completed: PackedStringArray = PackedStringArray()
var _equipped_at: Vector2i = Vector2i(-1, -1)
var _already_equipped: bool = false
var _rejections: PackedStringArray = PackedStringArray()
var _last_notice: String = ""
var _error: String = ""


func _init(client: NetClient) -> void:
	_client = client
	client.get_inventory().request_rejected.connect(_on_request_rejected)
	client.notice_received.connect(func(_code: int, text: String) -> void: _last_notice = text)


## Advances one tick. It starts when the client is in the world with its inventory and balances.
func step() -> void:
	if _step == Step.DONE or _step == Step.FAILED:
		return
	if _client == null or _client.get_state() != NetClient.State.IN_WORLD:
		if _step != Step.WAITING:
			_fail("la sesión se cerró a medias")
		return
	if _step == Step.WAITING:
		if _client.get_inventory().has_inventory() and _client.get_progress().has_wallet():
			_begin(Step.EQUIP, 0)
		return
	if _pause_left > 0:
		_pause_left -= 1
		return
	_ticks_in_step += 1
	if _ticks_in_step > step_timeout_ticks:
		_fail("el paso «%s» no se cumple en %d ticks%s" % [PHASE_NAMES[_step], step_timeout_ticks,
				" (último aviso del servidor: «%s»)" % _last_notice if not _last_notice.is_empty() else ""])
		return
	match _step:
		Step.EQUIP:
			_step_equip()
		Step.GOLD:
			_step_gold()
		Step.POTION:
			_step_potion()


## true when finished (successfully or not).
func is_finished() -> bool:
	return _step == Step.DONE or _step == Step.FAILED


func is_done() -> bool:
	return _step == Step.DONE


func is_failed() -> bool:
	return _step == Step.FAILED


## Why it failed (empty if it did not).
func get_error() -> String:
	return _error


## The last finished step ([code]equip[/code], [code]gold[/code], [code]potion[/code] or
## [code]done[/code]); empty before the first.
func get_phase() -> String:
	return _completed[_completed.size() - 1] if not _completed.is_empty() else ""


## The report's [code]scenario[/code] key: [code]name[/code], [code]phase[/code] (the last
## finished step), [code]completed[/code], [code]error[/code] (empty if it did not fail),
## [code]bow_slot[/code] ([code][contenedor,
## ranura][/code] of the bow after equipping it), [code]already_equipped[/code], [code]gold_before[/code],
## [code]potions_before[/code] (health ones, before giving it) and [code]rejections[/code] (the
## texts of the server's rejections on equipping).
func to_report() -> Dictionary:
	return {
		"name": NAME, "phase": get_phase(), "completed": Array(_completed), "error": _error,
		"bow_slot": [_equipped_at.x, _equipped_at.y], "already_equipped": _already_equipped,
		"gold_before": _gold_before, "potions_before": _potions_before, "rejections": Array(_rejections),
	}


# --- Steps ---------------------------------------------------------------------------------------

func _begin(next: Step, pause: int) -> void:
	_step = next
	_ticks_in_step = 0
	_pause_left = pause
	_sent = false
	_awaiting_answer = false
	_tries = 0


func _complete() -> void:
	var finished: Step = _step
	_completed.append(PHASE_NAMES[finished])
	match finished:
		Step.EQUIP:
			_begin(Step.GOLD, PAUSE_TICKS)
		Step.GOLD:
			_begin(Step.POTION, PAUSE_TICKS)
		_:
			_step = Step.DONE
	phase_completed.emit(PHASE_NAMES[finished])
	if _step == Step.DONE:
		_completed.append(PHASE_NAMES[Step.DONE])
		phase_completed.emit(PHASE_NAMES[Step.DONE])


func _fail(text: String) -> void:
	_error = text
	_step = Step.FAILED


# Equip the bow: the double-click request and wait for the server to confirm it.
func _step_equip() -> void:
	var inventory: ClientInventory = _client.get_inventory()
	if inventory.get_pending_count() > 0:
		return
	var at: Vector2i = _find(inventory.get_confirmed(), BOW)
	if at.x == InventoryState.ContainerId.EQUIPMENT:
		_already_equipped = _already_equipped or not _sent
		_equipped_at = at
		_complete()
		return
	if at.x < 0:
		_fail("no hay ningún %s en el inventario" % BOW)
		return
	# With no requests in flight and the bow still in the bag: the previous one was rejected (or lost
	# within ClientInventory's 5 s window) and it is requested again.
	_awaiting_answer = false
	if _tries >= MAX_TRIES:
		_fail("no se pudo equipar el arco tras %d intentos (%s)" % [_tries, ", ".join(_rejections)])
		return
	var target: Vector2i = inventory.equip_target(at)
	if target.x < 0:
		_fail("el arco no tiene a dónde ir")
		return
	_tries += 1
	if inventory.request(inventory.make_move(at, target)) == InventoryOps.Result.OK:
		_sent = true
		_awaiting_answer = true
	else:
		# Rejected locally (in combat, with an action…): it is retried.
		_pause_left = RETRY_TICKS


func _step_gold() -> void:
	var balance: int = _client.get_progress().get_balance(Currency.Code.GOLD)
	if not _sent:
		_gold_before = balance
		_client.send_debug_command(NetProtocol.DEBUG_CURRENCY_ADD,
				NetMessages.DebugCommand.currency_add(Currency.Code.GOLD, GOLD_AMOUNT).payload)
		_sent = true
		return
	if balance == _gold_before + GOLD_AMOUNT:
		_complete()


func _step_potion() -> void:
	var inventory: ClientInventory = _client.get_inventory()
	if not _sent:
		_potions_before = inventory.get_confirmed().count_of(POTION)
		_client.send_debug_command(NetProtocol.DEBUG_ITEM_GIVE,
				NetMessages.DebugCommand.item_give(ItemDatabase.shared().net_id_of(POTION), 1).payload)
		_sent = true
		return
	if inventory.get_pending_count() == 0 and inventory.get_confirmed().count_of(POTION) == _potions_before + 1:
		_complete()


# A server rejection of the equip request (local ones arrive before it is sent and do not count).
func _on_request_rejected(_result: int, text: String) -> void:
	if not _awaiting_answer:
		return
	_awaiting_answer = false
	_rejections.append(text)
	_pause_left = RETRY_TICKS


# The first slot of [param def_id] in [param state] (the bag and then the equipment); (−1, −1) if it is not there.
static func _find(state: InventoryState, def_id: StringName) -> Vector2i:
	if state == null:
		return Vector2i(-1, -1)
	for container: int in [InventoryState.ContainerId.BAG, InventoryState.ContainerId.EQUIPMENT]:
		for slot: int in state.slot_count(container):
			var item: ItemInstance = state.get_item(container, slot)
			if item != null and item.def_id == def_id:
				return Vector2i(container, slot)
	return Vector2i(-1, -1)
