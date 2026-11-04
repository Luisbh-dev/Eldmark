extends TestCase
## Real multi-process tests (docs/red.md, section 16, "Multiple processes"; TEC-10 and TEC-46): a
## headless server and two bots, each in its own Godot process, with real ENet over 127.0.0.1,
## launched with [method NetHarness.launch_process] and waited on for at most 25 s.
## [br][br]
## [b]Determinism between processes[/b] (in Vado Gris, the real zone, with its Terrain3D): each bot
## compares its predicted state with the server's at every snapshot. Without a network simulator
## there can be no unexplained difference (one that does not match a substituted input), and the
## comparison of the state logs ([StateLogComparer], the logic of
## [code]tools/compare_state_logs.gd[/code]) confirms it. The server also carries fake players:
## their bodies exist in the server's physics space and not in the bots', so it is also checked that
## they do not alter Jolt queries.
## [br]A second pass with [code]--net-sim[/code] on the bots: exact final convergence and no hard
## resync.
## [br][br]
## [b]Cheating bot[/b] ([code]--bot-cheat[/code], one method per mode, in [code]test_world[/code] so
## it is fast): rejected or kicked, without the honest bot having unexplained differences and
## without the server logging errors in its log.
## [br][br]
## [b]Combat cheating bot[/b] ([code]rewind[/code], [code]reach[/code] and [code]rate[/code], all
## three at once against the dummy in [code]test_world[/code]): none deals extra damage.
## [br][br]
## [b]Swarm[/b] ([code]--bots=N[/code], [BotSwarm]): one process with six lightweight clients
## against the server.
## [br][br]
## The logs and reports end up in [code]build/<pid>/np_*[/code] ([method NetHarness.build_path]:
## one folder per test process, so two suites at once do not step on each other; the state ones
## with a [code].txt[/code] extension: the importer turns the project's [code].csv[/code] files
## into translations).

## Maximum time to wait for all the processes (each test lasts less than 30 s).
const MAX_WAIT_SECONDS: float = 25.0
## Zone for the cheater tests: the flat circuit, which loads instantly.
const LIGHT_ZONE: String = "test_world"
## The server is closed by the stop file as soon as all the bots have left; its
## [code]--quit-after-ticks[/code] (the requested ones, scaled by this factor) are only the cap in
## case that never happens. Before, the requested ticks closed it, and a bot that was slow to start
## or to load the zone (its ticks are counted from when its process starts and lag on a loaded
## machine) found the server closed: it exited with 1 and "CLOSED".
const SERVER_TICKS_CAP_FACTOR: int = 3

var _pids: Array[int] = []


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _build_path(file_name: String) -> String:
	return NetHarness.build_path(file_name)


## A bot of the scenario: [param extra_args] are the extra user arguments ([code]--net-sim[/code],
## [code]--bot-cheat[/code]...).
func _bot(seed_value: int, realm_name: String,
		extra_args: PackedStringArray = PackedStringArray()) -> Dictionary:
	return {"seed": seed_value, "realm": realm_name, "extra": extra_args}


## A [code]--bots=N[/code] process (swarm of lightweight clients) instead of a [code]--bot[/code].
## [param extra_args] are the extra arguments ([code]--bot-brain=combat[/code]...).
func _swarm(count: int, seed_value: int, realm_name: String = "vardheim",
		extra_args: PackedStringArray = PackedStringArray()) -> Dictionary:
	return {"seed": seed_value, "realm": realm_name, "extra": extra_args, "swarm": count}


## Launches a server (with extra [param server_extra]) and the bots, waits for them to finish and
## collects their reports. Empty [param zone] = the default zone (Vado Gris). Returns:
## [code]{ok, elapsed, server: {...}, bots: [{...}]}[/code], with, per process, [code]exit[/code],
## [code]report[/code], [code]log[/code] and [code]states[/code] (paths).
func _run_scenario(tag: String, zone: String, server_ticks: int, bot_ticks: int,
		bots: Array[Dictionary], server_extra: PackedStringArray = PackedStringArray()) -> Dictionary:
	var port: int = NetHarness.free_udp_port()
	var server: Dictionary = {
		"report": _build_path("np_%s_server.json" % tag),
		"states": _build_path("np_%s_server.txt" % tag),
		"log": _build_path("np_%s_server.log" % tag),
		"stop": _build_path("np_%s_server.stop" % tag),
	}
	for key: String in ["report", "states", "log", "stop"]:
		DirAccess.remove_absolute(server[key])
	var server_args := PackedStringArray([
		"--server", "--port=%d" % port,
		"--quit-after-ticks=%d" % (server_ticks * SERVER_TICKS_CAP_FACTOR),
		"--stop-file=%s" % server["stop"],
		"--report=%s" % server["report"], "--state-log=%s" % server["states"],
	])
	if not zone.is_empty():
		server_args.append("--zone=%s" % zone)
	server_args.append_array(server_extra)
	var started_msec: int = Time.get_ticks_msec()
	var server_pid: int = NetHarness.launch_process(server_args, "np_%s_server" % tag)
	if server_pid > 0:
		_pids.append(server_pid)
	server["pid"] = server_pid
	var result: Dictionary = {"ok": false, "server": server, "bots": [], "elapsed": 0.0}
	if not assert_true(server_pid > 0, "the server launches"):
		return result

	# The state log exists as soon as the server is listening.
	var listening: bool = await _wait_for(func() -> bool: return FileAccess.file_exists(server["states"]),
			started_msec)
	if not assert_true(listening, "the server starts listening"):
		return result
	var bot_infos: Array[Dictionary] = []
	for i: int in bots.size():
		var spec: Dictionary = bots[i]
		var info: Dictionary = {
			"report": _build_path("np_%s_bot%d.json" % [tag, i]),
			"states": _build_path("np_%s_bot%d.txt" % [tag, i]),
			"log": _build_path("np_%s_bot%d.log" % [tag, i]),
		}
		for key: String in ["report", "states", "log"]:
			DirAccess.remove_absolute(info[key])
		var args := PackedStringArray([
			"--connect=127.0.0.1:%d" % port, "--realm=%s" % spec["realm"],
			"--bot-seed=%d" % spec["seed"], "--quit-after-ticks=%d" % bot_ticks,
			"--report=%s" % info["report"],
		])
		if spec.has("swarm"):
			args.append("--bots=%d" % spec["swarm"])
		else:
			args.append_array(PackedStringArray(["--bot", "--state-log=%s" % info["states"]]))
		args.append_array(spec["extra"])
		info["pid"] = NetHarness.launch_process(args, "np_%s_bot%d" % [tag, i])
		if info["pid"] > 0:
			_pids.append(info["pid"])
		assert_true(info["pid"] > 0, "bot %d launches" % i)
		bot_infos.append(info)
	result["bots"] = bot_infos

	# The bots leave first (by their ticks, kicked or rejected); then the server is closed with the
	# stop file, which it checks every second.
	var bots_done: bool = await _wait_for(func() -> bool:
		for info: Dictionary in bot_infos:
			if OS.is_process_running(info["pid"]):
				return false
		return true, started_msec)
	if bots_done:
		var stop := FileAccess.open(server["stop"], FileAccess.WRITE)
		if stop != null:
			stop.store_string("fin de la prueba\n")
			stop.close()
	var finished: bool = bots_done and await _wait_for(func() -> bool:
		return not OS.is_process_running(server_pid), started_msec)
	result["elapsed"] = float(Time.get_ticks_msec() - started_msec) / 1000.0
	if not assert_true(finished, "the processes finish on their own in less than %d s" % int(MAX_WAIT_SECONDS)):
		return result
	server["exit"] = OS.get_process_exit_code(server_pid)
	server["data"] = NetHarness.read_report(server["report"])
	for info: Dictionary in bot_infos:
		info["exit"] = OS.get_process_exit_code(info["pid"])
		info["data"] = NetHarness.read_report(info["report"])
	result["ok"] = true
	return result


## Waits for [param condition] to be met for up to [constant MAX_WAIT_SECONDS] after
## [param started_msec].
func _wait_for(condition: Callable, started_msec: int) -> bool:
	var deadline: int = started_msec + int(MAX_WAIT_SECONDS * 1000.0)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await tree.create_timer(0.1).timeout
	return true


## Lines of the process log that contain engine or script errors.
func _error_lines(log_path: String) -> PackedStringArray:
	return NetHarness.error_lines(log_path)


## Server-side record of the player with that net_id (empty if it does not exist).
func _server_player(scenario: Dictionary, net_id: int) -> Dictionary:
	var data: Dictionary = (scenario["server"] as Dictionary).get("data", {})
	for entry: Dictionary in data.get("player_list", []):
		if int(entry.get("net_id", 0)) == net_id:
			return entry
	return {}


## Comparison of a bot's state log with the server's.
func _compare(scenario: Dictionary, bot: Dictionary) -> StateLogComparer.Result:
	var net_id: int = int((bot["data"] as Dictionary).get("net_id", 0))
	return StateLogComparer.compare_files(scenario["server"]["states"], bot["states"], net_id)


## What an honest bot that has played the whole time must satisfy: it exited fine, it never erred
## without the server substituting an input, and its state log confirms it.
func _assert_honest_bot(scenario: Dictionary, bot: Dictionary, label: String) -> void:
	var report: Dictionary = bot["data"]
	assert_eq(bot["exit"], 0, "%s: exit code 0" % label)
	assert_eq(_error_lines(bot["log"]), PackedStringArray(), "%s: no errors in its log" % label)
	assert_eq(report.get("state"), "IN_WORLD", "%s: was playing when it ended" % label)
	assert_eq(int(report.get("unexplained_diffs", -1)), 0, "%s: no unexplained differences" % label)
	assert_eq(int(report.get("malformed_packets", -1)), 0, "%s: no malformed packets" % label)
	assert_eq(int(report.get("late_snapshots", -1)), 0, "%s: no out-of-order snapshots" % label)
	assert_true(int(report.get("snapshots_with_state", 0)) > 100,
			"%s: receives snapshots with its state (%s)" % [label, report.get("snapshots_with_state")])
	var comparison: StateLogComparer.Result = _compare(scenario, bot)
	assert_eq(comparison.error, "", "%s: the logs can be compared" % label)
	assert_true(comparison.is_ok(), "%s: %s" % [label, comparison.summary()])
	assert_true(comparison.matches > 100, "%s: many bit-for-bit matches (%d)" % [label, comparison.matches])


# --- Determinism between processes (Vado Gris, the real zone) ---------------------------------

func test_two_bots_predict_exactly_across_processes_on_the_real_zone() -> void:
	var bots: Array[Dictionary] = [_bot(1, "vardheim"), _bot(2, "solmarch")]
	var scenario: Dictionary = await _run_scenario("exact", "", 900, 700, bots,
			PackedStringArray(["--fake-players=6"]))
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "the server exits with 0")
	var data: Dictionary = server["data"]
	assert_eq(data.get("zone"), String(Zones.DEFAULT_ZONE), "serves Vado Gris")
	assert_true(int(data.get("ticks", 0)) >= 700 and int(data.get("ticks", 0)) < 900 * SERVER_TICKS_CAP_FACTOR,
			"it lives as long as the bots and the stop file closes it (%s ticks)" % data.get("ticks"))
	assert_eq(int((data.get("players", {}) as Dictionary).get("joined_total", 0)), 8,
			"two bots and six fake players")
	assert_eq(int(data.get("physics_errors", -1)), 0, "no physics errors on the server")
	assert_eq(int(data.get("respawns", -1)), 0, "nobody falls out of the world")
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "no warnings")
	assert_true((data.get("kicks", []) as Array).is_empty(), "no kicks")
	assert_eq((data.get("rejects", {}) as Dictionary).size(), 0, "nor rejections")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "no errors in the server log")
	for i: int in 2:
		var bot: Dictionary = scenario["bots"][i]
		_assert_honest_bot(scenario, bot, "bot %d" % (i + 1))
		var report: Dictionary = bot["data"]
		assert_eq(int(report.get("hard_resets", -1)), 0, "bot %d: no hard reset" % (i + 1))
		assert_eq(int(report.get("resyncs", -1)), 0, "bot %d: nor resync" % (i + 1))
		assert_eq(int(report.get("corrections", -1)), 0, "bot %d: not a single correction" % (i + 1))
		assert_true(bool((report.get("final", {}) as Dictionary).get("exact", false)),
				"bot %d: its final state is the server's" % (i + 1))


func test_bots_with_a_network_simulator_converge_exactly_without_hard_resyncs() -> void:
	var sim: PackedStringArray = PackedStringArray(["--net-sim=rtt=120,jitter=20,loss=5"])
	var bots: Array[Dictionary] = [_bot(1, "vardheim", sim), _bot(2, "solmarch", sim)]
	var scenario: Dictionary = await _run_scenario("netsim", "", 900, 700, bots)
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	assert_eq(scenario["server"]["exit"], 0, "the server exits with 0")
	assert_eq(_error_lines(scenario["server"]["log"]), PackedStringArray(),
			"no errors in the server log")
	for i: int in 2:
		var bot: Dictionary = scenario["bots"][i]
		var report: Dictionary = bot["data"]
		var label: String = "bot %d" % (i + 1)
		assert_eq(bot["exit"], 0, "%s: exit code 0" % label)
		assert_eq(_error_lines(bot["log"]), PackedStringArray(), "%s: no errors in its log" % label)
		assert_eq(report.get("net_sim"), "rtt=120,jitter=20,loss=5", "%s: carries the simulator" % label)
		assert_true(bool((report.get("final", {}) as Dictionary).get("exact", false)),
				"%s: exact final convergence (standing still for the last ticks)" % label)
		assert_eq(int(report.get("hard_resets", -1)), 0, "%s: no hard reset" % label)
		assert_eq(int(report.get("resyncs", -1)), 0, "%s: no hard resync" % label)
		assert_eq(int(report.get("unexplained_diffs", -1)), 0,
				"%s: every prediction error is explained by a substituted input" % label)
		assert_true(int(report.get("snapshots_with_state", 0)) > 100, "%s: receives snapshots" % label)
		var comparison: StateLogComparer.Result = _compare(scenario, bot)
		assert_eq(comparison.error, "", "%s: the logs can be compared" % label)
		assert_eq(comparison.unexplained, 0, "%s: %s" % [label, comparison.summary()])
		assert_eq(comparison.server_mismatches, 0, "%s: its own state is the server's" % label)


# --- Cheating bot (one method per mode, on the flat circuit) ----------------------------------

## test_world server with an honest bot and a cheater of mode [param cheat]; the times are short
## because the zone loads instantly.
func _run_cheat_scenario(cheat: String) -> Dictionary:
	var bots: Array[Dictionary] = [
		_bot(1, "vardheim"),
		_bot(2, "solmarch", PackedStringArray(["--bot-cheat=%s" % cheat])),
	]
	return await _run_scenario("cheat_%s" % cheat, LIGHT_ZONE, 560, 400, bots)


## What is common to all modes: the server notices nothing odd in its log, the honest one does not
## suffer and the server exits fine.
func _assert_honest_side_untouched(scenario: Dictionary) -> void:
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "the server exits with 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "no errors in the server log")
	assert_eq(_error_lines(scenario["bots"][1]["log"]), PackedStringArray(),
			"the cheater does not log errors either (rejection and kick are not engine errors)")
	assert_eq(int((server["data"] as Dictionary).get("physics_errors", -1)), 0, "nor physics errors")
	_assert_honest_bot(scenario, scenario["bots"][0], "bot honrado")
	var honest_id: int = int((scenario["bots"][0]["data"] as Dictionary).get("net_id", 0))
	var record: Dictionary = _server_player(scenario, honest_id)
	assert_eq(int(record.get("strikes", -1)), 0, "the honest one accumulates no warnings")
	assert_false(bool(record.get("kicked", true)), "nor is it kicked")


func test_cheater_with_another_protocol_version_is_rejected() -> void:
	var scenario: Dictionary = await _run_cheat_scenario("version")
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 1, "the cheater exits with 1")
	assert_true(bool(report.get("rejected", false)), "because it is rejected")
	assert_eq(int(report.get("reject_result", 0)), NetProtocol.Result.VERSION, "because of the version")
	assert_eq(report.get("reject_text"), NetProtocol.result_text(NetProtocol.Result.VERSION))
	assert_eq(report.get("cheat"), "version")
	var data: Dictionary = scenario["server"]["data"]
	assert_eq(int((data.get("players", {}) as Dictionary).get("joined_total", 0)), 1, "only the honest one gets in")
	assert_eq((data.get("rejects", {}) as Dictionary).size(), 1, "and the server counts a rejection")


func test_cheater_with_inputs_from_the_future_gains_nothing() -> void:
	var scenario: Dictionary = await _run_cheat_scenario("future")
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 0, "the cheater keeps playing and exits with 0")
	assert_true(int(report.get("cheat_packets", 0)) > 100, "it really was sending inputs from the future")
	var record: Dictionary = _server_player(scenario, int(report.get("net_id", 0)))
	assert_true(int(record.get("too_early_inputs", 0)) > 100, "the server discards them and counts them")
	assert_eq(int(record.get("strikes", -1)), 0, "no warnings")
	# No advantage: the server only applies the honest ones, so the cheater's state is the one it predicts.
	assert_eq(int(report.get("unexplained_diffs", -1)), 0, "its prediction never fails")
	var comparison: StateLogComparer.Result = _compare(scenario, cheater)
	assert_true(comparison.is_ok(), comparison.summary())


func test_cheater_with_conflicting_duplicates_gets_the_first_copy() -> void:
	var scenario: Dictionary = await _run_cheat_scenario("dupes")
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 0, "the cheater keeps playing and exits with 0")
	assert_true(int(report.get("cheat_packets", 0)) > 100, "it really was sending different copies")
	var record: Dictionary = _server_player(scenario, int(report.get("net_id", 0)))
	assert_eq(int(record.get("strikes", -1)), 0, "no warnings")
	assert_eq(int(report.get("unexplained_diffs", -1)), 0,
			"the first copy wins, the honest one: its prediction never fails")
	var comparison: StateLogComparer.Result = _compare(scenario, cheater)
	assert_true(comparison.is_ok(), comparison.summary())


func test_cheater_sending_garbage_is_kicked() -> void:
	await _assert_kicked("garbage")


func test_cheater_flooding_the_limiters_is_kicked() -> void:
	await _assert_kicked("flood")


func _assert_kicked(cheat: String) -> void:
	var scenario: Dictionary = await _run_cheat_scenario(cheat)
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	_assert_honest_side_untouched(scenario)
	var cheater: Dictionary = scenario["bots"][1]
	var report: Dictionary = cheater["data"]
	assert_eq(cheater["exit"], 1, "the cheater exits with 1")
	assert_eq(report.get("cheat"), cheat)
	assert_eq(report.get("state"), "CLOSED", "its session is closed")
	assert_true(String(report.get("disconnect_text", "")).contains("Expulsado"),
			"by a kick: \"%s\"" % report.get("disconnect_text"))
	var data: Dictionary = scenario["server"]["data"]
	var kicks: Array = data.get("kicks", [])
	if assert_eq(kicks.size(), 1, "the server kicks one"):
		assert_eq(int((kicks[0] as Dictionary).get("net_id", 0)), int(report.get("net_id", -1)),
				"the cheater")
	assert_true(int((data.get("strikes", {}) as Dictionary).get("total", 0)) >= 50,
			"after at least 50 warnings")
	var record: Dictionary = _server_player(scenario, int(report.get("net_id", 0)))
	assert_true(bool(record.get("kicked", false)), "and its record marks it as kicked")
	var players: Dictionary = data.get("players", {})
	assert_eq(int(players.get("joined_total", 0)), 2, "both got in")
	assert_eq(int(players.get("left_total", 0)), 2, "and both left: one kicked and the other by its own choice")


## The three combat modes of the cheating bot (TEC-14) at once, each a real process with
## [code]--bot --bot-cheat=<mode>[/code], against the test_world dummy. None deals extra damage: the
## [code]rewind[/code] one (40 ticks of view) never hits and adds suspicion with every blow; the
## [code]reach[/code] one attacks from 5 m and does not connect; the [code]rate[/code] one mashes the
## button and hits only at the pace of the combo from the data.
func test_combat_cheaters_in_real_processes_deal_no_damage_beyond_the_rules() -> void:
	var bots: Array[Dictionary] = [
		_bot(1, "solmarch", PackedStringArray(["--bot-cheat=rewind"])),
		_bot(2, "solmarch", PackedStringArray(["--bot-cheat=reach"])),
		_bot(3, "solmarch", PackedStringArray(["--bot-cheat=rate"])),
	]
	# 5.3 s of margin between how long each bot lasts and how long the server lasts: the three bot
	# processes start one after another and, with the machine loaded, join around server tick 170; if
	# the server closes before the bot finishes its 640 ticks, the bot exits with 1.
	var scenario: Dictionary = await _run_scenario("cheat_combat", LIGHT_ZONE, 960, 640, bots)
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "the server exits with 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "no errors in the server log")
	var data: Dictionary = server["data"]
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "no warnings: none breaks the protocol")
	assert_true((data.get("kicks", []) as Array).is_empty(), "nor kicks")
	var players: Dictionary = {}
	for index: int in 3:
		var bot: Dictionary = scenario["bots"][index]
		var report: Dictionary = bot["data"]
		assert_eq(bot["exit"], 0, "cheater %d exits with 0" % (index + 1))
		assert_eq(_error_lines(bot["log"]), PackedStringArray(), "and without errors in its log")
		assert_eq(report.get("cheat"), ["rewind", "reach", "rate"][index], "it carries the requested mode")
		assert_eq(int(report.get("unexplained_diffs", -1)), 0, "its prediction does not fail")
		players[report.get("cheat")] = _server_player(scenario, int(report.get("net_id", 0)))
	var rewind: Dictionary = players["rewind"]
	var reach: Dictionary = players["reach"]
	var rate: Dictionary = players["rate"]
	assert_true(int(rewind.get("swings", 0)) >= 3, "rewind throws blows (%s)" % rewind.get("swings"))
	assert_eq(int(rewind.get("swings_landed", -1)), 0, "none hits")
	assert_true(int(rewind.get("rewind_rejects", 0)) >= 3, "the server rejects them because of the cap")
	assert_eq(int(rewind.get("suspicion", -1)), int(rewind.get("rewind_rejects", -2)), "and the suspicion rises")
	assert_true(int(reach.get("swings", 0)) >= 3, "reach throws blows (%s)" % reach.get("swings"))
	assert_eq(int(reach.get("swings_landed", -1)), 0, "from 5 m none hits")
	assert_eq(int(reach.get("suspicion", -1)), 0, "with legitimate inputs there is no suspicion")
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_ticks: int = 0
	for light_id: int in weapon.light_ids:
		combo_ticks += CombatCatalog.attack(light_id).total_ticks
	var most_swings: int = ceili(640.0 * float(weapon.light_ids.size()) / float(combo_ticks)) + 1
	assert_true(int(rate.get("swings_landed", 0)) >= 3, "rate does hit some (%s)" % rate.get("swings_landed"))
	assert_true(int(rate.get("swings", 0)) <= most_swings,
			"but does not throw more attacks than the combo allows: %s <= %d" % [rate.get("swings"), most_swings])
	assert_eq(int(rate.get("suspicion", -1)), 0, "mashing the button adds no suspicion")
	var combat: Dictionary = data.get("combat", {})
	assert_eq(int(combat.get("rewind_rejected", -1)), int(rewind.get("rewind_rejects", -2)),
			"the server rejected only those of rewind")
	var suspicious: Array = combat.get("suspicious", [])
	if assert_eq(suspicious.size(), 1, "the report points to a single one"):
		assert_eq(int((suspicious[0] as Dictionary).get("net_id", 0)), int(rewind.get("net_id", -1)))


# --- Bot swarm (--bots=N) ---------------------------------------------------------------------

func test_a_swarm_process_fills_the_server_with_light_clients() -> void:
	var scenario: Dictionary = await _run_scenario("swarm", LIGHT_ZONE, 560, 360, [_swarm(6, 100)])
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "the server exits with 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "no errors in the server log")
	var data: Dictionary = server["data"]
	assert_eq(int((data.get("players", {}) as Dictionary).get("joined_total", 0)), 6, "the 6 bots get in")
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "no warnings")
	assert_true((data.get("kicks", []) as Array).is_empty(), "nor kicks")
	assert_true(float((data.get("inputs", {}) as Dictionary).get("substituted_percent", 100.0)) < 5.0,
			"with almost all inputs on time")
	var swarm: Dictionary = scenario["bots"][0]
	assert_eq(swarm["exit"], 0, "the swarm exits with 0: all of them were playing")
	assert_eq(_error_lines(swarm["log"]), PackedStringArray(), "no errors in the swarm log")
	var report: Dictionary = swarm["data"]
	assert_eq(report.get("mode"), "SWARM")
	assert_eq(int((report.get("bots", {}) as Dictionary).get("played", 0)), 6)
	var clients: Array = report.get("clients", [])
	assert_eq(clients.size(), 6, "one record per bot")
	for entry: Dictionary in clients:
		assert_true(int(entry.get("snapshots", 0)) > 40, "%s receives snapshots" % entry.get("name"))
		assert_true(int(entry.get("bytes_down", 0)) > 1000 and int(entry.get("bytes_up", 0)) > 1000,
				"%s: bytes up and down" % entry.get("name"))
		assert_true(float(entry.get("avg_snapshot_bytes", 0.0)) > 49.0, "and average snapshot size")


## Two combat swarms ([code]--bots=3 --bot-brain=combat[/code], one per realm) against the
## [code]test_world[/code] server: the lightweight bots, which do not simulate, find each other
## through the ENTITY_SPAWNs and snapshots, fight with real rewind (they send their view offset) and
## receive the ENTITY_EVENTs.
func test_combat_swarms_fight_each_other_with_the_rewind_of_a_real_client() -> void:
	var combat: PackedStringArray = PackedStringArray(["--bot-brain=combat"])
	var scenario: Dictionary = await _run_scenario("swarm_combat", LIGHT_ZONE, 700, 560,
			[_swarm(3, 100, "vardheim", combat), _swarm(3, 200, "solmarch", combat)])
	if not assert_true(scenario["ok"], "the scenario finishes"):
		return
	var server: Dictionary = scenario["server"]
	assert_eq(server["exit"], 0, "the server exits with 0")
	assert_eq(_error_lines(server["log"]), PackedStringArray(), "no errors in the server log")
	var data: Dictionary = server["data"]
	var stats: Dictionary = data.get("combat", {})
	print("[enjambres de combate] golpes %d, bloqueados %d, muertes %d, eventos enviados %d, rebobinados rechazados %d" % [
			int(stats.get("hits", 0)), int(stats.get("blocked", 0)), int(stats.get("deaths", 0)),
			int(stats.get("events_sent", 0)), int(stats.get("rewind_rejected", 0))])
	assert_true(int(stats.get("hits", 0)) >= 8, "they hit each other (%s blows)" % stats.get("hits"))
	assert_true(int(stats.get("deaths", 0)) >= 1, "and someone dies (%s deaths)" % stats.get("deaths"))
	assert_true(int(stats.get("events_sent", 0)) > int(stats.get("events", 0)),
			"each event reaches several clients (%s sent, %s emitted)" % [stats.get("events_sent"),
			stats.get("events")])
	assert_eq(int(stats.get("rewind_rejected", -1)), 0, "no view offset exceeds the cap")
	assert_eq((stats.get("suspicious", []) as Array).size(), 0, "and nobody raises suspicions")
	assert_eq(int((data.get("strikes", {}) as Dictionary).get("total", -1)), 0, "no warnings")
	assert_true((data.get("kicks", []) as Array).is_empty(), "nor kicks")
	for index: int in 2:
		var swarm: Dictionary = scenario["bots"][index]
		assert_eq(swarm["exit"], 0, "swarm %d exits with 0: all of them were playing" % (index + 1))
		assert_eq(_error_lines(swarm["log"]), PackedStringArray(), "no errors in its log")
		var clients: Array = (swarm["data"] as Dictionary).get("clients", [])
		assert_eq(clients.size(), 3)
		var known: int = 0
		for entry: Dictionary in clients:
			# The session maximum, not the value on leaving: under load the other swarm may have left
			# earlier and the final count depends on the exit order.
			known += int(entry.get("enemies_known_max", 0))
			assert_true(bool(entry.get("combat", false)), "%s fights" % entry.get("name"))
			assert_true(int(entry.get("spawns_seen", 0)) >= 5, "%s sees the others (%s)" % [
					entry.get("name"), entry.get("spawns_seen")])
			assert_true(int(entry.get("hit_events_seen", 0)) > 0, "%s receives hit events" % entry.get("name"))
			assert_true(int(entry.get("event_bytes", 0)) > 0)
			assert_eq(int(entry.get("malformed_packets", -1)), 0, "nor malformed packets")
		if index == 0:
			assert_eq(known, 9, "each bot of the first swarm got to know the 3 enemies")
