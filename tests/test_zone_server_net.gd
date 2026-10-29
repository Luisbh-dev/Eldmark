extends TestCase
## Pruebas de [ZoneServer] con clientes de verdad sobre ENet en 127.0.0.1, en un solo proceso.
## [br][br]
## El servidor y cada cliente tienen su propio [NetTransport] (con su [SceneMultiplayer]); los
## clientes son [RawClient]: hablan el protocolo a mano (HELLO, WELCOME, CLIENT_READY, INPUT_BATCH...)
## sin predicción ni interpolación, que son del cliente real. Se comprueba el handshake y los
## rechazos, el alta con el estado «tras S», los snapshots, las entradas, el interés, las bajas, la
## seguridad (avisos, expulsión, tipos inesperados, comandos de depuración), el simulador de red
## y el cierre con aviso. El ejecutor falla ante cualquier error del motor, así que cada prueba
## también comprueba que no se envía nada antes de [signal NetTransport.peer_connected].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const FIRST_PORT: int = 24900
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
var _raw_peers: Array[ENetMultiplayerPeer] = []
var _raw_attackers: Array[RawEnetAttacker] = []


## Un cliente que habla el protocolo a mano: envía su HELLO al conectar, completa la
## autenticación con el WELCOME, envía CLIENT_READY al conectar (si [member auto_ready]) y guarda
## todo lo que recibe del servidor.
class RawClient:
	extends RefCounted

	var transport: NetTransport
	var hello: PackedByteArray
	var tick: int = 0
	var auto_ready: bool = true
	## Ticks que atrasa el ack de snapshot que declara en cada lote (fingir lag).
	var ack_lag_ticks: int = 0
	## Retardo de interpolación (×8) que declara en cada lote.
	var interp_delay_q: int = 32
	var welcome: NetMessages.Welcome = null
	var reject: NetMessages.Reject = null
	var connected: bool = false
	var disconnected: bool = false
	var failed: bool = false
	var ready_sent: bool = false
	var own_spawn: NetMessages.EntitySpawn = null
	var spawns: Array[NetMessages.EntitySpawn] = []
	var despawns: Array[NetMessages.EntityDespawn] = []
	var snapshots: Array[NetMessages.Snapshot] = []
	var notices: Array[NetMessages.Notice] = []

	func _init(p_transport: NetTransport, p_hello: PackedByteArray) -> void:
		transport = p_transport
		hello = p_hello
		transport.peer_authenticating.connect(_on_authenticating)
		transport.auth_received.connect(_on_auth_received)
		transport.peer_connected.connect(_on_connected)
		transport.peer_disconnected.connect(_on_disconnected)
		transport.packet_received.connect(_on_packet)
		transport.connection_failed.connect(_on_failed)

	func _on_authenticating(peer_id: int) -> void:
		transport.send_auth(peer_id, hello)

	func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
		var result: int = NetMessages.peek_auth_result(bytes)
		if result == NetProtocol.Result.OK:
			welcome = NetMessages.Welcome.decode(bytes)
			transport.complete_auth(peer_id)
		elif result > 0:
			reject = NetMessages.Reject.decode(bytes)

	func _on_connected(_peer_id: int) -> void:
		connected = true
		if auto_ready:
			send_ready()

	func _on_disconnected(_peer_id: int) -> void:
		disconnected = true

	func _on_failed() -> void:
		failed = true

	func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
		match NetMessages.peek_type(bytes):
			NetProtocol.MSG_ENTITY_SPAWN:
				var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
				if spawn != null:
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

	func send_ready() -> void:
		ready_sent = true
		transport.send(1, NetProtocol.CH_RELIABLE, NetMessages.ClientReady.new().encode())

	func send_raw(channel: int, bytes: PackedByteArray) -> Error:
		return transport.send(1, channel, bytes)

	## INPUT_BATCH con [param count] entradas que acaban en [param newest_tick], todas con el
	## mismo movimiento y la misma vista.
	func send_inputs(newest_tick: int, count: int, move: Vector2, look_yaw: float) -> void:
		var batch := NetMessages.InputBatch.new()
		if not snapshots.is_empty():
			batch.ack_snapshot_tick = maxi(last_snapshot().server_tick - ack_lag_ticks, 1)
		batch.interp_delay_q = interp_delay_q
		batch.newest_tick = newest_tick
		for i: int in count:
			var input := PlayerInput.new()
			input.tick = newest_tick - count + 1 + i
			input.move = move
			input.look_yaw = look_yaw
			batch.inputs.append(input.quantized())
			batch.view_offsets_q.append(0)
		transport.send(1, NetProtocol.CH_INPUT, batch.encode())

	func last_snapshot() -> NetMessages.Snapshot:
		return snapshots[snapshots.size() - 1] if not snapshots.is_empty() else null

	func spawns_of(net_id: int) -> Array[NetMessages.EntitySpawn]:
		var found: Array[NetMessages.EntitySpawn] = []
		for spawn: NetMessages.EntitySpawn in spawns:
			if spawn.net_id == net_id:
				found.append(spawn)
		return found

	func notice_with_code(code: int) -> NetMessages.Notice:
		for notice: NetMessages.Notice in notices:
			if notice.code == code:
				return notice
		return null

	## net_id de los registros del último snapshot, ordenados.
	func visible_ids() -> Array[int]:
		var ids: Array[int] = []
		if not snapshots.is_empty():
			for record: EntityRecord in last_snapshot().records:
				ids.append(record.net_id)
		ids.sort()
		return ids


## Política de interés que puede esconder a los jugadores falsos (los de nombre «Bot…»).
class HidingPolicy:
	extends InterestPolicy

	var hide_bots: bool = false

	func is_relevant(_observer: NetEntity, entity: NetEntity, _was_relevant: bool) -> bool:
		return not (hide_bots and entity.display_name.begins_with("Bot"))


func after_each() -> void:
	_hooks.clear()
	for raw: ENetMultiplayerPeer in _raw_peers:
		raw.close()
	_raw_peers.clear()
	for attacker: RawEnetAttacker in _raw_attackers:
		attacker.close()
	_raw_attackers.clear()
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

## Zona de prueba y servidor escuchando en un puerto libre. [param configure] recibe el
## [ServerConfig] antes de arrancar.
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


func _hello(realm: int = VARDHEIM, player_name: String = "Ana",
		protocol_version: int = NetProtocol.PROTOCOL_VERSION, sim_hash: int = -1) -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.protocol_version = protocol_version
	hello.sim_hash = sim_hash if sim_hash >= 0 else _client_sim_hash()
	hello.realm = realm
	hello.display_name = player_name
	return hello.encode()


## Huella de la simulación calculada por el cliente sobre su propia instancia del personaje.
func _client_sim_hash(run_speed: float = 5.0) -> int:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	character.run_speed = run_speed
	_world.add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	_world.remove_child(character)
	character.free()
	return hash_value


func _connect_client(hello: PackedByteArray, auto_ready: bool = true,
		net_sim_spec: String = "") -> RawClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	transport.set_net_sim_spec(net_sim_spec)
	var client := RawClient.new(transport, hello)
	client.auto_ready = auto_ready
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "el cliente conecta")
	return client


## Un paso de física de los clientes: poll, ganchos (lo que envía cada prueba) y flush. El
## servidor hace el suyo en su propio _physics_process.
func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawClient in _clients:
		client.tick = _client_tick
		client.transport.poll(_client_tick)
	for hook: Callable in _hooks:
		hook.call(_client_tick)
	for client: RawClient in _clients:
		client.transport.flush()


func _run_frames(count: int) -> void:
	for _i: int in count:
		await _step()


## Avanza hasta que [param condition] sea verdadera. false si no ocurre en [param max_frames].
func _run_until(condition: Callable, max_frames: int = MAX_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await _step()
	return condition.call()


func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port, "*")
		probe.close()
		if error == OK:
			return port
	return -1


## Entra un cliente y espera a tener su alta. null si no la tiene.
func _join(player_name: String, realm: int = VARDHEIM) -> RawClient:
	var client: RawClient = _connect_client(_hello(realm, player_name))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "%s entra en el mundo" % player_name):
		return null
	return client


func _read_report() -> Dictionary:
	var path: String = ProjectSettings.globalize_path("res://build/test_zone_server_net_report.json")
	assert_eq(_server.write_report(path), OK, "se escribe el informe")
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("no se pudo leer el informe")
		return {}
	return json.data


# --- Pruebas ----------------------------------------------------------------------------------

func test_sim_hash_depends_on_the_character_settings() -> void:
	await _start_server()
	assert_eq(_server.get_sim_hash(), _client_sim_hash(),
			"el servidor y una instancia del cliente calculan la misma huella")
	assert_true(_server.get_sim_hash() != _client_sim_hash(6.5),
			"otra velocidad de carrera cambia la huella")


func test_handshake_spawns_the_player_and_streams_snapshots() -> void:
	await _start_server()
	var joined: Array[Vector2i] = []
	_server.player_joined.connect(func(peer_id: int, net_id: int) -> void:
		joined.append(Vector2i(peer_id, net_id)))
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var spawned: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(spawned, "llega el ENTITY_SPAWN propio"):
		return

	var welcome: NetMessages.Welcome = client.welcome
	if assert_not_null(welcome, "llegó el WELCOME"):
		assert_eq(welcome.zone_id, "test_world", "zona")
		assert_eq(welcome.tick_rate, 60, "60 ticks por segundo")
		assert_eq(welcome.snapshot_interval, NetProtocol.SNAPSHOT_INTERVAL_TICKS)
		assert_eq(welcome.max_input_batch, NetProtocol.MAX_INPUTS_PER_BATCH)
		assert_eq(welcome.max_rewind_ticks, NetProtocol.MAX_REWIND_TICKS)
		assert_eq(welcome.realm, VARDHEIM, "reino aceptado")
		assert_eq(welcome.channel, 0, "canal 0")
	var peer_ids: PackedInt32Array = _server.get_peer_ids()
	assert_eq(peer_ids.size(), 1, "un peer")
	var peer: ServerPeer = _server.get_peer(peer_ids[0])
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "el peer está en el mundo")
	assert_eq(peer.display_name, "Ana")
	assert_eq(peer.realm, VARDHEIM)
	assert_eq(joined, [Vector2i(peer.peer_id, peer.entity.net_id)], "player_joined")
	assert_eq(_server.get_player_count(), 1)

	var own: NetMessages.EntitySpawn = client.own_spawn
	assert_true(own.is_yours, "el bit «tuyo»")
	assert_eq(own.net_id, peer.entity.net_id, "net_id")
	assert_eq(own.kind, NetProtocol.EntityKind.PLAYER)
	assert_eq(own.realm, VARDHEIM)
	assert_eq(own.display_name, "Ana")
	assert_eq(own.spawn_tick, peer.entity.spawn_tick, "spawn_tick = tick S del alta")
	assert_eq(own.state.last_input_tick, own.spawn_tick, "el estado es «tras S»")
	assert_vec_near(own.state.position, ZoneFixture.VARDHEIM_SPAWNS[0], 1e-4,
			"en el primer punto de aparición de Vardheim")
	assert_true(own.state.grounded, "en el suelo")
	assert_vec_near(own.state.velocity, Vector3.ZERO, 1e-6, "velocidad 0")
	assert_true(own.state.equals_exact(PlayerState.decode(own.state.encode())),
			"el estado impuesto pasa por encode/decode")
	var history: StateHistory = _server.get_history()
	assert_true(history.has_tick(own.net_id, own.spawn_tick), "el historial graba el tick del alta")
	var at_spawn: StateHistory.Sample = history.sample(own.net_id, float(own.spawn_tick))
	if assert_not_null(at_spawn, "y se puede muestrear"):
		assert_vec_near(at_spawn.position, own.state.position, 1e-4, "con la posición del alta")

	# Snapshots: sin entradas reales, el servidor sustituye por la entrada neutra del alta.
	await _run_frames(40)
	assert_true(client.snapshots.size() >= 10, "llegan snapshots (%d)" % client.snapshots.size())
	var previous_tick: int = 0
	for snapshot: NetMessages.Snapshot in client.snapshots:
		assert_true(snapshot.server_tick > previous_tick, "los snapshots avanzan")
		previous_tick = snapshot.server_tick
		if assert_not_null(snapshot.own_state, "lleva el estado propio"):
			assert_eq(snapshot.own_state.last_input_tick, snapshot.server_tick,
					"el estado propio es el de «tras simular ese tick»")
			assert_vec_near(snapshot.own_state.position, own.state.position, 0.01,
					"sigue quieto en el punto de aparición")
		assert_eq(snapshot.input_ack_tick, snapshot.server_tick, "ack = último tick consumido")
		assert_true(snapshot.records.is_empty(), "solo está él")
		assert_eq(snapshot.server_tick % NetProtocol.SNAPSHOT_INTERVAL_TICKS,
				own.net_id % NetProtocol.SNAPSHOT_INTERVAL_TICKS,
				"los snapshots van en los ticks de la paridad de su net_id")
	var last: NetMessages.Snapshot = client.last_snapshot()
	assert_true(last.substitutions > 0, "las entradas sustituidas se cuentan")
	assert_eq(last.input_margin, NetProtocol.NO_MARGIN, "sin entradas no hay margen")
	assert_eq(last.own_teleport, 0)


func test_rejected_connections_get_a_reject_with_the_reason() -> void:
	await _start_server()
	var cases: Array[Dictionary] = [
		{"hello": _hello(VARDHEIM, "Ana", NetProtocol.PROTOCOL_VERSION + 1),
				"result": NetProtocol.Result.VERSION},
		{"hello": _hello(VARDHEIM, "Ana", NetProtocol.PROTOCOL_VERSION, 12345),
				"result": NetProtocol.Result.SIM_HASH},
		{"hello": _hello(NetProtocol.Realm.NONE, "Ana"), "result": NetProtocol.Result.REALM},
		{"hello": _hello(VARDHEIM, "ab"), "result": NetProtocol.Result.NAME},
		{"hello": PackedByteArray([1, 2, 3]), "result": NetProtocol.Result.MALFORMED},
	]
	for case: Dictionary in cases:
		var client: RawClient = _connect_client(case["hello"])
		var rejected: bool = await _run_until(func() -> bool: return client.reject != null)
		if not assert_true(rejected, "llega un REJECT (%s)" % NetProtocol.result_text(case["result"])):
			continue
		assert_eq(client.reject.result, case["result"], "motivo del rechazo")
		assert_eq(client.reject.text, NetProtocol.result_text(case["result"]), "texto en español")
		assert_null(client.welcome, "no hay WELCOME")
		assert_false(client.ready_sent, "no se envía nada más")
	await _run_frames(90)
	assert_eq(_server.get_peer_ids().size(), 0, "los peers rechazados se han ido")
	assert_eq(_server.get_player_count(), 0, "y no ocupan sitio")
	var report: Dictionary = _read_report()
	var rejects: Dictionary = report.get("rejects", {})
	assert_eq(rejects.size(), 5, "el informe cuenta cada motivo de rechazo")


func test_full_server_rejects_with_full() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_players = 2)
	_server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	var first: RawClient = await _join("Ana")
	if first == null:
		return
	var second: RawClient = _connect_client(_hello(VARDHEIM, "Bruno"))
	var rejected: bool = await _run_until(func() -> bool: return second.reject != null)
	assert_true(rejected, "el segundo recibe un REJECT")
	assert_eq(second.reject.result, NetProtocol.Result.FULL, "servidor lleno (el falso cuenta)")
	assert_eq(_server.get_player_count(), 2, "siguen dos")


func test_duplicate_name_is_rejected_while_the_first_player_is_connected() -> void:
	await _start_server()
	var first: RawClient = await _join("Álvaro")
	if first == null:
		return
	assert_true(_server.get_connected_names().has("Álvaro"), "el servidor conoce el nombre")
	# Mismo nombre con otras mayúsculas y sin tilde: se rechaza con NAME.
	var second: RawClient = _connect_client(_hello(VARDHEIM, "ALVARO"))
	var rejected: bool = await _run_until(func() -> bool: return second.reject != null)
	if not assert_true(rejected, "el segundo recibe un REJECT"):
		return
	assert_eq(second.reject.result, NetProtocol.Result.NAME, "nombre repetido")
	assert_null(second.welcome, "no hay WELCOME")
	assert_eq(_server.get_player_count(), 1, "sigue solo el primero")
	# Otro nombre sí entra.
	var third: RawClient = await _join("Bruno", SOLMARCH)
	if third == null:
		return
	assert_eq(_server.get_connected_names().size(), 2, "Álvaro y Bruno")
	# Cuando el primero se va, su nombre queda libre.
	var leave := NetMessages.ClientLeave.new()
	first.send_raw(NetProtocol.CH_RELIABLE, leave.encode())
	var gone: bool = await _run_until(func() -> bool:
		return not _server.get_connected_names().has("Álvaro"))
	assert_true(gone, "Álvaro se ha ido")
	var again: RawClient = await _join("Alvaro")
	assert_not_null(again, "y su nombre se puede volver a usar")


func test_inputs_move_the_player_and_the_snapshot_feeds_back() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var spawn_tick: int = client.own_spawn.spawn_tick
	var start: Vector3 = client.own_spawn.state.position
	var first_tick: int = spawn_tick + 3
	_hooks.append(func(_tick: int) -> void:
		# Entradas con un tick de antelación: la del tick T llega justo antes de simularse T.
		var newest: int = _server.get_tick() + 2
		if newest >= first_tick:
			client.send_inputs(newest, mini(4, newest - first_tick + 1), Vector2(0.0, 1.0),
					client.own_spawn.state.yaw))
	await _run_frames(90)

	var last: NetMessages.Snapshot = client.last_snapshot()
	assert_true(last.own_state.position.z < start.z - 3.0,
			"corre hacia delante (-Z): de z=%.2f a z=%.2f" % [start.z, last.own_state.position.z])
	assert_eq(last.own_state.last_input_tick, last.server_tick, "aplicó la entrada del tick")
	assert_true(last.input_margin >= 0 and last.input_margin <= 3,
			"margen de antelación %d" % last.input_margin)
	var earlier: NetMessages.Snapshot = client.snapshots[client.snapshots.size() - 6]
	assert_eq(last.substitutions, earlier.substitutions,
			"en régimen ya no se sustituyen entradas")
	assert_true(last.input_ack_tick >= last.server_tick and last.input_ack_tick <= last.server_tick + 3,
			"el ack va por delante del tick si hay entradas recibidas (%d, %d)"
			% [last.input_ack_tick, last.server_tick])
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_true(peer.rtt_ticks >= 1 and peer.rtt_ticks <= 4,
			"el servidor mide el RTT en ticks (%d)" % peer.rtt_ticks)
	assert_eq(peer.interp_delay_q, 32, "guarda el retardo de interpolación declarado")
	assert_true(peer.ack_snapshot_tick > 0, "y el último snapshot confirmado")
	var queue_stats: Dictionary = _read_report().get("inputs", {})
	assert_true(int(queue_stats.get("consumed", 0)) > 80, "el informe cuenta las entradas")


func test_players_see_each_other_and_leave_cleanly() -> void:
	await _start_server()
	var bot_id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	var left: Array[Vector2i] = []
	_server.player_left.connect(func(peer_id: int, net_id: int) -> void:
		left.append(Vector2i(peer_id, net_id)))
	var a: RawClient = await _join("Ana", VARDHEIM)
	var b: RawClient = await _join("Bruno", SOLMARCH)
	if a == null or b == null:
		return
	var a_id: int = a.own_spawn.net_id
	var b_id: int = b.own_spawn.net_id
	await _run_frames(30)

	# Cada uno recibe el SPAWN de los demás (el falso, el otro) y sus registros en los snapshots.
	assert_eq(a.spawns_of(a_id).size(), 1, "Ana recibe su propio SPAWN una vez")
	assert_eq(a.spawns_of(bot_id).size(), 1, "Ana ve al jugador falso")
	assert_eq(a.spawns_of(b_id).size(), 1, "y a Bruno")
	assert_eq(a.spawns_of(b_id)[0].display_name, "Bruno")
	assert_false(a.spawns_of(b_id)[0].is_yours, "el SPAWN ajeno no es «tuyo»")
	assert_eq(b.spawns_of(a_id).size(), 1, "Bruno ve a Ana")
	assert_eq(b.spawns_of(bot_id).size(), 1, "y al falso")
	assert_eq(a.spawns_of(bot_id)[0].display_name, "Bot-01")
	assert_eq(a.spawns_of(bot_id)[0].realm, SOLMARCH)
	var expected_for_a: Array[int] = [bot_id, b_id]
	expected_for_a.sort()
	assert_eq(a.visible_ids(), expected_for_a, "Ana ve en sus snapshots a Bruno y al falso, no a sí misma")
	var expected_for_b: Array[int] = [bot_id, a_id]
	expected_for_b.sort()
	assert_eq(b.visible_ids(), expected_for_b, "y Bruno a Ana y al falso")

	# Bruno sale con CLIENT_LEAVE: Ana recibe el DESPAWN con motivo «desconexión».
	var leave := NetMessages.ClientLeave.new()
	b.send_raw(NetProtocol.CH_RELIABLE, leave.encode())
	var despawned: bool = await _run_until(func() -> bool: return not a.despawns.is_empty())
	if not assert_true(despawned, "Ana recibe el DESPAWN de Bruno"):
		return
	var despawn: NetMessages.EntityDespawn = a.despawns[0]
	assert_eq(despawn.net_id, b_id, "es el de Bruno")
	assert_eq(despawn.reason, NetProtocol.DespawnReason.DISCONNECTED, "motivo: desconexión")
	assert_true(despawn.despawn_tick > a.own_spawn.spawn_tick and despawn.despawn_tick <= _server.get_tick(),
			"despawn_tick es el tick de la baja (%d)" % despawn.despawn_tick)
	await _run_frames(30)
	assert_null(_server.get_registry().get_entity(b_id), "Bruno ya no está en el registro")
	assert_false(_server.get_history().has_tick(b_id, _server.get_tick()),
			"ni su pista del historial")
	assert_true(_server.get_registry().is_quarantined(b_id, _server.get_tick()),
			"su id queda en cuarentena")
	assert_eq(_server.get_peer_ids().size(), 1, "solo queda Ana")
	assert_eq(left.size(), 1, "player_left")
	assert_eq(left[0].y, b_id)
	assert_false(a.visible_ids().has(b_id), "Bruno desaparece de los snapshots de Ana")
	assert_eq(_server.get_player_count(), 2, "Ana y el falso")

	# Un tercero que se corta sin avisar también da de baja (el ENet detecta el corte).
	var c: RawClient = await _join("Carla", VARDHEIM)
	if c == null:
		return
	assert_true(c.own_spawn.net_id != b_id, "el id de Bruno no se reutiliza en 10 s")
	var c_id: int = c.own_spawn.net_id
	_clients.erase(c)
	c.transport.close()
	var c_gone: bool = await _run_until(func() -> bool:
		for despawn_c: NetMessages.EntityDespawn in a.despawns:
			if despawn_c.net_id == c_id:
				return true
		return false)
	assert_true(c_gone, "Ana recibe el DESPAWN de Carla al cortarse su conexión")
	c.transport.free()


func test_unexpected_messages_count_strikes_by_session_state() -> void:
	await _start_server()
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return client.connected)
	if not assert_true(connected, "el cliente se conecta"):
		return
	var peer_id: int = _server.get_peer_ids()[0]
	var peer: ServerPeer = _server.get_peer(peer_id)
	assert_eq(peer.state, ServerPeer.State.LOADING, "cargando la zona")

	# Cargando: las entradas no tienen sentido.
	client.send_inputs(10, 1, Vector2.ZERO, 0.0)
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "INPUT_BATCH antes de entrar en el mundo")
	# Dos CLIENT_READY seguidos: el segundo sobra.
	client.send_ready()
	client.send_ready()
	var entered: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	assert_true(entered, "entra en el mundo")
	assert_eq(peer.strikes_total, 2, "el segundo CLIENT_READY es un aviso")
	# Dentro del mundo: otro CLIENT_READY, un mensaje del servidor al cliente y un lote mal formado.
	client.send_ready()
	client.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_SNAPSHOT, 1, 2, 3]))
	client.send_raw(NetProtocol.CH_INPUT, PackedByteArray([NetProtocol.MSG_INPUT_BATCH, 0, 0, 0]))
	await _run_frames(5)
	assert_eq(peer.strikes_total, 5, "tres avisos más")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "sin expulsión")
	assert_true(client.notices.is_empty(), "ni aviso al cliente")
	var report: Dictionary = _read_report()
	assert_eq(int((report.get("strikes", {}) as Dictionary).get("total", 0)), 5, "el informe cuenta los avisos")


func test_protocol_3_messages_do_not_count_as_strikes() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	# Cargando la zona, el /atascado no tiene sentido (como el resto de peticiones de jugador).
	var loading: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return loading.connected)
	if not assert_true(connected, "el cliente se conecta"):
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	if assert_not_null(loading.welcome, "llegó el WELCOME"):
		assert_eq(loading.welcome.realm_counts.size(), 3, "el WELCOME lleva el recuento por reino")
	loading.send_raw(NetProtocol.CH_RELIABLE, NetMessages.UnstuckRequest.new().encode())
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "UNSTUCK_REQUEST antes de entrar en el mundo es un aviso")
	loading.send_ready()
	var entered: bool = await _run_until(func() -> bool: return loading.own_spawn != null)
	if not assert_true(entered, "entra en el mundo"):
		return
	# Dentro del mundo, el /atascado bien formado se acepta (F3 hará lo que pide) y no suma nada.
	loading.send_raw(NetProtocol.CH_RELIABLE, NetMessages.UnstuckRequest.new().encode())
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "UNSTUCK_REQUEST en el mundo no suma avisos")
	# Los comandos de depuración con id fijo de la versión 4 y datos válidos tampoco, aunque F3 y F4 aún
	# no les hayan puesto manejador.
	for command: NetMessages.DebugCommand in [
			NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_RESET),
			NetMessages.DebugCommand.fort_owner(NetProtocol.Realm.SOLMARCH),
			NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_KILL_CAPTAIN),
			NetMessages.DebugCommand.fort_capture_speed(10), NetMessages.DebugCommand.npc_debug(true),
			NetMessages.DebugCommand.simple(NetProtocol.DEBUG_UNSTUCK)]:
		loading.send_raw(NetProtocol.CH_RELIABLE, command.encode())
	await _run_frames(5)
	assert_eq(peer.strikes_total, 1, "los comandos 7 a 12 válidos no suman avisos")
	# Lo que está mal formado o no es de un cliente sí cuenta.
	loading.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_UNSTUCK_REQUEST, 0]))
	loading.send_raw(NetProtocol.CH_RELIABLE,
			PackedByteArray([NetProtocol.MSG_DEBUG_COMMAND, NetProtocol.DEBUG_FORT_OWNER, 9]))
	loading.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.Scoreboard.new().encode())
	loading.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.ObjectState.from_fortress(1, 1, FortressState.new()).encode())
	await _run_frames(5)
	assert_eq(peer.strikes_total, 5, "un /atascado con datos, fort_owner 9 y dos mensajes del servidor")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "sin expulsión")


func test_flooding_gets_the_client_kicked_with_a_notice() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var peer_id: int = _server.get_peer_ids()[0]
	# Mensajes de un tipo que nadie envía al servidor, muy por encima del ritmo permitido.
	for i: int in 120:
		client.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, i]))
	var kicked: bool = await _run_until(func() -> bool:
		return client.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	if not assert_true(kicked, "el cliente recibe el NOTICE de expulsión"):
		return
	assert_true(client.notice_with_code(NetProtocol.NoticeCode.KICK).text.contains("Expulsado"),
			"con un texto en español")
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer(peer_id) == null)
	assert_true(gone, "el peer expulsado se da de baja")
	assert_null(_server.get_registry().get_entity(net_id), "y su personaje desaparece")
	var disconnected: bool = await _run_until(func() -> bool:
		return client.disconnected or client.failed)
	assert_true(disconnected, "el servidor corta la conexión después del aviso")
	var report: Dictionary = _read_report()
	var kicks: Array = report.get("kicks", [])
	if assert_eq(kicks.size(), 1, "el informe registra la expulsión"):
		assert_eq(int((kicks[0] as Dictionary).get("net_id", 0)), net_id)
		assert_false(String((kicks[0] as Dictionary).get("reason", "")).is_empty(), "con su motivo")
	var list: Array = report.get("player_list", [])
	assert_true(list.size() == 1 and bool((list[0] as Dictionary).get("kicked", false)),
			"y marca al jugador como expulsado")


## Las expulsiones del informe son las últimas max_logged_kicks, pero se cuentan todas (hallazgo S3:
## la lista crecía con cada expulsión, sin límite).
func test_kick_list_in_the_report_is_bounded_but_counts_every_kick() -> void:
	await _start_server()
	_server.max_logged_kicks = 10
	for i: int in 25:
		var peer_id: int = 9000 + i
		_server_transport.peer_authenticating.emit(peer_id)
		# Mensajes antes de autenticarse: cada uno es un aviso y a los 50 se le expulsa.
		for _j: int in 50:
			_server_transport.packet_received.emit(peer_id, NetMessages.ClientReady.new().encode())
	var report: Dictionary = _read_report()
	var kicks: Array = report.get("kicks", [])
	assert_eq(kicks.size(), 10, "el informe conserva las últimas 10 expulsiones")
	assert_eq(int((report.get("strikes", {}) as Dictionary).get("kicks_total", 0)), 25,
			"pero cuenta las 25")
	assert_eq(int((kicks[kicks.size() - 1] as Dictionary).get("peer_id", 0)), 9024,
			"la última es la más reciente")
	assert_eq(int((kicks[0] as Dictionary).get("peer_id", 0)), 9015, "y la primera, la décima desde el final")


## Expulsado un cliente (50 avisos), no puede volver en un RTT con los avisos a 0 y los cubos llenos
## (hallazgo S6): durante el enfriamiento, su IP recibe un REJECT nada más conectar. Pasado el
## enfriamiento, vuelve a entrar.
func test_a_kicked_address_is_rejected_during_the_cooldown() -> void:
	await _start_server()
	_server.kick_cooldown_ticks = 240
	var address: Array[String] = ["203.0.113.7"]
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		return address[0]
	var abuser: RawClient = await _join("Ana")
	if abuser == null:
		return
	for i: int in 120:
		abuser.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, i]))
	var kicked: bool = await _run_until(func() -> bool:
		return abuser.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	if not assert_true(kicked, "el abusón es expulsado"):
		return
	await _run_until(func() -> bool: return _server.get_player_count() == 0)
	assert_eq(_server.get_cooldown_count(), 1, "y su IP queda en enfriamiento")
	# Vuelve al momento, con otro nombre: rechazado antes de autenticarse.
	var again: RawClient = _connect_client(_hello(VARDHEIM, "Bruno"))
	var rejected: bool = await _run_until(func() -> bool: return again.reject != null)
	if assert_true(rejected, "la reconexión inmediata recibe un REJECT"):
		assert_eq(again.reject.result, NetProtocol.Result.TOO_MANY_CONNECTIONS, "por exceso de conexiones")
	assert_null(again.welcome, "sin WELCOME")
	assert_eq(_server.get_player_count(), 0, "y no ocupa sitio")
	# Otra IP no está afectada.
	address[0] = "198.51.100.9"
	var other: RawClient = await _join("Carla")
	assert_not_null(other, "otra IP entra con normalidad")
	# Pasado el enfriamiento, la IP del abusón vuelve a entrar.
	address[0] = "203.0.113.7"
	await _run_frames(260)
	var back: RawClient = await _join("Diana")
	assert_not_null(back, "pasado el enfriamiento, vuelve a entrar")
	var rejects: Dictionary = _read_report().get("rejects", {})
	assert_eq(int(rejects.get(NetProtocol.result_text(NetProtocol.Result.TOO_MANY_CONNECTIONS), 0)), 1,
			"el informe cuenta el rechazo")


## Desde loopback no hay tope por IP, así que el enfriamiento va por el nombre (sin mayúsculas ni
## tildes, como el resto de la comprobación de nombres).
func test_a_kicked_name_from_loopback_is_rejected_during_the_cooldown() -> void:
	await _start_server()
	_server.kick_cooldown_ticks = 240
	var abuser: RawClient = await _join("Álvaro")
	if abuser == null:
		return
	for i: int in 120:
		abuser.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([0x7F, i]))
	var kicked: bool = await _run_until(func() -> bool:
		return abuser.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	if not assert_true(kicked, "el abusón es expulsado"):
		return
	await _run_until(func() -> bool: return _server.get_player_count() == 0)
	var again: RawClient = _connect_client(_hello(VARDHEIM, "ALVARO"))
	var rejected: bool = await _run_until(func() -> bool: return again.reject != null)
	if assert_true(rejected, "volver con el mismo nombre recibe un REJECT"):
		assert_eq(again.reject.result, NetProtocol.Result.TOO_MANY_CONNECTIONS)
	var other: RawClient = await _join("Bruno")
	assert_not_null(other, "con otro nombre, desde loopback, se entra")
	await _run_frames(260)
	var back: RawClient = await _join("Alvaro")
	assert_not_null(back, "pasado el enfriamiento, el nombre vuelve a estar libre")


## Las entradas vencidas se purgan al siguiente alta de enfriamiento: el diccionario no crece sin
## límite.
func test_expired_cooldowns_are_purged() -> void:
	await _start_server()
	_server.kick_cooldown_ticks = 30
	var address: Array[String] = ["203.0.113.1"]
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		return address[0]
	for i: int in 4:
		address[0] = "203.0.113.%d" % (1 + i)
		_server_transport.peer_authenticating.emit(9100 + i)
		for _j: int in 50:
			_server_transport.packet_received.emit(9100 + i, NetMessages.ClientReady.new().encode())
	assert_eq(_server.get_cooldown_count(), 4, "cuatro IP expulsadas")
	await _run_frames(40)
	address[0] = "203.0.113.50"
	_server_transport.peer_authenticating.emit(9200)
	for _j: int in 50:
		_server_transport.packet_received.emit(9200, NetMessages.ClientReady.new().encode())
	assert_eq(_server.get_cooldown_count(), 1, "las vencidas se purgan; solo queda la nueva")


## El RTT en ticks que mide el servidor con el ack de snapshot lo decide el cliente: un tramposo
## que atrase sus acks se haría pasar por alguien con lag y obtendría el rebobinado máximo de la
## fase 3 (hallazgo S4). El servidor lo acota con una fuente independiente: el RTT de ENet más el
## retardo del simulador del propio servidor, más un margen.
func test_a_client_cannot_fake_lag_with_late_acks() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	client.ack_lag_ticks = 20
	client.interp_delay_q = NetProtocol.MAX_INTERP_DELAY_Q
	_hooks.append(func(_tick: int) -> void:
		client.send_inputs(_server.get_tick() + 2, 1, Vector2(0.0, 1.0), 0.0))
	await _run_frames(300)
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	var bound: int = ceili(_server_transport.get_rtt_ms(peer.peer_id) * 60.0 / 1000.0) \
			+ _server_transport.get_sim_round_trip_ticks() + ZoneServer.RTT_SLACK_TICKS
	assert_true(peer.rtt_ticks <= bound,
			"el RTT medido (%d ticks) no pasa del que permite ENet (%d)" % [peer.rtt_ticks, bound])
	assert_true(peer.rtt_ticks <= 6, "en loopback es de pocos ticks (%d)" % peer.rtt_ticks)
	# El máximo de la ventana, que usa el tope del rebobinado, también lo acota la fuente independiente:
	# atrasar los acks no da más que el RTT de ENet más el margen.
	assert_true(peer.rtt_peak_ticks >= peer.rtt_ticks and peer.rtt_peak_ticks <= bound,
			"el máximo del RTT (%d ticks) tampoco pasa de lo que permite ENet (%d)"
			% [peer.rtt_peak_ticks, bound])
	assert_eq(peer.strikes_total, 0, "sin avisos: fingir lag no es un paquete ilegal")
	# R1: la cota inferior (el mínimo del rebobinado para la defensa) sale del RTT de ENet, no de los
	# acks que el cliente atrasa.
	var enet_ticks: int = floori(_server_transport.get_rtt_ms(peer.peer_id) * 60.0 / 1000.0)
	assert_true(absi(peer.rtt_floor_ticks - enet_ticks) <= 1,
			"rtt_floor_ticks (%d) es el RTT de ENet (%d ticks)" % [peer.rtt_floor_ticks, enet_ticks])
	assert_true(peer.rtt_floor_ticks < 20, "y no los 20 ticks de ack atrasado")


## El simulador de red del propio servidor sí cuenta: es retardo real para el servidor.
func test_the_server_side_net_sim_still_raises_the_measured_rtt() -> void:
	await _start_server(func(config: ServerConfig) -> void:
		config.net_sim_spec = "rtt=200,jitter=0,loss=0,dup=0,seed=3")
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null, 900)
	if not assert_true(joined, "entra en el mundo"):
		return
	_hooks.append(func(_tick: int) -> void:
		client.send_inputs(_server.get_tick() + 14, 4, Vector2(0.0, 1.0), 0.0))
	await _run_frames(240)
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_true(peer.rtt_ticks >= 10,
			"con 200 ms de retardo simulado (12 ticks) el RTT medido lo refleja (%d)" % peer.rtt_ticks)
	assert_true(peer.rtt_peak_ticks >= peer.rtt_ticks, "y el máximo de la ventana nunca baja del mínimo (%d)"
			% peer.rtt_peak_ticks)


## interp_delay_q no puede pasar del máximo del reloj de interpolación del cliente (12 ticks × 8):
## el servidor lo limita y lo cuenta como aviso.
func test_interp_delay_above_the_clients_maximum_is_clamped_and_costs_a_strike() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	client.interp_delay_q = 255
	client.send_inputs(_server.get_tick() + 2, 1, Vector2.ZERO, 0.0)
	await _run_frames(5)
	assert_eq(peer.interp_delay_q, NetProtocol.MAX_INTERP_DELAY_Q, "se limita al máximo del cliente")
	assert_eq(peer.strikes_total, 1, "y suma un aviso")
	assert_eq(_strike_reasons().get("retardo de interpolación fuera de rango", 0), 1, "con su motivo")
	client.interp_delay_q = NetProtocol.MAX_INTERP_DELAY_Q
	client.send_inputs(_server.get_tick() + 2, 1, Vector2.ZERO, 0.0)
	await _run_frames(5)
	assert_eq(peer.interp_delay_q, NetProtocol.MAX_INTERP_DELAY_Q, "el máximo legítimo se acepta")
	assert_eq(peer.strikes_total, 1, "sin más avisos")


## Un cliente ENet en bruto (sin SceneMultiplayer) que manda paquetes que no son del protocolo antes del
## HELLO: antes registraban un error del motor por paquete (el ejecutor falla con cualquiera), se
## saltaban los limitadores y los avisos, solo los cortaba el auth_timeout de 5 s y 2000 paquetes
## llevaban el tick a 28 ms (hallazgo S1). Ahora cada uno suma un aviso, a los 50 se le expulsa y el
## tick no pasa de su presupuesto de 16 ms.
func test_foreign_packets_before_the_hello_get_the_sender_kicked() -> void:
	await _start_server()
	var attacker := RawEnetAttacker.new()
	assert_eq(attacker.connect_to(_port), OK, "el atacante conecta")
	_raw_attackers.append(attacker)
	_hooks.append(func(_tick: int) -> void: attacker.poll())
	var seen: bool = await _run_until(func() -> bool:
		return attacker.is_connected_to_server() and _server.get_peer_ids().size() == 1, 300)
	if not assert_true(seen, "el servidor ve al peer que se autentica"):
		return
	for _i: int in 2000:
		attacker.send(PackedByteArray([3, 1]), 1)
	attacker.flush()
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty(), 300)
	assert_true(gone, "el peer se expulsa en cuanto suma 50 avisos, sin esperar a los 5 s")
	var reasons: Dictionary = _strike_reasons()
	assert_eq(int(reasons.get(ZoneServer.DISCARDED_REASON, 0)), ServerPeer.STRIKE_LIMIT,
			"cada paquete ajeno es un aviso, hasta los 50")
	var report: Dictionary = _read_report()
	assert_eq((report.get("kicks", []) as Array).size(), 1, "una expulsión")
	assert_eq(_server.get_player_count(), 0, "y nadie ocupa sitio")
	var tick_max: int = _server.get_metrics().get_max_us(&"tick")
	assert_true(tick_max < 16000, "el tick más largo no pasa de 16 ms (%d µs)" % tick_max)


## Lo mismo con el peer ya autenticado y dentro del mundo: RPC, SIMPLIFY_PATH, SPAWN y órdenes de
## sistema. Quien juega con normalidad no se entera.
func test_foreign_packets_after_the_hello_get_the_sender_kicked_and_not_the_others() -> void:
	await _start_server()
	var honest: RawClient = await _join("Ana")
	if honest == null:
		return
	var attacker := RawEnetAttacker.new()
	assert_eq(attacker.connect_to(_port), OK, "el atacante conecta")
	_raw_attackers.append(attacker)
	_hooks.append(func(_tick: int) -> void: attacker.poll())
	var connected: bool = await _run_until(func() -> bool: return attacker.is_connected_to_server(), 300)
	if not assert_true(connected, "el atacante conecta"):
		return
	attacker.send_auth(_hello(VARDHEIM, "Malvado"))
	attacker.flush()
	var welcomed: bool = await _run_until(func() -> bool:
		return attacker.server_confirmed and not attacker.auth_messages.is_empty(), 300)
	if not assert_true(welcomed, "contesta WELCOME"):
		return
	assert_eq(NetMessages.peek_auth_result(attacker.auth_messages[0]), NetProtocol.Result.OK)
	attacker.send_confirmation()
	attacker.flush()
	var is_loading: Callable = func() -> bool:
		var peer: ServerPeer = _peer_named("Malvado")
		return peer != null and peer.state == ServerPeer.State.LOADING
	var admitted: bool = await _run_until(is_loading, 300)
	if not assert_true(admitted, "y lo admite (cargando la zona)"):
		return
	var mallory: ServerPeer = _peer_named("Malvado")
	var flood: int = 300
	for i: int in flood:
		attacker.send(PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0, 0, 0]), 0)  # SIMPLIFY_PATH
		attacker.send(PackedByteArray([0, 1, 2, 3, 4, 5, 6]), 0)  # RPC
		attacker.send(PackedByteArray([4, 1, 2, 3, 4, 5, 6, 7, 8]), 0)  # SPAWN
		attacker.send(PackedByteArray([7, 1, 2, 0, 0, 0]), 0)  # SYS ADD_PEER
	attacker.flush()
	var kicked: bool = await _run_until(func() -> bool: return _peer_named("Malvado") == null, 300)
	assert_true(kicked, "el atacante acaba expulsado")
	assert_true(mallory.strikes_total >= ServerPeer.STRIKE_LIMIT, "tras sumar 50 avisos (%d)"
			% mallory.strikes_total)
	assert_eq(int(_strike_reasons().get(ZoneServer.DISCARDED_REASON, 0)), ServerPeer.STRIKE_LIMIT,
			"todos por paquetes ajenos")
	# El otro jugador, a lo suyo.
	var honest_peer: ServerPeer = _peer_of(honest.own_spawn.net_id)
	assert_eq(honest_peer.strikes_total, 0, "el jugador honrado no suma avisos")
	assert_eq(honest_peer.state, ServerPeer.State.IN_WORLD, "y sigue en el mundo")
	var snapshots_before: int = honest.snapshots.size()
	await _run_frames(30)
	assert_true(honest.snapshots.size() > snapshots_before + 5, "recibiendo snapshots")
	var tick_max: int = _server.get_metrics().get_max_us(&"tick")
	assert_true(tick_max < 16000, "el tick más largo no pasa de 16 ms (%d µs)" % tick_max)


func test_debug_commands_need_the_flag() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var teleport: NetMessages.DebugCommand = NetMessages.DebugCommand.teleport(Vector3(7.0, 0.5, -9.0))
	client.send_raw(NetProtocol.CH_RELIABLE, teleport.encode())
	await _run_frames(10)
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.strikes_total, 1, "sin --debug-commands es un aviso")
	assert_eq(peer.entity.teleport_counter, 0, "y no hay teletransporte")
	assert_vec_near(peer.entity.get_position(), ZoneFixture.VARDHEIM_SPAWNS[0], 0.05,
			"el jugador sigue en su sitio")


func test_debug_teleport_with_the_flag() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var target := Vector3(7.0, 0.5, -9.0)
	client.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(target).encode())
	var teleported: bool = await _run_until(func() -> bool:
		return client.last_snapshot() != null and client.last_snapshot().own_teleport == 1)
	if not assert_true(teleported, "el snapshot lleva el contador de teletransporte propio"):
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.strikes_total, 0, "sin avisos")
	assert_eq(peer.entity.teleport_counter, 1)
	var own: PlayerState = client.last_snapshot().own_state
	assert_true(absf(own.position.x - 7.0) < 0.1 and absf(own.position.z + 9.0) < 0.1,
			"el estado propio está en el destino (%s)" % own.position)
	# Un destino fuera de rango o no finito es un aviso y no mueve a nadie.
	client.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(Vector3(1.0e9, 0.0, 0.0)).encode())
	client.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(Vector3(NAN, 0.0, 0.0)).encode())
	await _run_frames(10)
	assert_eq(peer.strikes_total, 2, "dos avisos")
	assert_eq(peer.entity.teleport_counter, 1, "sin más teletransportes")


func test_interest_policy_spawns_and_despawns_out_of_interest() -> void:
	await _start_server()
	var policy := HidingPolicy.new()
	_server.interest_policy = policy
	var bot_id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	await _run_frames(20)
	assert_eq(client.spawns_of(bot_id).size(), 1, "el falso es relevante")
	assert_true(client.visible_ids().has(bot_id), "y está en los snapshots")

	policy.hide_bots = true
	var hidden: bool = await _run_until(func() -> bool: return not client.despawns.is_empty(), 60)
	if not assert_true(hidden, "al dejar de ser relevante llega un DESPAWN (cada 6 ticks, como mucho)"):
		return
	assert_eq(client.despawns[0].net_id, bot_id)
	assert_eq(client.despawns[0].reason, NetProtocol.DespawnReason.OUT_OF_INTEREST, "motivo 0")
	await _run_frames(10)
	assert_false(client.visible_ids().has(bot_id), "deja de estar en los snapshots")
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_false(peer.relevant.has(bot_id), "y en el conjunto relevante del peer")

	policy.hide_bots = false
	var back: bool = await _run_until(func() -> bool: return client.spawns_of(bot_id).size() == 2, 60)
	assert_true(back, "al volver a ser relevante llega otro SPAWN")
	await _run_frames(10)
	assert_true(client.visible_ids().has(bot_id), "y reaparece en los snapshots")


func test_handshake_and_snapshots_with_a_network_simulator() -> void:
	await _start_server(func(config: ServerConfig) -> void:
		config.net_sim_spec = "rtt=100,jitter=10,loss=0,dup=0,seed=5")
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null, 600)
	if not assert_true(joined, "con 100 ms de RTT también entra en el mundo"):
		return
	_hooks.append(func(_tick: int) -> void:
		var newest: int = _server.get_tick() + 12
		if newest > client.own_spawn.spawn_tick + 3:
			client.send_inputs(newest, 4, Vector2(0.0, 1.0), client.own_spawn.state.yaw))
	await _run_frames(120)
	assert_true(client.snapshots.size() > 20, "llegan snapshots (%d)" % client.snapshots.size())
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_true(peer.rtt_ticks >= 3, "el RTT medido incluye el retardo simulado (%d ticks)"
			% peer.rtt_ticks)
	assert_true(client.last_snapshot().own_state.position.z < client.own_spawn.state.position.z - 2.0,
			"y las entradas surten efecto")


func test_client_that_never_sends_ready_is_kicked_after_the_loading_timeout() -> void:
	await _start_server()
	_server.loading_timeout_ticks = 90
	var client: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return client.connected)
	if not assert_true(connected, "el cliente se conecta y empieza a cargar"):
		return
	assert_eq(_server.get_player_count(), 1, "cargando la zona ya ocupa un sitio")
	var kicked: bool = await _run_until(func() -> bool:
		return client.notice_with_code(NetProtocol.NoticeCode.KICK) != null, 400)
	if assert_true(kicked, "pasado el límite de carga recibe un NOTICE de expulsión"):
		assert_true(client.notice_with_code(NetProtocol.NoticeCode.KICK).text.contains("carga"),
				"que explica el motivo")
	await _run_frames(10)
	assert_eq(_server.get_peer_ids().size(), 0, "y se le da de baja")
	assert_eq(_server.get_player_count(), 0)


func test_client_that_never_sends_hello_is_dropped_by_the_auth_timeout() -> void:
	await _start_server()
	# Se anula el plazo propio del servidor para el HELLO: aquí actúa el de NetTransport (5 s).
	_server.hello_timeout_ticks = 100000
	# Sin HELLO: el cliente conecta pero no envía nada en la autenticación.
	var client: RawClient = _connect_client(PackedByteArray())
	var seen: bool = await _run_until(func() -> bool: return _server.get_peer_ids().size() == 1, 120)
	if not assert_true(seen, "el servidor ve al peer que se autentica"):
		return
	assert_eq(_server.get_player_count(), 0, "un peer que se autentica no ocupa sitio")
	var dropped: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty(),
			int(NetTransport.AUTH_TIMEOUT_SECONDS * 60.0) + 240)
	assert_true(dropped, "pasado el tiempo de autenticación (5 s) el peer se da de baja")
	assert_true(client.failed or client.disconnected, "y el cliente ve que se corta")


## Una IP no puede ocupar todas las plazas de ENet con conexiones que nunca mandan el HELLO
## (hallazgo S2): el tope por IP se aplica al conectar, no solo al llegar el HELLO. Con
## max_players = 2 hay 6 plazas; una IP con 6 conexiones ociosas dejaba al séptimo cliente, legítimo,
## sin respuesta (ENet descarta su conexión en silencio). Las conexiones ociosas son ENet en bruto
## (sin SceneMultiplayer), como las de un atacante.
func test_idle_connections_cannot_exhaust_the_slots_of_one_ip() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_players = 2)
	# Solo se prueba el tope por IP: el plazo del HELLO no debe cortar nada durante la prueba.
	_server.hello_timeout_ticks = 100000
	var opened: Array[int] = [0]
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		opened[0] += 1
		return "203.0.113.7" if opened[0] <= 6 else "198.51.100.9"
	var idle: Array[ENetMultiplayerPeer] = []
	for _i: int in 6:
		var raw := ENetMultiplayerPeer.new()
		assert_eq(raw.create_client("127.0.0.1", _port, NetProtocol.CUSTOM_CHANNELS), OK)
		idle.append(raw)
		_raw_peers.append(raw)
		await _run_frames(3)
	_hooks.append(func(_tick: int) -> void:
		for raw: ENetMultiplayerPeer in idle:
			# Un peer que el servidor ha cortado queda inactivo y poll() registraría un error.
			if raw.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
				raw.poll())
	var connected_count: Callable = func() -> int:
		var count: int = 0
		for raw: ENetMultiplayerPeer in idle:
			if raw.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
				count += 1
		return count
	await _run_frames(60)
	assert_eq(connected_count.call(), 4,
			"el servidor corta lo que pasa del tope: quedan 4 conexiones de la IP")
	var legit: RawClient = _connect_client(_hello(VARDHEIM, "Ana"))
	var answered: bool = await _run_until(func() -> bool:
		return legit.welcome != null or legit.reject != null, 120)
	assert_true(answered, "el cliente legítimo recibe respuesta en menos de 120 ticks")
	assert_not_null(legit.welcome, "y es un WELCOME: las plazas no están agotadas")
	assert_eq(_strike_reasons().size(), 0, "sin avisos")
	var rejects: Dictionary = _read_report().get("rejects", {})
	assert_eq(int(rejects.get(NetProtocol.result_text(NetProtocol.Result.TOO_MANY_CONNECTIONS), 0)), 2,
			"el informe cuenta los dos rechazos")


## Un cliente que conecta y no manda el HELLO se corta en cuanto vence el plazo propio del servidor
## (90 ticks), mucho antes que los 5 s de la autenticación de SceneMultiplayer.
func test_a_connection_without_hello_is_dropped_after_the_hello_deadline() -> void:
	await _start_server()
	assert_eq(_server.hello_timeout_ticks, ZoneServer.HELLO_TIMEOUT_TICKS, "90 ticks por defecto")
	var client: RawClient = _connect_client(PackedByteArray())
	var seen: bool = await _run_until(func() -> bool: return _server.get_peer_ids().size() == 1, 120)
	if not assert_true(seen, "el servidor ve al peer que se autentica"):
		return
	var seen_at: int = _server.get_tick()
	var dropped: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty(),
			ZoneServer.HELLO_TIMEOUT_TICKS + 90)
	assert_true(dropped, "el peer sin HELLO se da de baja pasado el plazo")
	assert_true(_server.get_tick() - seen_at >= ZoneServer.HELLO_TIMEOUT_TICKS - 10,
			"no antes de tiempo (%d ticks)" % (_server.get_tick() - seen_at))
	assert_true(_server.get_tick() - seen_at < int(NetTransport.AUTH_TIMEOUT_SECONDS * 60.0),
			"y bastante antes de los 5 s de la autenticación")
	var closed: bool = await _run_until(func() -> bool: return client.failed or client.disconnected, 120)
	assert_true(closed, "el cliente ve que se corta")
	var rejects: Dictionary = _read_report().get("rejects", {})
	assert_eq(int(rejects.get(ZoneServer.HELLO_TIMEOUT_REASON, 0)), 1, "el informe lo cuenta")
	# Un cliente que sí manda el HELLO a tiempo no se ve afectado.
	var honest: RawClient = await _join("Ana")
	assert_not_null(honest, "uno normal entra")


func test_stop_notifies_the_clients_and_closes_the_transport() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	_server.stop("Mantenimiento")
	assert_false(_server.is_stopped(), "con clientes conectados se espera a que se vayan")
	var notified: bool = await _run_until(func() -> bool:
		return client.notice_with_code(NetProtocol.NoticeCode.SHUTDOWN) != null)
	if assert_true(notified, "el cliente recibe el NOTICE de cierre"):
		assert_eq(client.notice_with_code(NetProtocol.NoticeCode.SHUTDOWN).text, "Mantenimiento")
	var stopped: bool = await _run_until(func() -> bool: return _server.is_stopped(), 90)
	assert_true(stopped, "el servidor termina de cerrarse")
	assert_false(_server_transport.is_server(), "y cierra el transporte")
	assert_eq(_server.get_player_count(), 0)


# --- Seguridad (docs/red.md, sección 12): los limitadores, el tope por IP y los avisos -----------

## Avisos del informe por motivo: {motivo: veces}.
func _strike_reasons() -> Dictionary:
	var report: Dictionary = _read_report()
	return (report.get("strikes", {}) as Dictionary).get("by_reason", {})


## El peer con ese nombre (null si no hay ninguno).
func _peer_named(player_name: String) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.display_name == player_name:
			return peer
	return null


## El peer cuyo personaje es el de ese net_id (null si no hay ninguno).
func _peer_of(net_id: int) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer
	return null


func test_input_flood_trips_the_unreliable_limiter() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	assert_eq(peer.strikes_total, 0, "un cliente educado no suma avisos")
	# 40 lotes válidos en el mismo tick: la ráfaga de no fiables admite 30 (más lo que recupera,
	# 2 por tick); el resto se descarta y cada uno suma un aviso.
	var next_tick: int = _server.get_tick() + 5
	for i: int in 40:
		client.send_inputs(next_tick + i % 20, 1, Vector2(0.0, 1.0), 0.0)
	await _run_frames(5)
	assert_true(peer.strikes_total >= 6 and peer.strikes_total <= 12,
			"se descartan los lotes que pasan de la ráfaga (%d avisos)" % peer.strikes_total)
	assert_eq(_strike_reasons().get("exceso de ritmo", 0), peer.strikes_total,
			"y todos los avisos son por exceso de ritmo")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "sin llegar a la expulsión")
	assert_true(client.notices.is_empty(), "ni aviso al cliente")
	# Con calma, en cambio, el ritmo normal (un lote por tick) no cuesta ningún aviso.
	var strikes_before: int = peer.strikes_total
	for _i: int in 90:
		client.send_inputs(_server.get_tick() + 6, 4, Vector2.ZERO, 0.0)
		await _run_frames(1)
	assert_eq(peer.strikes_total, strikes_before, "un lote por tick no es exceso de ritmo")


## Un parón del servidor (el proceso se queda sin ejecutarse) hace que los lotes de entradas que el
## cliente siguió mandando lleguen todos juntos en el primer poll posterior: no es exceso de ritmo
## (hallazgo N2). Sin crédito por parón, el cubo no se recarga porque el tick no avanza y el cliente
## honrado suma un aviso por lote y es expulsado.
func test_a_server_stall_does_not_get_an_honest_client_kicked() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	_hooks.append(func(_tick: int) -> void:
		client.send_inputs(_server.get_tick() + 2, 4, Vector2(0.0, 1.0), 0.0))
	await _run_frames(30)
	assert_eq(peer.strikes_total, 0, "antes del parón, ningún aviso")
	_server.set_physics_process(false)
	await _run_frames(90)
	_server.set_physics_process(true)
	await _run_frames(30)
	assert_eq(peer.strikes_total, 0, "tras un parón de 90 ticks, ningún aviso")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "el cliente sigue en el mundo")
	assert_null(client.notice_with_code(NetProtocol.NoticeCode.KICK), "sin NOTICE de expulsión")
	var report: Dictionary = _read_report()
	assert_eq((report.get("kicks", []) as Array).size(), 0, "el informe no registra expulsiones")
	assert_eq(int((report.get("strikes", {}) as Dictionary).get("total", 0)), 0,
			"ni avisos")


func test_reliable_flood_trips_the_reliable_limiter() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	# 30 teletransportes válidos a la vez: los fiables admiten una ráfaga de 20 (el CLIENT_READY
	# del alta ya gastó una ficha) más 1 cada 6 ticks, así que el resto se descarta con un aviso
	# cada uno.
	for i: int in 30:
		client.send_raw(NetProtocol.CH_RELIABLE,
				NetMessages.DebugCommand.teleport(Vector3(float(i), 0.5, 0.0)).encode())
	await _run_frames(8)
	assert_true(peer.strikes_total >= 8 and peer.strikes_total <= 11,
			"los fiables que pasan de la ráfaga suman avisos (%d)" % peer.strikes_total)
	assert_eq(_strike_reasons().get("exceso de ritmo", 0), peer.strikes_total,
			"por exceso de ritmo")
	var teleports: int = int(_read_report().get("teleports", 0))
	assert_true(teleports >= 19 and teleports <= 21,
			"se aplican los que caben en la ráfaga, que ya gastó el CLIENT_READY (%d)" % teleports)
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "y no hay expulsión con menos de 50 avisos")


func test_bytes_limiter_drops_big_packets_even_below_the_packet_rate() -> void:
	await _start_server()
	var client: RawClient = await _join("Ana")
	if client == null:
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	# 5 paquetes de 1000 B (el tipo de un lote, mal formados): 4 KB de ráfaga de bytes dan para 4.
	var big: PackedByteArray = PackedByteArray()
	big.resize(1000)
	big[0] = NetProtocol.MSG_INPUT_BATCH
	for _i: int in 5:
		client.send_raw(NetProtocol.CH_INPUT, big)
	await _run_frames(5)
	var reasons: Dictionary = _strike_reasons()
	assert_eq(reasons.get("lote de entradas mal formado", 0), 4, "los 4 primeros llegan a decodificarse")
	assert_eq(reasons.get("exceso de ritmo", 0), 1, "el quinto lo descarta el limitador de bytes")
	assert_eq(peer.strikes_total, 5)
	# Un paquete mayor que la ráfaga entera no se concede nunca, por mucho que se espere.
	var huge: PackedByteArray = PackedByteArray()
	huge.resize(5000)
	huge[0] = NetProtocol.MSG_CLIENT_LEAVE
	client.send_raw(NetProtocol.CH_RELIABLE, huge)
	await _run_frames(5)
	assert_eq(_strike_reasons().get("exceso de ritmo", 0), 2, "un paquete de 5 KB tampoco pasa")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "y su CLIENT_LEAVE no se ejecutó")


func test_ip_cap_rejects_the_extra_connection_but_not_loopback() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.max_connections_per_ip = 2)
	# Desde loopback no hay tope: entran 4 clientes con un tope de 2.
	var loopback: Array[RawClient] = []
	for player_name: String in ["Ana", "Bruno", "Carla", "Diana"]:
		var client: RawClient = await _join(player_name)
		if client == null:
			return
		loopback.append(client)
	assert_eq(_server.get_player_count(), 4, "cuatro jugadores de loopback con un tope de 2")
	# Se finge que los siguientes vienen de una IP externa: ahora sí cuenta el tope.
	_server.remote_address_override = func(_peer_id: int, _address: String) -> String:
		return "203.0.113.7"
	var first: RawClient = await _join("Elena")
	var second: RawClient = await _join("Fabio")
	if first == null or second == null:
		return
	var third: RawClient = _connect_client(_hello(VARDHEIM, "Gloria"))
	var rejected: bool = await _run_until(func() -> bool: return third.reject != null)
	if not assert_true(rejected, "la tercera conexión de la misma IP recibe un REJECT"):
		return
	assert_eq(third.reject.result, NetProtocol.Result.TOO_MANY_CONNECTIONS, "por exceso de conexiones")
	assert_eq(third.reject.text, NetProtocol.result_text(NetProtocol.Result.TOO_MANY_CONNECTIONS))
	assert_null(third.welcome, "sin WELCOME")
	assert_eq(_server.get_player_count(), 6, "y no ocupa sitio")
	# Cuando una de las dos se va, vuelve a haber sitio para esa IP.
	first.transport.close()
	var gone: bool = await _run_until(func() -> bool: return _server.get_player_count() == 5)
	assert_true(gone, "la baja libera una conexión de esa IP")
	var fourth: RawClient = await _join("Hilda")
	assert_not_null(fourth, "y entra otra")
	assert_eq(_server.get_player_count(), 6)


func test_unexpected_messages_for_the_session_state_are_strikes() -> void:
	await _start_server(func(config: ServerConfig) -> void: config.debug_commands = true)
	# Cargando la zona: un comando de depuración antes de entrar en el mundo.
	var loading: RawClient = _connect_client(_hello(VARDHEIM, "Ana"), false)
	var connected: bool = await _run_until(func() -> bool: return loading.connected)
	if not assert_true(connected, "el cliente se conecta"):
		return
	var peer: ServerPeer = _server.get_peer(_server.get_peer_ids()[0])
	loading.send_raw(NetProtocol.CH_RELIABLE,
			NetMessages.DebugCommand.teleport(Vector3(1.0, 0.5, 1.0)).encode())
	await _run_frames(3)
	assert_eq(peer.strikes_total, 1, "DEBUG_COMMAND cargando la zona es un aviso")
	assert_eq(peer.state, ServerPeer.State.LOADING, "y no cambia su estado")
	# Un segundo HELLO de quien ya está autenticado.
	_server_transport.auth_received.emit(peer.peer_id, _hello(VARDHEIM, "Ana"))
	assert_eq(peer.strikes_total, 2, "un HELLO repetido es un aviso")
	# Un paquete de aplicación de un peer que aún se autentica (no debería poder llegar).
	_server_transport.peer_authenticating.emit(9999)
	var stranger: ServerPeer = _server.get_peer(9999)
	if assert_not_null(stranger, "el servidor da de alta al peer que se autentica"):
		_server_transport.packet_received.emit(9999, NetMessages.ClientReady.new().encode())
		assert_eq(stranger.strikes_total, 1, "un mensaje antes de autenticarse es un aviso")
	# Un CLIENT_LEAVE mal formado cuenta; uno bueno es una salida limpia.
	loading.send_raw(NetProtocol.CH_RELIABLE, PackedByteArray([NetProtocol.MSG_CLIENT_LEAVE, 0, 0]))
	await _run_frames(3)
	assert_eq(peer.strikes_total, 3, "CLIENT_LEAVE mal formado")
	assert_eq(peer.state, ServerPeer.State.LOADING)
	loading.send_raw(NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())
	var left: bool = await _run_until(func() -> bool: return _server.get_peer(peer.peer_id) == null)
	assert_true(left, "y el bueno da de baja al peer sin más avisos")
	assert_eq(peer.strikes_total, 3)


func test_random_garbage_gets_the_sender_kicked_and_leaves_the_others_untouched() -> void:
	await _start_server()
	var honest: RawClient = await _join("Ana")
	var cheater: RawClient = await _join("Bruno")
	if honest == null or cheater == null:
		return
	# Los ids de peer son aleatorios: cada peer se busca por el net_id de su personaje.
	var honest_peer: ServerPeer = _peer_of(honest.own_spawn.net_id)
	var cheater_peer: ServerPeer = _peer_of(cheater.own_spawn.net_id)
	var cheater_id: int = cheater.own_spawn.net_id
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	# Bytes al azar, de cualquier tamaño y tipo, por los tres canales: nada puede romper al servidor.
	var channels: Array[int] = [NetProtocol.CH_INPUT, NetProtocol.CH_RELIABLE]
	var sent: int = 0
	while sent < 400 and cheater_peer.state != ServerPeer.State.LEAVING:
		var garbage := PackedByteArray()
		garbage.resize(rng.randi_range(1, 160))
		for i: int in garbage.size():
			garbage[i] = rng.randi_range(0, 255)
		cheater.send_raw(channels[sent % channels.size()], garbage)
		sent += 1
		if sent % 4 == 0:
			await _run_frames(1)
	var kicked: bool = await _run_until(func() -> bool:
		return cheater.notice_with_code(NetProtocol.NoticeCode.KICK) != null)
	assert_true(kicked, "el que manda basura recibe el NOTICE de expulsión")
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer(cheater_peer.peer_id) == null)
	assert_true(gone, "y el servidor lo da de baja")
	assert_null(_server.get_registry().get_entity(cheater_id), "con su personaje")
	assert_eq(honest_peer.strikes_total, 0, "el otro cliente no suma ningún aviso")
	assert_eq(honest_peer.state, ServerPeer.State.IN_WORLD, "y sigue en el mundo")
	var snapshots_before: int = honest.snapshots.size()
	await _run_frames(30)
	assert_true(honest.snapshots.size() > snapshots_before + 5, "y recibiendo snapshots")
	assert_eq(_server.get_player_count(), 1, "queda un jugador")
