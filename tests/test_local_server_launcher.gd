extends TestCase
## Pruebas de [LocalServerLauncher] y del modo [code]--local[/code] (docs/red.md, 1.4 y 17.5).
## [br]- Argumentos con los que se lanza el servidor, dentro y fuera de una exportación.
## [br]- Archivo de bloqueo: un bloqueo falso con el pid de este proceso cuenta como servidor
## vivo y con un pid que no existe, no; se usa una ruta propia para no pisar el
## [code]user://dev_server.json[/code] real.
## [br]- [OnlineMain] en modo LOCAL reutiliza el servidor que dice el bloqueo (sin lanzar nada).
## [br]- Prueba de procesos: un cliente [code]--local[/code] headless lanza el servidor, conecta con él,
## juega unos ticks y se va sin cerrarlo.

const FAKE_LOCK: String = "user://test_local_server_launcher_lock.json"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const REPORT_PATH: String = "res://build/test_local_mode_report.json"
## Un pid que no puede existir (los pid de Linux y Windows no llegan a 2^31 - 2).
const NO_SUCH_PID: int = 2147483646
## Segundos como mucho que se espera a que el cliente de la prueba de procesos termine.
const PROCESS_TIMEOUT_MSEC: int = 26000

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _online: OnlineMain
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_lock_path: String
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = OnlineMain.config
	_saved_hook = OnlineMain.quit_hook
	_saved_lock_path = OnlineMain.lock_path
	_saved_max_fps = Engine.max_fps
	DirAccess.remove_absolute(FAKE_LOCK)
	_root = Node.new()
	_root.name = "LocalLauncherTest"
	tree.root.add_child(_root)


func after_each() -> void:
	DirAccess.remove_absolute(FAKE_LOCK)
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
	OnlineMain.lock_path = _saved_lock_path
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


func _write_lock(pid: int, port: int) -> void:
	var file: FileAccess = FileAccess.open(FAKE_LOCK, FileAccess.WRITE)
	file.store_string(JSON.stringify({"pid": pid, "port": port}))
	file.close()


# --- Argumentos -------------------------------------------------------------------------------

func test_build_args_matches_the_documented_command_line() -> void:
	var project: String = ProjectSettings.globalize_path("res://")
	var log_file: String = ProjectSettings.globalize_path("user://logs/dev_server.log")
	var args: PackedStringArray = LocalServerLauncher.build_args(24600, PackedStringArray(), false)
	assert_eq(args, PackedStringArray(["--headless", "--path", project, "--log-file", log_file, "--",
			"--server", "--port=24600", "--idle-quit=30", "--dev-lock"]))
	assert_true(log_file.is_absolute_path(), "el registro va con ruta del sistema, no user://")
	assert_true(project.is_absolute_path(), "y el proyecto también")


func test_build_args_in_an_export_has_no_path_and_appends_extras() -> void:
	var args: PackedStringArray = LocalServerLauncher.build_args(24777,
			PackedStringArray(["--zone=test_world", "--debug-commands"]), true)
	assert_false(args.has("--path"), "una exportación ya lleva el juego")
	assert_eq(args[0], "--headless")
	var separator: int = args.find("--")
	assert_true(separator > 0, "los argumentos de usuario van tras --")
	assert_eq(args.slice(separator), PackedStringArray(["--", "--server", "--port=24777",
			"--idle-quit=30", "--dev-lock", "--zone=test_world", "--debug-commands"]))
	var default_args: PackedStringArray = LocalServerLauncher.build_args(24600, PackedStringArray())
	assert_eq(default_args.has("--path"), not OS.has_feature("template"),
			"por omisión se decide con OS.has_feature(\"template\")")


func test_only_server_options_are_forwarded() -> void:
	var user_args := PackedStringArray(["--local", "--realm=solmarch", "--name=Ana", "--zone=test_world",
			"--debug-commands", "--net-sim=rtt=100", "--fake-players=5", "--max-players=8",
			"--quit-after-ticks=60", "--connect=otro", "--port=24650"])
	assert_eq(LocalServerLauncher.forwarded_args(user_args), PackedStringArray(["--zone=test_world",
			"--debug-commands", "--fake-players=5", "--max-players=8"]))
	assert_true(LocalServerLauncher.forwarded_args(PackedStringArray(["--local"])).is_empty())


# --- Archivo de bloqueo -----------------------------------------------------------------------

func test_find_running_with_a_fake_lock() -> void:
	assert_false(LocalServerLauncher.find_running(24600, FAKE_LOCK), "sin archivo, no hay servidor")
	assert_eq(LocalServerLauncher.get_running_port(FAKE_LOCK), -1)

	_write_lock(OS.get_process_id(), 24600)
	assert_true(LocalServerLauncher.find_running(24600, FAKE_LOCK),
			"el pid de este proceso está vivo")
	assert_eq(LocalServerLauncher.get_running_port(FAKE_LOCK), 24600)
	assert_false(LocalServerLauncher.find_running(24601, FAKE_LOCK), "pero sirve en otro puerto")
	assert_true(LocalServerLauncher.find_running(0, FAKE_LOCK), "con puerto 0 vale cualquiera")

	_write_lock(NO_SUCH_PID, 24600)
	assert_false(LocalServerLauncher.find_running(24600, FAKE_LOCK), "un pid inexistente no cuenta")
	assert_false(LocalServerLauncher.find_running(0, FAKE_LOCK))
	assert_eq(LocalServerLauncher.get_running_port(FAKE_LOCK), -1)
	assert_true(FileAccess.file_exists(FAKE_LOCK), "y comprobarlo no borra el archivo")


func test_malformed_locks_are_not_a_running_server() -> void:
	for text: String in ["", "no es json", "[1, 2]", "{}", "{\"pid\": \"x\", \"port\": 24600}",
			"{\"pid\": 1}", "{\"port\": 24600}"]:
		var file: FileAccess = FileAccess.open(FAKE_LOCK, FileAccess.WRITE)
		file.store_string(text)
		file.close()
		assert_true(LocalServerLauncher.read_lock(FAKE_LOCK).is_empty(), "no es un bloqueo: %s" % text)
		assert_false(LocalServerLauncher.find_running(0, FAKE_LOCK), text)
	_write_lock(OS.get_process_id(), 70000)
	assert_false(LocalServerLauncher.find_running(0, FAKE_LOCK), "un puerto fuera de rango no vale")
	_write_lock(OS.get_process_id(), 24600)
	assert_eq(LocalServerLauncher.read_lock(FAKE_LOCK), {"pid": OS.get_process_id(), "port": 24600})


func test_is_process_alive() -> void:
	assert_true(LocalServerLauncher.is_process_alive(OS.get_process_id()), "este proceso")
	assert_false(LocalServerLauncher.is_process_alive(NO_SUCH_PID), "uno que no existe")
	assert_false(LocalServerLauncher.is_process_alive(0))
	assert_false(LocalServerLauncher.is_process_alive(-5))


# --- OnlineMain en modo LOCAL, reutilizando un servidor -----------------------------------------

func test_local_mode_reuses_the_running_server_without_launching_another() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("test_world"))
	var server_config := ServerConfig.new()
	server_config.port = port
	server_config.zone_id = "test_world"
	_server = NetHarness.start_server(_server_viewport, server_config)
	await wait_physics_frames(3)
	# El bloqueo dice que el servidor del puerto está vivo (el pid es el de este proceso).
	_write_lock(OS.get_process_id(), port)
	OnlineMain.lock_path = FAKE_LOCK

	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.LOCAL
	config.port = NetProtocol.DEFAULT_PORT
	config.realm = NetProtocol.Realm.SOLMARCH
	config.display_name = "Ana"
	OnlineMain.config = config
	OnlineMain.quit_hook = func(_code: int) -> void: pass
	var packed: PackedScene = load(ONLINE_MAIN_SCENE) as PackedScene
	_online = packed.instantiate() as OnlineMain
	tree.root.add_child(_online)
	assert_eq(config.port, port, "el cliente se apunta al puerto del bloqueo")
	var client: NetClient = _online.get_client()
	assert_eq(client.connect_timeout_ms, LocalServerLauncher.CONNECT_TIMEOUT_MS,
			"con el tiempo de espera corto de ENet")
	var entered: bool = false
	for _i: int in 600:
		if client.get_state() == NetClient.State.IN_WORLD:
			entered = true
			break
		await tree.physics_frame
	assert_true(entered, "entra en el mundo (estado %s)" % NetClient.State.keys()[client.get_state()])
	assert_eq(_server.get_player_count(), 1)
	assert_true(_online.get_client() == client, "sin reintentos: es la misma sesión")


# --- Prueba de procesos -------------------------------------------------------------------------

## Un cliente [code]--local[/code] headless, con el servidor aún sin lanzar: lo lanza, reintenta hasta
## que contesta, entra en el mundo, juega 300 ticks y se va. El servidor sigue vivo (el cliente no
## lo cierra) hasta que la prueba lo mata. Si ya hay un servidor local de verdad en marcha (de quien
## ejecuta las pruebas), el cliente lo reutiliza y se comprueba eso, sin tocarlo.
func test_local_client_process_launches_the_server_and_connects() -> void:
	var existing_port: int = LocalServerLauncher.get_running_port()
	var port: int = NetHarness.free_udp_port()
	var report_path: String = ProjectSettings.globalize_path(REPORT_PATH)
	DirAccess.remove_absolute(report_path)
	var expected_port: int = existing_port if existing_port > 0 else port
	var pid: int = NetHarness.launch_process(PackedStringArray(["--local", "--realm=vardheim",
			"--name=Ana", "--zone=test_world", "--port=%d" % port, "--quit-after-ticks=300",
			"--report=%s" % report_path]), "test_local_mode_client")
	assert_true(pid > 0, "se lanza el cliente")
	if pid <= 0:
		return
	var started_msec: int = Time.get_ticks_msec()
	while OS.is_process_running(pid) and Time.get_ticks_msec() - started_msec < PROCESS_TIMEOUT_MSEC:
		await tree.create_timer(0.25).timeout
	var finished: bool = not OS.is_process_running(pid)
	if not finished:
		OS.kill(pid)
	assert_true(finished, "el cliente termina en menos de %d s" % (PROCESS_TIMEOUT_MSEC / 1000))

	var report: Dictionary = NetHarness.read_report(report_path)
	assert_false(report.is_empty(), "y escribe su informe")
	assert_eq(report.get("mode"), "LOCAL")
	assert_eq(report.get("state"), "IN_WORLD", "entró en el mundo (%s)" % report.get("disconnect_text"))
	assert_eq(int(report.get("port", 0)), expected_port, "por el puerto del servidor local")
	assert_eq(report.get("rejected"), false)
	if existing_port <= 0:
		assert_eq(report.get("zone"), "test_world", "la que se pidió al servidor lanzado")
	assert_true(int(report.get("matches", 0)) > 50, "y la predicción coincide con el servidor")
	assert_eq(int(report.get("unexplained_diffs", -1)), 0)

	if existing_port > 0:
		assert_true(LocalServerLauncher.find_running(existing_port), "el servidor real sigue ahí")
		return
	# Lo lanzó el cliente, que se ha ido: el servidor sigue en marcha y escribió su bloqueo.
	var lock: Dictionary = LocalServerLauncher.read_lock()
	assert_eq(int(lock.get("port", 0)), port, "el bloqueo apunta al servidor lanzado")
	assert_true(LocalServerLauncher.find_running(port), "y el cliente no lo cerró al irse")
	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path("user://logs/dev_server.log")),
			"con su registro")
	if int(lock.get("port", 0)) == port:
		OS.kill(int(lock["pid"]))
		for _i: int in 40:
			if not LocalServerLauncher.is_process_alive(int(lock["pid"])):
				break
			await tree.create_timer(0.1).timeout
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalServerLauncher.LOCK_PATH))
