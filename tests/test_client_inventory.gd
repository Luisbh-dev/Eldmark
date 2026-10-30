extends TestCase
## El inventario del cliente (docs/progresion.md §11.3 y §15, P6; UI-26): [ClientInventory] con un servidor de
## mentira que aplica las peticiones con la misma [method InventoryOps.apply] y responde con mensajes de verdad
## (codificados y decodificados). Lo optimista, la confirmación, el rechazo que devuelve el objeto a su casilla, los
## cambios del servidor intercalados con peticiones en vuelo, la pila provisional de un SPLIT, el plazo de 5 s, los
## huecos de revisión, el tope de 8 pendientes, los gestos y, con un recorrido al azar, que lo que el cliente da por
## bueno en local el servidor nunca lo rechaza. Además, el [ClientProgress] y el cableado en [NetClient].

const SEED: int = 20261030


## Un servidor de mentira: un [InventoryState] autoritativo, su revisión y los ids. Aplica cada petición con su
## contexto y devuelve el delta, ya pasado por el cable.
class FakeServer:
	var state: InventoryState = InventoryState.new()
	var revision: int = 1
	var context: InventoryOps.Context = InventoryOps.Context.new()
	var next_id: int = 5000

	func _init() -> void:
		context.new_uid = func() -> int:
			next_id += 1
			return next_id

	## La respuesta a [param message] (aplicada o rechazada), por el cable.
	func answer(message: ProgressMessages.InventoryRequest) -> ProgressMessages.InventoryDelta:
		var request: ProgressMessages.InventoryRequest = ProgressMessages.InventoryRequest.decode(message.encode())
		var outcome: InventoryOps.Outcome = InventoryOps.apply(state, request.to_request(), context)
		if outcome.is_ok():
			revision += 1
		return _wire(ProgressMessages.InventoryDelta.for_slots(revision, request.request_id, outcome.result, 0, state,
				outcome.changed))

	## Un cambio que decide el servidor (CAMP_REFILL, CONSUME...) con el motivo [param reason].
	func change(outcome: InventoryOps.Outcome, reason: int) -> ProgressMessages.InventoryDelta:
		revision += 1
		return _wire(ProgressMessages.InventoryDelta.for_slots(revision, 0, InventoryOps.Result.OK, reason, state,
				outcome.changed))

	## Las páginas del INVENTORY_FULL, por el cable.
	func full() -> Array[ProgressMessages.InventoryFull]:
		var pages: Array[ProgressMessages.InventoryFull] = []
		for page: ProgressMessages.InventoryFull in ProgressMessages.InventoryFull.split(revision, state):
			pages.append(ProgressMessages.InventoryFull.decode(page.encode()))
		return pages

	static func _wire(delta: ProgressMessages.InventoryDelta) -> ProgressMessages.InventoryDelta:
		return ProgressMessages.InventoryDelta.decode(delta.encode())


var _db: ItemDatabase
var _server: FakeServer
var _client: ClientInventory
var _sent: Array[ProgressMessages.InventoryRequest] = []
var _syncs: int = 0
var _rejections: Array[Array] = []
var _views: int = 0
var _confirmations: int = 0
var _client_context: InventoryOps.Context
var _in_combat: bool = false
var _send_ok: bool = true


func before_each() -> void:
	_db = ItemDatabase.shared()
	_server = FakeServer.new()
	_sent.clear()
	_rejections.clear()
	_syncs = 0
	_views = 0
	_confirmations = 0
	_in_combat = false
	_send_ok = true
	_client_context = InventoryOps.Context.new()
	_client = ClientInventory.new()
	_client.send_request = func(message: ProgressMessages.InventoryRequest) -> bool:
		if _send_ok:
			_sent.append(message)
		return _send_ok
	_client.send_sync = func() -> bool:
		_syncs += 1
		return true
	_client.context_provider = func() -> InventoryOps.Context:
		var copy := InventoryOps.Context.new()
		copy.level = _client_context.level
		copy.active_weapon_slot = _client_context.active_weapon_slot
		copy.can_touch_equipment = _client_context.can_touch_equipment
		copy.drinking = _client_context.drinking
		return copy
	_client.in_combat_provider = func() -> bool: return _in_combat
	_client.request_rejected.connect(func(result: int, text: String) -> void: _rejections.append([result, text]))
	_client.view_changed.connect(func() -> void: _views += 1)
	_client.confirmed_changed.connect(func() -> void: _confirmations += 1)


func after_each() -> void:
	# Las funciones de prueba capturan esta prueba y el servidor se captura a sí mismo: sin cortar los ciclos, las
	# referencias no se liberan nunca.
	_client.send_request = Callable()
	_client.send_sync = Callable()
	_client.context_provider = Callable()
	_client.in_combat_provider = Callable()
	for connection: Dictionary in _client.request_rejected.get_connections():
		_client.request_rejected.disconnect(connection["callable"])
	for connection: Dictionary in _client.view_changed.get_connections():
		_client.view_changed.disconnect(connection["callable"])
	for connection: Dictionary in _client.confirmed_changed.get_connections():
		_client.confirmed_changed.disconnect(connection["callable"])
	_server.context.new_uid = Callable()
	_client = null
	_server = null


# El kit del escudero (espada en WEAPON_1; arco, pociones de vida y de resistencia en la bolsa) en el servidor.
func _give_squire_kit() -> void:
	var ids: Array[int] = [100]
	var events: Array[ItemEvent] = StarterKit.grant(_server.state, &"squire", _db, func() -> int:
		ids[0] += 1
		return ids[0])
	assert_false(events.is_empty(), "el kit del escudero se coloca")


func _deliver_full() -> void:
	for page: ProgressMessages.InventoryFull in _server.full():
		_client.on_full_page(page)


func _bag(slot: int) -> Vector2i:
	return Vector2i(InventoryState.ContainerId.BAG, slot)


func _equipment(slot: int) -> Vector2i:
	return Vector2i(InventoryState.ContainerId.EQUIPMENT, slot)


func _slot_of(state: InventoryState, def_id: StringName) -> Vector2i:
	for position: Vector2i in state.occupied_slots():
		if state.get_item(position.x, position.y).def_id == def_id:
			return position
	return Vector2i(-1, -1)


func _answer_all() -> void:
	var pending: Array[ProgressMessages.InventoryRequest] = _sent.duplicate()
	_sent.clear()
	for message: ProgressMessages.InventoryRequest in pending:
		_client.on_delta(_server.answer(message))


# --- Pruebas ------------------------------------------------------------------------------------

func test_nothing_before_the_first_full_and_the_pages_are_joined() -> void:
	assert_false(_client.has_inventory())
	assert_eq(_client.request(InventoryOps.make_request(InventoryOps.Op.MOVE, 0, 0, 0, 1, 0, 1)),
			InventoryOps.Result.NOT_NOW, "sin inventario no se pide nada")
	assert_eq(_rejections.size(), 1, "con su aviso")
	assert_eq(_rejections[0][1], "Ahora no puedes hacerlo")
	assert_true(_sent.is_empty())
	_client.on_delta(_server.change(InventoryOps.Outcome.new(), EconomyReason.CAMP_REFILL))
	assert_eq(_client.get_stats()["deltas_ignored"], 1, "un delta antes del FULL se ignora (el FULL lo trae todo)")
	# Más de 30 objetos: dos páginas. Llegan al revés y con una de otra revisión en medio.
	for slot: int in range(30):
		var potion: ItemDefinition = _db.get_definition(&"potion_health")
		_server.state.set_item(InventoryState.ContainerId.BAG, slot, ItemInstance.create(1000 + slot, potion, 1 + slot % 15))
	_server.state.set_item(InventoryState.ContainerId.EQUIPMENT, 0,
			ItemInstance.create(2000, _db.get_definition(&"sword_shield_vado"), 1))
	_server.state.set_item(InventoryState.ContainerId.EQUIPMENT, 1,
			ItemInstance.create(2001, _db.get_definition(&"bow_vado"), 1))
	var pages: Array[ProgressMessages.InventoryFull] = _server.full()
	assert_eq(pages.size(), 2, "32 objetos son dos páginas")
	var stale: ProgressMessages.InventoryFull = pages[0]
	var old_revision: int = _server.revision
	_server.revision += 3
	pages = _server.full()
	_client.on_full_page(stale)
	assert_false(_client.has_inventory(), "una página sola no basta")
	_client.on_full_page(pages[1])
	assert_false(_client.has_inventory(), "una de otra revisión no se junta con la anterior")
	_client.on_full_page(pages[0])
	assert_true(_client.has_inventory(), "con las dos de la misma revisión, sí")
	assert_true(_client.get_confirmed().equals(_server.state), "el confirmado es el del servidor")
	assert_true(_client.get_view().equals(_server.state), "y la vista también")
	assert_eq(_client.get_revision(), old_revision + 3)
	assert_eq(_syncs, 0, "nada que sincronizar")


func test_a_move_is_optimistic_and_then_confirmed() -> void:
	_give_squire_kit()
	_deliver_full()
	var bow: Vector2i = _slot_of(_server.state, &"bow_vado")
	var free: int = _server.state.first_free(InventoryState.ContainerId.BAG)
	var uid: int = _server.state.get_item(bow.x, bow.y).uid
	_views = 0
	assert_eq(_client.request(_client.make_move(bow, _bag(free))), InventoryOps.Result.OK, "se envía")
	assert_eq(_sent.size(), 1)
	var message: ProgressMessages.InventoryRequest = _sent[0]
	assert_eq([message.request_id, message.op, message.from_container, message.from_slot, message.to_container,
			message.to_slot, message.count, message.expected_uid],
			[1, InventoryOps.Op.MOVE, bow.x, bow.y, 0, free, 0, uid], "la petición con el uid que se ve")
	assert_eq(_views, 1, "la vista cambia al instante")
	assert_eq(_client.get_view().get_item(0, free).uid, uid, "el arco ya está en su sitio nuevo en la vista")
	assert_eq(_client.get_confirmed().get_item(bow.x, bow.y).uid, uid, "pero no en el confirmado")
	assert_eq(_client.get_pending_count(), 1)
	_answer_all()
	assert_eq(_client.get_pending_count(), 0, "la respuesta la saca de pendientes")
	assert_true(_client.get_confirmed().equals(_server.state), "el confirmado es el del servidor")
	assert_true(_client.get_view().equals(_client.get_confirmed()), "y la vista coincide")
	assert_eq(_client.get_revision(), _server.revision)
	assert_true(_rejections.is_empty(), "sin avisos")
	assert_eq(_syncs, 0)


func test_a_rejection_puts_the_item_back_with_its_text() -> void:
	_give_squire_kit()
	_deliver_full()
	var bow: Vector2i = _slot_of(_server.state, &"bow_vado")
	var bow_uid: int = _server.state.get_item(bow.x, bow.y).uid
	# El cliente cree que está fuera de combate; el servidor sabe que no: equipar el arco da NOT_NOW.
	_server.context.can_touch_equipment = false
	_in_combat = true
	assert_eq(_client.request(_client.make_move(bow, _equipment(1))), InventoryOps.Result.OK)
	assert_eq(_client.get_view().get_item(1, 1).uid, bow_uid, "optimista: el arco ya parece equipado")
	var revision: int = _client.get_revision()
	_answer_all()
	assert_eq(_rejections.size(), 1, "un aviso")
	assert_eq(_rejections[0], [InventoryOps.Result.NOT_NOW, "No puedes cambiar el equipo en combate"])
	assert_eq(_client.get_view().get_item(bow.x, bow.y).uid, bow_uid, "el arco vuelve a su casilla")
	assert_null(_client.get_view().get_item(1, 1), "y la ranura de arma se queda vacía")
	assert_true(_client.get_view().equals(_server.state))
	assert_eq(_client.get_revision(), revision, "un rechazo no sube la revisión")
	assert_eq(_syncs, 0, "ni pide sincronía")
	# «Necesitas nivel N»: un arma que pide más nivel, en local (el servidor diría lo mismo).
	_server.context.can_touch_equipment = true
	_in_combat = false
	var strong := ItemDefinition.new()
	strong.id = &"test_level_bow"
	strong.display_name = "Arco de prueba"
	strong.category = ItemDefinition.Category.WEAPON
	strong.equip_slot = ItemDefinition.EquipSlot.WEAPON
	strong.ref_id = &"bow"
	strong.required_level = 12
	var db: ItemDatabase = ItemDatabase.build_from_definitions([strong] as Array[ItemDefinition],
			CombatCatalog.tables())
	var client := ClientInventory.new()
	client.db = db
	var texts: Array[String] = []
	client.request_rejected.connect(func(_result: int, text: String) -> void: texts.append(text))
	var state := InventoryState.new()
	state.set_item(0, 0, ItemInstance.create(7, strong, 1))
	var page: ProgressMessages.InventoryFull = ProgressMessages.InventoryFull.split(1, state)[0]
	client.on_full_page(page)
	assert_eq(client.request(client.make_move(Vector2i(0, 0), Vector2i(1, 1))), InventoryOps.Result.CANNOT_EQUIP)
	assert_eq(texts, ["Necesitas nivel 12"] as Array[String])


func test_server_changes_interleave_with_requests_in_flight() -> void:
	_give_squire_kit()
	_deliver_full()
	var bow: Vector2i = _slot_of(_server.state, &"bow_vado")
	var potion: Vector2i = _slot_of(_server.state, &"potion_health")
	var bow_uid: int = _server.state.get_item(bow.x, bow.y).uid
	var target: int = InventoryState.BAG_SLOTS_DEFAULT - 1
	assert_eq(_client.request(_client.make_move(bow, _bag(target))), InventoryOps.Result.OK)
	# Antes de atender la petición, el servidor bebe una poción (CONSUME): un cambio suyo con request_id 0.
	var consumed: InventoryOps.Outcome = InventoryOps.remove_items(_server.state, &"potion_health", 1,
			EconomyReason.CONSUME)
	assert_true(consumed.is_ok())
	_client.on_delta(_server.change(consumed, EconomyReason.CONSUME))
	assert_eq(_client.get_confirmed().count_of(&"potion_health"), _server.state.count_of(&"potion_health"),
			"el confirmado ya tiene la poción de menos")
	assert_eq(_client.get_view().get_item(0, target).uid, bow_uid, "y la vista sigue con el arco movido")
	assert_eq(_client.get_view().get_item(potion.x, potion.y).count,
			_server.state.get_item(potion.x, potion.y).count, "con la pila de pociones al día")
	assert_eq(_client.get_pending_count(), 1, "la petición sigue en vuelo")
	_answer_all()
	assert_true(_client.get_view().equals(_server.state), "al final, lo mismo que el servidor")
	assert_eq(_syncs, 0, "las revisiones van seguidas")
	# Una pendiente que deja de valer en local por un cambio del servidor sale de la vista y su rechazo llega igual.
	var health: Vector2i = _slot_of(_server.state, &"potion_health")
	var health_uid: int = _server.state.get_item(health.x, health.y).uid
	var free: int = _server.state.first_free(InventoryState.ContainerId.BAG)
	assert_eq(_client.request(_client.make_move(health, _bag(free))), InventoryOps.Result.OK)
	var all: int = _server.state.count_of(&"potion_health")
	var drunk: InventoryOps.Outcome = InventoryOps.remove_items(_server.state, &"potion_health", all,
			EconomyReason.CONSUME)
	_client.on_delta(_server.change(drunk, EconomyReason.CONSUME))
	assert_null(_client.get_view().get_item(0, free), "la pila ya no existe: la vista no la mueve")
	assert_eq(_client.get_view().find_uid(health_uid), Vector2i(-1, -1))
	_answer_all()
	assert_eq(_rejections.size(), 1, "el servidor la rechaza")
	assert_eq(_rejections[0], [InventoryOps.Result.STALE, "Ese objeto ya no está ahí"])
	assert_true(_client.get_view().equals(_server.state))
	assert_eq(_client.get_pending_count(), 0)


func test_a_split_has_a_provisional_uid_until_the_delta() -> void:
	_give_squire_kit()
	_deliver_full()
	var stack: Vector2i = _slot_of(_server.state, &"potion_stamina")
	var original: ItemInstance = _server.state.get_item(stack.x, stack.y)
	assert_true(original.count >= 2, "una pila que se puede dividir")
	var free: int = _server.state.first_free(InventoryState.ContainerId.BAG)
	assert_eq(_client.request(_client.make_split(stack, _bag(free), 1)), InventoryOps.Result.OK)
	var provisional: ItemInstance = _client.get_view().get_item(0, free)
	assert_eq(provisional.uid, -1, "la pila nueva lleva −request_id")
	assert_true(ClientInventory.is_provisional(provisional))
	assert_eq(_client.get_view().get_item(stack.x, stack.y).count, original.count - 1)
	# No se toca hasta que llegue el uid real: ni de origen ni de destino.
	var other: int = InventoryState.BAG_SLOTS_DEFAULT - 1
	assert_eq(_client.request(_client.make_move(_bag(free), _bag(other))), InventoryOps.Result.NOT_NOW)
	assert_eq(_client.request(_client.make_move(stack, _bag(free))), InventoryOps.Result.NOT_NOW)
	assert_eq(_client.validate(_client.make_move(_bag(free), _bag(other))), InventoryOps.Result.NOT_NOW)
	assert_eq(_sent.size(), 1, "solo salió el SPLIT")
	_answer_all()
	var real: ItemInstance = _client.get_view().get_item(0, free)
	assert_true(real.uid > 0, "el delta trae el uid real (%d)" % real.uid)
	assert_eq(real.uid, _server.state.get_item(0, free).uid)
	assert_eq(_client.request(_client.make_move(_bag(free), _bag(other))), InventoryOps.Result.OK, "ya se puede mover")
	_answer_all()
	assert_true(_client.get_view().equals(_server.state))
	# DESTROY también toma un id provisional (el op_id de su operación), sin tocar la vista con él.
	assert_eq(_client.request(_client.make_destroy(_bag(other), 1)), InventoryOps.Result.OK)
	assert_null(_client.get_view().get_item(0, other), "la pila de una destruida desaparece")
	_answer_all()
	assert_true(_client.get_view().equals(_server.state))


func test_no_answer_in_five_seconds_clears_the_pending_and_resyncs() -> void:
	_give_squire_kit()
	_deliver_full()
	_client.tick(10_000)
	var bow: Vector2i = _slot_of(_server.state, &"bow_vado")
	assert_eq(_client.request(_client.make_move(bow, _bag(InventoryState.BAG_SLOTS_DEFAULT - 1))),
			InventoryOps.Result.OK)
	_client.tick(10_000 + ClientInventory.RESPONSE_TIMEOUT_MSEC - 1)
	assert_eq(_client.get_pending_count(), 1, "antes del plazo sigue pendiente")
	assert_eq(_syncs, 0)
	_client.tick(10_000 + ClientInventory.RESPONSE_TIMEOUT_MSEC)
	assert_eq(_client.get_pending_count(), 0, "a los 5 s se vacían las pendientes")
	assert_eq(_syncs, 1, "y se pide sincronía")
	assert_true(_client.get_view().equals(_client.get_confirmed()), "la vista vuelve al confirmado")
	assert_true(_client.is_syncing())
	_client.tick(10_000 + ClientInventory.RESPONSE_TIMEOUT_MSEC + 100)
	assert_eq(_syncs, 1, "no se repite enseguida")
	# La respuesta tardía se aplica al confirmado (sin aviso: ya no se esperaba) y el FULL lo rehace todo.
	_answer_all()
	assert_true(_client.get_confirmed().equals(_server.state))
	_deliver_full()
	assert_false(_client.is_syncing(), "el FULL cierra la sincronía")
	assert_true(_client.get_view().equals(_server.state))
	assert_eq(_client.get_stats()["timeouts"], 1)
	# Si el FULL no llega, a los 5 s se vuelve a pedir.
	_client.tick(30_000)
	_client.on_delta(ProgressMessages.InventoryDelta.for_slots(_server.revision + 5, 0, InventoryOps.Result.OK,
			EconomyReason.CAMP_REFILL, _server.state, [] as Array[Vector2i]))
	assert_eq(_syncs, 2, "un hueco en la revisión pide sincronía")
	_client.tick(30_000 + ClientInventory.SYNC_INTERVAL_MSEC - 1)
	assert_eq(_syncs, 2)
	_client.tick(30_000 + ClientInventory.SYNC_INTERVAL_MSEC)
	assert_eq(_syncs, 3, "sin FULL, se pide otra vez pasado el plazo")


func test_revision_gaps_ask_for_a_sync_at_most_every_five_seconds() -> void:
	_give_squire_kit()
	_deliver_full()
	_client.tick(1_000)
	var revision: int = _client.get_revision()
	var empty: Array[Vector2i] = []
	_client.on_delta(ProgressMessages.InventoryDelta.for_slots(revision + 1, 0, InventoryOps.Result.OK,
			EconomyReason.CAMP_REFILL, _server.state, empty))
	assert_eq(_syncs, 0, "la siguiente revisión no pide nada")
	_client.on_delta(ProgressMessages.InventoryDelta.for_slots(revision + 3, 0, InventoryOps.Result.OK,
			EconomyReason.CAMP_REFILL, _server.state, empty))
	assert_eq(_syncs, 1, "saltarse una pide sincronía")
	assert_eq(_client.get_revision(), revision + 3)
	_client.on_delta(ProgressMessages.InventoryDelta.for_slots(revision + 9, 0, InventoryOps.Result.OK,
			EconomyReason.CAMP_REFILL, _server.state, empty))
	assert_eq(_syncs, 1, "otro hueco antes de 5 s no repite la petición")
	_deliver_full()
	_client.tick(1_000 + ClientInventory.SYNC_INTERVAL_MSEC)
	assert_eq(_syncs, 1, "el FULL la satisfizo")
	assert_eq(_client.get_stats()["revision_gaps"], 2)
	# La revisión da la vuelta en u32 sin pedir nada.
	_client._revision = ClientInventory.REVISION_MASK
	_client.on_delta(ProgressMessages.InventoryDelta.for_slots(0, 0, InventoryOps.Result.OK,
			EconomyReason.CAMP_REFILL, _server.state, empty))
	assert_eq(_syncs, 1, "de 2^32 − 1 a 0 va seguida")


func test_eight_requests_in_flight_at_most() -> void:
	_give_squire_kit()
	_deliver_full()
	var bow: Vector2i = _slot_of(_server.state, &"bow_vado")
	var from: Vector2i = bow
	for i: int in range(ClientInventory.MAX_PENDING):
		var to: Vector2i = _bag(InventoryState.BAG_SLOTS_DEFAULT - 1 - i)
		assert_eq(_client.request(_client.make_move(from, to)), InventoryOps.Result.OK, "petición %d" % i)
		from = to
	assert_eq(_client.request(_client.make_move(from, _bag(20))), InventoryOps.Result.RATE, "la novena espera")
	assert_eq(_rejections.back(), [InventoryOps.Result.RATE, "Más despacio"])
	assert_eq(_sent.size(), ClientInventory.MAX_PENDING)
	assert_eq(_client.get_pending_ids(), PackedInt32Array([1, 2, 3, 4, 5, 6, 7, 8]), "ids seguidos")
	_answer_all()
	assert_true(_client.get_view().equals(_server.state), "las ocho, en orden, dejan lo mismo que el servidor")
	assert_eq(_client.request(_client.make_move(from, _bag(20))), InventoryOps.Result.OK, "con hueco, sale")
	# Si no se puede enviar, nada cambia.
	_send_ok = false
	var before: InventoryState = _client.get_view().duplicate_state()
	assert_eq(_client.request(_client.make_move(_bag(20), _bag(21))), InventoryOps.Result.NOT_NOW)
	assert_true(_client.get_view().equals(before), "sin enviar no hay vista optimista")
	# Los ids saltan el 0 al dar la vuelta.
	_client._next_request_id = ClientInventory.MAX_REQUEST_ID
	_send_ok = true
	_answer_all()
	assert_eq(_client.request(_client.make_move(_bag(20), _bag(22))), InventoryOps.Result.OK)
	assert_eq(_sent.back().request_id, ClientInventory.MAX_REQUEST_ID)
	_answer_all()
	assert_eq(_client.request(_client.make_move(_bag(22), _bag(23))), InventoryOps.Result.OK)
	assert_eq(_sent.back().request_id, 1, "después de 65535, el 1")


func test_what_the_client_accepts_locally_the_server_never_rejects() -> void:
	_give_squire_kit()
	_deliver_full()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var sent: int = 0
	var refused: int = 0
	for step: int in range(600):
		var view: InventoryState = _client.get_view()
		var occupied: Array[Vector2i] = view.occupied_slots()
		var from: Vector2i = occupied[rng.randi_range(0, occupied.size() - 1)]
		var to := Vector2i(rng.randi_range(0, 1), 0)
		to.y = rng.randi_range(0, view.slot_count(to.x) - 1)
		var op: InventoryOps.Request
		match rng.randi_range(0, 9):
			0:
				op = _client.make_split(from, to, rng.randi_range(0, 4))
			1:
				op = _client.make_destroy(from, rng.randi_range(0, 2))
			_:
				op = _client.make_move(from, to)
		# A veces el contexto cambia en los dos lados a la vez (combate, la otra arma activa), sin nada en vuelo: con
		# peticiones en vuelo, el servidor las mira con el contexto nuevo y puede rechazarlas (eso lo prueba
		# test_a_rejection_puts_the_item_back_with_its_text).
		if rng.randf() < 0.1:
			_answer_all()
			if rng.randf() < 0.5:
				_client_context.can_touch_equipment = not _client_context.can_touch_equipment
				_server.context.can_touch_equipment = _client_context.can_touch_equipment
			else:
				_client_context.active_weapon_slot = 1 - _client_context.active_weapon_slot
				_server.context.active_weapon_slot = _client_context.active_weapon_slot
		if _client.request(op) == InventoryOps.Result.OK:
			sent += 1
		else:
			refused += 1
		# Las respuestas llegan en lotes al azar.
		if rng.randf() < 0.4 or _client.get_pending_count() >= ClientInventory.MAX_PENDING:
			_answer_all()
	_answer_all()
	assert_true(sent > 50 and refused > 50, "se envían (%d) y se rechazan en local (%d) muchas" % [sent, refused])
	var server_rejections: int = _client.get_stats()["server_rejections"]
	assert_eq(server_rejections, 0, "el servidor nunca rechaza lo que el cliente dio por bueno")
	assert_true(_client.get_view().equals(_server.state), "al final, la vista es la del servidor")
	assert_true(_client.get_confirmed().equals(_server.state))
	assert_eq(_syncs, 0, "sin huecos de revisión")


func test_gesture_targets() -> void:
	_give_squire_kit()
	_deliver_full()
	var bow: Vector2i = _slot_of(_server.state, &"bow_vado")
	var potion: Vector2i = _slot_of(_server.state, &"potion_health")
	assert_eq(_client.equip_target(bow), _equipment(1), "un arma va a WEAPON_2 si está vacía")
	assert_eq(_client.equip_target(potion), Vector2i(-1, -1), "una poción no se equipa")
	assert_eq(_client.equip_target(_bag(29)), Vector2i(-1, -1), "una casilla vacía tampoco")
	assert_eq(_client.equip_target(_equipment(0)), _bag(_server.state.first_free(0)),
			"desequipar va a la primera libre de la bolsa")
	_client.request(_client.make_move(bow, _equipment(1)))
	_answer_all()
	# Con las dos llenas, a la que no está activa.
	_server.state.set_item(0, 0, ItemInstance.create(900, _db.get_definition(&"bow_vado"), 1))
	_deliver_full()
	assert_eq(_client.equip_target(_bag(0)), _equipment(1), "con WEAPON_1 activa, a WEAPON_2")
	_client_context.active_weapon_slot = 1
	assert_eq(_client.equip_target(_bag(0)), _equipment(0), "con WEAPON_2 activa, a WEAPON_1")
	# Una armadura (de las pruebas), a su ranura (que en la fase 5 da CANNOT_EQUIP).
	var helm: ItemDefinition = load("res://tests/fixtures/items/armor/test_iron_helm.tres") as ItemDefinition
	var db: ItemDatabase = ItemDatabase.build_from_definitions([helm] as Array[ItemDefinition],
			CombatCatalog.tables())
	var client := ClientInventory.new()
	client.db = db
	var state := InventoryState.new()
	state.set_item(0, 3, ItemInstance.create(5, helm, 1))
	client.on_full_page(ProgressMessages.InventoryFull.split(1, state)[0])
	assert_eq(client.equip_target(_bag(3)), _equipment(InventoryState.EquipmentSlot.HEAD))
	assert_eq(client.request(client.make_move(_bag(3), _equipment(2))), InventoryOps.Result.CANNOT_EQUIP)
	# Desequipar con la bolsa llena no tiene a dónde.
	var full := InventoryState.new(1)
	full.set_item(0, 0, ItemInstance.create(5, _db.get_definition(&"potion_health"), 1))
	full.set_item(1, 0, ItemInstance.create(6, _db.get_definition(&"bow_vado"), 1))
	_client.on_full_page(ProgressMessages.InventoryFull.split(50, full)[0])
	assert_eq(_client.equip_target(_equipment(0)), Vector2i(-1, -1))


func test_the_client_progress_keeps_the_last_server_values() -> void:
	var progress := ClientProgress.new()
	var changes: Array[int] = [0]
	progress.changed.connect(func() -> void: changes[0] += 1)
	assert_eq(progress.get_level(), 1)
	progress.set_spawn_level(7)
	assert_eq(progress.get_level(), 7, "el nivel del SPAWN vale hasta el primer PROGRESS_UPDATE")
	progress.set_spawn_level(0)
	assert_eq(progress.get_level(), 7, "un SPAWN sin progreso no lo baja")
	progress.on_wallet(ProgressMessages.WalletUpdate.make(Currency.Code.GOLD, 1250, 50, EconomyReason.NPC_KILL))
	progress.on_wallet(ProgressMessages.WalletUpdate.make(Currency.Code.MERITS, 30, 0, 0))
	assert_eq([progress.get_balance(Currency.Code.GOLD), progress.get_balance(Currency.Code.MERITS)], [1250, 30])
	var curve: LevelCurve = LevelCurve.shared()
	progress.on_progress(ProgressMessages.ProgressUpdate.make(curve, 8, curve.total_to(8) + 10, 10,
			ProgressMessages.XpSource.NPC, 44, 0))
	assert_eq(progress.get_level(), 8)
	assert_eq(progress.get_xp_in_level(), 10)
	assert_eq(progress.get_xp_to_next(), curve.xp_for_next(8))
	assert_near(progress.get_xp_fraction(), 10.0 / float(curve.xp_for_next(8)), 0.0001)
	assert_eq([progress.get_realm_points(), progress.get_attribute_points()], [44, 7])
	progress.set_spawn_level(3)
	assert_eq(progress.get_level(), 8, "con PROGRESS_UPDATE el SPAWN ya no cuenta")
	progress.on_level_up(9)
	assert_eq(progress.get_level(), 9, "un LEVEL_UP propio sube ya")
	progress.on_level_up(5)
	assert_eq(progress.get_level(), 9, "y nunca baja")
	progress.on_progress(ProgressMessages.ProgressUpdate.make(curve, curve.level_cap, curve.total_to(curve.level_cap),
			0, ProgressMessages.XpSource.GM, 44, 0))
	assert_eq(progress.get_xp_fraction(), 1.0, "en el tope, la barra llena")
	assert_eq(changes[0], 6, "cada cambio avisa (y lo que no cambia nada, no)")


func test_net_client_feeds_the_inventory_and_gives_the_context() -> void:
	var client := NetClient.new()
	tree.root.add_child(client)
	client._net_id = 5
	client._state = NetClient.State.IN_WORLD
	var inventory: ClientInventory = client.get_inventory()
	assert_not_null(inventory)
	assert_not_null(client.get_progress())
	var context: InventoryOps.Context = client.inventory_context()
	assert_false(context.can_touch_equipment, "sin personaje no se toca el equipo")
	_give_squire_kit()
	for page: ProgressMessages.InventoryFull in _server.full():
		client._on_packet_received(NetClient.SERVER_PEER_ID, page.encode())
	assert_true(inventory.has_inventory(), "el FULL llega al inventario")
	assert_true(inventory.get_confirmed().equals(_server.state))
	client._on_packet_received(NetClient.SERVER_PEER_ID,
			ProgressMessages.WalletUpdate.make(Currency.Code.GOLD, 77, 77, EconomyReason.NPC_KILL).encode())
	assert_eq(client.get_progress().get_balance(Currency.Code.GOLD), 77)
	client._on_packet_received(NetClient.SERVER_PEER_ID, NetMessages.EntityEvent.level_up(5, 10, 4).encode())
	assert_eq(client.get_progress().get_level(), 4, "el LEVEL_UP propio sube el nivel")
	assert_eq(client.inventory_context().level, 4, "y el contexto lo lleva")
	# Con personaje: la ranura activa y si puede tocar el equipo salen de su estado predicho.
	var character: PlayerCharacter = (load(NetClient.PLAYER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	client.add_child(character)
	client._character = character
	character.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	context = client.inventory_context()
	assert_eq(context.active_weapon_slot, 1)
	assert_true(context.can_touch_equipment)
	assert_false(context.drinking)
	character.combat.action = CombatState.Action.ABILITY
	character.combat.action_id = CombatCatalog.consumable_ids()[0]
	context = client.inventory_context()
	assert_false(context.can_touch_equipment, "con una acción no")
	assert_true(context.drinking, "bebiendo una poción")
	character.combat.action = CombatState.Action.NONE
	client._status = NetMessages.STATUS_IN_COMBAT
	assert_false(client.inventory_context().can_touch_equipment, "en combate no")
	# Sin transporte, una petición válida no se puede enviar: NOT_NOW y nada cambia.
	var bow: Vector2i = _slot_of(_server.state, &"bow_vado")
	client._status = 0
	assert_eq(inventory.request(inventory.make_move(bow, _bag(29))), InventoryOps.Result.NOT_NOW)
	assert_true(inventory.get_view().equals(_server.state))
	client._state = NetClient.State.IDLE
	tree.root.remove_child(client)
	client.free()
