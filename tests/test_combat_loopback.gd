extends TestCase
## El combate de punta a punta con ENet real sobre 127.0.0.1, en un solo proceso (docs/combate.md,
## secciones 4 a 6; CMB-10): un [ZoneServer] y varios [NetClient] bots, cada uno en su
## [SubViewport] con su propio mundo de física y su propio [NetTransport].
## [br][br]
## Un bot ataca a otro: el atacante, la víctima y un tercero reciben el mismo HIT y el bloque extra
## de los snapshots de la víctima lleva su vida bajada. Con rebobinado de verdad: las entradas del
## cliente real llevan su [code]view_offset_q[/code] y el servidor las acepta dentro del tope. El
## tercer escenario golpea a un maniquí: todos ven bajar su vida en el registro del snapshot.
## [br][br]
## Los bots no leen los ENTITY_EVENT (eso es del cliente de combate): la prueba escucha los paquetes
## del transporte de cada uno.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 600

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []
var _listeners: Array[Listener] = []


## Escucha los paquetes que llegan a un cliente y guarda los eventos y el último snapshot.
class Listener:
	extends RefCounted

	var events: Array[NetMessages.EntityEvent] = []
	var snapshots: Array[NetMessages.Snapshot] = []

	func _init(transport: NetTransport) -> void:
		transport.packet_received.connect(_on_packet)

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_EVENT:
				var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
				if event != null:
					events.append(event)
			NetProtocol.MSG_SNAPSHOT:
				var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
				if snapshot != null:
					snapshots.append(snapshot)

	func hits() -> Array[NetMessages.EntityEvent]:
		var found: Array[NetMessages.EntityEvent] = []
		for event: NetMessages.EntityEvent in events:
			if event.event == NetMessages.EntityEvent.Kind.HIT:
				found.append(event)
		return found

	func last_snapshot() -> NetMessages.Snapshot:
		return snapshots[snapshots.size() - 1] if not snapshots.is_empty() else null


func before_each() -> void:
	_root = Node.new()
	_root.name = "CombatLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	_listeners.clear()
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_client_viewports.clear()
	_clients.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _start_server(configure: Callable = Callable()) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	if configure.is_valid():
		configure.call(config)
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


func _add_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed)
	_clients.append(client)
	_listeners.append(Listener.new(client.get_meta(&"transport") as NetTransport))
	return client


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _all_in_world() -> bool:
	for client: NetClient in _clients:
		if client.get_state() != NetClient.State.IN_WORLD:
			return false
	return true


## Cambia lo que hace el bot: [param script] es [code](tick, position, yaw) -> PlayerInput[/code].
func _set_script(client: NetClient, script: Callable) -> void:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	(client.get_meta(&"controller") as LocalPlayerController).set_bot(brain)


func _idle(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input


# --- Pruebas ----------------------------------------------------------------------------------

func test_a_bot_hits_another_and_attacker_victim_and_a_third_get_the_same_event() -> void:
	await _start_server()
	var attacker: NetClient = _add_bot(VARDHEIM, 1)
	var victim: NetClient = _add_bot(SOLMARCH, 2)
	var third: NetClient = _add_bot(VARDHEIM, 3)
	if not assert_true(await _wait_until(_all_in_world), "los tres bots entran en el mundo"):
		return
	await wait_physics_frames(30)
	var attacker_id: int = attacker.get_net_id()
	var victim_id: int = victim.get_net_id()
	# Primero se les quita el paseo (que no se muevan), después se les coloca.
	var press: int = _server.get_tick() + 150
	_set_script(attacker, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		if tick >= press and tick < press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input)
	_set_script(victim, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		return input)
	_set_script(third, _idle)
	await wait_physics_frames(20)
	_server.teleport(attacker_id, Vector3(0.0, 0.05, 0.0))
	_server.teleport(victim_id, Vector3(0.0, 0.05, -1.5))
	_server.teleport(third.get_net_id(), Vector3(10.0, 0.05, 10.0))
	_server.get_registry().get_entity(victim_id).get_character().yaw = PI
	var delivered: bool = await _wait_until(func() -> bool:
		return not _listeners[0].hits().is_empty() and not _listeners[1].hits().is_empty() \
				and not _listeners[2].hits().is_empty())
	if not assert_true(delivered, "los tres reciben el HIT"):
		return
	var first: NetMessages.EntityEvent = _listeners[0].hits()[0]
	for index: int in [1, 2]:
		assert_eq(_listeners[index].hits()[0].encode(), first.encode(),
				"el cliente %d recibe el mismo HIT, byte a byte" % index)
	assert_eq(first.attacker, attacker_id, "del atacante")
	assert_eq(first.net_id, victim_id, "a la víctima")
	assert_eq(first.amount, 90, "un ligero de frente")
	assert_eq(first.attack_id, CombatCatalog.attack_id(&"sword_light_1"))
	assert_eq(first.hit_flags, 0)
	assert_eq(_listeners[0].hits().size(), 1, "y un solo golpe por ataque")
	# El rebobinado de un cliente real no se rechaza: las entradas llevan su vista y entran en el tope.
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0, "ningún rebobinado excesivo")
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.suspicion_score, 0, "y ninguna sospecha")
	# La vida de la víctima baja en su bloque extra y en el registro que ven los demás.
	await wait_physics_frames(12)
	var own: NetMessages.Snapshot = _listeners[1].last_snapshot()
	assert_not_null(own.own_state, "el snapshot lleva el estado propio")
	assert_eq(own.health, 910, "el bloque extra de la víctima lleva su vida")
	assert_eq(own.max_health, 1000)
	assert_true(own.is_in_combat())
	var seen: EntityRecord = null
	for record: EntityRecord in _listeners[2].last_snapshot().records:
		if record.net_id == victim_id:
			seen = record
	if assert_not_null(seen, "el tercero ve a la víctima"):
		assert_eq(seen.health_q, EntityRecord.quantize_health(910, 1000), "con su vida en el registro")
	assert_eq(_listeners[0].last_snapshot().health, 1000, "el atacante no pierde vida")


func test_both_players_hit_the_dummy_and_every_snapshot_shows_its_health_drop() -> void:
	await _start_server()
	var first: NetClient = _add_bot(VARDHEIM, 1)
	var second: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _wait_until(_all_in_world)):
		return
	await wait_physics_frames(30)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -1.5), PI)
	assert_true(dummy > 0, "el servidor coloca el maniquí")
	var press: int = _server.get_tick() + 150
	for client: NetClient in [first, second]:
		_set_script(client, func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = 0.0
			if tick >= press and tick < press + 2:
				input.buttons = PlayerInput.PRIMARY
			return input)
	await wait_physics_frames(20)
	_server.teleport(first.get_net_id(), Vector3(0.0, 0.05, 0.0))
	_server.teleport(second.get_net_id(), Vector3(0.6, 0.05, 0.0))
	var done: bool = await _wait_until(func() -> bool:
		return _listeners[0].hits().size() >= 2 and _listeners[1].hits().size() >= 2)
	if not assert_true(done, "los dos golpean al maniquí y los dos ven los dos golpes"):
		return
	for listener: Listener in _listeners:
		for event: NetMessages.EntityEvent in listener.hits():
			assert_eq(event.net_id, dummy, "todos los golpes son al maniquí")
	await wait_physics_frames(12)
	var combatant: Combatant = _server.get_combat().get_combatant(dummy)
	assert_eq(combatant.health, 1000 - 180, "dos ligeros de 90")
	for listener: Listener in _listeners:
		var record: EntityRecord = null
		for candidate: EntityRecord in listener.last_snapshot().records:
			if candidate.net_id == dummy:
				record = candidate
		if assert_not_null(record, "cada cliente recibe el registro del maniquí") and record != null:
			assert_eq(record.kind, NetProtocol.EntityKind.NPC)
			assert_eq(record.health_q, EntityRecord.quantize_health(820, 1000), "con su vida")
	assert_eq(_server.get_combat().stats[&"rewind_rejected"], 0)
