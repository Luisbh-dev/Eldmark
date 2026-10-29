extends TestCase
## Pruebas de los eventos de combate del cliente (docs/combate.md, secciones 5 y 6): la cola
## ordenada por tick de dibujo ([CombatEventQueue]) y [NetClient] contra un servidor falso que
## manda el bloque extra del snapshot (vida, estado, tick de reaparición) y ENTITY_EVENT.
## [br]- Un evento propio (atacante, víctima, asesino o asistente) se entrega al llegar.
## [br]- Uno ajeno espera a que el tick de dibujo alcance su tick, aunque llegue antes.
## [br]- RESPAWN_REQUEST sale con el índice elegido y solo dentro del mundo.
## [br]- Una corrección de la predicción causada por lo que impone el servidor (un golpe recibido, su
## golpe parado, su muerte o su reaparición) cuenta como explicada por el combate, llegue el evento antes
## o después que el snapshot; sin evento (o con uno ajeno o muy anterior) sigue siendo un fallo.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const WAIT_FRAMES: int = 600
## net_id que el servidor falso da al jugador local.
const OWN_ID: int = 5
const OTHER_ID: int = 21
const THIRD_ID: int = 22


## Servidor mínimo: contesta al handshake, da de alta al cliente y manda snapshots con el bloque
## extra y los eventos que pida la prueba.
class FakeServer extends Node:
	var transport: NetTransport
	var tick: int = 0
	var peer_id: int = 0
	var spawn_state: PlayerState
	var spawn_net_id: int = OWN_ID
	var ready_tick: int = -1
	var spawn_tick: int = -1
	var health: int = 1000
	var max_health: int = 1000
	var status: int = 0
	var respawn_tick: int = 0
	var respawn_requests: Array[int] = []
	var malformed_requests: int = 0

	func _init() -> void:
		name = "FakeServer"
		process_physics_priority = -100
		spawn_state = PlayerState.new()
		spawn_state.position = Vector3(-20.0, 0.0, 0.0)
		spawn_state.grounded = true

	func listen(port: int) -> Error:
		transport = NetTransport.new()
		transport.name = "FakeTransport"
		add_child(transport)
		transport.auth_received.connect(_on_auth_received)
		transport.packet_received.connect(_on_packet)
		return transport.host(port, 4)

	func _physics_process(_delta: float) -> void:
		transport.poll(tick)
		tick += 1
		if ready_tick >= 0 and spawn_tick < 0 and tick >= ready_tick + 2:
			_send_spawn()
		if spawn_tick >= 0 and tick % 2 == 0:
			send_snapshot()
		transport.flush()

	func send_snapshot() -> void:
		var snapshot := NetMessages.Snapshot.new()
		snapshot.server_tick = tick
		snapshot.input_ack_tick = 0
		snapshot.own_state = spawn_state
		snapshot.health = health
		snapshot.max_health = max_health
		snapshot.status = status
		snapshot.respawn_tick = respawn_tick
		transport.send(peer_id, NetProtocol.CH_SNAPSHOT, snapshot.encode())

	func send_event(event: NetMessages.EntityEvent) -> void:
		transport.send(peer_id, NetProtocol.CH_RELIABLE, event.encode())

	func send_raw(bytes: PackedByteArray) -> void:
		transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)

	func _send_spawn() -> void:
		spawn_tick = tick
		var spawn := NetMessages.EntitySpawn.new()
		spawn.net_id = spawn_net_id
		spawn.spawn_tick = tick
		spawn.realm = NetProtocol.Realm.VARDHEIM
		spawn.is_yours = true
		spawn.state = spawn_state
		spawn.display_name = "Bot-9"
		transport.send(peer_id, NetProtocol.CH_RELIABLE, spawn.encode())

	func _on_auth_received(from_peer: int, bytes: PackedByteArray) -> void:
		peer_id = from_peer
		var hello: NetMessages.Hello = NetMessages.Hello.decode(bytes)
		var welcome := NetMessages.Welcome.new()
		welcome.protocol_version = NetProtocol.PROTOCOL_VERSION
		welcome.server_tick = tick
		welcome.tick_rate = 60
		welcome.realm = hello.realm if hello != null else NetProtocol.Realm.VARDHEIM
		welcome.zone_id = "test_world"
		transport.send_auth(from_peer, welcome.encode())
		transport.complete_auth(from_peer)

	func _on_packet(_from_peer: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_CLIENT_READY:
				ready_tick = tick
			NetProtocol.MSG_RESPAWN_REQUEST:
				var request: NetMessages.RespawnRequest = NetMessages.RespawnRequest.decode(bytes)
				if request == null:
					malformed_requests += 1
				else:
					respawn_requests.append(request.point_index)


## Eventos recibidos: [code]{event, own, render_tick, local_tick}[/code].
var _received: Array[Dictionary] = []
var _root: Node
var _fake: FakeServer
var _viewport: SubViewport
var _client: NetClient


func before_each() -> void:
	_received.clear()
	_root = Node.new()
	_root.name = "CombatEventsTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_viewport):
		_viewport.free()
	if is_instance_valid(_fake):
		_fake.free()
	_viewport = null
	_fake = null
	_client = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _start() -> void:
	var port: int = NetHarness.free_udp_port()
	_fake = FakeServer.new()
	_root.add_child(_fake)
	assert_eq(_fake.listen(port), OK)
	_viewport = NetHarness.make_world_viewport(_root, "")
	_client = NetHarness.start_bot(_viewport, port, VARDHEIM, 9)
	_client.combat_event.connect(_on_combat_event)


func _on_combat_event(event: NetMessages.EntityEvent, is_own: bool) -> void:
	_received.append({
		"event": event,
		"own": is_own,
		"render_tick": _client.get_interpolation_clock().get_render_tick(),
		"local_tick": _client.get_local_tick(),
	})


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _in_world() -> bool:
	return _client.get_state() == NetClient.State.IN_WORLD


## El reloj de dibujo ya arrancó (llegó algún snapshot con estado).
func _clock_running() -> bool:
	return _client.get_interpolation_clock().get_render_tick() > 0.0


func _hit(victim: int, attacker: int, tick: int, amount: int = 90,
		flags: int = 0) -> NetMessages.EntityEvent:
	return NetMessages.EntityEvent.hit(victim, tick, attacker, amount, 0, flags, 2)


func _event_of(entry: Dictionary) -> NetMessages.EntityEvent:
	return entry["event"] as NetMessages.EntityEvent


# --- La cola ----------------------------------------------------------------------------------

func test_queue_orders_events_by_tick_and_keeps_arrival_order_on_ties() -> void:
	var queue := CombatEventQueue.new()
	var late: NetMessages.EntityEvent = _hit(1, 2, 120)
	var early: NetMessages.EntityEvent = _hit(1, 2, 100)
	var tie_first: NetMessages.EntityEvent = _hit(3, 2, 110, 10)
	var tie_second: NetMessages.EntityEvent = _hit(3, 2, 110, 20)
	for event: NetMessages.EntityEvent in [late, early, tie_first, tie_second]:
		queue.push(event)
	assert_eq(queue.size(), 4)
	assert_eq(queue.peek_next_tick(), 100)
	var due: Array[NetMessages.EntityEvent] = queue.pop_due(1000.0)
	assert_eq(due.size(), 4)
	assert_true(due[0] == early and due[1] == tie_first and due[2] == tie_second \
			and due[3] == late, "por tick y, a igual tick, por orden de llegada")
	assert_eq(queue.size(), 0)
	assert_eq(queue.peek_next_tick(), -1)


func test_queue_only_releases_events_whose_tick_has_been_reached() -> void:
	var queue := CombatEventQueue.new()
	queue.push(_hit(1, 2, 100))
	queue.push(_hit(1, 2, 103))
	assert_eq(queue.pop_due(99.9).size(), 0, "antes de su tick no sale")
	assert_eq(queue.pop_due(100.0).size(), 1, "en su tick sale")
	assert_eq(queue.pop_due(102.5).size(), 0, "el siguiente aún no")
	assert_eq(queue.pop_due(103.0).size(), 1)
	assert_eq(queue.pop_due(500.0).size(), 0, "y la cola ya está vacía")


func test_queue_holds_everything_until_the_render_clock_starts() -> void:
	var queue := CombatEventQueue.new()
	queue.push(_hit(1, 2, 0))
	queue.push(_hit(1, 2, 5))
	assert_eq(queue.pop_due(0.0).size(), 0, "con el reloj sin arrancar no sale nada")
	assert_eq(queue.size(), 2)
	assert_eq(queue.pop_due(5.0).size(), 2, "y al arrancar salen los que tocan")


func test_queue_is_bounded_and_drops_the_oldest() -> void:
	var queue := CombatEventQueue.new()
	for i: int in CombatEventQueue.MAX_PENDING + 10:
		queue.push(_hit(1, 2, 1000 + i))
	assert_eq(queue.size(), CombatEventQueue.MAX_PENDING)
	assert_eq(queue.dropped, 10)
	assert_eq(queue.peek_next_tick(), 1010, "se pierden los más antiguos")
	queue.clear()
	assert_eq(queue.size(), 0)


# --- El bloque extra --------------------------------------------------------------------------

func test_extra_block_gives_health_status_and_respawn_tick() -> void:
	await _start()
	assert_false(_client.has_health(), "hasta el primer snapshot con estado no hay vida del servidor")
	assert_eq(_client.get_health(), _client.get_max_health(), "y se supone llena")
	assert_true(await _wait_until(_in_world))
	_fake.health = 700
	_fake.max_health = 1000
	_fake.status = NetMessages.STATUS_IN_COMBAT
	assert_true(await _wait_until(func() -> bool: return _client.get_health() == 700))
	assert_true(_client.has_health())
	assert_eq(_client.get_max_health(), 1000)
	assert_true(_client.is_in_combat())
	assert_false(_client.is_dead())
	assert_false(_client.is_protected())
	assert_eq(_client.get_respawn_tick(), 0)

	_fake.health = 0
	_fake.status = NetMessages.STATUS_DEAD
	_fake.respawn_tick = _fake.tick + 600
	assert_true(await _wait_until(_client.is_dead))
	assert_eq(_client.get_health(), 0)
	assert_eq(_client.get_respawn_tick(), _fake.respawn_tick)
	assert_eq(_client.get_stats()["health"], 0)

	_fake.health = 1000
	_fake.status = NetMessages.STATUS_PROTECTED
	_fake.respawn_tick = 0
	assert_true(await _wait_until(func() -> bool: return not _client.is_dead()))
	assert_true(_client.is_protected())
	assert_eq(_client.get_respawn_tick(), 0)


func test_estimated_server_tick_follows_the_snapshots() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	assert_true(await _wait_until(func() -> bool: return _client.has_health()))
	await wait_physics_frames(20)
	var estimated: int = _client.get_estimated_server_tick()
	assert_true(estimated > 0, "hay estimación")
	assert_true(estimated <= _fake.tick, "no adelanta al servidor (%d > %d)" % [estimated, _fake.tick])
	assert_true(_fake.tick - estimated <= 8, "y va pegada a él (%d ticks de diferencia)"
			% (_fake.tick - estimated))
	var before: int = estimated
	await wait_physics_frames(10)
	assert_true(_client.get_estimated_server_tick() >= before + 8, "avanza con los ticks locales")


# --- Eventos propios y ajenos -----------------------------------------------------------------

func test_own_events_are_delivered_on_arrival_even_if_their_tick_is_in_the_future() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	assert_true(await _wait_until(_clock_running))
	var far_future: int = int(_client.get_interpolation_clock().get_render_tick()) + 6000
	_fake.send_event(_hit(OTHER_ID, OWN_ID, far_future))       # atacante
	_fake.send_event(_hit(OWN_ID, OTHER_ID, far_future))       # víctima
	_fake.send_event(NetMessages.EntityEvent.death(OWN_ID, far_future, OTHER_ID, 2))
	_fake.send_event(NetMessages.EntityEvent.kill(OTHER_ID, far_future, OWN_ID, 2,
			PackedInt32Array([THIRD_ID])))                       # asesino
	_fake.send_event(NetMessages.EntityEvent.kill(OTHER_ID, far_future, THIRD_ID, 2,
			PackedInt32Array([OWN_ID])))                         # asistente
	_fake.send_event(NetMessages.EntityEvent.respawn(OWN_ID, far_future, 1))
	assert_true(await _wait_until(func() -> bool: return _received.size() >= 6))
	for entry: Dictionary in _received:
		assert_true(bool(entry["own"]), "todos son propios")
		assert_true(float(entry["render_tick"]) < float(far_future), "y no esperaron a su tick")
	assert_eq(_event_of(_received[0]).attacker, OWN_ID)
	assert_eq(_event_of(_received[5]).event, NetMessages.EntityEvent.Kind.RESPAWN)
	assert_eq(_event_of(_received[5]).point, 1)
	assert_eq(_client.get_stats()["combat_events_own"], 6)
	assert_eq(_client.get_stats()["combat_events_pending"], 0)


func test_events_of_others_wait_for_the_render_tick() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	assert_true(await _wait_until(_clock_running))
	var clock: InterpolationClock = _client.get_interpolation_clock()
	var due_tick: int = int(clock.get_render_tick()) + 90
	_fake.send_event(_hit(OTHER_ID, THIRD_ID, due_tick))
	assert_true(await _wait_until(func() -> bool:
			return _client.get_stats()["combat_events"] >= 1), "el evento llega")
	assert_eq(_received.size(), 0, "pero no se muestra todavía (le faltan ~90 ticks)")
	assert_eq(_client.get_stats()["combat_events_pending"], 1)
	assert_true(await _wait_until(func() -> bool: return _received.size() == 1, 400))
	var entry: Dictionary = _received[0]
	assert_false(bool(entry["own"]), "no es propio")
	assert_true(float(entry["render_tick"]) >= float(due_tick),
			"se entrega cuando el tick de dibujo (%.1f) alcanza el del evento (%d)"
			% [float(entry["render_tick"]), due_tick])
	assert_true(float(entry["render_tick"]) < float(due_tick) + 2.0, "y a tiempo (no tarde)")
	assert_eq(_client.get_stats()["combat_events_pending"], 0)


func test_events_of_others_in_the_past_are_delivered_at_once_and_in_order() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	assert_true(await _wait_until(func() -> bool:
			return _client.get_interpolation_clock().get_render_tick() >= 40.0))
	var now_tick: int = int(_client.get_interpolation_clock().get_render_tick())
	_fake.send_event(_hit(OTHER_ID, THIRD_ID, now_tick - 2, 30))
	_fake.send_event(_hit(OTHER_ID, THIRD_ID, now_tick - 10, 10))
	_fake.send_event(NetMessages.EntityEvent.respawn(THIRD_ID, now_tick - 6, 0))
	assert_true(await _wait_until(func() -> bool: return _received.size() == 3))
	var amounts: Array[int] = []
	for entry: Dictionary in _received:
		amounts.append(_event_of(entry).tick)
	assert_eq(amounts, [now_tick - 10, now_tick - 6, now_tick - 2] as Array[int],
			"salen ordenados por tick")
	for entry: Dictionary in _received:
		assert_false(bool(entry["own"]))


func test_malformed_event_is_counted_and_not_delivered() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var good: PackedByteArray = _hit(OTHER_ID, THIRD_ID, 10).encode()
	var truncated: PackedByteArray = good.slice(0, good.size() - 3)
	var before: int = _client.get_stats()["malformed_packets"]
	_fake.send_raw(truncated)
	_fake.send_raw(PackedByteArray([NetProtocol.MSG_ENTITY_EVENT]))
	assert_true(await _wait_until(func() -> bool:
			return _client.get_stats()["malformed_packets"] >= before + 2))
	await wait_physics_frames(10)
	assert_eq(_received.size(), 0)
	assert_eq(_client.get_stats()["combat_events"], 0)


func test_is_own_event_needs_a_local_character() -> void:
	await _start()
	var event: NetMessages.EntityEvent = _hit(OTHER_ID, OWN_ID, 10)
	assert_false(_client.is_own_event(event), "sin personaje local nada es propio")
	assert_true(await _wait_until(_in_world))
	assert_true(_client.is_own_event(event))
	assert_false(_client.is_own_event(_hit(OTHER_ID, THIRD_ID, 10)))
	assert_false(_client.is_own_event(NetMessages.EntityEvent.respawn(OTHER_ID, 10, 0)))
	assert_false(_client.is_own_event(null))


# --- Reaparición ------------------------------------------------------------------------------

func test_respawn_request_carries_the_chosen_index_and_only_works_in_the_world() -> void:
	await _start()
	assert_false(_client.send_respawn_request(2), "antes de entrar en el mundo no se envía")
	assert_true(await _wait_until(_in_world))
	assert_true(_client.send_respawn_request(2))
	assert_true(_client.send_respawn_request(0))
	assert_true(await _wait_until(func() -> bool: return _fake.respawn_requests.size() >= 2))
	assert_eq(_fake.respawn_requests, [2, 0] as Array[int])
	assert_eq(_fake.malformed_requests, 0)
	assert_eq(_client.get_stats()["respawn_requests"], 2)
	assert_true(_client.send_respawn_request(900), "un índice enorme se recorta al byte")
	assert_true(await _wait_until(func() -> bool: return _fake.respawn_requests.size() >= 3))
	assert_eq(_fake.respawn_requests[2], 255)


# --- Correcciones explicadas por el combate ---------------------------------------------------
# Sin servidor: se alimenta a un NetClient suelto con las llamadas internas que hace al reconciliar
# (un snapshot corregido) y al recibir un evento.

func _bare_client() -> NetClient:
	var client := NetClient.new()
	client._net_id = OWN_ID
	return client


## Una corrección del snapshot del servidor [param server_tick], sin sustitución ni teletransporte.
func _correct(client: NetClient, server_tick: int) -> void:
	client._last_snapshot_tick = server_tick
	client._record_result(ClientPrediction.Result.CORRECTED, false, false)


## El cliente recibe [param event] por el canal fiable.
func _receive(client: NetClient, event: NetMessages.EntityEvent) -> void:
	client._on_entity_event(event.encode())


## Pasa [param ticks] ticks locales (el bucle del tick da por definitivas las diferencias viejas).
func _advance(client: NetClient, ticks: int) -> void:
	for _i: int in ticks:
		client._local_tick += 1
		client._settle_pending_diffs()


func test_a_correction_after_a_hit_on_me_is_explained_by_combat() -> void:
	var client: NetClient = _bare_client()
	_receive(client, _hit(OWN_ID, OTHER_ID, 100))
	_correct(client, 100)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["diffs"], 1)
	assert_eq(stats["combat_diffs"], 1, "por el combate")
	assert_eq(stats["explained_diffs"], 1)
	assert_eq(stats["unexplained_diffs"], 0, "no es un fallo de la predicción")
	# Sigue igual cuando pasa el plazo: el evento ya estaba.
	_advance(client, NetClient.DIFF_SETTLE_TICKS + 10)
	stats = client.get_stats()
	assert_eq(stats["combat_diffs"], 1)
	assert_eq(stats["explained_diffs"], 1)
	assert_eq(stats["unexplained_diffs"], 0)
	client.free()


func test_the_snapshots_after_the_event_are_inside_the_window_and_later_ones_are_not() -> void:
	var client: NetClient = _bare_client()
	_receive(client, _hit(OWN_ID, OTHER_ID, 100))
	_correct(client, 100 + NetClient.COMBAT_EXPLAIN_TICKS)
	assert_eq(client.get_stats()["combat_diffs"], 1, "el último tick de la ventana")
	_correct(client, 100 + NetClient.COMBAT_EXPLAIN_TICKS + 1)
	assert_eq(client.get_stats()["unexplained_diffs"], 1, "uno más allá, no")
	_correct(client, 99)
	assert_eq(client.get_stats()["unexplained_diffs"], 2, "y uno anterior al golpe tampoco")
	client.free()


func test_the_event_may_arrive_after_the_snapshot_that_shows_the_change() -> void:
	var client: NetClient = _bare_client()
	_correct(client, 100)
	assert_eq(client.get_stats()["unexplained_diffs"], 1, "mientras no hay evento, cuenta como fallo provisional")
	_advance(client, 20)
	_receive(client, _hit(OWN_ID, OTHER_ID, 100))
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "al llegar el evento por el canal fiable queda explicada")
	assert_eq(stats["combat_diffs"], 1)
	assert_eq(stats["explained_diffs"], 1)
	_advance(client, NetClient.DIFF_SETTLE_TICKS)
	stats = client.get_stats()
	assert_eq(stats["combat_diffs"], 1, "y sigue explicada cuando se da por definitiva")
	assert_eq(stats["unexplained_diffs"], 0)
	client.free()


func test_without_a_combat_event_the_same_correction_is_a_prediction_failure() -> void:
	var client: NetClient = _bare_client()
	_correct(client, 100)
	_advance(client, NetClient.DIFF_SETTLE_TICKS + 10)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["unexplained_diffs"], 1, "nada la explica")
	assert_eq(stats["combat_diffs"], 0)
	assert_eq(stats["explained_diffs"], 0)
	assert_eq((stats["unexplained_ticks"] as Array).size(), 1, "y se recuerda el tick local en que se vio")
	client.free()


func test_events_of_others_and_far_away_events_do_not_explain_a_correction() -> void:
	var client: NetClient = _bare_client()
	_receive(client, _hit(THIRD_ID, OTHER_ID, 100))   # entre otros dos
	_receive(client, _hit(OTHER_ID, OWN_ID, 100))     # mi golpe, que no fue parado
	_receive(client, _hit(OWN_ID, OTHER_ID, 40))      # recibido mucho antes
	_correct(client, 100)
	_advance(client, NetClient.DIFF_SETTLE_TICKS + 10)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["unexplained_diffs"], 1, "ninguno de los tres la explica")
	assert_eq(stats["combat_diffs"], 0)
	client.free()


func test_my_swing_being_parried_my_death_and_my_respawn_also_explain_a_correction() -> void:
	var client: NetClient = _bare_client()
	_receive(client, _hit(OTHER_ID, OWN_ID, 100, 0, NetMessages.EntityEvent.HIT_FLAG_PARRIED))
	_receive(client, NetMessages.EntityEvent.death(OWN_ID, 200, OTHER_ID, 2))
	_receive(client, NetMessages.EntityEvent.respawn(OWN_ID, 300, 0))
	for server_tick: int in [100, 200, 300]:
		_correct(client, server_tick)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["combat_diffs"], 3, "las tres, explicadas por el combate")
	assert_eq(stats["unexplained_diffs"], 0)
	client.free()


func test_a_substitution_or_a_teleport_still_explain_a_correction_without_any_event() -> void:
	var client: NetClient = _bare_client()
	client._last_snapshot_tick = 100
	client._record_result(ClientPrediction.Result.CORRECTED, true, false)
	client._record_result(ClientPrediction.Result.CORRECTED, false, true)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["explained_diffs"], 2)
	assert_eq(stats["combat_diffs"], 0, "no son del combate")
	assert_eq(stats["unexplained_diffs"], 0)
	client.free()


func test_pending_diffs_and_remembered_events_are_bounded() -> void:
	var client: NetClient = _bare_client()
	for index: int in NetClient.MAX_TRACKED_DIFFS + 20:
		_correct(client, 1000 + index * 100)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["diffs"], NetClient.MAX_TRACKED_DIFFS + 20)
	assert_eq(stats["unexplained_diffs"], NetClient.MAX_TRACKED_DIFFS + 20, "ninguna se pierde de la cuenta")
	assert_true(client._pending_diffs.size() <= NetClient.MAX_TRACKED_DIFFS)
	for index: int in NetClient.MAX_TRACKED_DIFFS + 20:
		_receive(client, _hit(OWN_ID, OTHER_ID, 50000 + index))
	assert_true(client._imposed_ticks.size() <= NetClient.MAX_TRACKED_DIFFS)
	client.free()
