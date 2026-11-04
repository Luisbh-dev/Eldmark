extends TestCase
## The fort server as a separate process on the real Vado Gris (package F3; GUE-08, GUE-12,
## GUE-17): the standard input console gives the fortress to one realm, to another and returns it to neutral, and
## the process leaves its battle log (JSON Lines, [code]--battle-log[/code]), the report with the
## [code]war[/code] section and a summary produced by [code]tools/war/summarize_battle.gd[/code] from the file itself.

## Maximum time to wait for the process to finish or write a log line (each test lasts
## less than 30 s).
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


# --- Helpers ----------------------------------------------------------------------------------

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


## Waits for the process log to contain [param text]. false if [constant MAX_WAIT_SECONDS] passes.
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
	if not assert_false(process.is_empty(), "the server process launches with the input open"):
		return
	var pid: int = process["pid"]
	_pids.append(pid)
	_pipes.append(process)
	var stdin: FileAccess = process["stdio"]
	# The orders are given one by one: each lands on a different tick and leaves its war notice.
	var steps: Array[Array] = [
		["fort_owner vardheim", "vado_gris_fort es ahora de Vardheim"],
		["fort_owner solmarch", "vado_gris_fort es ahora de Solmarch"],
		["fort_reset", "vado_gris_fort vuelve a ser neutral"],
	]
	for step: Array in steps:
		stdin.store_string("%s\n" % step[0])
		stdin.flush()
		if not assert_true(await _wait_for_log(log_path, step[1]), "the console answers to \"%s\"" % step[0]):
			return
	stdin.store_string("shutdown 1\n")
	stdin.flush()
	if not assert_true(await _wait_for_log(log_path, "Servidor cerrado"), "the countdown closes the server"):
		return
	# The console thread waits for one more line to let the process exit (known limit on Linux).
	# On Windows the process exits on its own, so the Enter is only written if it is still alive.
	if OS.is_process_running(pid):
		stdin.store_string("\n")
		stdin.flush()
	assert_true(await _wait_for_exit(pid), "and the process ends")
	assert_eq(NetHarness.error_lines(log_path), PackedStringArray(), "no errors in the log")
	# The battle log: the header with the real fortress and the three notices, in order.
	var lines: PackedStringArray = FileAccess.get_file_as_string(battle_path).strip_edges().split("\n")
	if not assert_true(lines.size() >= 4, "the battle log has lines (%d)" % lines.size()):
		return
	var first: Dictionary = JSON.parse_string(lines[0])
	assert_eq(first["event"], "battle_start")
	assert_eq(first["zone"], "vado_gris")
	var fortresses: Array = first["fortresses"]
	if assert_eq(fortresses.size(), 1, "a fortress"):
		assert_eq(fortresses[0]["id"], "vado_gris_fort")
		assert_eq(float(fortresses[0]["radius"]), 5.0, "the radius comes from the circle marker")
		assert_eq((fortresses[0]["gate"] as Array).size(), 3)
	var war_keys: Array[String] = []
	var war_realms: Array[int] = []
	var last_tick: int = 0
	for line: String in lines:
		var entry: Dictionary = JSON.parse_string(line)
		assert_true(int(entry["tick"]) >= last_tick, "the ticks do not go backwards")
		last_tick = int(entry["tick"])
		if entry["event"] == "war":
			war_keys.append(entry["war"])
			war_realms.append(int(entry["realm"]))
	assert_eq(war_keys, ["fort_captured", "fort_captured", "fort_reset"] as Array[String])
	assert_eq(war_realms, [VARDHEIM, SOLMARCH, 0] as Array[int])
	# The report counts the fortress and what was sent.
	var report: Dictionary = _read_json(report_path)
	var war: Dictionary = report.get("war", {})
	var report_fortresses: Array = war.get("fortresses", [])
	if assert_eq(report_fortresses.size(), 1, "the report lists the fortress"):
		assert_eq(report_fortresses[0]["id"], "vado_gris_fort")
		assert_eq(int(report_fortresses[0]["owner"]), 0, "neutral after the reset")
		assert_eq(int(report_fortresses[0]["gate_health"]), 9000, "with the gate from the real definition")
	assert_true(int(war.get("object_states_sent", 0)) >= 3, "one OBJECT_STATE per change of owner")
	assert_eq(int(report.get("physics_errors", -1)), 0)
	# The summary comes from the file with the tool, as someone tuning the fort would run it.
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "-s", "res://tools/war/summarize_battle.gd", "--",
			battle_path, "--json"], output, true)
	var text: String = "\n".join(PackedStringArray(output))
	assert_eq(code, 0, text)
	# Between the engine header and the shutdown notices, the JSON goes from the first brace to the last.
	var json_start: int = text.find("{")
	var json_end: int = text.rfind("}")
	var summary: Variant = null
	if json_start >= 0 and json_end > json_start:
		summary = JSON.parse_string(text.substr(json_start, json_end - json_start + 1))
	if assert_true(summary is Dictionary, "the tool prints the summary as JSON"):
		var captures: Array = (summary as Dictionary)["captures"]
		assert_eq(captures.size(), 2, "two captures in the session")
		assert_eq(int(((summary as Dictionary)["war_events"] as Dictionary)["fort_reset"]), 1)
