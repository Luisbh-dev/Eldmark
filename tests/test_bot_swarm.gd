extends TestCase
## [BotSwarm] y [SwarmBot] (docs/red.md, secciones 15 y 17.5; TEC-11) contra un [ZoneServer] real en el
## mismo proceso, con ENet sobre 127.0.0.1: la escena de verdad ([code]scenes/client/bot_swarm.tscn[/code])
## con [code]--bots=8[/code]. Se comprueba que entran todos (uno cada 5 ticks), que reciben snapshots,
## que sus entradas llegan a tiempo, que el informe trae los bytes por cliente y que el cierre por
## [code]--quit-after-ticks[/code] y el rechazo por servidor lleno dan el código de salida esperado.
## El enjambre en un proceso aparte lo prueba [code]test_net_processes[/code].

const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"
const REPORT_FILE: String = "test_bot_swarm_report.json"
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _swarm: BotSwarm
var _port: int = 0
var _exit_codes: Array[int] = []
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = BotSwarm.config
	_saved_hook = BotSwarm.quit_hook
	_saved_max_fps = Engine.max_fps
	_exit_codes.clear()
	BotSwarm.quit_hook = func(code: int) -> void: _exit_codes.append(code)
	DirAccess.remove_absolute(NetHarness.build_path(REPORT_FILE))
	_root = Node.new()
	_root.name = "BotSwarmTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_swarm):
		_swarm.get_parent().remove_child(_swarm)
		_swarm.free()
	_swarm = null
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	BotSwarm.config = _saved_config
	BotSwarm.quit_hook = _saved_hook
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


# --- Ayudantes --------------------------------------------------------------------------------

func _start_server(max_players: int = 16) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = max_players
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


## El enjambre de la escena de verdad, con [param count] bots hacia el servidor de la prueba.
func _start_swarm(count: int, configure: Callable = Callable()) -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.SWARM
	config.port = _port
	config.bot_count = count
	config.bot_seed = 40
	config.report_path = NetHarness.build_path(REPORT_FILE)
	if configure.is_valid():
		configure.call(config)
	BotSwarm.config = config
	var packed: PackedScene = load(SWARM_SCENE) as PackedScene
	_swarm = packed.instantiate() as BotSwarm
	_root.add_child(_swarm)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _exited() -> bool:
	return not _exit_codes.is_empty()


# --- Pruebas ----------------------------------------------------------------------------------

func test_eight_bots_join_one_every_five_ticks_and_receive_snapshots() -> void:
	await _start_server()
	_start_swarm(8)
	assert_eq(_swarm.get_bots().size(), 1, "el primer bot se crea al empezar")
	var all_in: bool = await _wait_until(func() -> bool: return _swarm.count_in_world() == 8)
	if not assert_true(all_in, "los 8 entran en el mundo (%d)" % _swarm.count_in_world()):
		return
	assert_eq(_server.get_player_count(), 8, "el servidor tiene a los 8")
	for i: int in 8:
		assert_eq(_swarm.get_created_tick(i), i * BotSwarm.SPAWN_INTERVAL_TICKS,
				"el bot %d se crea en el tick %d" % [i, i * BotSwarm.SPAWN_INTERVAL_TICKS])
	await wait_physics_frames(240)

	var names: Dictionary = {}
	var in_sync: int = 0
	for bot: SwarmBot in _swarm.get_bots():
		var stats: Dictionary = bot.get_stats()
		var label: String = "bot %d" % bot.get_bot_index()
		assert_eq(bot.get_state(), SwarmBot.State.IN_WORLD, "%s sigue jugando" % label)
		assert_eq(bot.get_display_name(), NameRules.bot_name(40 + bot.get_bot_index()),
				"%s: nombre válido por semilla" % label)
		names[bot.get_display_name()] = true
		assert_true(int(stats["snapshots"]) > 50, "%s: recibe snapshots (%d)" % [label, stats["snapshots"]])
		assert_true(int(stats["snapshots_with_state"]) > 50, "%s: con su estado propio" % label)
		assert_eq(int(stats["malformed_packets"]), 0, "%s: sin paquetes mal formados" % label)
		assert_true(int(stats["bytes_up"]) > 1000 and int(stats["bytes_down"]) > 1000,
				"%s: sube y baja bytes (%d / %d)" % [label, stats["bytes_up"], stats["bytes_down"]])
		assert_true(float(stats["avg_snapshot_bytes"]) > 49.0 + 20.0 * 6.0,
				"%s: snapshots con los otros 7 (%.1f B de media)" % [label, stats["avg_snapshot_bytes"]])
		assert_eq(int(stats["max_snapshot_records"]), 7, "%s: ve a los otros 7" % label)
		assert_true(int(stats["batches_sent"]) > 150, "%s: envía lotes cada tick" % label)
		if _server_position(bot.get_net_id()).distance_to(bot.get_position()) < 3.0:
			in_sync += 1
	assert_eq(names.size(), 8, "ocho nombres distintos")

	# El servidor las trata como a clientes de verdad: sus entradas llegan a tiempo y no hay avisos.
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		assert_eq(peer.strikes_total, 0, "peer %d: sin avisos" % peer_id)
		assert_eq(peer.state, ServerPeer.State.IN_WORLD)
		assert_true(peer.input_queue.substitutions_total <= 4,
				"peer %d: entradas sustituidas %d" % [peer_id, peer.input_queue.substitutions_total])
		assert_eq(peer.input_queue.late_count, 0, "peer %d: ninguna entrada tarde" % peer_id)
	assert_eq(in_sync, 8, "la posición que usa cada bot (la de su snapshot) es la del servidor, con retraso")


func test_walking_bots_actually_move_on_the_server() -> void:
	await _start_server()
	_start_swarm(4, func(config: ClientConfig) -> void: config.bot_seed = 7)
	assert_true(await _wait_until(func() -> bool: return _swarm.count_in_world() == 4), "entran los 4")
	var starts: Dictionary = {}
	for bot: SwarmBot in _swarm.get_bots():
		starts[bot.get_net_id()] = _server_position(bot.get_net_id())
	await wait_physics_frames(420)
	var travelled: int = 0
	for bot: SwarmBot in _swarm.get_bots():
		var start: Vector3 = starts[bot.get_net_id()]
		var distance: float = start.distance_to(_server_position(bot.get_net_id()))
		if distance > 2.0:
			travelled += 1
	assert_true(travelled >= 3, "al menos 3 de los 4 han caminado más de 2 m (%d)" % travelled)


func test_report_has_bytes_per_client_and_the_swarm_quits_on_its_own() -> void:
	await _start_server()
	_start_swarm(4, func(config: ClientConfig) -> void: config.quit_after_ticks = 240)
	assert_true(await _wait_until(_exited), "el enjambre se cierra solo (--quit-after-ticks)")
	assert_eq(_exit_codes[0], 0, "con código 0: todos jugaban")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(int(report.get("version", 0)), 1)
	assert_eq(report.get("mode"), "SWARM")
	assert_eq(int(report.get("port", 0)), _port)
	var bots: Dictionary = report.get("bots", {})
	assert_eq(int(bots.get("requested", 0)), 4)
	assert_eq(int(bots.get("created", 0)), 4)
	assert_eq(int(bots.get("played", 0)), 4, "los 4 jugaron")
	assert_eq(int(bots.get("rejected", -1)), 0)
	var clients: Array = report.get("clients", [])
	if not assert_eq(clients.size(), 4, "una ficha por cliente"):
		return
	var snapshots: int = 0
	for entry: Dictionary in clients:
		assert_true(int(entry.get("bytes_up", 0)) > 500, "bytes de subida por cliente (%s)" % entry.get("bytes_up"))
		assert_true(int(entry.get("bytes_down", 0)) > 500, "bytes de bajada por cliente (%s)" % entry.get("bytes_down"))
		assert_true(int(entry.get("snapshots", 0)) > 20, "snapshots recibidos (%s)" % entry.get("snapshots"))
		assert_true(float(entry.get("avg_snapshot_bytes", 0.0)) > 49.0, "tamaño medio de snapshot")
		assert_true(float(entry.get("kb_down_per_s", 0.0)) > 0.1, "KB/s de bajada")
		snapshots += int(entry.get("snapshots", 0))
	var totals: Dictionary = report.get("totals", {})
	assert_eq(int(totals.get("snapshots", -1)), snapshots, "el total de snapshots es la suma")
	assert_true(float(totals.get("avg_snapshot_bytes", 0.0)) > 49.0)
	# Tras el cierre, los bots salen de la zona con CLIENT_LEAVE.
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0),
			"y el servidor se queda sin jugadores")


func test_bots_rejected_by_a_full_server_make_the_exit_code_one() -> void:
	await _start_server(2)
	_start_swarm(3, func(config: ClientConfig) -> void: config.quit_after_ticks = 200)
	assert_true(await _wait_until(_exited), "el enjambre se cierra solo")
	assert_eq(_exit_codes[0], 1, "con código 1: uno no pudo entrar")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	var bots: Dictionary = report.get("bots", {})
	assert_eq(int(bots.get("played", 0)), 2, "juegan 2")
	assert_eq(int(bots.get("rejected", 0)), 1, "y uno recibe REJECT")
	var rejected_entry: Dictionary = {}
	for entry: Dictionary in report.get("clients", []):
		if bool(entry.get("rejected", false)):
			rejected_entry = entry
	assert_eq(int(rejected_entry.get("reject_result", 0)), NetProtocol.Result.FULL, "por servidor lleno")
	assert_eq(rejected_entry.get("reject_text"), NetProtocol.result_text(NetProtocol.Result.FULL))
	assert_eq(rejected_entry.get("state"), "CLOSED")


## Posición del servidor del jugador con ese net_id (infinita si no existe).
func _server_position(net_id: int) -> Vector3:
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	if entity == null:
		return Vector3(INF, INF, INF)
	return entity.get_position()
