extends TestCase
## Tests for [NetHarness] (the helpers for the network integration tests) and for command-line
## startup of both modes: a real server process and a real bot process, launched
## with [method NetHarness.launch_process] and checked through their reports.

const PROCESS_TIMEOUT_MSEC: int = 25000
## A pid that does not exist (it does not fit in Linux or Windows pids).
const DEAD_PID: int = 2147483000

var _viewports: Array[SubViewport] = []
var _pids: Array[int] = []


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_viewports.clear()
	for pid: int in _pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	await wait_process_frames()


func test_free_udp_port_gives_distinct_ports_that_can_be_bound() -> void:
	var first: int = NetHarness.free_udp_port()
	var second: int = NetHarness.free_udp_port()
	assert_true(first >= NetHarness.FIRST_PORT and first <= NetHarness.LAST_PORT)
	assert_true(second != first, "two consecutive calls do not give the same port")
	for port: int in [first, second]:
		var probe := PacketPeerUDP.new()
		assert_eq(probe.bind(port), OK, "port %d can be opened" % port)
		probe.close()
	# A port that is busy right after the last one handed out is skipped.
	var occupied := PacketPeerUDP.new()
	assert_eq(occupied.bind(second + 1), OK)
	var third: int = NetHarness.free_udp_port()
	assert_true(third != second + 1 and third > second, "the busy one is not handed out again (%d)" % third)
	occupied.close()
	# And one that an ENet server has open, neither.
	var enet := ENetMultiplayerPeer.new()
	assert_eq(enet.create_server(third + 1, 2, NetProtocol.CUSTOM_CHANNELS), OK)
	var fourth: int = NetHarness.free_udp_port()
	assert_true(fourth != third + 1, "nor that of an ENet server (%d)" % fourth)
	enet.close()


func test_each_process_starts_looking_for_ports_in_its_own_slot() -> void:
	var starts: Dictionary = {}
	for pid: int in range(5000, 5000 + NetHarness.PORT_SLOT_COUNT):
		var first: int = NetHarness.first_port_for(pid)
		assert_true(first >= NetHarness.FIRST_PORT and first + NetHarness.PORT_SLOT_SIZE <= NetHarness.LAST_PORT,
				"the slot of pid %d fits in the range (%d)" % [pid, first])
		starts[first] = true
	assert_eq(starts.size(), NetHarness.PORT_SLOT_COUNT, "consecutive pids, different slots")
	assert_eq(NetHarness.first_port_for(7), NetHarness.first_port_for(7 + NetHarness.PORT_SLOT_COUNT),
			"and they repeat every PORT_SLOT_COUNT pids")
	var port: int = NetHarness.free_udp_port()
	var slot_start: int = NetHarness.first_port_for(OS.get_process_id())
	assert_true(port >= NetHarness.FIRST_PORT and port <= NetHarness.LAST_PORT)
	assert_true(port >= slot_start or port < NetHarness.FIRST_PORT + NetHarness.PORT_SLOT_SIZE * 2,
			"this process searches starting from its slot (%d), not from the first port" % slot_start)


func test_build_files_live_in_a_folder_of_this_process() -> void:
	var dir: String = NetHarness.get_build_dir()
	assert_eq(dir.get_file(), str(OS.get_process_id()), "build/<pid>")
	assert_eq(dir.get_base_dir(), ProjectSettings.globalize_path("res://build"))
	assert_true(DirAccess.dir_exists_absolute(dir), "and it exists")
	assert_eq(NetHarness.build_path("informe.json"), dir.path_join("informe.json"))


func test_stale_build_folders_of_dead_processes_are_removed() -> void:
	var base: String = ProjectSettings.globalize_path("res://build")
	var dead: String = base.path_join(str(DEAD_PID))
	var named: String = base.path_join("test_harness_not_a_pid")
	DirAccess.make_dir_recursive_absolute(dead.path_join("sub"))
	DirAccess.make_dir_recursive_absolute(named)
	var file: FileAccess = FileAccess.open(dead.path_join("sub").path_join("np_a.log"), FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var mine: String = NetHarness.get_build_dir()
	var removed: int = NetHarness.clean_stale_build_dirs()
	assert_true(removed >= 1, "at least the dead process's one is deleted")
	assert_false(DirAccess.dir_exists_absolute(dead), "the folder of a process that no longer exists, with its contents")
	assert_true(DirAccess.dir_exists_absolute(mine), "this process's, no")
	assert_true(DirAccess.dir_exists_absolute(named), "nor those that are not a pid")
	DirAccess.remove_absolute(named)


func test_make_world_viewport_has_its_own_physics_world_and_zone() -> void:
	var first: SubViewport = NetHarness.make_world_viewport(tree.root, "")
	var second: SubViewport = NetHarness.make_world_viewport(tree.root,
			NetZones.scene_path("test_world"))
	_viewports.append(first)
	_viewports.append(second)
	for viewport: SubViewport in _viewports:
		assert_true(viewport.own_world_3d, "with its own world")
		assert_not_null(NetHarness.get_world(viewport), "and its zone")
	var first_world: World3D = first.find_world_3d()
	var second_world: World3D = second.find_world_3d()
	assert_true(first_world != second_world)
	assert_true(first_world != tree.root.find_world_3d())
	assert_true(first_world.space != second_world.space, "and its own physics space")
	assert_eq(NetHarness.get_world(second).name, "TestWorld")
	assert_eq(Zones.get_spawn_points(NetHarness.get_world(first), &"solmarch").size(), 1)


func test_error_lines_finds_engine_and_script_errors_in_a_log() -> void:
	var path: String = NetHarness.build_path("test_harness_errors.log")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("Godot Engine\nWARNING: solo un aviso\nERROR: algo falló\n   at: f (x.cpp:1)\n"
			+ "SCRIPT ERROR: Parse Error: otro\nfin\n")
	file.close()
	var found: PackedStringArray = NetHarness.error_lines(path)
	assert_eq(found, PackedStringArray(["ERROR: algo falló", "SCRIPT ERROR: Parse Error: otro"]))
	assert_eq(NetHarness.error_lines(NetHarness.build_path("test_harness_no_existe.log")), PackedStringArray(),
			"a log that does not exist has no errors")
	DirAccess.remove_absolute(path)


func test_read_report_survives_missing_and_broken_files() -> void:
	var dir: String = NetHarness.get_build_dir()
	assert_eq(NetHarness.read_report(dir.path_join("no_existe.json")), {})
	var broken_path: String = dir.path_join("test_harness_broken.json")
	var broken: FileAccess = FileAccess.open(broken_path, FileAccess.WRITE)
	broken.store_string("{esto no es json")
	broken.close()
	assert_eq(NetHarness.read_report(broken_path), {})
	var array_path: String = dir.path_join("test_harness_array.json")
	var array_file: FileAccess = FileAccess.open(array_path, FileAccess.WRITE)
	array_file.store_string("[1, 2]")
	array_file.close()
	assert_eq(NetHarness.read_report(array_path), {}, "a JSON that is not an object is not valid either")
	var good_path: String = dir.path_join("test_harness_good.json")
	var good: FileAccess = FileAccess.open(good_path, FileAccess.WRITE)
	good.store_string("{\"a\": 1}")
	good.close()
	assert_eq(NetHarness.read_report(good_path), {"a": 1.0})
	for path: String in [broken_path, array_path, good_path]:
		DirAccess.remove_absolute(path)


## A server and a bot, each in its own process (no window), launched as a user would:
## checks that [code]boot.gd[/code] routes [code]--server[/code] and [code]--bot[/code], that
## [ClientConfig] really reads the arguments and that both reports come out.
func test_server_and_bot_processes_play_together_and_write_their_reports() -> void:
	var server_report: String = NetHarness.build_path("test_harness_server.json")
	var bot_report: String = NetHarness.build_path("test_harness_bot.json")
	DirAccess.remove_absolute(server_report)
	DirAccess.remove_absolute(bot_report)
	var port: int = NetHarness.free_udp_port()
	var server_pid: int = NetHarness.launch_process(PackedStringArray([
		"--server", "--zone=test_world", "--port=%d" % port, "--quit-after-ticks=600",
		"--report=%s" % server_report,
	]), "test_harness_server")
	_pids.append(server_pid)
	assert_true(server_pid > 0, "the server is launched")
	# The server takes a while to load the zone and open the port: the bot retries until it connects.
	var bot_pid: int = -1
	var started: int = Time.get_ticks_msec()
	while bot_pid < 0 and Time.get_ticks_msec() - started < PROCESS_TIMEOUT_MSEC:
		await wait_process_frames(30)
		var server_log: String = NetHarness.build_path("test_harness_server.log")
		if FileAccess.file_exists(server_log) \
				and FileAccess.get_file_as_string(server_log).contains("escuchando"):
			bot_pid = NetHarness.launch_process(PackedStringArray([
				"--bot", "--connect=127.0.0.1:%d" % port, "--realm=solmarch", "--bot-seed=4",
				"--name=%s" % NameRules.bot_name(4), "--quit-after-ticks=300", "--report=%s" % bot_report,
			]), "test_harness_bot")
	_pids.append(bot_pid)
	assert_true(bot_pid > 0, "the server gets to listen and the bot is launched")
	while (OS.is_process_running(server_pid) or OS.is_process_running(bot_pid)) \
			and Time.get_ticks_msec() - started < PROCESS_TIMEOUT_MSEC:
		await wait_process_frames(30)
	assert_false(OS.is_process_running(bot_pid), "the bot finishes on its own")
	assert_false(OS.is_process_running(server_pid), "and the server too")

	var server: Dictionary = NetHarness.read_report(server_report)
	assert_eq(server.get("zone"), "test_world")
	assert_eq(int(server.get("ticks", 0)), 600)
	var players: Dictionary = server.get("players", {})
	assert_eq(int(players.get("joined_total", 0)), 1, "a player entered")
	assert_eq(int(players.get("left_total", 0)), 1, "and left")
	var bot: Dictionary = NetHarness.read_report(bot_report)
	assert_eq(bot.get("name"), NameRules.bot_name(4))
	assert_eq(bot.get("mode"), "BOT")
	assert_eq(bot.get("realm"), "Solmarch")
	assert_eq(bot.get("state"), "IN_WORLD")
	assert_eq(bot.get("zone"), "test_world")
	assert_true(int(bot.get("matches", 0)) > 50, "exact prediction between processes")
	assert_eq(int(bot.get("unexplained_diffs", -1)), 0, "no unexplained differences")
	assert_true(bool(bot.get("final", {}).get("exact", false)))
	assert_eq(NetHarness.error_lines(NetHarness.build_path("test_harness_server.log")), PackedStringArray(),
			"no errors in the server log")
	assert_eq(NetHarness.error_lines(NetHarness.build_path("test_harness_bot.log")), PackedStringArray(),
			"nor in the bot's")
	for path: String in [server_report, bot_report]:
		DirAccess.remove_absolute(path)
