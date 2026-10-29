extends TestCase
## El combate del servidor por la red, con clientes que hablan el protocolo a mano sobre ENet en
## 127.0.0.1 (docs/combate.md, secciones 5 y 6; docs/red.md, 5.5 y 5.6): a quién se envía cada
## ENTITY_EVENT (HIT, DEATH, KILL y RESPAWN), el bloque extra del snapshot con la vida, el PNJ en
## los snapshots, RESPAWN_REQUEST (en plazo, fuera de plazo y con un índice que ya no vale) y los
## comandos de depuración (con y sin [code]--debug-commands[/code]).
## [br][br]
## Los clientes son [RawClient]: sin predicción ni interpolación, mandan las entradas que dice cada
## prueba (con botones) en los ticks del servidor.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const FIRST_PORT: int = 25100
const MAX_FRAMES: int = 400

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _port: int = 0
var _clients: Array[RawClient] = []
var _hooks: Array[Callable] = []
var _client_tick: int = 0
var _next_client_index: int = 0


## Un cliente que habla el protocolo a mano y guarda lo que recibe del servidor, con los eventos.
class RawClient:
	extends RefCounted

	var transport: NetTransport
	var hello: PackedByteArray
	var welcome: NetMessages.Welcome = null
	var own_spawn: NetMessages.EntitySpawn = null
	var spawns: Array[NetMessages.EntitySpawn] = []
	var snapshots: Array[NetMessages.Snapshot] = []
	var events: Array[NetMessages.EntityEvent] = []
	var notices: Array[NetMessages.Notice] = []
	var connected: bool = false
	var disconnected: bool = false

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
		if NetMessages.peek_auth_result(bytes) == NetProtocol.Result.OK:
			welcome = NetMessages.Welcome.decode(bytes)
			transport.complete_auth(peer_id)

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_SPAWN:
				var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
				if spawn != null:
					spawns.append(spawn)
					if spawn.is_yours:
						own_spawn = spawn
			NetProtocol.MSG_SNAPSHOT:
				var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
				if snapshot != null:
					snapshots.append(snapshot)
			NetProtocol.MSG_ENTITY_EVENT:
				var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
				if event != null:
					events.append(event)
			NetProtocol.MSG_NOTICE:
				var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
				if notice != null:
					notices.append(notice)

	func send_raw(channel: int, bytes: PackedByteArray) -> Error:
		return transport.send(1, channel, bytes)

	## INPUT_BATCH con las entradas de los ticks [param first_tick] a [param last_tick]; los botones
	## de cada tick los da [param buttons_of] ([code](tick: int) -> int[/code]).
	func send_inputs(first_tick: int, last_tick: int, look_yaw: float, buttons_of: Callable) -> void:
		var batch := NetMessages.InputBatch.new()
		if not snapshots.is_empty():
			batch.ack_snapshot_tick = last_snapshot().server_tick
		batch.interp_delay_q = 32
		batch.newest_tick = last_tick
		for tick: int in range(first_tick, last_tick + 1):
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = look_yaw
			input.buttons = buttons_of.call(tick) if buttons_of.is_valid() else 0
			batch.inputs.append(input.quantized())
			batch.view_offsets_q.append(0)
		transport.send(1, NetProtocol.CH_INPUT, batch.encode())

	func last_snapshot() -> NetMessages.Snapshot:
		return snapshots[snapshots.size() - 1] if not snapshots.is_empty() else null

	func events_of(kind: int) -> Array[NetMessages.EntityEvent]:
		var found: Array[NetMessages.EntityEvent] = []
		for event: NetMessages.EntityEvent in events:
			if event.event == kind:
				found.append(event)
		return found


## Política de interés que esconde a algunos jugadores a otros: net_id del observador -> net_id
## que no ve.
class HidingPolicy:
	extends InterestPolicy

	var hidden: Dictionary = {}

	func is_relevant(observer: NetEntity, entity: NetEntity, _was_relevant: bool) -> bool:
		var hidden_ids: Array = hidden.get(observer.net_id, [])
		return not hidden_ids.has(entity.net_id)


func after_each() -> void:
	_hooks.clear()
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

func _start_server(configure: Callable = Callable()) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
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
	_port = _find_free_port()
	config.port = _port
	if configure.is_valid():
		configure.call(config)
	assert_eq(_server.start(config, _world, _server_transport, DevAuthProvider.new()), OK,
			"el servidor abre el puerto %d" % _port)


func _hello(realm: int, player_name: String) -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	hello.sim_hash = _server.get_sim_hash()
	hello.realm = realm
	hello.display_name = player_name
	return hello.encode()


func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port, "*")
		probe.close()
		if error == OK:
			return port
	return -1


## Un paso de física de los clientes: poll, ganchos y flush.
func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawClient in _clients:
		client.transport.poll(_client_tick)
	for hook: Callable in _hooks:
		hook.call(_client_tick)
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


## Entra un cliente y espera a su alta.
func _join(player_name: String, realm: int) -> RawClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawClient.new(transport, _hello(realm, player_name))
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "%s conecta" % player_name)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "%s entra en el mundo" % player_name):
		return null
	return client


func _entity_of(client: RawClient) -> NetEntity:
	return _server.get_registry().get_entity(client.own_spawn.net_id)


func _combatant_of(client: RawClient) -> Combatant:
	return _server.get_combat().get_combatant(client.own_spawn.net_id)


## Hace que [param client] mande, en cada paso, las entradas de los próximos ticks del servidor con
## [param look_yaw] y esos botones ([param buttons_of] recibe el tick del servidor).
func _drive(client: RawClient, look_yaw: float, buttons_of: Callable = Callable()) -> void:
	_hooks.append(func(_tick: int) -> void:
		var next: int = _server.get_tick() + 1
		client.send_inputs(next, next + 3, look_yaw, buttons_of))


## Coloca a [param client] en [param position] mirando a [param yaw] (en el servidor).
func _place(client: RawClient, position: Vector3, yaw: float) -> void:
	_server.teleport(client.own_spawn.net_id, position)
	_entity_of(client).get_character().yaw = yaw


# --- Lo que no viaja ---------------------------------------------------------------------------

## R4: quien entra en la zona recibe un ENTITY_SPAWN por cada entidad que ya estaba, y el de las ajenas no
## lleva su resistencia, agotamiento, enfriamiento de parada ni controles; el propio sí lo lleva todo.
func test_the_spawn_of_other_players_does_not_leak_their_private_combat_state() -> void:
	await _start_server()
	var ana: RawClient = await _join("Ana", VARDHEIM)
	if ana == null:
		return
	var combat: CombatState = _entity_of(ana).get_character().combat
	combat.stamina = 137
	combat.stamina_regen_tick = _server.get_tick() + 100000
	combat.combat_flags = CombatState.FLAG_EXHAUSTED
	combat.parry_ready_tick = _server.get_tick() + 5000
	var bea: RawClient = await _join("Bea", SOLMARCH)
	if bea == null:
		return
	var seen: NetMessages.EntitySpawn = null
	for spawn: NetMessages.EntitySpawn in bea.spawns:
		if spawn.net_id == ana.own_spawn.net_id:
			seen = spawn
	if not assert_not_null(seen, "Bea recibe el SPAWN de Ana"):
		return
	assert_false(seen.is_yours, "ajeno")
	var neutral: CombatState = CombatState.initial(CombatCatalog.rules(), combat.weapon_id)
	assert_eq(seen.state.combat.stamina, neutral.stamina, "sin la resistencia exacta")
	assert_eq(seen.state.combat.combat_flags, 0, "ni el agotamiento")
	assert_eq(seen.state.combat.parry_ready_tick, 0, "ni el enfriamiento de la parada")
	assert_eq(seen.state.combat.stamina_regen_tick, 0)
	assert_eq(seen.state.combat.weapon_id, combat.weapon_id, "el arma sí")
	assert_true(ana.own_spawn.is_yours, "el SPAWN propio sigue marcado como tuyo")


# --- Eventos ----------------------------------------------------------------------------------

func test_a_hit_reaches_attacker_victim_and_a_third_player_with_the_same_content() -> void:
	await _start_server()
	var attacker: RawClient = await _join("Ana", VARDHEIM)
	var victim: RawClient = await _join("Bea", SOLMARCH)
	var third: RawClient = await _join("Cleo", VARDHEIM)
	if attacker == null or victim == null or third == null:
		return
	_place(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	_place(victim, Vector3(0.0, 0.05, -1.5), PI)
	_place(third, Vector3(8.0, 0.05, 8.0), 0.0)
	var press: int = _server.get_tick() + 10
	_drive(attacker, 0.0, func(tick: int) -> int:
		return PlayerInput.PRIMARY if tick >= press and tick < press + 2 else 0)
	_drive(victim, PI)
	_drive(third, 0.0)
	var delivered: bool = await _run_until(func() -> bool:
		return not attacker.events.is_empty() and not victim.events.is_empty() \
				and not third.events.is_empty())
	if not assert_true(delivered, "los tres reciben el evento"):
		return
	var first: NetMessages.EntityEvent = attacker.events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	for client: RawClient in [victim, third]:
		var copy: NetMessages.EntityEvent = client.events_of(NetMessages.EntityEvent.Kind.HIT)[0]
		assert_eq(copy.encode(), first.encode(), "el mismo HIT, byte a byte")
	assert_eq(first.attacker, attacker.own_spawn.net_id)
	assert_eq(first.net_id, victim.own_spawn.net_id)
	assert_eq(first.amount, 90)
	# La vida de la víctima baja en su bloque extra y en el registro que ven los demás.
	await _run_frames(6)
	var own: NetMessages.Snapshot = victim.last_snapshot()
	assert_eq(own.health, 910, "bloque extra propio de la víctima")
	assert_eq(own.max_health, 1000)
	assert_true(own.is_in_combat(), "en combate")
	var seen_by_third: EntityRecord = null
	for record: EntityRecord in third.last_snapshot().records:
		if record.net_id == victim.own_spawn.net_id:
			seen_by_third = record
	if assert_not_null(seen_by_third, "el tercero ve a la víctima"):
		assert_eq(seen_by_third.health_q, EntityRecord.quantize_health(910, 1000),
				"y su vida cuantizada en el registro")
	assert_eq(attacker.last_snapshot().health, 1000, "el atacante no pierde vida")


func test_events_only_go_to_players_who_own_or_see_the_entities() -> void:
	await _start_server()
	var policy := HidingPolicy.new()
	_server.interest_policy = policy
	var attacker: RawClient = await _join("Ana", VARDHEIM)
	var victim: RawClient = await _join("Bea", SOLMARCH)
	var blind: RawClient = await _join("Cleo", VARDHEIM)
	if attacker == null or victim == null or blind == null:
		return
	# Cleo no ve ni a Ana ni a Bea.
	policy.hidden[blind.own_spawn.net_id] = [attacker.own_spawn.net_id, victim.own_spawn.net_id]
	_place(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	_place(victim, Vector3(0.0, 0.05, -1.5), PI)
	var press: int = _server.get_tick() + 30
	_drive(attacker, 0.0, func(tick: int) -> int:
		return PlayerInput.PRIMARY if tick >= press and tick < press + 2 else 0)
	_drive(victim, PI)
	_drive(blind, 0.0)
	assert_true(await _run_until(func() -> bool: return not victim.events.is_empty()),
			"la víctima recibe el golpe")
	await _run_frames(20)
	assert_false(attacker.events.is_empty(), "el atacante también")
	assert_eq(blind.events.size(), 0, "quien no ve a ninguno de los dos no recibe nada")


func test_kill_and_death_events_name_the_killer_and_the_assistants() -> void:
	await _start_server()
	var attacker: RawClient = await _join("Ana", VARDHEIM)
	var victim: RawClient = await _join("Bea", SOLMARCH)
	var helper: RawClient = await _join("Cleo", VARDHEIM)
	if attacker == null or victim == null or helper == null:
		return
	_place(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	_place(victim, Vector3(0.0, 0.05, -1.5), PI)
	_place(helper, Vector3(8.0, 0.05, 8.0), 0.0)
	# Cleo ya había hecho la mitad del daño; a Bea le quedan 60.
	var combatant: Combatant = _combatant_of(victim)
	combatant.health = 60
	combatant.mark_combat(_server.get_tick())
	combatant.ledger.record(_server.get_tick(), helper.own_spawn.net_id, 500)
	var press: int = _server.get_tick() + 10
	_drive(attacker, 0.0, func(tick: int) -> int:
		return PlayerInput.PRIMARY if tick >= press and tick < press + 2 else 0)
	_drive(victim, PI)
	_drive(helper, 0.0)
	var delivered: bool = await _run_until(func() -> bool:
		return not helper.events_of(NetMessages.EntityEvent.Kind.KILL).is_empty() \
				and not attacker.events_of(NetMessages.EntityEvent.Kind.KILL).is_empty() \
				and not victim.events_of(NetMessages.EntityEvent.Kind.DEATH).is_empty())
	if not assert_true(delivered, "asesino, víctima y asistente reciben su evento"):
		return
	var kill: NetMessages.EntityEvent = attacker.events_of(NetMessages.EntityEvent.Kind.KILL)[0]
	assert_eq(kill.killer, attacker.own_spawn.net_id)
	assert_eq(kill.net_id, victim.own_spawn.net_id)
	assert_eq(kill.assistants, PackedInt32Array([helper.own_spawn.net_id]), "Cleo asistió")
	var death: NetMessages.EntityEvent = victim.events_of(NetMessages.EntityEvent.Kind.DEATH)[0]
	assert_eq(death.killer, attacker.own_spawn.net_id)
	assert_eq(death.attack_id, CombatCatalog.attack_id(&"sword_light_1"))
	var hit: NetMessages.EntityEvent = victim.events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	assert_true(hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL), "el golpe es mortal")
	assert_eq(hit.amount, 60, "lo que le quedaba")
	await _run_frames(10)
	assert_eq(victim.events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "una sola DEATH")
	assert_eq(attacker.events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1, "un solo KILL")
	# Y el snapshot propio de la víctima la da por muerta con su tick de reaparición.
	var own: NetMessages.Snapshot = victim.last_snapshot()
	assert_true(own.is_dead(), "muerta")
	assert_eq(own.health, 0)
	assert_eq(own.respawn_tick, combatant.respawn_tick)


# --- Reaparición pedida -----------------------------------------------------------------------

func test_respawn_request_flow_and_its_warnings() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana", SOLMARCH)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_drive(client, 0.0)
	var timing: CombatTiming = _server.get_combat_timing()
	timing.respawn = 60
	timing.auto_respawn = 600
	# Vivo: pedir reaparecer está fuera de plazo.
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(0))
	await _run_frames(10)
	assert_eq(peer.strikes_total, 1, "vivo: un aviso")
	# Muerto, pero mucho antes de poder: otro aviso.
	_server.get_combat().kill(_combatant_of(client), _server.get_tick() + 1)
	await _run_frames(5)
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(0))
	await _run_frames(5)
	assert_eq(peer.strikes_total, 2, "demasiado pronto: un aviso")
	assert_true(_combatant_of(client).is_dead(), "sigue muerta")
	# A su hora, con un índice que ya no vale: no es un aviso y reaparece en el primer punto.
	var respawn_tick: int = client.last_snapshot().respawn_tick
	assert_eq(respawn_tick, _combatant_of(client).respawn_tick, "el snapshot da el tick de reaparición")
	assert_true(await _run_until(func() -> bool: return _server.get_tick() >= respawn_tick - 6),
			"llega la hora")
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(200))
	var back: bool = await _run_until(func() -> bool: return _combatant_of(client).is_alive())
	if not assert_true(back, "reaparece"):
		return
	assert_eq(peer.strikes_total, 2, "un índice que ya no vale no suma avisos")
	assert_vec_near(_entity_of(client).get_position(), ZoneFixture.SOLMARCH_SPAWN, 0.1,
			"en el primer punto de su reino")
	await _run_frames(8)
	var own: NetMessages.Snapshot = client.last_snapshot()
	assert_false(own.is_dead())
	assert_true(own.is_protected(), "con la protección de reaparición")
	assert_eq(own.health, 1000)
	assert_eq(own.own_teleport, 1, "con teletransporte")
	var respawns: Array[NetMessages.EntityEvent] = client.events_of(NetMessages.EntityEvent.Kind.RESPAWN)
	if assert_eq(respawns.size(), 1, "recibe su RESPAWN"):
		assert_eq(respawns[0].point, 0)
		assert_eq(respawns[0].net_id, client.own_spawn.net_id)
	# Ya viva, otra petición es un aviso más.
	client.send_raw(NetProtocol.CH_RELIABLE, _respawn_request(0))
	await _run_frames(8)
	assert_eq(peer.strikes_total, 3)
	# Un mensaje mal formado también.
	client.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_RESPAWN_REQUEST]))
	await _run_frames(8)
	assert_eq(peer.strikes_total, 4)


func _respawn_request(point_index: int) -> PackedByteArray:
	var request := NetMessages.RespawnRequest.new()
	request.point_index = point_index
	return request.encode()


# --- Comandos de depuración -------------------------------------------------------------------

func _command(id: int, payload: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var command := NetMessages.DebugCommand.new()
	command.command = id
	command.payload = payload
	return command.encode()


func test_debug_commands_without_the_flag_are_warnings() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana", VARDHEIM)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_combatant_of(client).take_damage(400, 1)
	_combatant_of(client).mark_combat(_server.get_tick())
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_HEAL))
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_KILL))
	await _run_frames(10)
	assert_eq(peer.strikes_total, 2, "sin --debug-commands, cada uno es un aviso")
	assert_eq(_combatant_of(client).health, 600, "y no hacen nada")
	assert_eq(_server.get_commands().audit_total, 0, "ni se auditan")


func test_debug_commands_with_the_flag_act_on_the_sender_and_are_audited() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana", VARDHEIM)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	var combatant: Combatant = _combatant_of(client)
	_drive(client, 0.0)
	# heal
	combatant.take_damage(400, 1)
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_HEAL))
	assert_true(await _run_until(func() -> bool: return combatant.health == 1000), "heal cura")
	# stamina_inf: sin datos alterna y con un byte fija el valor.
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_STAMINA_INF))
	assert_true(await _run_until(func() -> bool:
		return (_entity_of(client).get_character().combat.combat_flags
				& CombatState.FLAG_INFINITE_STAMINA) != 0), "stamina_inf activa la resistencia infinita")
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_STAMINA_INF, PackedByteArray([0])))
	assert_true(await _run_until(func() -> bool:
		return (_entity_of(client).get_character().combat.combat_flags
				& CombatState.FLAG_INFINITE_STAMINA) == 0), "y con 0 la quita")
	# set_weapon con el id del catálogo.
	var weapon_payload := PackedByteArray([0, 0])
	weapon_payload.encode_u16(0, CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_SET_WEAPON, weapon_payload))
	# spawn_dummy delante del jugador, bloqueando.
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_SPAWN_DUMMY, PackedByteArray([NpcBrain.Mode.BLOCK])))
	assert_true(await _run_until(func() -> bool: return _server.get_dummy_count() == 1), "aparece el maniquí")
	var dummy_spawns: Array[NetMessages.EntitySpawn] = []
	assert_true(await _run_until(func() -> bool:
		for spawn: NetMessages.EntitySpawn in client.spawns:
			if spawn.kind == NetProtocol.EntityKind.NPC and not dummy_spawns.has(spawn):
				dummy_spawns.append(spawn)
		return not dummy_spawns.is_empty()), "el jugador recibe el SPAWN del PNJ")
	if dummy_spawns.is_empty():
		return
	var dummy_spawn: NetMessages.EntitySpawn = dummy_spawns[0]
	assert_eq(dummy_spawn.display_name, ZoneServer.DUMMY_NAME)
	assert_eq(dummy_spawn.realm, RealmCatalog.NEUTRAL_CODE)
	# El PNJ viaja en su propia sección del snapshot.
	assert_true(await _run_until(func() -> bool:
		for record: EntityRecord in client.last_snapshot().records:
			if record.net_id == dummy_spawn.net_id:
				return record.kind == NetProtocol.EntityKind.NPC
		return false), "y en el snapshot, como PNJ")
	# kill: el último; después de morir no sirve ni heal.
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_KILL))
	assert_true(await _run_until(func() -> bool: return combatant.is_dead()), "kill mata")
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_HEAL))
	await _run_frames(10)
	assert_true(combatant.is_dead(), "un muerto no se cura con heal")
	assert_eq(peer.strikes_total, 0, "ninguno de estos usos es un aviso")
	# Cada uso queda auditado con quién y qué.
	var audit: PackedStringArray = _server.get_commands().audit
	assert_true(audit.size() >= 6, "seis usos auditados (%d)" % audit.size())
	assert_true(audit[0].contains("Ana") and audit[0].contains("heal"), audit[0])
	assert_true(audit[audit.size() - 1].contains("rechazado"), "el último heal fue rechazado")


func test_bad_debug_commands_are_warnings() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana", VARDHEIM)
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	client.send_raw(NetProtocol.CH_RELIABLE, _command(99))
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_SET_WEAPON, PackedByteArray([1])))
	var unknown_weapon := PackedByteArray([0, 0])
	unknown_weapon.encode_u16(0, 999)
	client.send_raw(NetProtocol.CH_RELIABLE, _command(NetProtocol.DEBUG_SET_WEAPON, unknown_weapon))
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_STAMINA_INF, PackedByteArray([1, 2, 3])))
	client.send_raw(NetProtocol.CH_RELIABLE,
			_command(NetProtocol.DEBUG_SPAWN_DUMMY, PackedByteArray([9])))
	await _run_frames(15)
	assert_eq(peer.strikes_total, 5, "id desconocido, arma mal formada, arma inexistente, datos de más y modo inválido")
	assert_eq(_server.get_dummy_count(), 0)
