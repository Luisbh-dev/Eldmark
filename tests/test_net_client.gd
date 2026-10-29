extends TestCase
## Pruebas de [NetClient] contra un servidor falso que habla el protocolo a mano (docs/red.md,
## secciones 3, 5.4, 6.2 y 9.4): el contenido del HELLO, que no se envíe ninguna entrada antes del
## SPAWN propio, la redundancia y la recortada por el ack del INPUT_BATCH, la cabecera del lote, que
## los snapshots desordenados no reconcilien, cómo se clasifican las diferencias de la predicción
## (explicadas, sin explicar, teletransportes, reinicios duros), los NOTICE, la salida ordenada y los
## fallos de conexión. El servidor falso no simula: manda lo que cada prueba le pide.
## [br][br]
## Las pruebas con un servidor real (el de [ZoneServer]) están en [code]test_net_loopback.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const WAIT_FRAMES: int = 600


## Servidor que contesta al handshake, da de alta al cliente cuando lo pide la prueba y guarda todo
## lo que recibe. Sus snapshots no llevan estado propio salvo los que manda la prueba a mano.
class FakeServer extends Node:
	var transport: NetTransport
	var tick: int = 0
	var peer_id: int = 0
	var zone_id: String = "test_world"
	var tick_rate: int = 60
	var welcome_version: int = NetProtocol.PROTOCOL_VERSION
	var spawn_state: PlayerState
	var spawn_net_id: int = 5
	## Ticks entre el CLIENT_READY y el SPAWN propio (muy grande = nunca).
	var spawn_delay_ticks: int = 2
	var auto_snapshots: bool = true
	var snapshot_interval_ticks: int = 2
	## true: el ack de los snapshots es el último tick de entrada recibido; false: [member fixed_ack].
	var follow_ack: bool = false
	var fixed_ack: int = 0
	var substitutions: int = 0
	var margin: int = 2
	var hello: NetMessages.Hello = null
	var ready_count: int = 0
	var ready_tick: int = -1
	var spawn_tick: int = -1
	## {batch, tick, after_spawn}
	var batches: Array[Dictionary] = []
	var debug_commands: Array[NetMessages.DebugCommand] = []
	var leave_received: bool = false
	var snapshots_sent: int = 0
	var last_newest: int = 0

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
		if ready_tick >= 0 and spawn_tick < 0 and tick >= ready_tick + spawn_delay_ticks:
			_send_spawn()
		if auto_snapshots and spawn_tick >= 0 and tick % snapshot_interval_ticks == 0:
			send_snapshot(tick)
		transport.flush()

	func send_snapshot(server_tick: int, own_state: PlayerState = null,
			teleport_counter: int = 0) -> void:
		var snapshot := NetMessages.Snapshot.new()
		snapshot.server_tick = server_tick
		snapshot.input_ack_tick = last_newest if follow_ack else fixed_ack
		snapshot.input_margin = margin
		snapshot.substitutions = substitutions & 0xFFFF
		snapshot.own_teleport = teleport_counter
		snapshot.own_state = own_state
		transport.send(peer_id, NetProtocol.CH_SNAPSHOT, snapshot.encode())
		snapshots_sent += 1

	func send_notice(code: int, text: String) -> void:
		var notice := NetMessages.Notice.new()
		notice.code = code
		notice.text = text
		transport.send(peer_id, NetProtocol.CH_RELIABLE, notice.encode())

	func batches_after_spawn() -> Array[Dictionary]:
		var found: Array[Dictionary] = []
		for entry: Dictionary in batches:
			if entry["after_spawn"]:
				found.append(entry)
		return found

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
		hello = NetMessages.Hello.decode(bytes)
		var welcome := NetMessages.Welcome.new()
		welcome.protocol_version = welcome_version
		welcome.server_tick = tick
		welcome.tick_rate = tick_rate
		welcome.realm = hello.realm if hello != null else NetProtocol.Realm.VARDHEIM
		welcome.zone_id = zone_id
		transport.send_auth(from_peer, welcome.encode())
		transport.complete_auth(from_peer)

	func _on_packet(from_peer: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_CLIENT_READY:
				ready_count += 1
				ready_tick = tick
			NetProtocol.MSG_INPUT_BATCH:
				var batch: NetMessages.InputBatch = NetMessages.InputBatch.decode(bytes)
				if batch != null:
					last_newest = maxi(last_newest, batch.newest_tick)
					batches.append({"batch": batch, "tick": tick, "after_spawn": spawn_tick >= 0})
			NetProtocol.MSG_CLIENT_LEAVE:
				leave_received = true
				transport.disconnect_after_flush(from_peer)
			NetProtocol.MSG_DEBUG_COMMAND:
				var command: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(bytes)
				if command != null:
					debug_commands.append(command)


var _root: Node
var _fake: FakeServer
var _viewport: SubViewport
var _client: NetClient
var _port: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "NetClientTest"
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

## Servidor falso y un bot conectado a él. [param configure] recibe el servidor antes de arrancar.
func _start(configure: Callable = Callable()) -> void:
	_port = NetHarness.free_udp_port()
	_fake = FakeServer.new()
	if configure.is_valid():
		configure.call(_fake)
	_root.add_child(_fake)
	assert_eq(_fake.listen(_port), OK)
	_viewport = NetHarness.make_world_viewport(_root, "")
	_client = NetHarness.start_bot(_viewport, _port, VARDHEIM, 9)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _in_world() -> bool:
	return _client.get_state() == NetClient.State.IN_WORLD


## Cuenta cuántos lotes de entradas ha enviado el cliente y devuelve los nuevos en [param frames]
## fotogramas.
func _collect_batches(frames: int) -> Array[Dictionary]:
	var before: int = _fake.batches.size()
	await wait_physics_frames(frames)
	var found: Array[Dictionary] = []
	for i: int in range(before, _fake.batches.size()):
		found.append(_fake.batches[i])
	return found


func _counts_of(entries: Array[Dictionary]) -> Array[int]:
	var counts: Array[int] = []
	for entry: Dictionary in entries:
		counts.append((entry["batch"] as NetMessages.InputBatch).inputs.size())
	return counts


# --- Handshake y arranque ---------------------------------------------------------------------

func test_hello_carries_the_clients_identity() -> void:
	await _start()
	assert_true(await _wait_until(func() -> bool: return _fake.hello != null), "llega el HELLO")
	var hello: NetMessages.Hello = _fake.hello
	assert_eq(hello.protocol_version, NetProtocol.PROTOCOL_VERSION)
	assert_eq(hello.realm, VARDHEIM)
	assert_eq(hello.display_name, "Bot-9")
	assert_true(hello.is_bot(), "un bot lo declara en los flags")
	assert_eq(hello.character_id, 0)
	assert_true(hello.ticket.is_empty())
	var scene: PackedScene = load(NetClient.PLAYER_SCENE_PATH) as PackedScene
	var probe: PlayerCharacter = scene.instantiate() as PlayerCharacter
	_root.add_child(probe)
	assert_eq(hello.sim_hash, NetProtocol.compute_sim_hash(probe),
			"la huella es la de la simulación del personaje")
	probe.free()


func test_ready_is_sent_once_after_the_zone_is_ready() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	assert_eq(_fake.ready_count, 1, "un solo CLIENT_READY")
	assert_true(_client.get_controller().auto_step == false)
	assert_eq(_client.get_net_id(), _fake.spawn_net_id)
	assert_eq(_client.get_spawn_tick(), _fake.spawn_tick)


func test_no_input_is_sent_before_the_own_spawn() -> void:
	await _start(func(fake: FakeServer) -> void: fake.spawn_delay_ticks = 45)
	assert_true(await _wait_until(func() -> bool: return _fake.ready_tick >= 0))
	await wait_physics_frames(40)
	assert_eq(_client.get_state(), NetClient.State.READY_SENT, "aún sin personaje")
	assert_true(_fake.batches.is_empty(), "ni una entrada antes del SPAWN propio")
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(8)
	assert_false(_fake.batches.is_empty(), "y con el SPAWN empiezan a salir")
	for entry: Dictionary in _fake.batches:
		assert_true(entry["after_spawn"], "todas después del alta")
	var first: NetMessages.InputBatch = _fake.batches[0]["batch"]
	assert_eq(first.newest_tick, _client.get_prediction().get_first_real_tick(),
			"la primera entrada real es P0")


func test_send_debug_command_needs_a_character() -> void:
	await _start(func(fake: FakeServer) -> void: fake.spawn_delay_ticks = 30)
	assert_true(await _wait_until(func() -> bool: return _fake.ready_tick >= 0))
	var payload: PackedByteArray = NetMessages.DebugCommand.teleport(Vector3(1.0, 2.0, 3.0)).payload
	_client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	await wait_physics_frames(10)
	assert_true(_fake.debug_commands.is_empty(), "sin personaje no se envía")
	assert_true(await _wait_until(_in_world))
	_client.send_debug_command(NetProtocol.DEBUG_TELEPORT, payload)
	assert_true(await _wait_until(func() -> bool: return not _fake.debug_commands.is_empty()))
	assert_vec_near(_fake.debug_commands[0].get_teleport_position(), Vector3(1.0, 2.0, 3.0), 0.001)


# --- INPUT_BATCH ------------------------------------------------------------------------------

func test_batches_repeat_the_last_four_inputs_by_default() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(20)
	var batches: Array[Dictionary] = await _collect_batches(40)
	assert_true(batches.size() >= 38, "uno por tick de física (%d)" % batches.size())
	var first_real: int = _client.get_prediction().get_first_real_tick()
	var previous_newest: int = 0
	for entry: Dictionary in batches:
		var batch: NetMessages.InputBatch = entry["batch"]
		assert_eq(batch.inputs.size(), NetProtocol.INPUT_REDUNDANCY, "R = 4 sin ack ni pérdidas")
		assert_true(batch.inputs[0].tick >= first_real, "nunca antes de P0")
		assert_eq(batch.view_offsets_q.size(), 4)
		for i: int in batch.inputs.size():
			assert_eq(batch.inputs[i].tick, batch.newest_tick - batch.inputs.size() + 1 + i)
		var step: int = batch.newest_tick - previous_newest
		assert_true(previous_newest == 0 or (step >= 0 and step <= 2),
				"newest sube 0, 1 o 2 por tick (%d)" % step)
		previous_newest = batch.newest_tick
	var sent: int = _client.get_stats()["batches_sent"]
	assert_true(sent - _fake.batches.size() >= 0 and sent - _fake.batches.size() <= 2,
			"lo enviado es lo recibido, salvo lo que va en camino (%d, %d)"
			% [sent, _fake.batches.size()])


func test_acknowledged_inputs_are_not_sent_again() -> void:
	await _start(func(fake: FakeServer) -> void: fake.follow_ack = true)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(30)
	var counts: Array[int] = _counts_of(await _collect_batches(60))
	assert_false(counts.is_empty())
	assert_true(counts.max() <= 3, "con el ack al día solo se reenvía lo pendiente: %s" % [counts])
	assert_true(counts.min() >= 1)


func test_a_rise_of_substitutions_widens_the_redundancy_for_two_seconds() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(30)
	assert_eq(_counts_of(await _collect_batches(10)).max(), 4)
	_fake.substitutions = 3
	var counts: Array[int] = _counts_of(await _collect_batches(30))
	assert_eq(counts.max(), 8, "R = 8 tras una subida de las sustituciones: %s" % [counts])
	assert_eq(counts[counts.size() - 1], 8)
	assert_eq(_client.get_stats()["substitution_rises"], 1)
	assert_eq(_client.get_stats()["substitutions_total"], 3)
	await wait_physics_frames(110)
	counts = _counts_of(await _collect_batches(10))
	assert_eq(counts.max(), 4, "y a los 120 ticks vuelve a R = 4")


func test_batch_header_has_ack_delay_and_view_offsets() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(120)
	var entries: Array[Dictionary] = _fake.batches_after_spawn()
	var early: NetMessages.InputBatch = entries[0]["batch"]
	assert_true(early.ack_snapshot_tick <= _fake.tick)
	assert_eq(early.view_offsets_q[0], 0, "sin reloj de dibujo, desfase 0")
	var late: NetMessages.InputBatch = entries[entries.size() - 1]["batch"]
	assert_true(late.ack_snapshot_tick > 0 and late.ack_snapshot_tick <= _fake.tick,
			"ack = el snapshot más nuevo recibido (%d)" % late.ack_snapshot_tick)
	assert_true(late.interp_delay_q >= 32 and late.interp_delay_q <= 96,
			"retardo de interpolación × 8 entre 4 y 12 ticks (%d)" % late.interp_delay_q)
	for q: int in late.view_offsets_q:
		assert_true(q > 0 and q < 65535, "(tick - render_tick) × 16 (%d)" % q)
	var previous: int = 0
	for entry: Dictionary in entries:
		var ack: int = (entry["batch"] as NetMessages.InputBatch).ack_snapshot_tick
		assert_true(ack >= previous, "el ack no retrocede")
		previous = ack


# --- Snapshots y reconciliación ---------------------------------------------------------------

func test_out_of_order_snapshots_only_feed_the_interpolators() -> void:
	await _start(func(fake: FakeServer) -> void: fake.auto_snapshots = false)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(10)
	var prediction: ClientPrediction = _client.get_prediction()
	var newer: int = _client.get_spawn_tick() + 6
	var older: int = _client.get_spawn_tick() + 3
	var before: Dictionary = _client.get_stats()
	_fake.send_snapshot(newer, prediction.get_predicted_state(newer).duplicate_state())
	_fake.send_snapshot(older, prediction.get_predicted_state(older).duplicate_state())
	await wait_physics_frames(4)
	var stats: Dictionary = _client.get_stats()
	assert_eq(stats["snapshots"], before["snapshots"] + 2, "los dos llegan")
	assert_eq(stats["snapshots_with_state"], before["snapshots_with_state"] + 1,
			"solo el más nuevo se reconcilia")
	assert_eq(stats["late_snapshots"], before["late_snapshots"] + 1, "y el otro se cuenta")
	assert_eq(stats["matches"], before["matches"] + 1)
	assert_eq(stats["server_tick"], newer)
	# Uno más antiguo que el ya reconciliado, llegado después, tampoco.
	_fake.send_snapshot(newer - 1, prediction.get_predicted_state(newer - 1).duplicate_state())
	await wait_physics_frames(4)
	assert_eq(_client.get_stats()["snapshots_with_state"], before["snapshots_with_state"] + 1)
	assert_eq(_client.get_stats()["late_snapshots"], before["late_snapshots"] + 2)


func test_differences_are_classified_as_explained_unexplained_teleport_or_hard_reset() -> void:
	await _start(func(fake: FakeServer) -> void: fake.auto_snapshots = false)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(14)
	var prediction: ClientPrediction = _client.get_prediction()
	var spawn: int = _client.get_spawn_tick()
	var character: PlayerCharacter = _client.get_character()
	var visual: Node3D = character.get_node(^"Visual") as Node3D

	# 1. Una diferencia sin ninguna subida de sustituciones: fallo de la predicción.
	var wrong: PlayerState = prediction.get_predicted_state(spawn + 2).duplicate_state()
	wrong.position.x += 0.5
	_fake.send_snapshot(spawn + 2, wrong)
	await wait_physics_frames(3)
	var stats: Dictionary = _client.get_stats()
	assert_eq(stats["diffs"], 1)
	assert_eq(stats["unexplained_diffs"], 1, "sin subida de sustituciones no hay explicación")
	assert_eq(stats["explained_diffs"], 0)
	assert_eq(stats["corrections"], 1, "la corrección es de más de 1 mm")
	assert_near(stats["max_correction"], 0.5, 0.05)
	assert_eq(stats["consecutive_matches"], 0)
	assert_eq(stats["unexplained_ticks"].size(), 1)
	assert_true(visual.position.length() > 0.05, "y el error se reparte como desfase visual")

	# 2. Una diferencia con una subida de sustituciones: explicada.
	var substituted: PlayerState = prediction.get_predicted_state(spawn + 4).duplicate_state()
	substituted.position.z -= 0.3
	_fake.substitutions = 1
	_fake.send_snapshot(spawn + 4, substituted)
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["diffs"], 2)
	assert_eq(stats["explained_diffs"], 1, "coincide con una subida de sustituciones")
	assert_eq(stats["unexplained_diffs"], 1)

	# 3. Un estado idéntico al predicho: coincidencia exacta.
	_fake.send_snapshot(spawn + 6, prediction.get_predicted_state(spawn + 6).duplicate_state())
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["matches"], 1)
	assert_eq(stats["consecutive_matches"], 1)
	assert_eq(stats["diffs"], 2)

	# 4. Un teletransporte (cambia el contador): explicado, sin suavizado.
	var teleported: PlayerState = prediction.get_predicted_state(spawn + 8).duplicate_state()
	teleported.position = Vector3(20.0, 0.0, 10.0)
	_fake.send_snapshot(spawn + 8, teleported, 1)
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["teleport_diffs"], 1)
	assert_eq(stats["explained_diffs"], 2)
	assert_eq(stats["unexplained_diffs"], 1)
	assert_eq(visual.position, Vector3.ZERO, "un teletransporte no se suaviza")
	assert_vec_near(character.get_state().position, Vector3(20.0, 0.0, 10.0), 2.0,
			"el cuerpo salta al sitio del servidor")

	# 5. Un estado por delante de lo predicho: reinicio duro.
	var ahead: int = prediction.get_predicted_tick() + 10
	var reset_state: PlayerState = teleported.duplicate_state()
	reset_state.position = Vector3(5.0, 0.0, 5.0)
	_fake.send_snapshot(ahead, reset_state, 1)
	await wait_physics_frames(3)
	stats = _client.get_stats()
	assert_eq(stats["hard_resets"], 1)
	assert_eq(stats["hard_reset_ticks"].size(), 1)
	assert_true(prediction.get_predicted_tick() >= ahead, "la predicción retoma desde ahí")


func test_resync_counter_follows_tick_sync_hard_jumps() -> void:
	# Un servidor que dice que las entradas llegan 20 ticks tarde obliga a TickSync a saltar hacia
	# delante de golpe: se cuenta como resincronización.
	await _start(func(fake: FakeServer) -> void: fake.margin = -20)
	assert_true(await _wait_until(_in_world))
	assert_true(await _wait_until(func() -> bool: return _client.get_stats()["resyncs"] > 0),
			"hay una resincronización dura hacia delante")
	var stats: Dictionary = _client.get_stats()
	assert_true(stats["tick_sync_adjustments"] >= 1)
	assert_eq(stats["resync_ticks"].size(), stats["resyncs"])


# --- NOTICE, salida y fallos ------------------------------------------------------------------

func test_notice_text_becomes_the_disconnect_text() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var notices: Array[Dictionary] = []
	_client.notice_received.connect(func(code: int, text: String) -> void:
		notices.append({"code": code, "text": text}))
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	_fake.send_notice(NetProtocol.NoticeCode.KICK, "Expulsado del servidor: prueba")
	_fake.transport.disconnect_after_flush(_fake.peer_id)
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(notices.size(), 1)
	assert_eq(notices[0]["code"], NetProtocol.NoticeCode.KICK)
	assert_eq(texts[0], "Expulsado del servidor: prueba")
	assert_eq(_client.get_state(), NetClient.State.CLOSED)
	assert_eq(texts.size(), 1)
	assert_eq(_client.get_last_notice_text(), "Expulsado del servidor: prueba")


func test_losing_the_server_without_a_notice_has_a_generic_text() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	_fake.transport.disconnect_after_flush(_fake.peer_id)
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(texts[0], NetClient.TEXT_CONNECTION_LOST)


func test_leave_sends_client_leave_and_stops_sending_inputs() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(20)
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	_client.leave()
	assert_eq(_client.get_state(), NetClient.State.LEAVING)
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_true(_fake.leave_received, "el servidor recibe CLIENT_LEAVE")
	assert_eq(texts[0], NetClient.TEXT_LEFT)
	assert_eq(_client.get_state(), NetClient.State.CLOSED)
	var sent: int = _fake.batches.size()
	await wait_physics_frames(20)
	assert_eq(_fake.batches.size(), sent, "tras salir no se envía nada más")
	_client.leave()
	assert_eq(texts.size(), 1, "y salir dos veces no avisa dos veces")


func test_tick_rate_mismatch_aborts_the_connection() -> void:
	await _start(func(fake: FakeServer) -> void: fake.tick_rate = 30)
	var welcomed: Array[bool] = []
	_client.welcomed.connect(func(_welcome: NetMessages.Welcome) -> void: welcomed.append(true))
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(texts[0], NetClient.TEXT_BAD_TICK_RATE % [30, Engine.physics_ticks_per_second])
	assert_true(welcomed.is_empty(), "no llega a autenticarse")
	assert_eq(_fake.ready_count, 0)
	assert_eq(_client.get_state(), NetClient.State.CLOSED)


func test_protocol_version_mismatch_in_welcome_aborts_the_connection() -> void:
	await _start(func(fake: FakeServer) -> void: fake.welcome_version = 99)
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty()))
	assert_eq(texts[0], NetClient.TEXT_BAD_VERSION)
	assert_eq(_fake.ready_count, 0)


func test_connection_failure_is_reported_once() -> void:
	_port = NetHarness.free_udp_port()
	_viewport = NetHarness.make_world_viewport(_root, "")
	_client = NetHarness.start_bot(_viewport, _port, VARDHEIM, 9)
	var texts: Array[String] = []
	_client.disconnected.connect(func(text: String) -> void: texts.append(text))
	assert_true(await _wait_until(func() -> bool: return not texts.is_empty(), 900),
			"sin servidor, el cliente se rinde")
	assert_eq(texts[0], NetClient.TEXT_CONNECT_FAILED % ["127.0.0.1", _port])
	assert_eq(_client.get_state(), NetClient.State.CLOSED)
	await wait_physics_frames(30)
	assert_eq(texts.size(), 1)


func test_garbage_from_the_server_is_counted_not_fatal() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, 1, 2]))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_SNAPSHOT, PackedByteArray([0x10, 1, 2]))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([0x20, 0, 0]))
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([0x21]))
	await wait_physics_frames(10)
	assert_eq(_client.get_stats()["malformed_packets"], 4)
	assert_eq(_client.get_state(), NetClient.State.IN_WORLD, "el cliente sigue en el mundo")


func test_remote_entities_flow_to_the_remote_world() -> void:
	await _start()
	assert_true(await _wait_until(_in_world))
	var other := NetMessages.EntitySpawn.new()
	other.net_id = 77
	other.spawn_tick = _fake.tick
	other.realm = NetProtocol.Realm.SOLMARCH
	other.state = PlayerState.new()
	other.state.position = Vector3(3.0, 0.0, 3.0)
	other.display_name = "Otro"
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, other.encode())
	assert_true(await _wait_until(func() -> bool:
		return _client.get_remote_world().get_view(77) != null), "el SPAWN ajeno crea su vista")
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = 77
	despawn.despawn_tick = _fake.tick + 4
	_fake.transport.send(_fake.peer_id, NetProtocol.CH_RELIABLE, despawn.encode())
	assert_true(await _wait_until(func() -> bool:
		return _client.get_remote_world().get_view(77) == null), "y el DESPAWN la quita")
	assert_eq(_client.get_character().get_parent(), _client.get_meta(&"entities"),
			"el personaje local cuelga del nodo que se pasó a notify_zone_ready")
	assert_eq(_client.get_remote_world().get_parent(), _client.get_meta(&"entities"))
