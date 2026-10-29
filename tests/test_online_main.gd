extends TestCase
## Pruebas de [OnlineMain] (docs/red.md, 1.2 y 17.5) contra un [ZoneServer] real en el mismo proceso:
## la escena entera, con la zona cargada en un hilo, y el cierre por [code]--quit-after-ticks[/code]
## (que aquí no cierra el proceso: [member OnlineMain.quit_hook] recoge el código de salida).
## [br]- Cliente normal: cámara, HUD y humanoide animado al aparecer, y la pantalla de carga fuera.
## [br]- Bot: sin cámara ni HUD, informe al terminar, quieto al final y código de salida 0.
## [br]- Rechazo, cierre del servidor y zona desconocida: código de salida 1 e informe.

const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const REPORT_FILE: String = "test_online_main_report.json"
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _online: OnlineMain
var _port: int = 0
var _exit_codes: Array[int] = []
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = OnlineMain.config
	_saved_hook = OnlineMain.quit_hook
	_saved_max_fps = Engine.max_fps
	_exit_codes.clear()
	OnlineMain.quit_hook = func(code: int) -> void: _exit_codes.append(code)
	DirAccess.remove_absolute(NetHarness.build_path(REPORT_FILE))
	_root = Node.new()
	_root.name = "OnlineMainTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_online):
		_online.get_parent().remove_child(_online)
		_online.free()
	_online = null
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	OnlineMain.config = _saved_config
	OnlineMain.quit_hook = _saved_hook
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


# --- Ayudantes --------------------------------------------------------------------------------

## Servidor con la zona real de test_world escuchando en un puerto libre.
func _start_server(zone_id: String = "test_world", max_players: int = 8) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("test_world"))
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = zone_id
	config.max_players = max_players
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


## Cliente en red con la escena de verdad.
func _start_online(mode: ClientConfig.Mode, configure: Callable = Callable()) -> void:
	var config := ClientConfig.new()
	config.mode = mode
	config.port = _port
	config.realm = NetProtocol.Realm.SOLMARCH
	config.display_name = "Ana"
	config.bot_seed = 3
	config.report_path = NetHarness.build_path(REPORT_FILE)
	if configure.is_valid():
		configure.call(config)
	OnlineMain.config = config
	var packed: PackedScene = load(ONLINE_MAIN_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	tree.root.add_child(_online)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _in_world() -> bool:
	return _online.get_client().get_state() == NetClient.State.IN_WORLD


func _exited() -> bool:
	return not _exit_codes.is_empty()


# --- Pruebas ----------------------------------------------------------------------------------

func test_human_client_loads_the_zone_and_mounts_camera_hud_and_visual() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.ONLINE)
	var client: NetClient = _online.get_client()
	assert_true(await _wait_until(_in_world), "entra en el mundo (estado %s)"
			% NetClient.State.keys()[client.get_state()])
	var world: Node3D = _online.get_world()
	if not assert_not_null(world, "la zona se cargó"):
		return
	assert_eq(world.name, "TestWorld", "la del WELCOME")
	var character: PlayerCharacter = client.get_character()
	assert_not_null(character)
	assert_not_null(_online.get_camera_rig(), "con cámara de acción")
	assert_not_null(_online.get_hud(), "y HUD")
	assert_null(_online.get_bot_brain(), "y sin cerebro de bot")
	var visual: HumanoidVisual = character.get_node_or_null(^"Visual/HumanoidVisual") \
			as HumanoidVisual
	assert_not_null(visual, "con el humanoide animado")
	for child: Node in character.get_node(^"Visual").get_children():
		assert_false(child is MeshInstance3D, "y sin la cápsula provisional")
	var overlay: CanvasLayer = _online.get_node(^"Overlay") as CanvasLayer
	assert_false(overlay.visible, "la pantalla de carga se quita al aparecer")
	assert_eq(_server.get_player_count(), 1)
	# Unos segundos jugando: la predicción coincide con el servidor.
	await wait_physics_frames(90)
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["unexplained_diffs"], 0, "%s" % [stats])
	assert_true(stats["matches"] > 20)
	assert_true(_exit_codes.is_empty())


func test_bot_has_no_camera_and_finishes_with_a_report_and_code_zero() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 300)
	assert_true(await _wait_until(_in_world))
	assert_null(_online.get_camera_rig(), "un bot no tiene cámara")
	assert_null(_online.get_hud(), "ni HUD")
	assert_not_null(_online.get_bot_brain(), "pero sí cerebro")
	assert_false(_online.has_node(^"Overlay"), "ni pantallas")
	assert_true(await _wait_until(_exited), "al cumplir --quit-after-ticks cierra")
	assert_eq(_exit_codes, [0] as Array[int], "con código 0, una sola vez")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("name"), "Ana")
	assert_eq(report.get("mode"), "BOT")
	assert_eq(report.get("zone"), "test_world")
	assert_eq(report.get("rejected"), false)
	assert_eq(report.get("state"), "IN_WORLD", "el informe se escribe antes de salir de la zona")
	assert_eq(int(report.get("unexplained_diffs", -1)), 0)
	assert_true(int(report.get("matches", 0)) > 50)
	var final_state: Dictionary = report.get("final", {})
	assert_true(bool(final_state.get("exact", false)))
	var velocity: Array = final_state.get("velocity", [1.0, 1.0, 1.0])
	assert_vec_near(Vector3(velocity[0], velocity[1], velocity[2]), Vector3.ZERO, 0.001,
			"el bot termina quieto")
	# Sale de la zona con CLIENT_LEAVE: el servidor se queda sin jugadores.
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0),
			"el servidor da de baja al bot que se va")


func test_the_bot_brain_follows_bot_brain_and_bot_cheat() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.bot_brain = ClientConfig.BOT_BRAIN_COMBAT)
	assert_true(await _wait_until(_in_world))
	var brain: BotBrain = _online.get_bot_brain()
	if assert_not_null(brain, "con cerebro"):
		assert_eq(brain.get_pattern(), BotBrain.Pattern.COMBAT, "--bot-brain=combat pelea")
		assert_true(brain.has_enemy_finder(), "y sabe buscar enemigos")


func test_a_combat_cheat_mode_gives_the_bot_the_cheaters_brain() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.bot_cheat = BotCheater.MODE_REACH)
	assert_true(await _wait_until(_in_world))
	var brain: BotBrain = _online.get_bot_brain()
	if assert_not_null(brain):
		assert_true(brain is BotCheatBrain, "--bot-cheat=reach usa el cerebro del tramposo")
		assert_true(brain.has_enemy_finder())


func test_the_default_bot_brain_wanders() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT)
	assert_true(await _wait_until(_in_world))
	var brain: BotBrain = _online.get_bot_brain()
	if assert_not_null(brain):
		assert_eq(brain.get_pattern(), BotBrain.Pattern.WANDER)
		assert_false(brain is BotCheatBrain)


func test_rejection_ends_with_code_one_and_the_reason_in_the_report() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.display_name = "ab"
		config.quit_after_ticks = 600)
	assert_true(await _wait_until(_exited), "se cierra")
	assert_eq(_exit_codes, [1] as Array[int])
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("rejected"), true)
	assert_eq(int(report.get("reject_result", 0)), NetProtocol.Result.NAME)
	assert_eq(report.get("reject_text"), NetProtocol.result_text(NetProtocol.Result.NAME))
	assert_eq(_server.get_player_count(), 0)


func test_server_shutdown_ends_with_code_one_and_keeps_the_report() -> void:
	await _start_server()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 3000)
	assert_true(await _wait_until(_in_world))
	await wait_physics_frames(60)
	_server.stop("Cierre de prueba")
	assert_true(await _wait_until(_exited), "se cierra cuando el servidor se va")
	assert_eq(_exit_codes, [1] as Array[int])
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("disconnect_text"), "Cierre de prueba")
	assert_eq(report.get("state"), "CLOSED")
	assert_true(int(report.get("matches", 0)) > 10, "con lo que se vivió hasta entonces")


func test_unknown_zone_from_the_server_ends_with_code_one() -> void:
	await _start_server("zona_que_no_existe")
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 600)
	assert_true(await _wait_until(_exited), "no hay zona que cargar: se cierra")
	assert_eq(_exit_codes, [1] as Array[int])
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0, 120),
			"y no queda registrado en el servidor")


func test_quit_after_ticks_without_entering_the_world_is_a_failure() -> void:
	# Sin servidor al que llegar: el límite de ticks llega antes que el fallo de conexión.
	_port = NetHarness.free_udp_port()
	_start_online(ClientConfig.Mode.BOT, func(config: ClientConfig) -> void:
		config.quit_after_ticks = 30)
	assert_true(await _wait_until(_exited, 300))
	assert_eq(_exit_codes, [1] as Array[int], "no llegar a entrar en la zona es un fallo")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(report.get("state"), "CONNECTING")
