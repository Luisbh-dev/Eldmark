extends TestCase
## Pruebas de [ZoneServer] sin red: el servidor de una zona con jugadores falsos
## ([method ZoneServer.add_fake_player]) en una [SubViewport] con su propio mundo de física.
## [br][br]
## La zona de prueba es un suelo plano con tres puntos de aparición (dos de Vardheim y uno de
## Solmarch). Se comprueba que el tick avanza, que los jugadores están en el registro por
## [code]net_id[/code], que el historial se graba, que los snapshots caben en 1200 B, el
## teletransporte, la reaparición al caer fuera del mundo, el tope de jugadores, el CSV de
## [code]--state-log[/code], el informe y el cierre. El protocolo con clientes reales está en
## [code]test_zone_server_net.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
## Archivos de salida, en build/ (carpeta de temporales).
const REPORT_FILE: String = "res://build/test_zone_server_report.json"
const STATE_LOG_FILE: String = "res://build/test_zone_server_states.csv"
## Puntos de aparición de la zona de prueba ([ZoneFixture]).
const VARDHEIM_SPAWNS: Array[Vector3] = ZoneFixture.VARDHEIM_SPAWNS
const SOLMARCH_SPAWN: Vector3 = ZoneFixture.SOLMARCH_SPAWN

var _viewport: SubViewport
var _server: ZoneServer
var _world: Node3D


func after_each() -> void:
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_world = null
	_viewport = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## Mundo de prueba (suelo y puntos de aparición) y servidor en marcha, sin transporte.
func _start_server(config: ServerConfig = null) -> ZoneServer:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)

	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	# Los cuerpos de colisión entran en el espacio de física en los primeros pasos.
	await wait_physics_frames(3)
	var used: ServerConfig = config if config != null else _make_config()
	var error: Error = _server.start(used, _world, null, DevAuthProvider.new())
	assert_eq(error, OK, "el servidor arranca")
	return _server


func _make_config() -> ServerConfig:
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	return config


func _character_of(net_id: int) -> PlayerCharacter:
	return _server.get_registry().get_entity(net_id).get_character()


# --- Pruebas ----------------------------------------------------------------------------------

func test_fake_players_run_for_300_ticks() -> void:
	await _start_server()
	var ticks_seen: Array[int] = []
	_server.tick_finished.connect(func(tick: int) -> void: ticks_seen.append(tick))
	var circler: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.CIRCLE,
			VARDHEIM_SPAWNS[0], 20.0), VARDHEIM)
	var walker: int = _server.add_fake_player(BotBrain.new(2, BotBrain.Pattern.WANDER,
			VARDHEIM_SPAWNS[0], 20.0), VARDHEIM)
	var jumper: int = _server.add_fake_player(BotBrain.new(3, BotBrain.Pattern.JUMPY,
			SOLMARCH_SPAWN, 20.0), SOLMARCH)
	assert_eq([circler, walker, jumper], [1, 2, 3], "net_id 1, 2 y 3 en orden de alta")
	assert_eq(_server.get_player_count(), 3, "tres jugadores")
	assert_eq(_server.get_registry().size(), 3, "tres entidades en el registro")
	var start_tick: int = _server.get_tick()
	await wait_physics_frames(300)

	var elapsed: int = _server.get_tick() - start_tick
	assert_true(elapsed >= 299 and elapsed <= 301, "el tick avanza 1 por paso de física (%d)" % elapsed)
	assert_eq(ticks_seen.size(), elapsed, "tick_finished una vez por tick")
	for i: int in ticks_seen.size():
		if ticks_seen[i] != start_tick + 1 + i:
			fail("los ticks son seguidos (índice %d: %d)" % [i, ticks_seen[i]])
			break

	var sorted: Array[NetEntity] = _server.get_registry().get_sorted()
	assert_eq(sorted.size(), 3, "tres entidades")
	var last_id: int = 0
	for entity: NetEntity in sorted:
		assert_true(entity.net_id > last_id, "el registro va por net_id ascendente")
		last_id = entity.net_id
		assert_eq(entity.kind, NetProtocol.EntityKind.PLAYER)
		var character: PlayerCharacter = entity.get_character()
		assert_not_null(character, "el jugador %d tiene personaje" % entity.net_id)
		assert_null(character.get_node_or_null(^"Visual"), "el servidor no lleva el nodo Visual")
		assert_true(character.position.y > -1.0 and character.position.y < 5.0,
				"%s sigue sobre el suelo" % entity.display_name)
		assert_true(absf(character.position.x) < 200.0 and absf(character.position.z) < 200.0,
				"%s no se sale del suelo" % entity.display_name)
		assert_eq(character.last_input_tick, _server.get_tick(),
				"%s aplicó la entrada del último tick" % entity.display_name)

	var moved: float = _character_of(circler).global_position.distance_to(VARDHEIM_SPAWNS[0])
	assert_true(moved > 3.0, "el que da vueltas se ha movido (%.1f m)" % moved)
	assert_eq(_server.get_metrics().get_counter(ServerMetrics.COUNTER_PLAYERS), 3,
			"el contador de jugadores de las métricas")


func test_history_records_every_tick_of_every_player() -> void:
	await _start_server()
	var ids: Array[int] = []
	for i: int in 3:
		ids.append(_server.add_fake_player(BotBrain.new(10 + i, BotBrain.Pattern.CIRCLE,
				VARDHEIM_SPAWNS[0], 15.0), VARDHEIM))
	await wait_physics_frames(90)
	var history: StateHistory = _server.get_history()
	var tick: int = _server.get_tick()
	for net_id: int in ids:
		assert_true(history.has_tick(net_id, tick), "el último tick está grabado")
		assert_true(history.has_tick(net_id, tick - StateHistory.LENGTH_TICKS + 1),
				"el anillo guarda %d ticks" % StateHistory.LENGTH_TICKS)
		assert_false(history.has_tick(net_id, tick - StateHistory.LENGTH_TICKS),
				"el más viejo ya se sobrescribió")
		var sample: StateHistory.Sample = history.sample(net_id, float(tick))
		if assert_not_null(sample, "muestra del último tick"):
			assert_vec_near(sample.position, _character_of(net_id).global_position, 1e-4,
					"la muestra del último tick es la posición actual")
			assert_near(sample.yaw, _character_of(net_id).yaw, 1e-5, "y el yaw")
		var half: StateHistory.Sample = history.sample(net_id, float(tick) - 0.5)
		assert_not_null(half, "también se puede muestrear entre dos ticks")
	assert_null(history.sample(9999, float(tick)), "un id desconocido no tiene pista")


func test_snapshots_fit_in_the_packet_limit() -> void:
	var config: ServerConfig = _make_config()
	config.max_players = 64
	await _start_server(config)
	for i: int in 60:
		var realm: int = VARDHEIM if i % 2 == 0 else SOLMARCH
		var home: Vector3 = VARDHEIM_SPAWNS[0] if realm == VARDHEIM else SOLMARCH_SPAWN
		assert_true(_server.add_fake_player(BotBrain.new(100 + i, BotBrain.Pattern.WANDER, home,
				10.0), realm) > 0, "alta %d" % i)
	await wait_physics_frames(60)

	var builder := SnapshotBuilder.new(_server.interest_policy)
	var tick: int = _server.get_tick()
	builder.begin(tick, _server.get_registry().get_sorted())
	# Observador: el jugador 1, que ve a los otros 59.
	var observer: NetEntity = _server.get_registry().get_entity(1)
	var peer := ServerPeer.new(777)
	peer.entity = observer
	peer.input_queue = InputQueue.new()
	peer.input_queue.reset(tick, NetProtocol.neutral_input(tick, observer.get_character().yaw))
	for entity: NetEntity in _server.get_registry().get_sorted():
		if entity != observer:
			peer.relevant[entity.net_id] = true
	var seen: Dictionary[int, bool] = {}
	for build_index: int in 4:
		var packet: PackedByteArray = builder.build_for(peer)
		assert_true(packet.size() <= NetProtocol.MAX_PACKET_BYTES,
				"el snapshot ocupa %d B, como mucho 1200" % packet.size())
		var decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(packet)
		if not assert_not_null(decoded, "el snapshot se decodifica"):
			return
		assert_eq(decoded.server_tick, tick, "lleva el tick del servidor")
		assert_not_null(decoded.own_state, "lleva el estado propio")
		assert_true(decoded.records.size() <= 57, "como mucho 57 registros (%d)" % decoded.records.size())
		for record: EntityRecord in decoded.records:
			assert_true(record.net_id != observer.net_id, "el propio jugador no está entre los registros")
			seen[record.net_id] = true
	assert_eq(seen.size(), 59, "con la prioridad, todos los visibles salen en pocos snapshots")


func test_teleport_changes_state_and_bumps_the_counter() -> void:
	await _start_server()
	var id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	await wait_physics_frames(5)
	var entity: NetEntity = _server.get_registry().get_entity(id)
	var character: PlayerCharacter = entity.get_character()
	var yaw_before: float = character.yaw
	assert_eq(entity.teleport_counter, 0, "sin teletransportes")

	_server.teleport(id, Vector3(10.0, 0.5, -3.0))
	assert_eq(entity.teleport_counter, 1, "el contador sube")
	assert_vec_near(character.global_position, Vector3(10.0, 0.5, -3.0), 1e-5, "nueva posición")
	assert_vec_near(character.velocity, Vector3.ZERO, 1e-6, "velocidad 0")
	assert_near(character.yaw, yaw_before, 1e-6, "conserva el yaw")
	var state: PlayerState = character.get_state()
	assert_true(state.equals_exact(PlayerState.decode(state.encode())),
			"el estado impuesto pasa por encode/decode")

	await wait_physics_frames(2)
	var history: StateHistory = _server.get_history()
	var tick: int = _server.get_tick()
	var sample: StateHistory.Sample = history.sample(id, float(tick))
	if assert_not_null(sample, "muestra tras el teletransporte"):
		assert_eq((sample.flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK, 1,
				"el historial lleva el contador de teletransporte")

	for _i: int in 3:
		_server.teleport(id, Vector3(1.0, 0.5, 1.0))
	assert_eq(entity.teleport_counter, 0, "el contador da la vuelta módulo 4")
	_server.teleport(12345, Vector3.ZERO)
	_server.teleport(id, Vector3(NAN, 0.0, 0.0))
	assert_eq(entity.teleport_counter, 0, "un id desconocido o una posición no finita no hacen nada")
	assert_vec_near(character.global_position, Vector3(1.0, 0.5, 1.0), 1e-5, "la posición no cambia")


func test_falling_out_of_the_world_respawns_at_the_spawn_point() -> void:
	await _start_server()
	var id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	await wait_physics_frames(3)
	var entity: NetEntity = _server.get_registry().get_entity(id)
	assert_eq(entity.teleport_counter, 0)
	# Debajo de FALL_LIMIT_Y y sin suelo: el servidor lo devuelve a su punto de aparición.
	_server.teleport(id, Vector3(0.0, -150.0, 0.0))
	assert_eq(entity.teleport_counter, 1)
	await wait_physics_frames(3)
	var position: Vector3 = entity.get_position()
	assert_true(position.y > -1.0, "ha reaparecido (y = %.2f)" % position.y)
	assert_vec_near(Vector3(position.x, 0.0, position.z), SOLMARCH_SPAWN, 0.1,
			"en el punto de aparición de Solmarch")
	assert_eq(entity.teleport_counter, 2, "la reaparición también sube el contador")
	assert_true(entity.get_character().grounded, "reaparece en el suelo")
	assert_eq(_server.write_report(_report_path()), OK)
	var report: Dictionary = _read_json(_report_path())
	assert_eq(int(report.get("respawns", -1)), 1, "el informe cuenta la reaparición")
	assert_eq(int(report.get("teleports", -1)), 1, "y el teletransporte")


func test_player_limit_counts_fake_players() -> void:
	var config: ServerConfig = _make_config()
	config.max_players = 2
	await _start_server(config)
	assert_true(_server.add_fake_player(BotBrain.new(1), VARDHEIM) > 0)
	assert_true(_server.add_fake_player(BotBrain.new(2), VARDHEIM) > 0)
	assert_eq(_server.add_fake_player(BotBrain.new(3), VARDHEIM), -1, "con el cupo lleno no entra otro")
	assert_eq(_server.add_fake_player(null, VARDHEIM), -1, "sin cerebro tampoco")
	assert_eq(_server.get_player_count(), 2)


func test_players_spawn_at_their_realm_and_on_the_ground() -> void:
	await _start_server()
	var first: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	var second: int = _server.add_fake_player(BotBrain.new(2, BotBrain.Pattern.IDLE), VARDHEIM)
	var third: int = _server.add_fake_player(BotBrain.new(3, BotBrain.Pattern.IDLE), SOLMARCH)
	var expected: Dictionary[int, Vector3] = {
		first: VARDHEIM_SPAWNS[0], second: VARDHEIM_SPAWNS[1], third: SOLMARCH_SPAWN,
	}
	for net_id: int in expected:
		var state: PlayerState = _character_of(net_id).get_state()
		assert_vec_near(state.position, expected[net_id], 1e-5, "punto de aparición de %d" % net_id)
		assert_true(state.grounded, "el punto de aparición está en el suelo")
		assert_true(state.equals_exact(PlayerState.decode(state.encode())),
				"el estado de alta pasa por encode/decode")
		assert_eq(state.last_input_tick, 0, "last_input_tick = tick del alta")
	await wait_physics_frames(30)
	for net_id: int in expected:
		var character: PlayerCharacter = _character_of(net_id)
		assert_vec_near(character.global_position, expected[net_id], 0.05,
				"quieto en su punto de aparición")
		assert_true(character.grounded)


func test_state_log_and_report() -> void:
	var config: ServerConfig = _make_config()
	config.state_log_path = _state_log_path()
	config.port = 24999
	await _start_server(config)
	var ids: Array[int] = []
	for i: int in 2:
		ids.append(_server.add_fake_player(BotBrain.new(5 + i, BotBrain.Pattern.CIRCLE,
				VARDHEIM_SPAWNS[0], 15.0), VARDHEIM))
	var start_tick: int = _server.get_tick()
	await wait_physics_frames(60)
	var ticks: int = _server.get_tick() - start_tick
	assert_eq(_server.write_report(_report_path()), OK, "se escribe el informe")
	_server.stop()
	assert_true(_server.is_stopped(), "sin peers, el cierre es inmediato")

	# --state-log: tick,net_id,substituted,hex(PlayerState) por tick y jugador.
	var lines: PackedStringArray = FileAccess.get_file_as_string(_state_log_path()).strip_edges() \
			.split("\n")
	assert_eq(lines.size(), ticks * 2, "una línea por tick y jugador")
	var previous_tick: int = 0
	for line: String in lines:
		var fields: PackedStringArray = line.split(",")
		if not assert_eq(fields.size(), 4, "cuatro campos: %s" % line):
			return
		var line_tick: int = fields[0].to_int()
		assert_true(line_tick >= previous_tick, "los ticks no retroceden")
		previous_tick = line_tick
		assert_true(ids.has(fields[1].to_int()), "net_id conocido")
		assert_eq(fields[2], "0", "los jugadores falsos nunca se sustituyen")
		var state: PlayerState = PlayerState.decode(fields[3].hex_decode())
		if assert_not_null(state, "el estado se decodifica de su hexadecimal"):
			assert_eq(state.last_input_tick, line_tick, "el estado es el de «tras el tick»")

	var report: Dictionary = _read_json(_report_path())
	assert_eq(int(report.get("version", 0)), 1)
	assert_eq(report.get("zone"), "test_world")
	assert_eq(int(report.get("port", 0)), 24999)
	assert_eq(int(report.get("ticks", 0)), _server.get_tick(), "ticks")
	assert_eq(int(report.get("tick_rate", 0)), 60)
	var players: Dictionary = report.get("players", {})
	assert_eq(int(players.get("fake", 0)), 2, "dos jugadores falsos")
	assert_eq(int(players.get("peak", 0)), 2, "pico de dos jugadores")
	assert_eq(int(players.get("joined_total", 0)), 2)
	var player_list: Array = report.get("player_list", [])
	assert_eq(player_list.size(), 2, "una ficha por jugador")
	var metrics: Dictionary = report.get("metrics", {})
	var sections: Dictionary = metrics.get("sections", {})
	for section: String in ["tick", "net", "sim", "history", "snapshot", "flush"]:
		assert_true(sections.has(section), "el informe lleva la sección %s" % section)
	var tick_section: Dictionary = sections.get("tick", {})
	assert_true(int(tick_section.get("samples", 0)) >= ticks - 1, "muestras del tick")
	assert_true(int(tick_section.get("p99", 0)) > 0, "p99 del tick medido")
	assert_true(report.has("strikes") and report.has("kicks") and report.has("bytes")
			and report.has("inputs"), "avisos, expulsiones, bytes y entradas")


func test_stop_releases_the_players_but_keeps_the_report() -> void:
	await _start_server()
	for i: int in 3:
		_server.add_fake_player(BotBrain.new(i), VARDHEIM)
	await wait_physics_frames(10)
	_server.stop("prueba")
	assert_true(_server.is_stopped())
	assert_eq(_server.get_player_count(), 0, "sin jugadores tras cerrar")
	assert_eq(_server.get_registry().size(), 0, "ni entidades")
	var ticks: int = _server.get_tick()
	await wait_physics_frames(5)
	assert_eq(_server.get_tick(), ticks, "el tick ya no avanza")
	assert_eq(_server.add_fake_player(BotBrain.new(9), VARDHEIM), -1, "no se añaden jugadores")
	assert_eq(_server.write_report(_report_path()), OK, "el informe se puede escribir tras cerrar")
	var report: Dictionary = _read_json(_report_path())
	assert_eq((report.get("player_list", []) as Array).size(), 3, "con las fichas de los 3 jugadores")
	_server.stop()  # cerrar dos veces no hace nada


func test_start_validates_its_arguments() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	tree.root.add_child(_viewport)
	_world = Node3D.new()
	_viewport.add_child(_world)
	_server = ZoneServer.new()
	assert_eq(_server.start(_make_config(), _world, null, null), ERR_UNCONFIGURED,
			"el servidor debe estar en el árbol")
	_viewport.add_child(_server)
	assert_eq(_server.start(null, _world, null, null), ERR_UNCONFIGURED, "sin configuración")
	assert_eq(_server.start(_make_config(), null, null, null), ERR_UNCONFIGURED, "sin mundo")
	assert_eq(_server.start(_make_config(), _world, null, null), OK, "con todo")
	assert_eq(_server.start(_make_config(), _world, null, null), ERR_ALREADY_IN_USE,
			"no se arranca dos veces")
	assert_eq(_server.add_fake_player(BotBrain.new(1), VARDHEIM), 1,
			"sin puntos de aparición, el jugador aparece en el origen")
	assert_vec_near(_character_of(1).global_position, Vector3.ZERO, 1e-5)


func _report_path() -> String:
	return ProjectSettings.globalize_path(REPORT_FILE)


func _state_log_path() -> String:
	return ProjectSettings.globalize_path(STATE_LOG_FILE)


func _read_json(path: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("no se pudo leer el JSON %s" % path)
		return {}
	return json.data
