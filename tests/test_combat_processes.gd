extends TestCase
## El servidor de combate como proceso aparte (docs/combate.md, secciones 6 y 7; TEC-15 y TEC-19):
## jugadores falsos con el cerebro de combate que pelean entre sí y dejan su registro de combate y su
## informe, y la consola de la entrada estándar ([code]--console[/code]) leída en un hilo sin parar
## el tick: el servidor sigue simulando mientras espera líneas y las ejecuta al empezar un tick.

## Tiempo máximo de espera a que el proceso termine (cada prueba dura menos de 30 s).
const MAX_WAIT_SECONDS: float = 25.0

var _pids: Array[int] = []
## Tuberías de los procesos lanzados con entrada estándar: si se liberan, el hijo ve el final de la
## entrada.
var _pipes: Array[Dictionary] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	_pipes.clear()
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _server_args(user_args: PackedStringArray, log_path: String) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--",
		"--server",
	])
	args.append_array(user_args)
	return args


func _wait_for_exit(pid: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline:
			return false
		await tree.create_timer(0.1).timeout
	return true


## Espera a que el registro del proceso contenga [param text]. false si pasa
## [constant MAX_WAIT_SECONDS].
func _wait_for_log(log_path: String, text: String) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(log_path) and FileAccess.get_file_as_string(log_path).contains(text):
			return true
		await tree.create_timer(0.1).timeout
	return false


func _read_json(path: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("no se pudo leer %s" % path)
		return {}
	return json.data


# --- Pruebas ----------------------------------------------------------------------------------

func test_combat_fakes_fight_in_a_server_process_and_leave_their_combat_log() -> void:
	var port: int = NetHarness.free_udp_port()
	var log_path: String = NetHarness.build_path("test_combat_processes_a.log")
	var report_path: String = NetHarness.build_path("test_combat_processes_a.json")
	var combat_log_path: String = NetHarness.build_path("test_combat_processes_a.txt")
	var pid: int = OS.create_process(OS.get_executable_path(), _server_args(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--quit-after-ticks=900", "--fake-players=6",
		"--fake-brain=combat", "--fake-layout=cluster", "--report=%s" % report_path,
		"--combat-log=%s" % combat_log_path,
	]), log_path))
	if not assert_true(pid > 0, "el proceso del servidor se lanza"):
		return
	_pids.append(pid)
	if not assert_true(await _wait_for_exit(pid), "el servidor se cierra solo"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "código de salida 0")
	var report: Dictionary = _read_json(report_path)
	var combat: Dictionary = report.get("combat", {})
	assert_true(int(combat.get("hits", 0)) > 5, "los falsos se pegan (%s golpes)" % combat.get("hits"))
	assert_true(int(combat.get("damage", 0)) > 0, "y hacen daño")
	assert_eq(int(combat.get("rewind_rejected", -1)), 0, "los falsos no rebobinan")
	assert_eq(int(combat.get("dummies_created", -1)), 1, "el maniquí del mundo de pruebas se creó")
	assert_eq(int((report.get("players", {}) as Dictionary).get("fake", 0)), 6)
	assert_eq(int(report.get("physics_errors", -1)), 0)
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Maniquíes de entrenamiento colocados: 1"), "el registro cuenta el maniquí")
	assert_eq(NetHarness.error_lines(log_path), PackedStringArray(), "sin errores en el registro")
	var lines: PackedStringArray = FileAccess.get_file_as_string(combat_log_path).strip_edges() \
			.split("\n")
	assert_eq(lines[0], ZoneServer.COMBAT_LOG_HEADER, "cabecera del registro de combate")
	assert_true(lines.size() > 5, "y una línea por golpe resuelto (%d)" % (lines.size() - 1))
	var results: Dictionary = {}
	var ability_lines: int = 0
	var previous_tick: int = 0
	for index: int in range(1, lines.size()):
		var columns: PackedStringArray = lines[index].split(",")
		if columns.size() != 8:
			fail("la línea %d no tiene 8 columnas: %s" % [index, lines[index]])
			break
		results[columns[6]] = true
		assert_true(columns[0].to_int() >= previous_tick, "los ticks no retroceden")
		previous_tick = columns[0].to_int()
		# Los desenlaces de un derribado (docs/habilidades.md, 4.5 y 4.7) llevan el nombre de su fuente: remate o
		# desangrado (los falsos de combate rematan con daño, pero un derribado puede desangrarse antes). Desde H5 los
		# falsos pelean con el kit: un golpe de habilidad lleva el nombre de la habilidad (golpe de escudo, embestida).
		var outcome: bool = columns[6] == "bled_out" or columns[6] == "executed"
		var ability: bool = CombatCatalog.ability_id(StringName(columns[3])) != 0
		if ability:
			ability_lines += 1
		assert_true(columns[3].begins_with("sword_") or ability or (outcome and (columns[3] == "desangrado"
				or columns[3] == "remate")), "el ataque lleva su nombre (%s)" % lines[index])
	assert_true(results.has("hit"), "hay golpes")
	assert_true(ability_lines > 0, "y alguno de habilidad: los falsos usan el kit (H5)")


func test_the_console_reads_stdin_in_a_thread_and_does_not_stop_the_tick() -> void:
	var port: int = NetHarness.free_udp_port()
	var log_path: String = NetHarness.build_path("test_combat_processes_b.log")
	var report_path: String = NetHarness.build_path("test_combat_processes_b.json")
	var args: PackedStringArray = _server_args(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--quit-after-ticks=3000", "--fake-players=2",
		"--console", "--no-dummies", "--report=%s" % report_path,
	]), log_path)
	var process: Dictionary = OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if not assert_false(process.is_empty(), "el proceso del servidor se lanza con la entrada abierta"):
		return
	var pid: int = process["pid"]
	_pids.append(pid)
	_pipes.append(process)
	var stdin: FileAccess = process["stdio"]
	# Las líneas llegan por la tubería antes de que el servidor haya arrancado: esperan en la cola.
	stdin.store_string("help\n")
	stdin.store_string("players\n")
	stdin.store_string("announce Hola a todos\n")
	stdin.store_string("spawn_dummy 3 0 3 girando\n")
	stdin.store_string("kick Bot-01\n")
	stdin.store_string("volar alto\n")
	stdin.store_string("shutdown 1\n")
	stdin.flush()
	if not assert_true(await _wait_for_log(log_path, "Servidor cerrado"),
			"la cuenta atrás de shutdown cierra el servidor"):
		return
	# El hilo lector sigue esperando una línea y, en Linux, el proceso no sale hasta que le llega una
	# (límite conocido de la consola): un Intro del operador lo deja salir.
	assert_true(OS.is_process_running(pid), "el proceso espera a la entrada estándar")
	stdin.store_string("\n")
	stdin.flush()
	assert_true(await _wait_for_exit(pid), "y al pulsar Intro termina")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Consola de la entrada estándar activada"), "la consola arranca")
	assert_true(log_text.contains("[auditoría] consola: announce Hola a todos"), "auditoría del anuncio")
	assert_true(log_text.contains("Anuncio enviado a 0 jugadores"), "y su respuesta")
	assert_true(log_text.contains("[auditoría] consola: spawn_dummy 3 0 3 girando"))
	assert_true(log_text.contains("Maniquí girando creado"))
	assert_true(log_text.contains("Jugador falso Bot-01 dado de baja"), "kick")
	assert_true(log_text.contains("Comando desconocido: volar"), "un comando desconocido se responde")
	assert_true(log_text.contains("[auditoría] consola: volar alto -> desconocido"), "y también se audita")
	assert_true(log_text.contains("Cuenta atrás de cierre cumplida"), "la cuenta atrás")
	assert_true(log_text.contains("Cierre del servidor: cierre pedido desde la consola"), "y el cierre")
	assert_true(log_text.contains("La consola sigue leyendo la entrada estándar"),
			"y avisa de que el proceso espera a que se cierre la entrada")
	assert_eq(NetHarness.error_lines(log_path), PackedStringArray(), "sin errores en el registro")
	# El servidor siguió simulando con la entrada abierta y sin líneas: el segundo de cuenta atrás son
	# 60 ticks de verdad, y no se llegó a los 3000 del límite.
	var report: Dictionary = _read_json(report_path)
	var ticks: int = int(report.get("ticks", 0))
	assert_true(ticks >= 60 and ticks < 1500, "el cierre llegó por la consola (%d ticks)" % ticks)
