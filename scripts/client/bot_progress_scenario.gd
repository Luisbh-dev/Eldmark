class_name BotProgressScenario
extends RefCounted
## El escenario [code]progress[/code] del bot ([code]--bot-scenario=progress[/code], docs/progresion.md §15 P8): lo
## que hace un jugador con su inventario y su cartera, por los mismos caminos que el cliente con ventana, para que
## las pruebas de extremo a extremo comparen después lo que el bot vio con lo que guardó la plataforma
## ([code]platform/e2e/progress_test.go[/code]). En orden:
## [br]1. [b]equip[/b]: se equipa el arco del kit ([code]bow_vado[/code]) desde la bolsa, con la misma petición que el
## doble clic de [InventoryWindow] ([method ClientInventory.equip_target]). Si ya lo lleva puesto, no hace nada.
## [br]2. [b]gold[/b]: se da [constant GOLD_AMOUNT] de oro con DEBUG_COMMAND 41 y espera su WALLET_UPDATE.
## [br]3. [b]potion[/b]: se da una poción de vida con DEBUG_COMMAND 40 y espera su INVENTORY_DELTA.
## [br]Con plataforma, los dos comandos piden [code]--debug-commands[/code] en la zona y una cuenta [code]admin[/code]
## (docs/progresion.md §10). Cada paso empieza [constant PAUSE_TICKS] ticks después de que acabe el anterior (así una
## prueba puede actuar entre dos pasos: la de la caída mata la zona tras el oro y antes de la poción) y falla si no se
## cumple en [member step_timeout_ticks]. Un equipo rechazado (en combate, con una acción) se reintenta cada
## [constant RETRY_TICKS] ticks, [constant MAX_TRIES] veces como mucho.
## [br][br]
## No mueve al bot: quien lo lleva lo deja quieto ([OnlineMain] pone el cerebro en reposo al empezar). Lo avanza
## [method step], una vez por tick de física; [signal phase_completed] sale al acabar cada paso (y con
## [code]done[/code] al acabar todos) y [method to_report] es la clave [code]scenario[/code] del informe. Solo cliente.

## Acabó el paso [param phase] ([code]equip[/code], [code]gold[/code], [code]potion[/code]) o todos ([code]done[/code]).
signal phase_completed(phase: String)

enum Step { WAITING, EQUIP, GOLD, POTION, DONE, FAILED }

const NAME: String = "progress"
const PHASE_NAMES: Dictionary[int, String] = {
	Step.EQUIP: "equip", Step.GOLD: "gold", Step.POTION: "potion", Step.DONE: "done",
}
const BOW: StringName = &"bow_vado"
const POTION: StringName = &"potion_health"
const GOLD_AMOUNT: int = 50
## Ticks entre el final de un paso y el principio del siguiente.
const PAUSE_TICKS: int = 60
## Ticks entre dos intentos de equipar.
const RETRY_TICKS: int = 30
const MAX_TRIES: int = 5
## Ticks que puede durar un paso (sin contar la pausa) antes de darlo por fallido.
const DEFAULT_STEP_TIMEOUT_TICKS: int = 600

## Ticks que puede durar un paso; las pruebas lo bajan.
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


## Avanza un tick. Empieza cuando el cliente está en el mundo con su inventario y sus saldos.
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


## true al acabar (bien o mal).
func is_finished() -> bool:
	return _step == Step.DONE or _step == Step.FAILED


func is_done() -> bool:
	return _step == Step.DONE


func is_failed() -> bool:
	return _step == Step.FAILED


## Por qué falló (vacío si no).
func get_error() -> String:
	return _error


## El último paso acabado ([code]equip[/code], [code]gold[/code], [code]potion[/code] o [code]done[/code]); vacío
## antes del primero.
func get_phase() -> String:
	return _completed[_completed.size() - 1] if not _completed.is_empty() else ""


## La clave [code]scenario[/code] del informe: [code]name[/code], [code]phase[/code] (el último paso acabado),
## [code]completed[/code], [code]error[/code] (vacío si no falló), [code]bow_slot[/code] ([code][contenedor,
## ranura][/code] del arco tras equiparlo), [code]already_equipped[/code], [code]gold_before[/code],
## [code]potions_before[/code] (de vida, antes de darla) y [code]rejections[/code] (los textos de los rechazos del
## servidor al equipar).
func to_report() -> Dictionary:
	return {
		"name": NAME, "phase": get_phase(), "completed": Array(_completed), "error": _error,
		"bow_slot": [_equipped_at.x, _equipped_at.y], "already_equipped": _already_equipped,
		"gold_before": _gold_before, "potions_before": _potions_before, "rejections": Array(_rejections),
	}


# --- Pasos ---------------------------------------------------------------------------------------

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


# Equipar el arco: la petición del doble clic y esperar a que el servidor la confirme.
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
	# Sin peticiones en vuelo y el arco aún en la bolsa: la anterior se rechazó (o se perdió en el plazo de 5 s de
	# ClientInventory) y se vuelve a pedir.
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
		# Rechazada en local (en combate, con una acción…): se reintenta.
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


# Un rechazo del servidor a la petición de equipar (los de en local llegan antes de enviarla y no cuentan).
func _on_request_rejected(_result: int, text: String) -> void:
	if not _awaiting_answer:
		return
	_awaiting_answer = false
	_rejections.append(text)
	_pause_left = RETRY_TICKS


# La primera ranura de [param def_id] en [param state] (la bolsa y después el equipo); (−1, −1) si no está.
static func _find(state: InventoryState, def_id: StringName) -> Vector2i:
	if state == null:
		return Vector2i(-1, -1)
	for container: int in [InventoryState.ContainerId.BAG, InventoryState.ContainerId.EQUIPMENT]:
		for slot: int in state.slot_count(container):
			var item: ItemInstance = state.get_item(container, slot)
			if item != null and item.def_id == def_id:
				return Vector2i(container, slot)
	return Vector2i(-1, -1)
