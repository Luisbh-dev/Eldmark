extends TestCase
## El servidor del fuerte como proceso aparte sobre el Vado Gris de verdad (paquete F3; GUE-08, GUE-12,
## GUE-17): la consola de la entrada estándar da la fortaleza a un reino, a otro y la devuelve a neutral, y
## el proceso deja su registro de batalla (JSON Lines, [code]--battle-log[/code]), el informe con la sección
## [code]war[/code] y un resumen que saca [code]tools/war/summarize_battle.gd[/code] del propio archivo.

## Tiempo máximo de espera a que el proceso termine o escriba una línea del registro (cada prueba dura
## menos de 30 s).
const MAX_WAIT_SECONDS: float = 22.0
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH

var _pids: Array[int] = []
var _pipes: Array[Dictionary] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	_pipes.clear()
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _wait_for_exit(pid: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline:
			return false
		await tree.create_timer(0.1).timeout
	return true


## Espera a que el registro del proceso contenga [param text]. false si pasa [constant MAX_WAIT_SECONDS].
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

func test_a_server_process_on_the_vado_gris_leaves_its_battle_log_report_and_summary() -> void:
	var port: int = NetHarness.free_udp_port()
	var log_path: String = NetHarness.build_path("test_fortress_processes.log")
	var report_path: String = NetHarness.build_path("test_fortress_processes.json")
	var battle_path: String = NetHarness.build_path("test_fortress_processes.jsonl")
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--",
		"--server", "--port=%d" % port, "--zone=vado_gris", "--quit-after-ticks=4000", "--console",
		"--no-dummies", "--report=%s" % report_path, "--battle-log=%s" % battle_path,
	])
	var process: Dictionary = OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if not assert_false(process.is_empty(), "el proceso del servidor se lanza con la entrada abierta"):
		return
	var pid: int = process["pid"]
	_pids.append(pid)
	_pipes.append(process)
	var stdin: FileAccess = process["stdio"]
	# Las órdenes se dan una a una: cada una cae en un tick distinto y deja su aviso de guerra.
	var steps: Array[Array] = [
		["fort_owner vardheim", "vado_gris_fort es ahora de Vardheim"],
		["fort_owner solmarch", "vado_gris_fort es ahora de Solmarch"],
		["fort_reset", "vado_gris_fort vuelve a ser neutral"],
	]
	for step: Array in steps:
		stdin.store_string("%s\n" % step[0])
		stdin.flush()
		if not assert_true(await _wait_for_log(log_path, step[1]), "la consola responde a «%s»" % step[0]):
			return
	stdin.store_string("shutdown 1\n")
	stdin.flush()
	if not assert_true(await _wait_for_log(log_path, "Servidor cerrado"), "la cuenta atrás cierra el servidor"):
		return
	# El hilo de la consola espera una línea más para dejar salir al proceso (límite conocido en Linux).
	stdin.store_string("\n")
	stdin.flush()
	assert_true(await _wait_for_exit(pid), "y el proceso termina")
	assert_eq(NetHarness.error_lines(log_path), PackedStringArray(), "sin errores en el registro")
	# El registro de batalla: la cabecera con la fortaleza real y los tres avisos, en orden.
	var lines: PackedStringArray = FileAccess.get_file_as_string(battle_path).strip_edges().split("\n")
	if not assert_true(lines.size() >= 4, "el registro de batalla tiene líneas (%d)" % lines.size()):
		return
	var first: Dictionary = JSON.parse_string(lines[0])
	assert_eq(first["event"], "battle_start")
	assert_eq(first["zone"], "vado_gris")
	var fortresses: Array = first["fortresses"]
	if assert_eq(fortresses.size(), 1, "una fortaleza"):
		assert_eq(fortresses[0]["id"], "vado_gris_fort")
		assert_eq(float(fortresses[0]["radius"]), 5.0, "el radio sale del marcador del círculo")
		assert_eq((fortresses[0]["gate"] as Array).size(), 3)
	var war_keys: Array[String] = []
	var war_realms: Array[int] = []
	var last_tick: int = 0
	for line: String in lines:
		var entry: Dictionary = JSON.parse_string(line)
		assert_true(int(entry["tick"]) >= last_tick, "los ticks no retroceden")
		last_tick = int(entry["tick"])
		if entry["event"] == "war":
			war_keys.append(entry["war"])
			war_realms.append(int(entry["realm"]))
	assert_eq(war_keys, ["fort_captured", "fort_captured", "fort_reset"] as Array[String])
	assert_eq(war_realms, [VARDHEIM, SOLMARCH, 0] as Array[int])
	# El informe cuenta la fortaleza y lo enviado.
	var report: Dictionary = _read_json(report_path)
	var war: Dictionary = report.get("war", {})
	var report_fortresses: Array = war.get("fortresses", [])
	if assert_eq(report_fortresses.size(), 1, "el informe lista la fortaleza"):
		assert_eq(report_fortresses[0]["id"], "vado_gris_fort")
		assert_eq(int(report_fortresses[0]["owner"]), 0, "neutral tras el reinicio")
		assert_eq(int(report_fortresses[0]["gate_health"]), 9000, "con la puerta de la definición real")
	assert_true(int(war.get("object_states_sent", 0)) >= 3, "un OBJECT_STATE por cada cambio de dueño")
	assert_eq(int(report.get("physics_errors", -1)), 0)
	# El resumen sale del archivo con la herramienta, como lo haría quien ajusta el fuerte.
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "-s", "res://tools/war/summarize_battle.gd", "--",
			battle_path, "--json"], output, true)
	var text: String = "\n".join(PackedStringArray(output))
	assert_eq(code, 0, text)
	# Entre la cabecera del motor y los avisos de cierre, el JSON va de la primera llave a la última.
	var json_start: int = text.find("{")
	var json_end: int = text.rfind("}")
	var summary: Variant = null
	if json_start >= 0 and json_end > json_start:
		summary = JSON.parse_string(text.substr(json_start, json_end - json_start + 1))
	if assert_true(summary is Dictionary, "la herramienta imprime el resumen en JSON"):
		var captures: Array = (summary as Dictionary)["captures"]
		assert_eq(captures.size(), 2, "dos capturas en la sesión")
		assert_eq(int(((summary as Dictionary)["war_events"] as Dictionary)["fort_reset"]), 1)
