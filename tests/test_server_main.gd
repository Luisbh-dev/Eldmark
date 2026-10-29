extends TestCase
## Pruebas de [ServerMain] y del modo [code]--server[/code] de [code]boot.gd[/code], con el
## servidor arrancado como proceso aparte (docs/red.md, sección 16):
## [code]OS.create_process(OS.get_executable_path(), [--headless, --path, …, --, --server, …])[/code].
## [br][br]
## Se comprueba que arranca, simula y cierra solo con [code]--quit-after-ticks[/code] y
## [code]--idle-quit[/code] (código de salida 0), que escribe el informe de [code]--report[/code] y
## el CSV de [code]--state-log[/code], que el registro no contiene errores del motor ni de script
## y que una zona desconocida sale con el código 1. Una de las pruebas usa la zona real, el Vado
## Gris, con Terrain3D.
## [br][br]
## No se usa [code]--dev-lock[/code]: escribiría el [code]user://dev_server.json[/code] real de
## quien ejecuta las pruebas. El archivo de bloqueo se prueba con sus funciones estáticas.

const BootScript = preload("res://scripts/boot.gd")
## Tiempo máximo de espera a que el proceso termine (cada prueba dura menos de 30 s).
const MAX_WAIT_SECONDS: float = 25.0
const BUILD_DIR: String = "res://build"
const FIRST_PORT: int = 24800
const LOCK_FILE: String = "user://test_server_main_lock.json"

var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	if FileAccess.file_exists(LOCK_FILE):
		DirAccess.remove_absolute(LOCK_FILE)
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _build_path(file_name: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BUILD_DIR))
	return ProjectSettings.globalize_path(BUILD_DIR.path_join(file_name))


## Lanza el servidor con [param user_args] (los de después de [code]--[/code]). Devuelve el pid.
func _launch(user_args: PackedStringArray, log_path: String) -> int:
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--",
		"--server",
	])
	args.append_array(user_args)
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	if pid > 0:
		_pids.append(pid)
	return pid


## Espera a que el proceso termine. false si pasa [constant MAX_WAIT_SECONDS].
func _wait_for_exit(pid: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline:
			return false
		await tree.create_timer(0.1).timeout
	return true


func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var error: Error = probe.bind(port, "*")
		probe.close()
		if error == OK:
			return port
	return -1


func _read_report(path: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("no se pudo leer el informe %s" % path)
		return {}
	return json.data


## Líneas del registro del proceso que contienen errores del motor o de scripts.
func _error_lines(log_path: String) -> PackedStringArray:
	var found := PackedStringArray()
	for line: String in FileAccess.get_file_as_string(log_path).split("\n"):
		if line.contains("ERROR") or line.contains("SCRIPT ERROR"):
			found.append(line)
	return found


# --- Pruebas ----------------------------------------------------------------------------------

func test_server_process_with_fake_players_writes_report_and_states() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_a.log")
	var report_path: String = _build_path("test_server_main_a.json")
	var states_path: String = _build_path("test_server_main_a.csv")
	for path: String in [report_path, states_path]:
		DirAccess.remove_absolute(path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--quit-after-ticks=300", "--fake-players=4",
		"--report=%s" % report_path, "--state-log=%s" % states_path,
		"--net-sim=rtt=80,jitter=10,loss=0,dup=0,seed=3",
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra solo"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")

	var report: Dictionary = _read_report(report_path)
	assert_eq(int(report.get("version", 0)), 1, "versión del informe")
	assert_eq(report.get("zone"), "test_world", "zona")
	assert_eq(int(report.get("port", 0)), port, "puerto")
	assert_eq(int(report.get("ticks", 0)), 300, "300 ticks simulados")
	assert_eq(int(report.get("tick_rate", 0)), 60, "60 ticks por segundo")
	var players: Dictionary = report.get("players", {})
	assert_eq(int(players.get("fake", 0)), 4, "cuatro jugadores falsos")
	assert_eq(int(players.get("peak", 0)), 4, "pico de cuatro jugadores")
	assert_eq(int(players.get("at_stop", 0)), 4, "cuatro jugadores al cerrar")
	assert_eq((report.get("player_list", []) as Array).size(), 4, "cuatro fichas de jugador")
	assert_eq(int(report.get("physics_errors", -1)), 0, "sin errores de física")
	assert_eq(int(report.get("respawns", -1)), 0, "nadie cae fuera del mundo")
	var sections: Dictionary = (report.get("metrics", {}) as Dictionary).get("sections", {})
	var tick_section: Dictionary = sections.get("tick", {})
	assert_eq(int(tick_section.get("samples", 0)), 300, "300 medidas de la duración del tick")
	assert_true(int(tick_section.get("p99", 0)) > 0, "p99 del tick medido")

	# --state-log: una línea por tick y jugador.
	var lines: PackedStringArray = FileAccess.get_file_as_string(states_path).strip_edges() \
			.split("\n")
	assert_eq(lines.size(), 300 * 4, "una línea por tick y jugador en el CSV")

	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("escuchando en el puerto UDP %d" % port), "el registro dice el puerto")
	assert_true(log_text.contains("Alta de Bot-01"), "y las altas")
	assert_true(log_text.contains("Simulador de red: rtt=80"), "y el simulador de red")
	assert_true(log_text.contains("Servidor cerrado"), "y el cierre")
	assert_eq(_error_lines(log_path), PackedStringArray(), "sin errores en el registro")


func test_vado_gris_server_process_runs_and_closes_cleanly() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_b.log")
	var report_path: String = _build_path("test_server_main_b.json")
	DirAccess.remove_absolute(report_path)
	# Sin --zone: la zona por defecto es el Vado Gris, con su Terrain3D real.
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--quit-after-ticks=600", "--fake-players=2", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra solo"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")

	var report: Dictionary = _read_report(report_path)
	assert_eq(report.get("zone"), String(Zones.DEFAULT_ZONE), "sirve la zona por defecto")
	assert_eq(int(report.get("ticks", 0)), 600, "600 ticks simulados")
	assert_eq(int(report.get("physics_errors", -1)), 0, "sin errores de física")
	assert_eq(int(report.get("respawns", -1)), 0, "nadie cae fuera del mundo")
	var list: Array = report.get("player_list", [])
	if assert_eq(list.size(), 2, "dos jugadores falsos"):
		var realms: Array[String] = []
		for entry: Dictionary in list:
			realms.append(entry.get("realm", ""))
			var position: Array = entry.get("position", [0.0, -999.0, 0.0])
			assert_true(float(position[1]) > -5.0 and float(position[1]) < 60.0,
					"%s sigue sobre el terreno (y = %.2f)" % [entry.get("name"), float(position[1])])
			assert_true(absf(float(position[0])) < 2600.0 and absf(float(position[2])) < 2600.0,
					"%s sigue dentro de la zona" % entry.get("name"))
		assert_eq(realms, ["Vardheim", "Solmarch"], "un jugador falso de cada reino con campamento")

	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("nodos solo visuales quitados"), "se quita lo visual de la zona")
	assert_true(log_text.contains("Servidor cerrado"), "se cierra")
	assert_eq(_error_lines(log_path), PackedStringArray(), "sin errores en el registro")


## Distancia mayor (m) entre dos jugadores de la lista del informe.
func _max_pairwise_distance(player_list: Array) -> float:
	var farthest: float = 0.0
	for a: Dictionary in player_list:
		for b: Dictionary in player_list:
			var pa: Array = a.get("position", [0.0, 0.0, 0.0])
			var pb: Array = b.get("position", [0.0, 0.0, 0.0])
			farthest = maxf(farthest, Vector3(pa[0], pa[1], pa[2]).distance_to(Vector3(pb[0], pb[1], pb[2])))
	return farthest


func test_fake_layout_cluster_keeps_every_player_within_60_m() -> void:
	var log_path: String = _build_path("test_server_main_e.log")
	var report_path: String = _build_path("test_server_main_e.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--quit-after-ticks=420", "--fake-players=12",
		"--fake-layout=cluster", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra solo"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	var report: Dictionary = _read_report(report_path)
	var list: Array = report.get("player_list", [])
	assert_eq(list.size(), 12, "doce jugadores falsos")
	var realms: Dictionary = {}
	for entry: Dictionary in list:
		realms[entry.get("realm")] = true
	assert_eq(realms.size(), 1, "todos del mismo reino: %s" % [realms.keys()])
	var spread: float = _max_pairwise_distance(list)
	assert_true(spread < 60.0, "ninguno a más de 60 m de otro (%.1f m)" % spread)
	assert_eq(int(report.get("physics_errors", -1)), 0, "sin errores de física")
	assert_eq(int(report.get("respawns", -1)), 0, "nadie cae fuera del mundo")
	assert_eq(_error_lines(log_path), PackedStringArray(), "sin errores en el registro")


func test_fake_layout_spread_scatters_the_players_over_the_terrain() -> void:
	var log_path: String = _build_path("test_server_main_f.log")
	var report_path: String = _build_path("test_server_main_f.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--quit-after-ticks=420", "--fake-players=12",
		"--fake-layout=spread", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra solo"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	var report: Dictionary = _read_report(report_path)
	var list: Array = report.get("player_list", [])
	assert_eq(list.size(), 12, "doce jugadores falsos")
	var spread: float = _max_pairwise_distance(list)
	assert_true(spread > 400.0, "repartidos por la zona (hasta %.0f m entre dos)" % spread)
	for entry: Dictionary in list:
		var position: Array = entry.get("position", [0.0, -999.0, 0.0])
		assert_true(float(position[1]) > -5.0 and float(position[1]) < 80.0,
				"%s sigue sobre el terreno (y = %.2f)" % [entry.get("name"), float(position[1])])
	assert_eq(int(report.get("physics_errors", -1)), 0, "sin errores de física")
	assert_eq(int(report.get("respawns", -1)), 0, "nadie cae fuera del mundo")
	assert_eq(int(report.get("teleports", -1)), 12, "cada uno se coloca con un teletransporte")
	assert_eq(_error_lines(log_path), PackedStringArray(), "sin errores en el registro")


func test_fake_churn_replaces_the_oldest_player_every_interval() -> void:
	var log_path: String = _build_path("test_server_main_g.log")
	var report_path: String = _build_path("test_server_main_g.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--zone=test_world", "--quit-after-ticks=330",
		"--fake-players=6", "--fake-churn=30", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra solo"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	var report: Dictionary = _read_report(report_path)
	var players: Dictionary = report.get("players", {})
	assert_eq(int(players.get("joined_total", 0)), 16, "6 de entrada y una alta cada 30 ticks (10)")
	assert_eq(int(players.get("left_total", 0)), 10, "y una baja cada 30 ticks")
	assert_eq(int(players.get("at_stop", 0)), 6, "siempre hay 6 jugadores")
	assert_eq(int(players.get("peak", 0)), 6, "sin pasar nunca de 6")
	assert_eq(_error_lines(log_path), PackedStringArray(), "sin errores en el registro")


func test_idle_quit_closes_a_server_without_players() -> void:
	var log_path: String = _build_path("test_server_main_c.log")
	var report_path: String = _build_path("test_server_main_c.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--zone=test_world", "--idle-quit=1",
		"--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra solo sin jugadores"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	var report: Dictionary = _read_report(report_path)
	var ticks: int = int(report.get("ticks", 0))
	assert_true(ticks >= 60 and ticks < 240, "cierra tras 1 s sin jugadores (%d ticks)" % ticks)
	assert_true(FileAccess.get_file_as_string(log_path).contains("--idle-quit"),
			"el registro dice por qué cierra")
	assert_eq(_error_lines(log_path), PackedStringArray(), "sin errores en el registro")


## Espera, hasta [constant MAX_WAIT_SECONDS], a que el registro del proceso contenga [param text].
func _wait_for_log(log_path: String, text: String, pid: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(log_path) \
				and FileAccess.get_file_as_string(log_path).contains(text):
			return true
		if not OS.is_process_running(pid):
			return false
		await tree.create_timer(0.1).timeout
	return false


## SIGTERM y SIGINT matan el proceso de Godot sin pasar por GDScript (no hay forma de atraparlos),
## así que no hay NOTICE de cierre ni informe (hallazgo S5). Para pararlo de forma ordenada desde
## fuera (systemd, un script) está --stop-file=<ruta>: el servidor mira cada segundo si el archivo
## existe y entonces hace el mismo cierre que --quit-after-ticks.
func test_stop_file_closes_the_server_in_an_orderly_way() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_h.log")
	var report_path: String = _build_path("test_server_main_h.json")
	var stop_path: String = _build_path("test_server_main_h.stop")
	for path: String in [report_path, stop_path]:
		DirAccess.remove_absolute(path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--fake-players=2", "--report=%s" % report_path,
		"--stop-file=%s" % stop_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_log(log_path, "escuchando en el puerto UDP", pid),
			"el servidor llega a escuchar"):
		return
	await tree.create_timer(1.0).timeout
	assert_true(OS.is_process_running(pid), "sigue en marcha mientras no exista el archivo")
	var stop_file: FileAccess = FileAccess.open(stop_path, FileAccess.WRITE)
	if not assert_not_null(stop_file, "se crea el archivo de parada"):
		return
	stop_file.store_string("parar")
	stop_file.close()
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra al ver el archivo"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("--stop-file"), "el registro dice por qué cierra")
	assert_true(log_text.contains("Servidor cerrado"), "y que se ha cerrado")
	var report: Dictionary = _read_report(report_path)
	assert_true(bool(report.get("closed", false)), "el informe final está marcado como cerrado")
	assert_eq(int((report.get("players", {}) as Dictionary).get("fake", 0)), 2, "con sus jugadores")
	assert_false(FileAccess.file_exists(stop_path), "y borra el archivo de parada para el próximo arranque")
	assert_eq(_error_lines(log_path), PackedStringArray(), "sin errores en el registro")


## Un archivo de parada que ya existía al arrancar es de una parada anterior: se borra y no mata al
## servidor nuevo.
func test_a_stale_stop_file_is_removed_at_startup() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_i.log")
	var stop_path: String = _build_path("test_server_main_i.stop")
	var stale: FileAccess = FileAccess.open(stop_path, FileAccess.WRITE)
	stale.store_string("viejo")
	stale.close()
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--quit-after-ticks=200",
		"--stop-file=%s" % stop_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor llega a --quit-after-ticks"):
		return
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Servidor cerrado"), "cierra por su cuenta")
	assert_true(log_text.contains("200 ticks"), "después de simular todos los ticks")
	assert_false(FileAccess.file_exists(stop_path), "el archivo viejo se ha borrado")


## Si matan al servidor (SIGTERM, SIGINT, docker stop...) no se escribe el informe final, pero con
## --report se reescribe cada 600 ticks (10 s), igual que el registro de estados se vuelca cada
## segundo: lo que queda en disco es el de la última marca.
func test_report_is_rewritten_periodically_so_a_killed_server_leaves_one() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_j.log")
	var report_path: String = _build_path("test_server_main_j.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--fake-players=3", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while not FileAccess.file_exists(report_path) and Time.get_ticks_msec() < deadline \
			and OS.is_process_running(pid):
		await tree.create_timer(0.2).timeout
	if not assert_true(FileAccess.file_exists(report_path), "aparece un informe sin cerrar el servidor"):
		return
	# Tras OS.kill() el motor olvida el proceso: preguntar por él registraría un error.
	OS.kill(pid)
	_pids.erase(pid)
	await tree.create_timer(0.5).timeout
	var report: Dictionary = _read_report(report_path)
	assert_eq(int(report.get("ticks", 0)), 600, "es el de la marca de 600 ticks")
	assert_false(bool(report.get("closed", true)), "y no está marcado como cerrado")
	assert_eq(int((report.get("players", {}) as Dictionary).get("current", 0)), 3, "con los 3 jugadores")
	assert_false(FileAccess.get_file_as_string(log_path).contains("Servidor cerrado"),
			"el cierre ordenado no llegó a ocurrir")


func test_unknown_zone_exits_with_error_code() -> void:
	var log_path: String = _build_path("test_server_main_d.log")
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--zone=atlantida", "--quit-after-ticks=60",
	]), log_path)
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	if not assert_true(await _wait_for_exit(pid), "el servidor termina"):
		return
	assert_eq(OS.get_process_exit_code(pid), 1, "código de salida 1")
	assert_true(FileAccess.get_file_as_string(log_path).contains("Zona desconocida: 'atlantida'"),
			"el registro dice cuál es la zona desconocida")


func test_dev_lock_file_is_written_and_only_removed_by_its_owner() -> void:
	assert_eq(ServerMain.write_dev_lock(LOCK_FILE, 4242, 24600), OK, "se escribe")
	var json := JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(LOCK_FILE)), OK, "es JSON")
	var data: Dictionary = json.data
	assert_eq(int(data.get("pid", 0)), 4242, "pid")
	assert_eq(int(data.get("port", 0)), 24600, "puerto")
	assert_false(ServerMain.remove_dev_lock(LOCK_FILE, 1111), "el bloqueo de otro servidor no se borra")
	assert_true(FileAccess.file_exists(LOCK_FILE), "sigue ahí")
	assert_true(ServerMain.remove_dev_lock(LOCK_FILE, 4242), "el dueño lo borra")
	assert_false(FileAccess.file_exists(LOCK_FILE), "ya no existe")
	assert_false(ServerMain.remove_dev_lock(LOCK_FILE, 4242), "borrar lo que no existe no hace nada")


func test_boot_ignores_network_arguments_in_the_sandbox_parser() -> void:
	var options: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--connect=127.0.0.1:24600", "--local", "--bot", "--bots=8", "--name=Ana", "--port=24601",
		"--net-sim=rtt=120,jitter=20", "--quit-after-ticks=100", "--report=informe.json",
		"--state-log=estados.csv", "--bot-seed=3", "--bot-cheat=flood",
	]))
	assert_eq((options["warnings"] as PackedStringArray).size(), 0,
			"los argumentos de red no son «desconocidos»")
	assert_eq(options["zone"], Zones.DEFAULT_ZONE, "y no cambian el sandbox")
