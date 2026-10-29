extends TestCase
## Pruebas de [LocalServerLauncher] y del modo [code]--local[/code] (docs/red.md, 1.4 y 17.5).
## [br]- Argumentos con los que se lanza el servidor, dentro y fuera de una exportación.
## [br]- Archivo de bloqueo: un bloqueo falso con el pid de este proceso cuenta como servidor
## vivo y con un pid que no existe, no; se usa una ruta propia para no pisar el
## [code]user://dev_server.json[/code] real.
## [br]- [OnlineMain] en modo LOCAL reutiliza el servidor que dice el bloqueo (sin lanzar nada).
## [br]- Prueba de procesos: un cliente [code]--local[/code] headless lanza el servidor, conecta con él,
## juega unos ticks y se va sin cerrarlo.

const FAKE_LOCK_FILE: String = "test_local_server_launcher_lock.json"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const REPORT_FILE: String = "test_local_mode_report.json"
## Un pid que no puede existir (los pid de Linux y Windows no llegan a 2^31 - 2).
const NO_SUCH_PID: int = 2147483646
## Segundos como mucho que se espera a que el cliente de la prueba de procesos termine.
const PROCESS_TIMEOUT_MSEC: int = 26000
## Proceso auxiliar de las pruebas de [method LocalServerLauncher.is_process_alive].
const PROBE_SCRIPT: String = "res://tests/process_probe.gd"
## Tiempo (ms) como mucho que se espera a un proceso auxiliar.
const PROBE_TIMEOUT_MSEC: int = 15000

## Bloqueo falso de esta ejecución (en build/<pid>/, no se comparte con otra suite).
var _fake_lock: String = ""
var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _online: OnlineMain
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_lock_path: String
var _saved_max_fps: int = 0
## Procesos auxiliares lanzados por la prueba en curso (se matan al terminar).
var _probe_pids: Array[int] = []


func before_each() -> void:
	_fake_lock = NetHarness.build_path(FAKE_LOCK_FILE)
	_saved_config = OnlineMain.config
	_saved_hook = OnlineMain.quit_hook
	_saved_lock_path = OnlineMain.lock_path
	_saved_max_fps = Engine.max_fps
	DirAccess.remove_absolute(_fake_lock)
	_root = Node.new()
	_root.name = "LocalLauncherTest"
	tree.root.add_child(_root)


func after_each() -> void:
	DirAccess.remove_absolute(_fake_lock)
	for probe_pid: int in _probe_pids:
		if LocalServerLauncher.is_process_alive(probe_pid):
			OS.kill(probe_pid)
	_probe_pids.clear()
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
	var file: FileAccess = FileAccess.open(_fake_lock, FileAccess.WRITE)
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
			"--quit-after-ticks=60", "--connect=otro", "--port=24650", "--dev-lock-path=/tmp/l.json"])
	assert_eq(LocalServerLauncher.forwarded_args(user_args), PackedStringArray(["--zone=test_world",
			"--debug-commands", "--fake-players=5", "--max-players=8", "--dev-lock-path=/tmp/l.json"]))
	assert_true(LocalServerLauncher.forwarded_args(PackedStringArray(["--local"])).is_empty())


func test_a_custom_lock_path_gets_its_own_server_log() -> void:
	var lock: String = "/tmp/eldmark_lock/dev_server.json"
	var args: PackedStringArray = LocalServerLauncher.build_args(24600,
			PackedStringArray(["--dev-lock-path=%s" % lock]), false)
	var log_index: int = args.find("--log-file")
	assert_true(log_index >= 0)
	assert_eq(args[log_index + 1], "/tmp/eldmark_lock/dev_server.log",
			"con otro bloqueo, otro registro: no se pisa el del servidor local real")
	assert_true(args.has("--dev-lock-path=%s" % lock), "y el servidor recibe la opción")
	assert_eq(LocalServerLauncher.log_path_for(""), ProjectSettings.globalize_path(LocalServerLauncher.LOG_PATH),
			"sin bloqueo propio, el registro de siempre")


# --- Archivo de bloqueo -----------------------------------------------------------------------

func test_find_running_with_a_fake_lock() -> void:
	assert_false(LocalServerLauncher.find_running(24600, _fake_lock), "sin archivo, no hay servidor")
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), -1)

	_write_lock(OS.get_process_id(), 24600)
	assert_true(LocalServerLauncher.find_running(24600, _fake_lock),
			"el pid de este proceso está vivo")
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), 24600)
	assert_false(LocalServerLauncher.find_running(24601, _fake_lock), "pero sirve en otro puerto")
	assert_true(LocalServerLauncher.find_running(0, _fake_lock), "con puerto 0 vale cualquiera")

	_write_lock(NO_SUCH_PID, 24600)
	assert_false(LocalServerLauncher.find_running(24600, _fake_lock), "un pid inexistente no cuenta")
	assert_false(LocalServerLauncher.find_running(0, _fake_lock))
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), -1)
	assert_true(FileAccess.file_exists(_fake_lock), "y comprobarlo no borra el archivo")


func test_malformed_locks_are_not_a_running_server() -> void:
	for text: String in ["", "no es json", "[1, 2]", "{}", "{\"pid\": \"x\", \"port\": 24600}",
			"{\"pid\": 1}", "{\"port\": 24600}"]:
		var file: FileAccess = FileAccess.open(_fake_lock, FileAccess.WRITE)
		file.store_string(text)
		file.close()
		assert_true(LocalServerLauncher.read_lock(_fake_lock).is_empty(), "no es un bloqueo: %s" % text)
		assert_false(LocalServerLauncher.find_running(0, _fake_lock), text)
	_write_lock(OS.get_process_id(), 70000)
	assert_false(LocalServerLauncher.find_running(0, _fake_lock), "un puerto fuera de rango no vale")
	_write_lock(OS.get_process_id(), 24600)
	assert_eq(LocalServerLauncher.read_lock(_fake_lock), {"pid": OS.get_process_id(), "port": 24600})


func test_is_process_alive() -> void:
	assert_true(LocalServerLauncher.is_process_alive(OS.get_process_id()), "este proceso")
	assert_false(LocalServerLauncher.is_process_alive(NO_SUCH_PID), "uno que no existe")
	assert_false(LocalServerLauncher.is_process_alive(0))
	assert_false(LocalServerLauncher.is_process_alive(-5))


## La rama de Windows de [method LocalServerLauncher.is_process_alive] consulta [code]tasklist[/code]
## (OS.is_process_running solo conoce los procesos que lanzó este mismo proceso). Aquí se comprueba, en
## cualquier plataforma, el comando y cómo se lee su salida, que sale en el idioma del sistema.
func test_tasklist_is_asked_for_one_pid_and_its_output_is_read_by_column() -> void:
	assert_eq(LocalServerLauncher.tasklist_args(12345), PackedStringArray(["/FI", "PID eq 12345",
			"/FO", "CSV", "/NH"]), "una sola fila, en CSV y sin cabecera")
	var listed: String = "\"Godot_v4.7.2-stable_win64_console.exe\",\"12345\",\"Console\",\"1\",\"85.304 K\"\r\n"
	assert_true(LocalServerLauncher.tasklist_lists_pid(listed, 12345), "el pid es la segunda columna")
	assert_false(LocalServerLauncher.tasklist_lists_pid(listed, 1), "el número de sesión no es el pid")
	assert_false(LocalServerLauncher.tasklist_lists_pid(listed, 85), "ni la memoria")
	assert_false(LocalServerLauncher.tasklist_lists_pid(listed, 123456), "ni un pid que empieza igual")
	var two: String = "\"a.exe\",\"7\",\"Console\",\"1\",\"1 K\"\r\n\"12345.exe\",\"999\",\"Console\",\"1\",\"2 K\"\r\n"
	assert_true(LocalServerLauncher.tasklist_lists_pid(two, 999), "con varias filas, en cualquiera")
	assert_false(LocalServerLauncher.tasklist_lists_pid(two, 12345), "el nombre de imagen no cuenta")
	# Sin coincidencias tasklist sale con 0 y un aviso en el idioma del sistema.
	for message: String in [
			"INFORMACIÓN: no hay tareas ejecutándose que coincidan con los criterios especificados.\r\n",
			"INFO: No tasks are running which match the specified criteria.\r\n",
			"INFORMATION : aucune tâche en service ne correspond aux critères spécifiés.\r\n", ""]:
		assert_false(LocalServerLauncher.tasklist_lists_pid(message, 12345), message)


## Lo que pasaba en Windows: [method OS.is_process_running] solo conoce los procesos que lanzó el
## propio proceso, así que una segunda ventana [code]--local[/code] no veía vivo el servidor de la
## primera. Un proceso hijo comprueba el pid de este (que no lanzó él).
func test_a_child_process_sees_this_process_as_alive() -> void:
	var out_path: String = NetHarness.build_path("probe_alive.json")
	DirAccess.remove_absolute(out_path)
	var pid: int = NetHarness.launch_script(PROBE_SCRIPT, PackedStringArray([
			"--probe-alive=%d" % OS.get_process_id(), "--probe-out=%s" % out_path]), "probe_alive")
	_probe_pids.append(pid)
	assert_true(pid > 0, "se lanza el proceso auxiliar")
	var result: Dictionary = await _wait_for_probe_result(out_path)
	assert_eq(result.get("alive"), true, "el proceso auxiliar ve vivo a quien lo lanzó, aunque no lo lanzó él")


## Un proceso que este no lanzó (un nieto: lo lanza el proceso auxiliar y este lo ve sin ser su
## padre) cuenta como vivo mientras exista y deja de contar al morir.
func test_a_grandchild_this_process_never_launched_is_seen_alive_until_it_dies() -> void:
	var out_path: String = NetHarness.build_path("probe_spawn.json")
	DirAccess.remove_absolute(out_path)
	var pid: int = NetHarness.launch_script(PROBE_SCRIPT, PackedStringArray([
			"--probe-spawn=20", "--probe-out=%s" % out_path, "--probe-dir=%s" % NetHarness.get_build_dir()]),
			"probe_spawn")
	_probe_pids.append(pid)
	assert_true(pid > 0, "se lanza el proceso auxiliar")
	var result: Dictionary = await _wait_for_probe_result(out_path)
	var grandchild: int = int(result.get("grandchild", -1))
	_probe_pids.append(grandchild)
	if not assert_true(grandchild > 0, "que lanza otro proceso"):
		return
	assert_true(LocalServerLauncher.is_process_alive(grandchild), "el nieto está vivo para quien no es su padre")
	OS.kill(grandchild)
	var gone: bool = false
	for _i: int in 50:
		if not LocalServerLauncher.is_process_alive(grandchild):
			gone = true
			break
		await tree.create_timer(0.1).timeout
	assert_true(gone, "y deja de estarlo cuando muere")


# Espera a que el proceso auxiliar escriba su resultado y lo devuelve (vacío si no llega a tiempo).
func _wait_for_probe_result(out_path: String) -> Dictionary:
	var started_msec: int = Time.get_ticks_msec()
	while not FileAccess.file_exists(out_path) and Time.get_ticks_msec() - started_msec < PROBE_TIMEOUT_MSEC:
		await tree.create_timer(0.1).timeout
	# El proceso abre el archivo y lo escribe después: se espera a que haya contenido.
	await tree.create_timer(0.2).timeout
	return NetHarness.read_report(out_path)


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
	OnlineMain.lock_path = _fake_lock

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
## lo cierra) hasta que la prueba lo mata. El bloqueo y el registro del servidor son propios de esta
## ejecución ([code]--dev-lock-path[/code], en [code]build/<pid>/[/code]): no se toca el
## [code]user://dev_server.json[/code] real de quien ejecuta las pruebas ni se comparte con otra suite.
func test_local_client_process_launches_the_server_and_connects() -> void:
	var lock_path: String = NetHarness.build_path("test_local_mode_lock.json")
	var server_log: String = LocalServerLauncher.log_path_for(lock_path)
	var port: int = NetHarness.free_udp_port()
	var report_path: String = NetHarness.build_path(REPORT_FILE)
	for path: String in [lock_path, server_log, report_path]:
		DirAccess.remove_absolute(path)
	var pid: int = NetHarness.launch_process(PackedStringArray(["--local", "--realm=vardheim",
			"--name=Ana", "--zone=test_world", "--port=%d" % port, "--quit-after-ticks=300",
			"--dev-lock-path=%s" % lock_path, "--report=%s" % report_path]), "test_local_mode_client")
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
	assert_eq(int(report.get("port", 0)), port, "por el puerto del servidor lanzado")
	assert_eq(report.get("rejected"), false)
	assert_eq(report.get("zone"), "test_world", "la que se pidió al servidor lanzado")
	assert_true(int(report.get("matches", 0)) > 50, "y la predicción coincide con el servidor")
	assert_eq(int(report.get("unexplained_diffs", -1)), 0)

	# Lo lanzó el cliente, que se ha ido: el servidor sigue en marcha y escribió su bloqueo.
	var lock: Dictionary = LocalServerLauncher.read_lock(lock_path)
	assert_eq(int(lock.get("port", 0)), port, "el bloqueo propio apunta al servidor lanzado")
	assert_true(LocalServerLauncher.find_running(port, lock_path), "y el cliente no lo cerró al irse")
	assert_true(FileAccess.file_exists(server_log), "con su registro junto al bloqueo")
	if int(lock.get("port", 0)) == port:
		OS.kill(int(lock["pid"]))
		for _i: int in 40:
			if not LocalServerLauncher.is_process_alive(int(lock["pid"])):
				break
			await tree.create_timer(0.1).timeout
		DirAccess.remove_absolute(lock_path)
