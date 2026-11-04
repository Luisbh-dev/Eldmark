extends TestCase
## Tests for [ServerMain] and the [code]--server[/code] mode of [code]boot.gd[/code], with the
## server started as a separate process (docs/red.md, section 16):
## [code]OS.create_process(OS.get_executable_path(), [--headless, --path, …, --, --server, …])[/code].
## [br][br]
## It checks that it starts, simulates and shuts down on its own with [code]--quit-after-ticks[/code] and
## [code]--idle-quit[/code] (exit code 0), that it writes the [code]--report[/code] report and
## the [code]--state-log[/code] CSV, that the log contains no engine or script errors,
## and that an unknown zone exits with code 1. One of the tests uses the real zone, Vado
## Gris, with Terrain3D.
## [br][br]
## [code]--dev-lock[/code] is only used with [code]--dev-lock-path[/code] (a file in
## [code]build/<pid>/[/code]): without it, it would write the real [code]user://dev_server.json[/code] of whoever
## runs the tests. The lock file is also tested with its static functions.

const BootScript = preload("res://scripts/boot.gd")
## Maximum time to wait for the process to finish (each test lasts under 30 s).
const MAX_WAIT_SECONDS: float = 25.0
const LOCK_FILE_NAME: String = "test_server_main_lock.json"

var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	if FileAccess.file_exists(_lock_file()):
		DirAccess.remove_absolute(_lock_file())
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _build_path(file_name: String) -> String:
	return NetHarness.build_path(file_name)


## Lock file for the static tests (in build/<pid>/, not shared with another suite).
func _lock_file() -> String:
	return NetHarness.build_path(LOCK_FILE_NAME)


## Launches the server with [param user_args] (those after [code]--[/code]). Returns the pid.
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


## Waits for the process to finish. false if [constant MAX_WAIT_SECONDS] passes.
func _wait_for_exit(pid: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline:
			return false
		await tree.create_timer(0.1).timeout
	return true


func _find_free_port() -> int:
	return NetHarness.free_udp_port()


func _read_report(path: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("the report %s could not be read" % path)
		return {}
	return json.data


## Lines of the process log that contain engine or script errors.
func _error_lines(log_path: String) -> PackedStringArray:
	return NetHarness.error_lines(log_path)


# --- Tests ------------------------------------------------------------------------------------

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
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")

	var report: Dictionary = _read_report(report_path)
	assert_eq(int(report.get("version", 0)), 1, "report version")
	assert_eq(report.get("zone"), "test_world", "zone")
	assert_eq(int(report.get("port", 0)), port, "port")
	assert_eq(int(report.get("ticks", 0)), 300, "300 simulated ticks")
	assert_eq(int(report.get("tick_rate", 0)), 60, "60 ticks per second")
	var players: Dictionary = report.get("players", {})
	assert_eq(int(players.get("fake", 0)), 4, "four fake players")
	assert_eq(int(players.get("peak", 0)), 4, "peak of four players")
	assert_eq(int(players.get("at_stop", 0)), 4, "four players at shutdown")
	assert_eq((report.get("player_list", []) as Array).size(), 4, "four player records")
	assert_eq(int(report.get("physics_errors", -1)), 0, "no physics errors")
	assert_eq(int(report.get("respawns", -1)), 0, "nobody falls out of the world")
	var sections: Dictionary = (report.get("metrics", {}) as Dictionary).get("sections", {})
	var tick_section: Dictionary = sections.get("tick", {})
	assert_eq(int(tick_section.get("samples", 0)), 300, "300 measurements of the tick duration")
	assert_true(int(tick_section.get("p99", 0)) > 0, "p99 of the measured tick")

	# --state-log: one line per tick and player.
	var lines: PackedStringArray = FileAccess.get_file_as_string(states_path).strip_edges() \
			.split("\n")
	assert_eq(lines.size(), 300 * 4, "one line per tick and player in the CSV")

	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("escuchando en el puerto UDP %d" % port), "the log states the port")
	assert_true(log_text.contains("Alta de Bot-01"), "and the joins")
	assert_true(log_text.contains("Simulador de red: rtt=80"), "and the network simulator")
	assert_true(log_text.contains("Servidor cerrado"), "and the shutdown")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


func test_vado_gris_server_process_runs_and_closes_cleanly() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_b.log")
	var report_path: String = _build_path("test_server_main_b.json")
	DirAccess.remove_absolute(report_path)
	# Without --zone: the default zone is Vado Gris, with its real Terrain3D.
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--quit-after-ticks=600", "--fake-players=2", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")

	var report: Dictionary = _read_report(report_path)
	assert_eq(report.get("zone"), String(Zones.DEFAULT_ZONE), "serves the default zone")
	assert_eq(int(report.get("ticks", 0)), 600, "600 simulated ticks")
	assert_eq(int(report.get("physics_errors", -1)), 0, "no physics errors")
	assert_eq(int(report.get("respawns", -1)), 0, "nobody falls out of the world")
	var list: Array = report.get("player_list", [])
	if assert_eq(list.size(), 2, "two fake players"):
		var realms: Array[String] = []
		for entry: Dictionary in list:
			realms.append(entry.get("realm", ""))
			var position: Array = entry.get("position", [0.0, -999.0, 0.0])
			assert_true(float(position[1]) > -5.0 and float(position[1]) < 60.0,
					"%s stays on the terrain (y = %.2f)" % [entry.get("name"), float(position[1])])
			assert_true(absf(float(position[0])) < 2600.0 and absf(float(position[2])) < 2600.0,
					"%s stays inside the zone" % entry.get("name"))
		assert_eq(realms, ["Vardheim", "Solmarch"], "one fake player from each realm with a camp")

	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("nodos solo visuales quitados"), "the zone's visuals are removed")
	assert_true(log_text.contains("Servidor cerrado"), "it shuts down")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


func test_siege_fake_brain_marches_to_the_fort_and_run_at_opens_the_circle() -> void:
	var log_path: String = _build_path("test_server_main_k.log")
	var report_path: String = _build_path("test_server_main_k.json")
	DirAccess.remove_absolute(report_path)
	# Vado Gris (default): four siege fake players, two per realm, and the command that kills the captain at tick 300.
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--quit-after-ticks=900", "--fake-players=4", "--fake-brain=siege",
		"--run-at=300:fort_kill_captain", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("--run-at (tick 300): fort_kill_captain -> El capitán de vado_gris_fort ha muerto"),
			"the scheduled command runs on its tick")
	var report: Dictionary = _read_report(report_path)
	var fortresses: Array = (report.get("war", {}) as Dictionary).get("fortresses", [])
	if assert_eq(fortresses.size(), 1, "a fort"):
		assert_eq(int((fortresses[0] as Dictionary).get("phase", -1)), FortressState.Phase.VULNERABLE,
				"without a captain the circle is open")
	var list: Array = report.get("player_list", [])
	assert_eq(list.size(), 4, "four fake players")
	for entry: Dictionary in list:
		var position: Array = entry.get("position", [0.0, 0.0, 0.0])
		var camp_z: float = -138.0 if entry.get("realm") == "Vardheim" else 138.0
		# By 15 s they have already left the camp (at least 9 m) and are heading toward the fort.
		assert_true(absf(float(position[2]) - camp_z) > 9.0 and absf(float(position[2])) < absf(camp_z),
				"%s (%s) marches toward the fort (z = %.1f)" % [entry.get("name"), entry.get("realm"), float(position[2])])
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


## Greatest distance (m) between two players in the report's list.
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
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var report: Dictionary = _read_report(report_path)
	var list: Array = report.get("player_list", [])
	assert_eq(list.size(), 12, "twelve fake players")
	var realms: Dictionary = {}
	for entry: Dictionary in list:
		realms[entry.get("realm")] = true
	assert_eq(realms.size(), 1, "all from the same realm: %s" % [realms.keys()])
	var spread: float = _max_pairwise_distance(list)
	assert_true(spread < 60.0, "none more than 60 m from another (%.1f m)" % spread)
	assert_eq(int(report.get("physics_errors", -1)), 0, "no physics errors")
	assert_eq(int(report.get("respawns", -1)), 0, "nobody falls out of the world")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


func test_fake_layout_spread_scatters_the_players_over_the_terrain() -> void:
	var log_path: String = _build_path("test_server_main_f.log")
	var report_path: String = _build_path("test_server_main_f.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--quit-after-ticks=420", "--fake-players=12",
		"--fake-layout=spread", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var report: Dictionary = _read_report(report_path)
	var list: Array = report.get("player_list", [])
	assert_eq(list.size(), 12, "twelve fake players")
	var spread: float = _max_pairwise_distance(list)
	assert_true(spread > 400.0, "spread across the zone (up to %.0f m between two)" % spread)
	for entry: Dictionary in list:
		var position: Array = entry.get("position", [0.0, -999.0, 0.0])
		assert_true(float(position[1]) > -5.0 and float(position[1]) < 80.0,
				"%s stays on the terrain (y = %.2f)" % [entry.get("name"), float(position[1])])
	assert_eq(int(report.get("physics_errors", -1)), 0, "no physics errors")
	assert_eq(int(report.get("respawns", -1)), 0, "nobody falls out of the world")
	assert_eq(int(report.get("teleports", -1)), 12, "each one is placed with a teleport")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


func test_fake_churn_replaces_the_oldest_player_every_interval() -> void:
	var log_path: String = _build_path("test_server_main_g.log")
	var report_path: String = _build_path("test_server_main_g.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--zone=test_world", "--quit-after-ticks=330",
		"--fake-players=6", "--fake-churn=30", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var report: Dictionary = _read_report(report_path)
	var players: Dictionary = report.get("players", {})
	assert_eq(int(players.get("joined_total", 0)), 16, "6 at the start and one join every 30 ticks (10)")
	assert_eq(int(players.get("left_total", 0)), 10, "and one leave every 30 ticks")
	assert_eq(int(players.get("at_stop", 0)), 6, "there are always 6 players")
	assert_eq(int(players.get("peak", 0)), 6, "never going over 6")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


## Launches a swarm ([code]--bots[/code]) against the server on port [param port].
func _launch_swarm(user_args: PackedStringArray, log_path: String) -> int:
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--",
	])
	args.append_array(user_args)
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	if pid > 0:
		_pids.append(pid)
	return pid


func test_max_realm_diff_rejects_people_and_makes_the_fake_fillers_leave() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_l.log")
	var swarm_log: String = _build_path("test_server_main_l_swarm.log")
	var report_path: String = _build_path("test_server_main_l.json")
	DirAccess.remove_absolute(report_path)
	# Test zone (three realms): six filler fake players, two per realm; up to a lead of 1 human. The server
	# is full of filler only (--max-players=6, GUE-43): the human gets in anyway and a fake player sets aside its slot, which it
	# gives up when the human enters the world.
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--quit-after-ticks=840", "--fake-players=6",
		"--max-players=6", "--max-realm-diff=1", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	var started: bool = false
	for _i: int in 200:
		if FileAccess.get_file_as_string(log_path).contains("escuchando en el puerto"):
			started = true
			break
		await tree.create_timer(0.1).timeout
	if not assert_true(started, "the server listens"):
		return
	# Three Vardheim humans: the first gets in (1 against 0) and the other two are rejected (2 against 0).
	var swarm_pid: int = _launch_swarm(PackedStringArray([
		"--bots=3", "--connect=127.0.0.1:%d" % port, "--realm=vardheim", "--bot-seed=300",
		"--quit-after-ticks=500",
	]), swarm_log)
	assert_true(swarm_pid > 0, "the swarm launches")
	assert_true(await _wait_for_exit(pid), "the server shuts down on its own")
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var report: Dictionary = _read_report(report_path)
	var rejects: Dictionary = report.get("rejects", {})
	assert_eq(int(rejects.get(NetProtocol.result_text(NetProtocol.Result.IMBALANCE), 0)), 2,
			"two of the three are rejected for imbalance: %s" % [rejects])
	assert_false(rejects.has(NetProtocol.result_text(NetProtocol.Result.FULL)),
			"nobody receives \"lleno\" (full): the filler does not take human slots (%s)" % [rejects])
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Equilibrio de reinos: diferencia máxima de 1"), "the log announces it")
	assert_true(log_text.contains("un falso de relleno aparta su plaza"), "with the server full, a fake player sets aside its slot")
	var retired: Array[String] = []
	var added_back: Array[String] = []
	for line: String in log_text.split("\n"):
		if line.contains("Baja de Bot-") and line.contains("jugador falso"):
			retired.append(line)
		elif line.contains("Alta de Bot-07") and line.contains("jugador falso"):
			added_back.append(line)
	assert_eq(retired.size(), 1, "a human joins Vardheim and a single fake player is removed")
	if not retired.is_empty():
		assert_true(retired[0].contains("Baja de Bot-01"), "the oldest of Vardheim: %s" % retired[0])
	assert_eq(added_back.size(), 1, "when the human leaves, a fake player joins again")
	if not added_back.is_empty():
		assert_true(added_back[0].contains("Vardheim"), "in the realm that has fallen short: %s" % added_back[0])
	assert_true(log_text.contains("Alta de Bot-01 (jugador falso, net_id 1, Vardheim)"), "the filler fake players start with Vardheim")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


func test_idle_quit_closes_a_server_without_players() -> void:
	var log_path: String = _build_path("test_server_main_c.log")
	var report_path: String = _build_path("test_server_main_c.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--zone=test_world", "--idle-quit=1",
		"--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on its own with no players"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var report: Dictionary = _read_report(report_path)
	var ticks: int = int(report.get("ticks", 0))
	assert_true(ticks >= 60 and ticks < 240, "shuts down after 1 s with no players (%d ticks)" % ticks)
	assert_true(FileAccess.get_file_as_string(log_path).contains("--idle-quit"),
			"the log says why it shuts down")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


## Waits, up to [constant MAX_WAIT_SECONDS], for the process log to contain [param text].
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


## SIGTERM and SIGINT kill the Godot process without passing through GDScript (there is no way to catch them),
## so there is no shutdown NOTICE or report (finding S5). To stop it in an orderly way from
## outside (systemd, a script) there is --stop-file=<path>: the server checks every second whether the file
## exists and then performs the same shutdown as --quit-after-ticks.
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
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_log(log_path, "escuchando en el puerto UDP", pid),
			"the server gets to listening"):
		return
	await tree.create_timer(1.0).timeout
	assert_true(OS.is_process_running(pid), "it keeps running while the file does not exist")
	var stop_file: FileAccess = FileAccess.open(stop_path, FileAccess.WRITE)
	if not assert_not_null(stop_file, "the stop file is created"):
		return
	stop_file.store_string("parar")
	stop_file.close()
	if not assert_true(await _wait_for_exit(pid), "the server shuts down on seeing the file"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("--stop-file"), "the log says why it shuts down")
	assert_true(log_text.contains("Servidor cerrado"), "and that it has shut down")
	var report: Dictionary = _read_report(report_path)
	assert_true(bool(report.get("closed", false)), "the final report is marked as closed")
	assert_eq(int((report.get("players", {}) as Dictionary).get("fake", 0)), 2, "with its players")
	assert_false(FileAccess.file_exists(stop_path), "and it deletes the stop file for the next startup")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


## A stop file that already existed at startup belongs to an earlier stop: it is deleted and does not kill the
## new server.
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
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server reaches --quit-after-ticks"):
		return
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Servidor cerrado"), "shuts down on its own")
	assert_true(log_text.contains("200 ticks"), "after simulating all the ticks")
	assert_false(FileAccess.file_exists(stop_path), "the old file has been deleted")


## If the server is killed (SIGTERM, SIGINT, docker stop...) the final report is not written, but with
## --report it is rewritten every 600 ticks (10 s), just as the state log is flushed every
## second: what remains on disk is that of the last mark.
func test_report_is_rewritten_periodically_so_a_killed_server_leaves_one() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_j.log")
	var report_path: String = _build_path("test_server_main_j.json")
	DirAccess.remove_absolute(report_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--fake-players=3", "--report=%s" % report_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	var deadline: int = Time.get_ticks_msec() + int(MAX_WAIT_SECONDS * 1000.0)
	while not FileAccess.file_exists(report_path) and Time.get_ticks_msec() < deadline \
			and OS.is_process_running(pid):
		await tree.create_timer(0.2).timeout
	if not assert_true(FileAccess.file_exists(report_path), "a report appears without the server shutting down"):
		return
	# After OS.kill() the engine forgets the process: asking about it would log an error.
	OS.kill(pid)
	_pids.erase(pid)
	await tree.create_timer(0.5).timeout
	var report: Dictionary = _read_report(report_path)
	assert_eq(int(report.get("ticks", 0)), 600, "it is the one from the 600-tick mark")
	assert_false(bool(report.get("closed", true)), "and it is not marked as closed")
	assert_eq(int((report.get("players", {}) as Dictionary).get("current", 0)), 3, "with the 3 players")
	assert_false(FileAccess.get_file_as_string(log_path).contains("Servidor cerrado"),
			"the orderly shutdown never happened")


func test_dev_lock_is_written_at_the_given_path_while_listening_and_removed_on_close() -> void:
	var port: int = _find_free_port()
	var log_path: String = _build_path("test_server_main_j.log")
	var lock_path: String = _build_path("test_server_main_j_lock.json")
	DirAccess.remove_absolute(lock_path)
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % port, "--zone=test_world", "--quit-after-ticks=420", "--dev-lock",
		"--dev-lock-path=%s" % lock_path,
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	var deadline: int = Time.get_ticks_msec() + 15000
	while not FileAccess.file_exists(lock_path) and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.1).timeout
	if not assert_true(FileAccess.file_exists(lock_path), "writes the lock at the given path"):
		return
	var lock: Dictionary = LocalServerLauncher.read_lock(lock_path)
	assert_eq(int(lock.get("pid", 0)), pid, "with its pid")
	assert_eq(int(lock.get("port", 0)), port, "and its port")
	assert_true(LocalServerLauncher.find_running(port, lock_path), "and --local would see it as a live server")
	assert_true(await _wait_for_exit(pid), "the server shuts down on its own")
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	assert_false(FileAccess.file_exists(lock_path), "and on shutdown it deletes its lock")
	assert_false(LocalServerLauncher.find_running(port, lock_path), "there is no server anymore")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	assert_true(log_text.contains("Archivo de bloqueo escrito: %s" % lock_path), "the log says where")
	assert_eq(_error_lines(log_path), PackedStringArray(), "no errors in the log")


func test_unknown_zone_exits_with_error_code() -> void:
	var log_path: String = _build_path("test_server_main_d.log")
	var pid: int = _launch(PackedStringArray([
		"--port=%d" % _find_free_port(), "--zone=atlantida", "--quit-after-ticks=60",
	]), log_path)
	if not assert_true(pid > 0, "the server process launches"):
		return
	if not assert_true(await _wait_for_exit(pid), "the server terminates"):
		return
	assert_eq(OS.get_process_exit_code(pid), 1, "exit code 1")
	assert_true(FileAccess.get_file_as_string(log_path).contains("Zona desconocida: 'atlantida'"),
			"the log says which zone is unknown")


func test_dev_lock_file_is_written_and_only_removed_by_its_owner() -> void:
	assert_eq(ServerMain.write_dev_lock(_lock_file(), 4242, 24600), OK, "it is written")
	var json := JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(_lock_file())), OK, "it is JSON")
	var data: Dictionary = json.data
	assert_eq(int(data.get("pid", 0)), 4242, "pid")
	assert_eq(int(data.get("port", 0)), 24600, "port")
	assert_false(ServerMain.remove_dev_lock(_lock_file(), 1111), "another server's lock is not deleted")
	assert_true(FileAccess.file_exists(_lock_file()), "it is still there")
	assert_true(ServerMain.remove_dev_lock(_lock_file(), 4242), "the owner deletes it")
	assert_false(FileAccess.file_exists(_lock_file()), "it no longer exists")
	assert_false(ServerMain.remove_dev_lock(_lock_file(), 4242), "deleting what does not exist does nothing")


func test_boot_ignores_network_arguments_in_the_sandbox_parser() -> void:
	var options: Dictionary = BootScript.parse_client_options(PackedStringArray([
		"--connect=127.0.0.1:24600", "--local", "--bot", "--bots=8", "--name=Ana", "--port=24601",
		"--net-sim=rtt=120,jitter=20", "--quit-after-ticks=100", "--report=informe.json",
		"--state-log=estados.csv", "--bot-seed=3", "--bot-cheat=flood",
	]))
	assert_eq((options["warnings"] as PackedStringArray).size(), 0,
			"the network arguments are not \"unknown\"")
	assert_eq(options["zone"], Zones.DEFAULT_ZONE, "and do not change the sandbox")
