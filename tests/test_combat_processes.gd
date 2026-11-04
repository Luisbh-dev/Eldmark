extends TestCase
## The combat server as a separate process (docs/combate.md, sections 6 and 7; TEC-15 and TEC-19):
## fake players with the combat brain that fight each other and leave their combat log and their
## report, and the standard input console ([code]--console[/code]) read in a thread without stopping
## the tick: the server keeps simulating while it waits for lines and runs them at the start of a tick.

## Maximum time to wait for the process to finish (each test lasts less than 30 s).
const MAX_WAIT_SECONDS: float = 25.0

var _pids: Array[int] = []
## Pipes of the processes launched with standard input: if they are released, the child sees the end of
## the input.
var _pipes: Array[Dictionary] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	_pipes.clear()
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _server_args(user_args: PackedStringArray, log_path: String) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--",
		"--server",
	])
	args.append_array(user_args)
	return args


## Drains the pipes of the processes launched with standard input (on Windows they stall without this).
func _drain_pipes() -> void:
	for process: Dictionary in _pipes:
		NetHarness.drain_pipes(process)


func _wait_for_exit(pid: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline:
			return false
		_drain_pipes()
		await tree.create_timer(0.1).timeout
	return true


## Waits for the process log to contain [param text]. false if [constant MAX_WAIT_SECONDS]
## passes.
func _wait_for_log(log_path: String, text: String) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(log_path) and FileAccess.get_file_as_string(log_path).contains(text):
			return true
		_drain_pipes()
		await tree.create_timer(0.1).timeout
	return false


func _read_json(path: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("%s could not be read" % path)
		return {}
	return json.data


# --- Tests ------------------------------------------------------------------------------------

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
	if not assert_true(pid > 0, "the server process launches"):
		return
	_pids.append(pid)
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var report: Dictionary = _read_json(report_path)
	var combat: Dictionary = report.get("combat", {})
	assert_true(int(combat.get("hits", 0)) > 5, "the fakes hit each other (%s hits)" % combat.get("hits"))
	assert_true(int(combat.get("damage", 0)) > 0, "and do damage")
	assert_eq(int(combat.get("rewind_rejected", -1)), 0, "the fakes do not rewind")
	assert_eq(int(combat.get("dummies_created", -1)), 1, "the dummy of the test world was created")
	assert_eq(int((report.get("players", {}) as Dictionary).get("fake", 0)), 6)
	assert_eq(int(report.get("physics_errors", -1)), 0)
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Maniquíes de entrenamiento colocados: 1"), "the log counts the dummy")
	assert_eq(NetHarness.error_lines(log_path), PackedStringArray(), "no errors in the log")
	var lines: PackedStringArray = FileAccess.get_file_as_string(combat_log_path).strip_edges() \
			.split("\n")
	assert_eq(lines[0], ZoneServer.COMBAT_LOG_HEADER, "combat log header")
	assert_true(lines.size() > 5, "and one line per resolved hit (%d)" % (lines.size() - 1))
	var results: Dictionary = {}
	var ability_lines: int = 0
	var previous_tick: int = 0
	for index: int in range(1, lines.size()):
		var columns: PackedStringArray = lines[index].split(",")
		if columns.size() != 8:
			fail("line %d does not have 8 columns: %s" % [index, lines[index]])
			break
		results[columns[6]] = true
		assert_true(columns[0].to_int() >= previous_tick, "the ticks do not go backwards")
		previous_tick = columns[0].to_int()
		# The outcomes of a downed player (docs/habilidades.md, 4.5 and 4.7) carry the name of their source: finishing blow or
		# bleeding out (the combat fakes finish with damage, but a downed player can bleed out first). Since H5 the
		# fakes fight with the kit: an ability hit carries the ability's name (shield bash, charge).
		var outcome: bool = columns[6] == "bled_out" or columns[6] == "executed"
		var ability: bool = CombatCatalog.ability_id(StringName(columns[3])) != 0
		if ability:
			ability_lines += 1
		assert_true(columns[3].begins_with("sword_") or ability or (outcome and (columns[3] == "desangrado"
				or columns[3] == "remate")), "the attack carries its name (%s)" % lines[index])
	assert_true(results.has("hit"), "there are hits")
	assert_true(ability_lines > 0, "and some of ability: the fakes use the kit (H5)")


func test_the_console_reads_stdin_in_a_thread_and_does_not_stop_the_tick() -> void:
	var port: int = NetHarness.free_udp_port()
	var log_path: String = NetHarness.build_path("test_combat_processes_b.log")
	var report_path: String = NetHarness.build_path("test_combat_processes_b.json")
	var args: PackedStringArray = _server_args(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--quit-after-ticks=3000", "--fake-players=2",
		"--console", "--no-dummies", "--report=%s" % report_path,
	]), log_path)
	var process: Dictionary = OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if not assert_false(process.is_empty(), "the server process launches with the input open"):
		return
	var pid: int = process["pid"]
	_pids.append(pid)
	_pipes.append(process)
	var stdin: FileAccess = process["stdio"]
	# The lines arrive through the pipe before the server has started: they wait in the queue.
	stdin.store_string("help\n")
	stdin.store_string("players\n")
	stdin.store_string("announce Hola a todos\n")
	stdin.store_string("spawn_dummy 3 0 3 girando\n")
	stdin.store_string("kick Bot-01\n")
	stdin.store_string("volar alto\n")
	stdin.store_string("shutdown 1\n")
	stdin.flush()
	if not assert_true(await _wait_for_log(log_path, "Servidor cerrado"),
			"the shutdown countdown closes the server"):
		return
	# The reader thread keeps waiting for a line and, on Linux, the process does not exit until one
	# arrives (a known console limit): an operator Enter lets it exit. On Windows that limit does not
	# exist: the process exits on its own about 100 ms after closing, so it cannot be required to still be
	# alive nor can an Enter be written to it blindly.
	if OS.get_name() != "Windows":
		assert_true(OS.is_process_running(pid), "the process waits on standard input")
	if OS.is_process_running(pid):
		stdin.store_string("\n")
		stdin.flush()
	assert_true(await _wait_for_exit(pid), "and on pressing Enter it ends")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Consola de la entrada estándar activada"), "the console starts")
	assert_true(log_text.contains("[auditoría] consola: announce Hola a todos"), "audit of the announcement")
	assert_true(log_text.contains("Anuncio enviado a 0 jugadores"), "and its response")
	assert_true(log_text.contains("[auditoría] consola: spawn_dummy 3 0 3 girando"))
	assert_true(log_text.contains("Maniquí girando creado"))
	assert_true(log_text.contains("Jugador falso Bot-01 dado de baja"), "kick")
	assert_true(log_text.contains("Comando desconocido: volar"), "an unknown command is answered")
	assert_true(log_text.contains("[auditoría] consola: volar alto -> desconocido"), "and is also audited")
	assert_true(log_text.contains("Cuenta atrás de cierre cumplida"), "the countdown")
	assert_true(log_text.contains("Cierre del servidor: cierre pedido desde la consola"), "and the shutdown")
	assert_true(log_text.contains("La consola sigue leyendo la entrada estándar"),
			"and it warns that the process waits for the input to close")
	assert_eq(NetHarness.error_lines(log_path), PackedStringArray(), "no errors in the log")
	# The server kept simulating with the input open and no lines: the countdown second is
	# 60 real ticks, and the limit of 3000 was not reached.
	var report: Dictionary = _read_json(report_path)
	var ticks: int = int(report.get("ticks", 0))
	assert_true(ticks >= 60 and ticks < 1500, "the shutdown came through the console (%d ticks)" % ticks)
