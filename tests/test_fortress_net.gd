extends TestCase
## El servidor del fuerte con clientes de verdad sobre ENet en 127.0.0.1, en un solo proceso (paquete F3):
## lo que ve un cliente de una captura completa (el SPAWN de la fortaleza, los OBJECT_STATE y los avisos
## WAR en orden), el KILL a toda la zona, el marcador cada 2 s en páginas, la salida y la desconexión en
## combate (GUE-41) y el comando /atascado (MUN-41). Los clientes son [RawClient]s que hablan el protocolo a
## mano, como en [code]test_zone_server_net.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const FIRST_PORT: int = 25400
const MAX_FRAMES: int = 600

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _port: int = 0
var _clients: Array[RawClient] = []
var _client_tick: int = 0
var _next_client_index: int = 0


## Un cliente que habla el protocolo a mano y guarda todo lo que recibe, también lo de la fortaleza.
class RawClient:
	extends RefCounted

	var transport: NetTransport
	var hello: PackedByteArray
	var welcome: NetMessages.Welcome = null
	var reject: NetMessages.Reject = null
	var connected: bool = false
	var disconnected: bool = false
	var own_spawn: NetMessages.EntitySpawn = null
	var spawns: Array[NetMessages.EntitySpawn] = []
	var despawns: Array[NetMessages.EntityDespawn] = []
	var snapshots: Array[NetMessages.Snapshot] = []
	var notices: Array[NetMessages.Notice] = []
	var events: Array[NetMessages.EntityEvent] = []
	var object_states: Array[NetMessages.ObjectState] = []
	var scoreboards: Array[NetMessages.Scoreboard] = []
	var malformed: int = 0

	func _init(p_transport: NetTransport, p_hello: PackedByteArray) -> void:
		transport = p_transport
		hello = p_hello
		transport.peer_authenticating.connect(func(peer_id: int) -> void:
			transport.send_auth(peer_id, hello))
		transport.auth_received.connect(_on_auth_received)
		transport.peer_connected.connect(func(_peer_id: int) -> void:
			connected = true
			transport.send(1, NetProtocol.CH_RELIABLE, NetMessages.ClientReady.new().encode()))
		transport.peer_disconnected.connect(func(_peer_id: int) -> void: disconnected = true)
		transport.packet_received.connect(_on_packet)

	func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
		var result: int = NetMessages.peek_auth_result(bytes)
		if result == NetProtocol.Result.OK:
			welcome = NetMessages.Welcome.decode(bytes)
			transport.complete_auth(peer_id)
		elif result > 0:
			reject = NetMessages.Reject.decode(bytes)

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_SPAWN:
				var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
				if spawn == null:
					malformed += 1
					return
				spawns.append(spawn)
				if spawn.is_yours:
					own_spawn = spawn
			NetProtocol.MSG_ENTITY_DESPAWN:
				var despawn: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
				if despawn != null:
					despawns.append(despawn)
			NetProtocol.MSG_SNAPSHOT:
				var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
				if snapshot != null:
					snapshots.append(snapshot)
			NetProtocol.MSG_NOTICE:
				var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
				if notice != null:
					notices.append(notice)
			NetProtocol.MSG_ENTITY_EVENT:
				var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
				if event == null:
					malformed += 1
				else:
					events.append(event)
			NetProtocol.MSG_OBJECT_STATE:
				var object_state: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
				if object_state == null:
					malformed += 1
				else:
					object_states.append(object_state)
			NetProtocol.MSG_SCOREBOARD:
				var board: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(bytes)
				if board == null:
					malformed += 1
				else:
					scoreboards.append(board)

	func send_raw(channel: int, bytes: PackedByteArray) -> Error:
		return transport.send(1, channel, bytes)

	func events_of(kind: int) -> Array[NetMessages.EntityEvent]:
		var found: Array[NetMessages.EntityEvent] = []
		for event: NetMessages.EntityEvent in events:
			if event.event == kind:
				found.append(event)
		return found

	func war_ids() -> Array[int]:
		var ids: Array[int] = []
		for event: NetMessages.EntityEvent in events_of(NetMessages.EntityEvent.Kind.WAR):
			ids.append(event.war_event)
		return ids

	func has_notice_containing(text: String) -> bool:
		for notice: NetMessages.Notice in notices:
			if notice.text.contains(text):
				return true
		return false


## Política de interés que esconde a los jugadores falsos (los «Bot…») para probar lo que va a toda la zona.
class HidingPolicy:
	extends InterestPolicy

	func is_relevant(_observer: NetEntity, entity: NetEntity, _was_relevant: bool) -> bool:
		return not entity.display_name.begins_with("Bot")


func after_each() -> void:
	for client: RawClient in _clients:
		if is_instance_valid(client.transport):
			client.transport.free()
	_clients.clear()
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_server_transport):
		_server_transport.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_server_transport = null
	_world = null
	_viewport = null
	_client_tick = 0
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _start_server(definition: FortressDefinition = null, configure: Callable = Callable()) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, definition if definition != null
			else FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	_server_transport = NetTransport.new()
	_server_transport.name = "ServerTransport"
	_viewport.add_child(_server_transport)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.no_dummies = true
	_port = _find_free_port()
	config.port = _port
	if configure.is_valid():
		configure.call(config)
	assert_eq(_server.start(config, _world, _server_transport, DevAuthProvider.new()), OK,
			"el servidor abre el puerto %d" % _port)


func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port, "*")
		probe.close()
		if error == OK:
			return port
	return -1


func _client_sim_hash() -> int:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	_world.add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	_world.remove_child(character)
	character.free()
	return hash_value


func _hello(realm: int, player_name: String) -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	hello.sim_hash = _client_sim_hash()
	hello.realm = realm
	hello.display_name = player_name
	return hello.encode()


func _connect_client(realm: int, player_name: String) -> RawClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawClient.new(transport, _hello(realm, player_name))
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "el cliente conecta")
	return client


func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawClient in _clients:
		client.transport.poll(_client_tick)
	for client: RawClient in _clients:
		client.transport.flush()


func _run_frames(count: int) -> void:
	for _i: int in count:
		await _step()


func _run_until(condition: Callable, max_frames: int = MAX_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await _step()
	return condition.call()


## Entra un cliente y espera a su alta. null si no la tiene.
func _join(player_name: String, realm: int = VARDHEIM) -> RawClient:
	var client: RawClient = _connect_client(realm, player_name)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "%s entra en el mundo" % player_name):
		return null
	return client


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


func _combatant(net_id: int) -> Combatant:
	return _server.get_combat().get_combatant(net_id)


func _brain() -> CombatFixture.ScriptBrain:
	return CombatFixture.ScriptBrain.new(1)


# --- El fuerte en el cliente --------------------------------------------------------------------

func test_a_joining_client_gets_the_fortress_spawn_with_its_whole_state() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana")
	if ana == null:
		return
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	var found: Array[NetMessages.EntitySpawn] = []
	for spawn: NetMessages.EntitySpawn in ana.spawns:
		if spawn.net_id == gate_id:
			found.append(spawn)
	if not assert_eq(found.size(), 1, "un SPAWN de la fortaleza"):
		return
	assert_eq(found[0].kind, NetProtocol.EntityKind.STRUCTURE)
	assert_eq(found[0].definition_id, String(FORTRESS))
	assert_eq(found[0].fields.size(), FortressFields.all_ids().size(), "con todos los campos")
	var mirror: FortressState = FortressState.initial(FortressFixture.make_definition(), 0)
	found[0].to_object_state().apply_to_fortress(mirror)
	assert_eq(mirror.gate_health, 900)
	assert_eq(mirror.owner, 0)
	assert_eq(ana.malformed, 0)
	# Los snapshots no llevan registros de estructuras.
	await _run_frames(10)
	for snapshot: NetMessages.Snapshot in ana.snapshots:
		for record: EntityRecord in snapshot.records:
			assert_true(record.net_id != gate_id, "la fortaleza no va en los snapshots")


func test_a_full_capture_reaches_every_client_as_object_state_and_war_events_in_order() -> void:
	await _start_server()
	_server.spawn_captain_double(FORTRESS)
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	_server.teleport(ana.own_spawn.net_id, FortressFixture.circle_center())
	await _run_frames(30)
	assert_true(ana.war_ids().is_empty(), "con el capitán vivo, nada")
	_server.console_command("fort_kill_captain")
	var both_notified := func() -> bool: return ana.war_ids().size() >= 3 and bo.war_ids().size() >= 3
	var captured: bool = await _run_until(both_notified)
	assert_true(captured, "los dos clientes reciben los tres avisos (%s y %s)" % [ana.war_ids(), bo.war_ids()])
	assert_eq(ana.war_ids(), [WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED] as Array[int],
			"en el orden en que ocurren")
	assert_eq(bo.war_ids(), ana.war_ids(), "a toda la zona, el mismo aviso")
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	var realms: Array[int] = []
	for event: NetMessages.EntityEvent in ana.events_of(NetMessages.EntityEvent.Kind.WAR):
		assert_eq(event.net_id, gate_id)
		realms.append(event.war_realm)
	assert_eq(realms, [0, VARDHEIM, VARDHEIM] as Array[int], "el capitán lo mató la orden de depuración (reino 0)")
	# El cliente reconstruye el estado con los OBJECT_STATE (más el SPAWN).
	await _run_frames(20)
	var mirror: FortressState = FortressState.initial(FortressFixture.make_definition(), 0)
	for spawn: NetMessages.EntitySpawn in bo.spawns:
		if spawn.net_id == gate_id:
			spawn.to_object_state().apply_to_fortress(mirror)
	for object_state: NetMessages.ObjectState in bo.object_states:
		assert_eq(object_state.net_id, gate_id)
		object_state.apply_to_fortress(mirror)
	assert_eq(mirror.owner, VARDHEIM, "el cliente ve cambiar el dueño")
	assert_eq(mirror.phase, _state().phase)
	assert_eq(mirror.presence[VARDHEIM], _state().presence[VARDHEIM])
	assert_eq(mirror.capture_progress_at_start, _state().capture_progress_at_start)
	# Ritmo: como mucho uno cada 6 ticks, salvo los que cambian la colisión de la puerta.
	var previous: NetMessages.ObjectState = null
	for object_state: NetMessages.ObjectState in bo.object_states:
		if previous != null and object_state.tick - previous.tick < FortressController.OBJECT_STATE_INTERVAL_TICKS:
			assert_true(object_state.has_field(FortressFields.OWNER) or object_state.has_field(FortressFields.GATE_HEALTH),
					"dos OBJECT_STATE a menos de 6 ticks solo si cambia la colisión de la puerta")
		previous = object_state
	assert_eq(bo.malformed, 0)


func test_a_kill_goes_to_the_whole_zone_even_to_a_client_that_does_not_see_the_bots() -> void:
	await _start_server(null, func(config: ServerConfig) -> void: config.max_players = 8)
	_server.interest_policy = HidingPolicy.new()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var killer: int = _server.add_fake_player(_brain(), VARDHEIM)
	var victim: int = _server.add_fake_player(_brain(), SOLMARCH)
	await _run_frames(10)
	var combat: CombatDirector = _server.get_combat()
	var tick: int = _server.get_tick() + 1
	combat.event_emitted.emit(NetMessages.EntityEvent.death(victim, tick, killer, 1),
			PackedInt32Array([victim, killer]))
	combat.event_emitted.emit(NetMessages.EntityEvent.kill(victim, tick, killer, 1, PackedInt32Array()),
			PackedInt32Array([victim, killer]))
	await _run_frames(20)
	assert_eq(ana.events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1,
			"el KILL llega a quien no ve a ninguno de los dos")
	assert_eq(ana.events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 0,
			"el DEATH, que no es de la zona entera, no")
	assert_eq(ana.events_of(NetMessages.EntityEvent.Kind.KILL)[0].killer, killer)


func test_a_gate_hit_reaches_the_attackers_client_with_the_fortress_net_id() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, Vector3(77.5, 0.05, 0.0))
	_server.get_registry().get_entity(net_id).get_character().yaw = -PI * 0.5
	var combatant: Combatant = _combatant(net_id)
	var target: StructureTarget = _server.get_fortresses().get_structure_targets()[0]
	_server.get_fortresses().on_structure_hit(target, combatant, 31, _server.get_tick() + 1)
	await _run_frames(10)
	assert_eq(ana.war_ids(), [WarEvents.UNDER_ATTACK] as Array[int], "el aviso llega a la zona")
	assert_eq(_state().gate_health, 900 - 31)


# --- Marcador ----------------------------------------------------------------------------------

func test_the_scoreboard_arrives_every_two_seconds_in_pages_of_66_rows() -> void:
	await _start_server(null, func(config: ServerConfig) -> void: config.max_players = 100)
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	for _i: int in 70:
		_server.add_fake_player(_brain(), SOLMARCH)
	var combat: CombatDirector = _server.get_combat()
	var victim: int = _server.get_fortresses().get_net_id(FORTRESS) + 2
	combat.event_emitted.emit(NetMessages.EntityEvent.kill(victim, 5, ana.own_spawn.net_id, 1,
			PackedInt32Array()), PackedInt32Array())
	var arrived: bool = await _run_until(func() -> bool: return ana.scoreboards.size() >= 2, 400)
	assert_true(arrived, "llega un marcador, partido en dos páginas")
	var pages: Dictionary = {}
	for board: NetMessages.Scoreboard in ana.scoreboards:
		assert_eq(board.page_count, 2)
		pages[board.page_index] = board
	assert_true(pages.has(0) and pages.has(1))
	assert_eq((pages[0] as NetMessages.Scoreboard).rows.size(), 66, "una página llena")
	assert_eq((pages[1] as NetMessages.Scoreboard).rows.size(), 71 - 66, "y el resto en la otra")
	var own_row: NetMessages.ScoreRow = null
	for board: NetMessages.Scoreboard in pages.values():
		for row: NetMessages.ScoreRow in board.rows:
			if row.net_id == ana.own_spawn.net_id:
				own_row = row
	if assert_not_null(own_row, "mi fila está"):
		assert_eq(own_row.kills, 1)
		assert_eq(own_row.merits, 10)
	var more: int = ana.scoreboards.size()
	var again: bool = await _run_until(func() -> bool: return ana.scoreboards.size() >= more + 2, 400)
	assert_true(again, "y se repite cada 2 s")
	assert_eq(ana.malformed, 0)


# --- Salida y desconexión en combate (GUE-41) ---------------------------------------------------

func test_leaving_in_combat_leaves_a_neutral_attackable_body_for_the_linger_time() -> void:
	await _start_server()
	_server.linger_ticks = 120
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, FortressFixture.circle_center())
	_combatant(net_id).mark_combat(_server.get_tick() + 1)
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	var gone: bool = await _run_until(func() -> bool: return ana.disconnected)
	assert_true(gone, "el cliente se va")
	await _run_frames(10)
	assert_true(_server.is_lingering(net_id), "su cuerpo sigue en el mundo")
	assert_not_null(_server.get_registry().get_entity(net_id))
	assert_eq(_server.get_lingering_count(), 1)
	assert_false(bo.despawns.any(func(d: NetMessages.EntityDespawn) -> bool: return d.net_id == net_id),
			"los demás no reciben el DESPAWN todavía")
	# Quieto y sin botones: entradas neutras de verdad.
	var body: PlayerCharacter = _server.get_registry().get_entity(net_id).get_character()
	var position: Vector3 = body.global_position
	await _run_frames(20)
	assert_vec_near(body.global_position, position, 0.05, "quieto")
	assert_eq(body.combat.action, CombatState.Action.NONE, "sin acción ni bloqueo")
	# Atacable: el combatiente sigue vivo y puede recibir daño.
	assert_true(_combatant(net_id).is_alive())
	# Su nombre sigue reservado.
	var again: RawClient = _connect_client(VARDHEIM, "Ana")
	var rejected: bool = await _run_until(func() -> bool: return again.reject != null)
	assert_true(rejected, "el nombre está reservado")
	assert_eq(again.reject.result, NetProtocol.Result.NAME)
	# No cuenta en el círculo: con el fuerte abierto, estar dentro no captura.
	_state().on_captain_died(_server.get_tick() + 1, SOLMARCH)
	await _run_frames(30)
	assert_eq(_state().presence[VARDHEIM], 0, "el cuerpo que queda no cuenta")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	# Pasado el plazo, desaparece y todos reciben su DESPAWN.
	var removed: bool = await _run_until(func() -> bool: return not _server.is_lingering(net_id))
	assert_true(removed, "el cuerpo se retira a los %d ticks" % _server.linger_ticks)
	assert_null(_server.get_registry().get_entity(net_id))
	var despawned: bool = await _run_until(func() -> bool:
		return bo.despawns.any(func(d: NetMessages.EntityDespawn) -> bool: return d.net_id == net_id))
	assert_true(despawned, "DESPAWN para quien lo veía")
	var free_again: RawClient = _connect_client(VARDHEIM, "Ana")
	var entered: bool = await _run_until(func() -> bool: return free_again.own_spawn != null)
	assert_true(entered, "y el nombre queda libre")


func test_leaving_out_of_combat_is_immediate() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	var net_id: int = ana.own_spawn.net_id
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	var despawned: bool = await _run_until(func() -> bool:
		return bo.despawns.any(func(d: NetMessages.EntityDespawn) -> bool: return d.net_id == net_id))
	assert_true(despawned, "fuera de combate, la baja es inmediata")
	assert_false(_server.is_lingering(net_id))
	assert_eq(_server.get_lingering_count(), 0)


func test_a_dropped_connection_in_combat_also_leaves_the_body() -> void:
	await _start_server()
	_server.linger_ticks = 60
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_combatant(net_id).mark_combat(_server.get_tick() + 1)
	await _run_frames(3)
	ana.transport.close()
	var lingering: bool = await _run_until(func() -> bool: return _server.is_lingering(net_id), 300)
	assert_true(lingering, "una desconexión en combate también deja el cuerpo")
	var removed: bool = await _run_until(func() -> bool: return not _server.is_lingering(net_id), 300)
	assert_true(removed)


func test_killing_the_lingering_body_credits_the_killer_like_any_other_death() -> void:
	await _start_server()
	_server.linger_ticks = 600
	var ana: RawClient = await _join("Ana", VARDHEIM)
	var bo: RawClient = await _join("Bob", SOLMARCH)
	if ana == null or bo == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, Vector3(-20.0, 0.05, 8.0))
	_combatant(net_id).mark_combat(_server.get_tick() + 1)
	_combatant(net_id).health = 40
	await _run_frames(3)
	ana.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	await _run_until(func() -> bool: return _server.is_lingering(net_id))
	# Un enemigo golpea al cuerpo: un ligero de 90 lo mata.
	var killer: int = _server.add_fake_player(_brain(), SOLMARCH)
	_server.teleport(killer, Vector3(-20.0, 0.05, 6.5))
	_server.get_registry().get_entity(killer).get_character().yaw = PI
	var attack_tick: int = _server.get_tick() + 3
	var brain: CombatFixture.ScriptBrain = _server._fakes[killer] as CombatFixture.ScriptBrain
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		if tick >= attack_tick and tick < attack_tick + 2:
			input.buttons = PlayerInput.PRIMARY
		return input
	var is_dead := func() -> bool: return _combatant(net_id) == null or _combatant(net_id).is_dead()
	var dead: bool = await _run_until(is_dead, 200)
	assert_true(dead, "el cuerpo muere como cualquier otro")
	var kills: Array[NetMessages.EntityEvent] = bo.events_of(NetMessages.EntityEvent.Kind.KILL)
	if assert_eq(kills.size(), 1, "con su KILL"):
		assert_eq(kills[0].killer, killer, "acreditado al que lo mató")
		assert_eq(kills[0].net_id, net_id)
	assert_eq(_server.get_scores().get_entry(killer).kills, 1, "y la baja cuenta en el marcador")
	var removed: bool = await _run_until(func() -> bool: return not _server.is_lingering(net_id), 100)
	assert_true(removed, "muerto, el cuerpo se retira enseguida")


# --- /atascado (MUN-41) --------------------------------------------------------------------------

func _unstuck_request() -> PackedByteArray:
	return NetMessages.UnstuckRequest.new().encode()


func test_unstuck_teleports_to_the_nearest_valid_point_after_the_channel_and_logs_it() -> void:
	await _start_server()
	_server.get_unstuck().channel_ticks = 60
	_server.get_unstuck().cooldown_ticks = 300
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	_server.teleport(net_id, Vector3(150.0, 0.05, 90.0))
	var counter: int = entity.teleport_counter
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var started: bool = await _run_until(func() -> bool: return _server.get_unstuck().is_channeling("ana"), 60)
	assert_true(started, "empieza la canalización")
	var notified: bool = await _run_until(func() -> bool: return ana.has_notice_containing("/atascado"), 60)
	assert_true(notified, "y se le avisa")
	assert_vec_near(entity.get_position(), Vector3(150.0, 0.05, 90.0), 0.5, "aún no se ha movido")
	var moved: bool = await _run_until(func() -> bool: return _server.get_unstuck().completed_count == 1, 200)
	assert_true(moved, "completa la canalización")
	await _run_frames(3)
	assert_vec_near(entity.get_position(), FortressFixture.VARDHEIM_CAMP, 1.5,
			"al punto de su reino más cercano (el campamento: el fuerte es neutral)")
	assert_true(entity.teleport_counter != counter, "con salto de teletransporte para los clientes")
	# Queda registrado: zona, origen y destino.
	var path: String = ProjectSettings.globalize_path("res://build/test_fortress_net_report.json")
	assert_eq(_server.write_report(path), OK)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var unstuck: Dictionary = (report["war"] as Dictionary)["unstuck"]
	assert_eq(int(unstuck["uses"]), 1)
	var entry: Dictionary = (unstuck["log"] as Array)[0]
	assert_eq(entry["zone"], "test_world")
	assert_eq(entry["name"], "Ana")
	assert_eq((entry["from"] as Array)[0], 150.0)
	# Segundo uso inmediato: en reutilización.
	var notices_before: int = ana.notices.size()
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	await _run_until(func() -> bool: return ana.notices.size() > notices_before, 60)
	assert_true(ana.has_notice_containing("disponible de nuevo"), "reutilización de 5 min")
	assert_false(_server.get_unstuck().is_channeling("ana"))


func test_unstuck_is_refused_in_combat_and_interrupted_by_damage() -> void:
	await _start_server()
	_server.get_unstuck().channel_ticks = 90
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, Vector3(150.0, 0.05, 90.0))
	var combatant: Combatant = _combatant(net_id)
	combatant.mark_combat(_server.get_tick() + 1)
	await _run_frames(3)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var refused: bool = await _run_until(func() -> bool: return ana.has_notice_containing("en combate"), 60)
	assert_true(refused, "en combate no se puede")
	assert_false(_server.get_unstuck().is_channeling("ana"))
	# Fuera de combate empieza; el daño lo interrumpe y no gasta la reutilización.
	combatant.in_combat_until = 0
	await _run_frames(3)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var started: bool = await _run_until(func() -> bool: return _server.get_unstuck().is_channeling("ana"), 60)
	assert_true(started)
	await _run_frames(20)
	combatant.take_damage(10, _server.get_tick() + 1)
	combatant.mark_combat(_server.get_tick() + 1)
	var interrupted: bool = await _run_until(func() -> bool: return ana.has_notice_containing("interrumpido"), 60)
	assert_true(interrupted, "el daño interrumpe la canalización")
	assert_false(_server.get_unstuck().is_channeling("ana"))
	assert_eq(_server.get_unstuck().interrupted_count, 1)
	assert_eq(_server.get_unstuck().completed_count, 0)
	assert_vec_near(_server.get_registry().get_entity(net_id).get_position(), Vector3(150.0, 0.05, 90.0), 0.5,
			"no se mueve")
	assert_eq(_server.get_unstuck().cooldown_remaining("ana", _server.get_tick()), 0, "y no gasta la reutilización")


func test_unstuck_goes_to_the_fortress_of_the_realm_when_it_is_the_nearest_valid_point() -> void:
	await _start_server()
	_server.get_unstuck().channel_ticks = 30
	_server.console_command("fort_owner vardheim")
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var net_id: int = ana.own_spawn.net_id
	_server.teleport(net_id, FortressFixture.ORIGIN + Vector3(30.0, 0.05, 0.0))
	await _run_frames(5)
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	var moved: bool = await _run_until(func() -> bool: return _server.get_unstuck().completed_count == 1, 200)
	assert_true(moved)
	await _run_frames(3)
	assert_vec_near(_server.get_registry().get_entity(net_id).get_position(),
			FortressFixture.ORIGIN + FortressFixture.INNER_POINTS_LOCAL[1], 1.5,
			"un fuerte propio y tranquilo es el punto válido más cercano")


func test_unstuck_does_not_need_debug_commands_and_a_malformed_request_is_a_strike() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	ana.send_raw(NetProtocol.CH_RELIABLE, _unstuck_request())
	await _run_frames(5)
	assert_eq(peer.strikes_total, 0, "vale sin --debug-commands")
	ana.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_UNSTUCK_REQUEST, 1]))
	await _run_frames(5)
	assert_eq(peer.strikes_total, 1, "uno mal formado suma un aviso")
