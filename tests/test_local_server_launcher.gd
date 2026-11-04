extends TestCase
## Tests for [LocalServerLauncher] and for the [code]--local[/code] mode (docs/red.md, 1.4 and 17.5).
## [br]- Arguments the server is launched with, inside and outside an export.
## [br]- Lock file: a fake lock counts as a live server if its pid is that of a process
## with the command line of a local server ([code]--server --dev-lock[/code]: a helper
## process, [code]tests/process_probe.gd[/code]) and does not count with a pid that does not exist or with that of a
## live process that is not a server (an orphaned lock with a reused pid); its own path is used
## so as not to overwrite the real [code]user://dev_server.json[/code].
## [br]- [method LocalServerLauncher.is_process_alive] with processes that this one did not launch (a child looks at
## the runner, a grandchild that the runner did not launch) and the reading of the output of [code]tasklist[/code].
## [br]- [OnlineMain] in LOCAL mode reuses the server named by the lock (without launching anything).
## [br]- Process test: a headless [code]--local[/code] client launches the server, connects to it,
## plays a few ticks and leaves without closing it.

const FAKE_LOCK_FILE: String = "test_local_server_launcher_lock.json"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
const REPORT_FILE: String = "test_local_mode_report.json"
## A pid that cannot exist (Linux and Windows pids do not reach 2^31 - 2).
const NO_SUCH_PID: int = 2147483646
## Seconds at most to wait for the process test's client to finish.
const PROCESS_TIMEOUT_MSEC: int = 26000
## Helper process for the tests of [method LocalServerLauncher.is_process_alive].
const PROBE_SCRIPT: String = "res://tests/process_probe.gd"
## Time (ms) at most to wait for a helper process.
const PROBE_TIMEOUT_MSEC: int = 15000

## Fake lock of this run (in build/<pid>/, not shared with another suite).
var _fake_lock: String = ""
var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _online: OnlineMain
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_lock_path: String
var _saved_max_fps: int = 0
## Helper processes launched by the current test (killed on finishing).
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


# --- Arguments --------------------------------------------------------------------------------

func test_build_args_matches_the_documented_command_line() -> void:
	var project: String = ProjectSettings.globalize_path("res://")
	var log_file: String = ProjectSettings.globalize_path("user://logs/dev_server.log")
	var args: PackedStringArray = LocalServerLauncher.build_args(24600, PackedStringArray(), false)
	assert_eq(args, PackedStringArray(["--headless", "--path", project, "--log-file", log_file, "--",
			"--server", "--port=24600", "--idle-quit=30", "--dev-lock"]))
	assert_true(log_file.is_absolute_path(), "the log goes with a system path, not user://")
	assert_true(project.is_absolute_path(), "and so does the project")


func test_build_args_in_an_export_has_no_path_and_appends_extras() -> void:
	var args: PackedStringArray = LocalServerLauncher.build_args(24777,
			PackedStringArray(["--zone=test_world", "--debug-commands"]), true)
	assert_false(args.has("--path"), "an export already carries the game")
	assert_eq(args[0], "--headless")
	var separator: int = args.find("--")
	assert_true(separator > 0, "user arguments go after --")
	assert_eq(args.slice(separator), PackedStringArray(["--", "--server", "--port=24777",
			"--idle-quit=30", "--dev-lock", "--zone=test_world", "--debug-commands"]))
	var default_args: PackedStringArray = LocalServerLauncher.build_args(24600, PackedStringArray())
	assert_eq(default_args.has("--path"), not OS.has_feature("template"),
			"by default it is decided with OS.has_feature(\"template\")")


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
			"with another lock, another log: the real local server's is not overwritten")
	assert_true(args.has("--dev-lock-path=%s" % lock), "and the server receives the option")
	assert_eq(LocalServerLauncher.log_path_for(""), ProjectSettings.globalize_path(LocalServerLauncher.LOG_PATH),
			"without its own lock, the usual log")


# --- Lock file --------------------------------------------------------------------------------

func test_find_running_with_a_fake_lock() -> void:
	assert_false(LocalServerLauncher.find_running(24600, _fake_lock), "without a file, there is no server")
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), -1)

	var server_pid: int = await _launch_fake_server()
	_write_lock(server_pid, 24600)
	assert_true(LocalServerLauncher.find_running(24600, _fake_lock),
			"the pid of a live local server (--server --dev-lock)")
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), 24600)
	assert_false(LocalServerLauncher.find_running(24601, _fake_lock), "but it serves on another port")
	assert_true(LocalServerLauncher.find_running(0, _fake_lock), "with port 0 any is valid")

	_write_lock(NO_SUCH_PID, 24600)
	assert_false(LocalServerLauncher.find_running(24600, _fake_lock), "a nonexistent pid does not count")
	assert_false(LocalServerLauncher.find_running(0, _fake_lock))
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), -1)
	assert_true(FileAccess.file_exists(_fake_lock), "and checking it does not delete the file")


## An orphaned lock whose pid has been reused (systemd, docker stop or Ctrl+C kill the server without
## it deleting its lock) is not a server: the live process is not one launched with
## [code]--server --dev-lock[/code]. This can only be checked where the command line is readable (Linux).
func test_a_live_process_that_is_not_a_dev_server_is_not_a_running_server() -> void:
	_write_lock(OS.get_process_id(), 24600)
	assert_true(LocalServerLauncher.is_process_alive(OS.get_process_id()), "the runner is alive")
	if not LocalServerLauncher.can_check_command_line():
		assert_true(LocalServerLauncher.is_dev_server_process(OS.get_process_id()),
				"unable to read the command line, a live process is valid")
		return
	assert_false(LocalServerLauncher.is_dev_server_process(OS.get_process_id()), "but it is not a server")
	assert_false(LocalServerLauncher.find_running(24600, _fake_lock), "its pid in a lock does not count")
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), -1)
	# And a foreign process that does carry both flags, does.
	var server_pid: int = await _launch_fake_server()
	assert_true(LocalServerLauncher.is_dev_server_process(server_pid))
	_write_lock(server_pid, 24600)
	assert_eq(LocalServerLauncher.get_running_port(_fake_lock), 24600)


func test_command_line_is_a_dev_server_only_with_both_flags_as_whole_arguments() -> void:
	var base := PackedStringArray(["godot", "--headless", "--path", "/p", "--log-file", "/l", "--"])
	assert_true(LocalServerLauncher.command_line_is_dev_server(base + PackedStringArray(
			["--server", "--port=24600", "--idle-quit=30", "--dev-lock"])))
	assert_false(LocalServerLauncher.command_line_is_dev_server(base + PackedStringArray(["--server"])),
			"a server without --dev-lock writes no lock")
	assert_false(LocalServerLauncher.command_line_is_dev_server(base + PackedStringArray(["--dev-lock"])))
	assert_false(LocalServerLauncher.command_line_is_dev_server(base + PackedStringArray(
			["--server", "--dev-lock-path=/x"])), "--dev-lock-path is not --dev-lock")
	assert_false(LocalServerLauncher.command_line_is_dev_server(base + PackedStringArray(
			["--filter=--server --dev-lock"])), "nor is the text inside another argument")
	assert_false(LocalServerLauncher.command_line_is_dev_server(PackedStringArray()))


func test_malformed_locks_are_not_a_running_server() -> void:
	for text: String in ["", "no es json", "[1, 2]", "{}", "{\"pid\": \"x\", \"port\": 24600}",
			"{\"pid\": 1}", "{\"port\": 24600}"]:
		var file: FileAccess = FileAccess.open(_fake_lock, FileAccess.WRITE)
		file.store_string(text)
		file.close()
		assert_true(LocalServerLauncher.read_lock(_fake_lock).is_empty(), "it is not a lock: %s" % text)
		assert_false(LocalServerLauncher.find_running(0, _fake_lock), text)
	_write_lock(OS.get_process_id(), 70000)
	assert_false(LocalServerLauncher.find_running(0, _fake_lock), "an out-of-range port is not valid")
	_write_lock(OS.get_process_id(), 24600)
	assert_eq(LocalServerLauncher.read_lock(_fake_lock), {"pid": OS.get_process_id(), "port": 24600})


func test_is_process_alive() -> void:
	assert_true(LocalServerLauncher.is_process_alive(OS.get_process_id()), "this process")
	assert_false(LocalServerLauncher.is_process_alive(NO_SUCH_PID), "one that does not exist")
	assert_false(LocalServerLauncher.is_process_alive(0))
	assert_false(LocalServerLauncher.is_process_alive(-5))


## The Windows branch of [method LocalServerLauncher.is_process_alive] queries [code]tasklist[/code]
## (OS.is_process_running only knows the processes launched by this same process). Here we check, on
## any platform, the command and how its output is read, which comes out in the system's language.
func test_tasklist_is_asked_for_one_pid_and_its_output_is_read_by_column() -> void:
	assert_eq(LocalServerLauncher.tasklist_args(12345), PackedStringArray(["/FI", "PID eq 12345",
			"/FO", "CSV", "/NH"]), "a single row, in CSV and without a header")
	var listed: String = "\"Godot_v4.7.2-stable_win64_console.exe\",\"12345\",\"Console\",\"1\",\"85.304 K\"\r\n"
	assert_true(LocalServerLauncher.tasklist_lists_pid(listed, 12345), "the pid is the second column")
	assert_false(LocalServerLauncher.tasklist_lists_pid(listed, 1), "the session number is not the pid")
	assert_false(LocalServerLauncher.tasklist_lists_pid(listed, 85), "nor the memory")
	assert_false(LocalServerLauncher.tasklist_lists_pid(listed, 123456), "nor a pid that starts the same")
	var two: String = "\"a.exe\",\"7\",\"Console\",\"1\",\"1 K\"\r\n\"12345.exe\",\"999\",\"Console\",\"1\",\"2 K\"\r\n"
	assert_true(LocalServerLauncher.tasklist_lists_pid(two, 999), "with several rows, in any of them")
	assert_false(LocalServerLauncher.tasklist_lists_pid(two, 12345), "the image name does not count")
	# With no matches tasklist exits with 0 and a warning in the system's language.
	for message: String in [
			"INFORMACIÓN: no hay tareas ejecutándose que coincidan con los criterios especificados.\r\n",
			"INFO: No tasks are running which match the specified criteria.\r\n",
			"INFORMATION : aucune tâche en service ne correspond aux critères spécifiés.\r\n", ""]:
		assert_false(LocalServerLauncher.tasklist_lists_pid(message, 12345), message)


## What happened on Windows: [method OS.is_process_running] only knows the processes launched by the
## process itself, so a second [code]--local[/code] window did not see the first one's server as alive.
## A child process checks this one's pid (which it did not launch).
func test_a_child_process_sees_this_process_as_alive() -> void:
	var out_path: String = NetHarness.build_path("probe_alive.json")
	DirAccess.remove_absolute(out_path)
	var pid: int = NetHarness.launch_script(PROBE_SCRIPT, PackedStringArray([
			"--probe-alive=%d" % OS.get_process_id(), "--probe-out=%s" % out_path]), "probe_alive")
	_probe_pids.append(pid)
	assert_true(pid > 0, "the helper process is launched")
	var result: Dictionary = await _wait_for_probe_result(out_path)
	assert_eq(result.get("alive"), true, "the helper process sees whoever launched it as alive, even though it did not launch it")


## A process that this one did not launch (a grandchild: launched by the helper process and seen by this one without being its
## parent) counts as alive while it exists and stops counting when it dies.
func test_a_grandchild_this_process_never_launched_is_seen_alive_until_it_dies() -> void:
	var out_path: String = NetHarness.build_path("probe_spawn.json")
	DirAccess.remove_absolute(out_path)
	var pid: int = NetHarness.launch_script(PROBE_SCRIPT, PackedStringArray([
			"--probe-spawn=20", "--probe-out=%s" % out_path, "--probe-dir=%s" % NetHarness.get_build_dir()]),
			"probe_spawn")
	_probe_pids.append(pid)
	assert_true(pid > 0, "the helper process is launched")
	var result: Dictionary = await _wait_for_probe_result(out_path)
	var grandchild: int = int(result.get("grandchild", -1))
	_probe_pids.append(grandchild)
	if not assert_true(grandchild > 0, "which launches another process"):
		return
	assert_true(LocalServerLauncher.is_process_alive(grandchild), "the grandchild is alive for whoever is not its parent")
	OS.kill(grandchild)
	var gone: bool = false
	for _i: int in 50:
		if not LocalServerLauncher.is_process_alive(grandchild):
			gone = true
			break
		await tree.create_timer(0.1).timeout
	assert_true(gone, "and stops being so when it dies")


# Launches a helper process with the command line of a local server (--server --dev-lock) that
# lives 25 s and acts as the server for the fake locks. Returns its pid once it looks like one (right
# after launching, and before the exec, Linux still shows it the command line of whoever launched it).
func _launch_fake_server() -> int:
	var pid: int = NetHarness.launch_script(PROBE_SCRIPT, PackedStringArray([
			"--server", "--dev-lock", "--probe-sleep=25"]), "probe_fake_server")
	_probe_pids.append(pid)
	var started_msec: int = Time.get_ticks_msec()
	while not LocalServerLauncher.is_dev_server_process(pid) \
			and Time.get_ticks_msec() - started_msec < PROBE_TIMEOUT_MSEC:
		await tree.create_timer(0.05).timeout
	return pid


# Waits for the helper process to write its result and returns it (empty if it does not arrive in time).
func _wait_for_probe_result(out_path: String) -> Dictionary:
	var started_msec: int = Time.get_ticks_msec()
	while not FileAccess.file_exists(out_path) and Time.get_ticks_msec() - started_msec < PROBE_TIMEOUT_MSEC:
		await tree.create_timer(0.1).timeout
	# The process opens the file and writes to it afterwards: we wait until there is content.
	await tree.create_timer(0.2).timeout
	return NetHarness.read_report(out_path)


# --- OnlineMain in LOCAL mode, reusing a server ------------------------------------------------

func test_local_mode_reuses_the_running_server_without_launching_another() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, NetZones.scene_path("test_world"))
	var server_config := ServerConfig.new()
	server_config.port = port
	server_config.zone_id = "test_world"
	_server = NetHarness.start_server(_server_viewport, server_config)
	await wait_physics_frames(3)
	# The lock says the server on the port is alive (a helper process with the command line
	# of a local server; the real server runs in this process).
	_write_lock(await _launch_fake_server(), port)
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
	assert_eq(config.port, port, "the client points at the lock's port")
	var client: NetClient = _online.get_client()
	assert_eq(client.connect_timeout_ms, LocalServerLauncher.CONNECT_TIMEOUT_MS,
			"with ENet's short timeout")
	var entered: bool = false
	for _i: int in 600:
		if client.get_state() == NetClient.State.IN_WORLD:
			entered = true
			break
		await tree.physics_frame
	assert_true(entered, "enters the world (state %s)" % NetClient.State.keys()[client.get_state()])
	assert_eq(_server.get_player_count(), 1)
	assert_true(_online.get_client() == client, "without retries: it is the same session")


# --- Process test -------------------------------------------------------------------------------

## A headless [code]--local[/code] client, with the server not yet launched: it launches it, retries until
## it answers, enters the world, plays 300 ticks and leaves. The server stays alive (the client does not
## close it) until the test kills it. The server's lock and log are specific to this
## run ([code]--dev-lock-path[/code], in [code]build/<pid>/[/code]): the real
## [code]user://dev_server.json[/code] of whoever runs the tests is not touched nor shared with another suite.
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
	assert_true(pid > 0, "the client is launched")
	if pid <= 0:
		return
	var started_msec: int = Time.get_ticks_msec()
	while OS.is_process_running(pid) and Time.get_ticks_msec() - started_msec < PROCESS_TIMEOUT_MSEC:
		await tree.create_timer(0.25).timeout
	var finished: bool = not OS.is_process_running(pid)
	if not finished:
		OS.kill(pid)
	assert_true(finished, "the client finishes in under %d s" % (PROCESS_TIMEOUT_MSEC / 1000))

	var report: Dictionary = NetHarness.read_report(report_path)
	assert_false(report.is_empty(), "and writes its report")
	assert_eq(report.get("mode"), "LOCAL")
	assert_eq(report.get("state"), "IN_WORLD", "entered the world (%s)" % report.get("disconnect_text"))
	assert_eq(int(report.get("port", 0)), port, "through the launched server's port")
	assert_eq(report.get("rejected"), false)
	assert_eq(report.get("zone"), "test_world", "the one requested from the launched server")
	assert_true(int(report.get("matches", 0)) > 50, "and the prediction matches the server")
	assert_eq(int(report.get("unexplained_diffs", -1)), 0)

	# The client launched it, and has gone: the server keeps running and wrote its lock.
	var lock: Dictionary = LocalServerLauncher.read_lock(lock_path)
	assert_eq(int(lock.get("port", 0)), port, "the own lock points at the launched server")
	assert_true(LocalServerLauncher.find_running(port, lock_path), "and the client did not close it on leaving")
	assert_true(FileAccess.file_exists(server_log), "with its log next to the lock")
	# The runner only sees its own process's errors: the client's and the server's logs are inspected.
	assert_eq(NetHarness.error_lines(NetHarness.build_path("test_local_mode_client.log")),
			PackedStringArray(), "no errors in the client's log")
	assert_eq(NetHarness.error_lines(server_log), PackedStringArray(), "nor in the launched server's")
	if int(lock.get("port", 0)) == port:
		OS.kill(int(lock["pid"]))
		for _i: int in 40:
			if not LocalServerLauncher.is_process_alive(int(lock["pid"])):
				break
			await tree.create_timer(0.1).timeout
		DirAccess.remove_absolute(lock_path)
