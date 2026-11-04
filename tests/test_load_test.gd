extends TestCase
## Tests for the load tools ([code]tools/load_test.gd[/code], launched by hand outside the
## runner) and for [LoadTestSummary], the part of its summary that can be tested without launching processes.
## [br][br]
## [b]Smoke[/b]: the tool's script loads and can be instantiated, so a syntax error
## in it breaks the suite and is not discovered when launching the multi-minute battery.
## [br][br]
## [b]Measurement window[/b]: the percentage of substituted inputs in the server's report is for the whole
## session, startup included (each bot loses a few dozen inputs while [TickSync]
## finds its lead time, more with 100 ms of RTT). The phase 2 criterion (networking.md, 16) is measured in
## steady state: [method LoadTestSummary.window_substituted] subtracts what had accumulated when the window began, from
## the "Métricas (tick N)" lines (metrics) that the server writes every 600 ticks.

const LOAD_TEST_PATH: String = "res://tools/load_test.gd"
const BootScript = preload("res://scripts/boot.gd")

const METRICS_LINE_600: String = "[Eldmark] Métricas (tick 600): 74 jugadores, tick p50 3200 µs / p99 5100 µs / máx 9000 µs (p99 por sección: tick 5100, net 300), entradas sustituidas 4.00 %, subida 85.5 KB/s, bajada 10.0 KB/s"
const METRICS_LINE_1800: String = "[Eldmark] Métricas (tick 1800): 74 jugadores, tick p50 3300 µs / p99 5200 µs / máx 9100 µs (p99 por sección: tick 5200, net 310), entradas sustituidas 1.39 %, subida 86.0 KB/s, bajada 10.1 KB/s"


# --- Smoke -----------------------------------------------------------------------------------

func test_load_test_script_loads_and_can_be_instantiated() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script, "%s loads (a syntax error would leave it as null)" % LOAD_TEST_PATH):
		return
	assert_true(script.can_instantiate(), "and can be instantiated")
	assert_true(script.get_script_method_list().any(
			func(method: Dictionary) -> bool: return method["name"] == "_initialize"),
			"it is a command-line script (SceneTree._initialize)")


func test_load_test_matrix_covers_the_scenarios_of_the_plan() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	var constants: Dictionary = script.get_script_constant_map()
	var matrix: Array = constants.get("MATRIX", [])
	var rtt_100_cluster_64: bool = false
	var fakes: Dictionary = {}
	for entry: Array in matrix:
		fakes[int(entry[1])] = true
		if entry[0] == "cluster" and int(entry[1]) == 64 and int(entry[2]) >= 10 \
				and String(entry[3]).begins_with("rtt=100"):
			rtt_100_cluster_64 = true
	assert_true(rtt_100_cluster_64, "there is a scenario with 64 clustered fakes, bots and 100 ms of RTT (the phase 2 criterion)")
	for count: int in [64, 128, 256]:
		assert_true(fakes.has(count), "the battery includes %d fake players" % count)
	assert_eq(int(constants.get("MATRIX_SECONDS", 0)), 120, "120 s of measurement per scenario in --matrix")


# --- Server metrics lines -------------------------------------------------------------------

func test_cumulative_substituted_percent_is_read_from_the_server_log() -> void:
	var text: String = "\n".join([
		"[Eldmark] Servidor de la zona 'vado_gris' escuchando en el puerto UDP 25000",
		METRICS_LINE_600,
		"[Eldmark] Alta de Bot-01 (net_id 5)",
		METRICS_LINE_1800,
		"[Eldmark] Métricas (tick 2400): sin porcentaje en esta línea",
	])
	assert_eq(LoadTestSummary.parse_metrics_log(text), {600: 4.0, 1800: 1.39},
			"tick -> cumulative percentage, and only from the metrics lines")
	assert_eq(LoadTestSummary.parse_metrics_log(""), {})


# --- Measurement window -----------------------------------------------------------------------

## Ten bots that entered at tick 10 and are still inside, and a fake player (which does not count).
func _players() -> Array:
	var players: Array = []
	for i: int in 10:
		players.append({"fake": false, "joined_tick": 10, "left_tick": -1})
	players.append({"fake": true, "joined_tick": 0, "left_tick": -1})
	return players


func test_consumed_inputs_count_every_tick_a_real_player_was_in() -> void:
	var players: Array = _players()
	assert_eq(LoadTestSummary.consumed_until(players, 600, 3000), 10 * 590, "10 bots from tick 10")
	assert_eq(LoadTestSummary.consumed_until(players, 5, 3000), 0, "before entering they consume nothing")
	players.append({"fake": false, "joined_tick": 100, "left_tick": 400})
	assert_eq(LoadTestSummary.consumed_until(players, 600, 3000), 10 * 590 + 300,
			"one that left at 400 only counts until then")
	var unfinished: Array = [{"fake": false, "joined_tick": 10, "left_tick": -1}]
	assert_eq(LoadTestSummary.consumed_until(unfinished, 5000, 1010), 1000,
			"those still inside count up to the server's last tick")


func test_window_percent_subtracts_what_was_accumulated_at_the_start() -> void:
	var cumulative: Dictionary = {600: 4.0, 1200: 2.2, 1800: 1.39}
	var window: Dictionary = LoadTestSummary.window_substituted(cumulative, _players(), 500, 1900, 2000)
	assert_eq(int(window.get("from_tick", 0)), 600, "it starts at the first metrics line after startup")
	assert_eq(int(window.get("to_tick", 0)), 1800, "and ends at the last one before the bots finish")
	# 5900 inputs consumed at tick 600 (236 substituted) and 17900 at 1800 (249).
	assert_eq(int(window.get("inputs", 0)), 17900 - 5900)
	assert_eq(int(window.get("substituted", -1)), 249 - 236)
	assert_near(float(window["percent"]), 100.0 * 13.0 / 12000.0, 1e-9, "13 de 12000: 0,11 %")
	assert_true(float(window["percent"]) < 1.0, "far below the whole session (1.39 %)")


func test_window_percent_is_unavailable_without_two_metric_lines_in_range() -> void:
	var cumulative: Dictionary = {600: 4.0, 1800: 1.39}
	assert_true(LoadTestSummary.window_substituted({}, _players(), 500, 1900, 2000).is_empty(), "without lines")
	assert_true(LoadTestSummary.window_substituted({600: 4.0}, _players(), 500, 1900, 2000).is_empty(),
			"with only one")
	assert_true(LoadTestSummary.window_substituted(cumulative, _players(), 700, 1700, 2000).is_empty(),
			"or if the range does not contain two")
	assert_true(LoadTestSummary.window_substituted(cumulative, [], 500, 1900, 2000).is_empty(),
			"or if there are no network players")


# --- Skirmishes (TEC-15) ----------------------------------------------------------------------

func test_brawl_matrix_has_fights_of_32_40_64_and_128_combatants() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	var constants: Dictionary = script.get_script_constant_map()
	var totals: Array[int] = []
	for entry: Array in constants.get("BRAWL_MATRIX", []):
		assert_eq(entry[0], "brawl", "all are skirmishes")
		assert_true(int(entry[2]) > 0, "with real clients that receive snapshots and events")
		totals.append(int(entry[1]) + int(entry[2]))
	assert_eq(totals, [32, 40, 64, 128] as Array[int], "fakes plus real bots (40: the per-battle limit)")
	assert_eq(totals[1], NetZones.max_players("vado_gris"), "which is Vado Gris's capacity")
	assert_true(int(constants.get("BRAWL_SECONDS", 0)) >= 60, "at least one minute of measurement")
	assert_true(String(constants.get("BRAWL_CENTER", "")).contains(","), "the huddle has its (x,z) point")


func test_combat_figures_come_from_the_server_report() -> void:
	var report: Dictionary = {
		"combat": {"hits": 120, "blocked": 10, "deaths": 4, "events": 200, "events_sent": 6000,
				"event_bytes_sent": 2048 * 60, "hit_tests": 4000, "resolve_us": 120000, "resolve_busy_ticks": 500},
		"metrics": {"sections": {
			"combat": {"total_us": 400000},
			"combat_resolve": {"total_us": 120000},
			"combat_events": {"total_us": 20000},
		}},
	}
	var figures: Dictionary = LoadTestSummary.combat_figures(report, 60.0)
	assert_eq(figures["hits"], 120)
	assert_eq(figures["blocked"], 10)
	assert_eq(figures["deaths"], 4)
	assert_eq(figures["events"], 200)
	assert_eq(figures["events_sent"], 6000)
	assert_near(float(figures["event_kb_per_s"]), 2048.0 * 60.0 / 1024.0 / 60.0, 1e-9, "KB/s of events")
	assert_eq(figures["hit_tests"], 4000)
	assert_eq(figures["resolve_busy_ticks"], 500)
	assert_near(float(figures["resolve_us_per_test"]), 30.0, 1e-9, "120000 µs over 4000 checks")
	assert_near(float(figures["resolve_share"]), 0.3, 1e-9, "a part of the combat section")
	assert_near(float(figures["events_us_per_event"]), 100.0, 1e-9, "20000 µs over 200 events")


func test_combat_figures_of_a_quiet_server_do_not_divide_by_zero() -> void:
	var figures: Dictionary = LoadTestSummary.combat_figures({}, 0.0)
	for key: String in ["hits", "events", "hit_tests"]:
		assert_eq(figures[key], 0)
	for key: String in ["event_kb_per_s", "resolve_us_per_test", "resolve_share", "events_us_per_event"]:
		assert_eq(float(figures[key]), 0.0, key)


func test_phase_4_figures_count_arrows_and_the_kit_and_the_brawl_has_marksmen() -> void:
	var report: Dictionary = {"combat": {
		"projectiles_fired": 600, "projectiles_harmless": 2, "projectile_character_hits": 400,
		"projectile_world_hits": 150, "arrow_blocked": 30, "wall_blocked": 5, "projectiles_expired": 10,
		"projectiles_evicted": 3, "projectile_peak": 64, "projectile_rewind_rejected": 1,
		"projectile_busy_ticks": 3000, "projectile_us": 1500000, "projectile_segments": 9000,
		"projectile_capsule_tests": 800, "projectile_messages_sent": 12000, "projectile_bytes_sent": 1024 * 60,
		"status_applied": 50, "pulses": 70, "healed": 3000, "interrupts": 9, "downs": 12, "revives": 3,
		"executions": 6, "bled_out": 1,
	}}
	var kit: Dictionary = LoadTestSummary.phase_4_figures(report, 60.0)
	assert_eq(kit["fired"], 600)
	assert_near(float(kit["fired_per_s"]), 10.0, 1e-9, "600 arrows in 60 s")
	assert_eq(kit["arrow_blocked"], 35, "the blocked ones, by shield or by wall")
	assert_eq(kit["peak"], 64)
	assert_eq(kit["zone_cap"], CombatCatalog.rules().max_projectiles_per_zone, "the zone's cap, from the data")
	assert_eq(kit["evicted"], 3)
	assert_near(float(kit["projectile_us_per_busy_tick"]), 500.0, 1e-9, "1.5 s over 3000 busy ticks")
	assert_near(float(kit["kb_per_s"]), 1.0, 1e-9)
	assert_eq([kit["downs"], kit["revives"], kit["executions"], kit["bled_out"]], [12, 3, 6, 1])
	var quiet: Dictionary = LoadTestSummary.phase_4_figures({}, 0.0)
	assert_eq(float(quiet["fired_per_s"]), 0.0, "without dividing by zero")
	assert_eq(float(quiet["projectile_us_per_busy_tick"]), 0.0)
	var constants: Dictionary = (load(LOAD_TEST_PATH) as GDScript).get_script_constant_map()
	assert_eq(String(constants.get("BRAWL_LOADOUT", "")), "marksman:50", "the skirmish has half archers")
	assert_true((constants.get("SECTIONS", []) as Array).has("combat_projectiles"),
			"and the summary shows the projectiles section")


# --- Sieges (GUE-16) -----------------------------------------------------------------------------

func test_siege_matrix_has_sieges_of_32_and_64_a_side() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	var constants: Dictionary = script.get_script_constant_map()
	var sides: Array[int] = []
	for entry: Array in constants.get("SIEGE_MATRIX", []):
		assert_eq(entry[0], "siege", "all are sieges")
		assert_true(int(entry[2]) > 0, "with real clients that receive the fort's OBJECT_STATE")
		assert_eq((int(entry[1]) + int(entry[2])) % 2, 0, "both sides, equal")
		sides.append((int(entry[1]) + int(entry[2])) / 2)
	assert_eq(sides, [32, 64] as Array[int], "32 against 32 and 64 against 64")
	assert_eq(int(constants.get("SIEGE_SECONDS", 0)), 120, "120 s of measurement")
	assert_true(float(constants.get("SIEGE_EXTRA_SETTLE_SECONDS", 0.0)) >= 40.0, "the bots have time to reach the gate")


# Integration of the abilities on F6b: Vado Gris has its own capacity (40, the per-battle limit with the kit;
# docs/networking.md 14 and docs/fortress.md 8.3), so every scenario with more players has to request its own with --max-players.
func test_every_battery_scenario_fits_in_the_server_it_launches() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	var constants: Dictionary = script.get_script_constant_map()
	var over_zone_capacity: int = 0
	for matrix: String in ["MATRIX", "BRAWL_MATRIX", "SIEGE_MATRIX"]:
		for entry: Array in constants.get(matrix, []):
			var players: int = int(entry[1]) + int(entry[2])
			assert_true(int(script.call("server_max_players", int(entry[1]), int(entry[2]))) >= players,
					"%s %s: the %d players fit" % [matrix, entry, players])
			if players > NetZones.max_players("vado_gris"):
				over_zone_capacity += 1
	assert_true(over_zone_capacity > 0, "there are scenarios with more players than Vado Gris's capacity (the F6b sieges)")
	assert_true(FileAccess.get_file_as_string(LOAD_TEST_PATH).contains(
			'"--max-players=%d" % server_max_players(fakes, bots)'), "and the server is launched with that explicit capacity")


func test_the_tick_timeline_is_read_from_the_metric_lines() -> void:
	var text: String = "\n".join([
		METRICS_LINE_600,
		"[Eldmark] Métricas (tick 1200): 74 jugadores, tick p50 3250 µs / p99 6000 µs / máx 9500 µs (p99 por sección: tick 6000), entradas sustituidas 0.00 %, subida 9.0 KB/s, bajada 1.0 KB/s, 21 PNJ",
		METRICS_LINE_1800,
		"[Eldmark] Métricas (tick 2400): sin datos del tick",
		"[Eldmark] Métricas (tick 3000): 80 jugadores, tick p50 9000 µs / p99 16000 µs / máx 30000 µs (p99 por sección: tick 16000), bajada 1.0 KB/s, 9 PNJ\r",
	])
	var marks: Array[Dictionary] = LoadTestSummary.parse_tick_timeline(text)
	assert_eq(marks.size(), 4, "lines with no tick data do not count")
	assert_eq(marks[0], {"tick": 600, "players": 74, "npcs": -1, "p50_us": 3200, "p99_us": 5100, "max_us": 9000},
			"a line from before F6b does not state the NPCs")
	assert_eq(marks[1]["npcs"], 21, "the NPCs, at the end of the line (GUE-16)")
	assert_eq(marks[3]["players"], 80)
	assert_eq(marks[3]["npcs"], 9)
	var window: Dictionary = LoadTestSummary.timeline_window(marks, 1000, 3000)
	assert_eq(window["marks"], 3, "the marks 1200, 1800 and 3000")
	assert_eq(window["p50_us"], 3300, "median of the p50s")
	assert_eq(window["p99_us"], 6000, "median of the p99s")
	assert_eq(window["worst_p99_us"], 16000, "the worst p99")
	assert_eq(window["max_us"], 30000, "the largest maximum")
	assert_eq(window["npcs_min"], 9, "the minimum NPCs among the marks that state it")
	assert_eq(window["npcs_max"], 21)
	assert_eq(window["players_min"], 74, "and the players (if they change, the marks are not all from the same load)")
	assert_eq(window["players_max"], 80)
	assert_eq(LoadTestSummary.timeline_window(marks, 0, 1000)["npcs_min"], -1, "without marks with NPCs, -1")
	assert_true(LoadTestSummary.timeline_window(marks, 4000, 5000).is_empty(), "without marks in the window, nothing")
	assert_true(LoadTestSummary.parse_tick_timeline("").is_empty())


func test_presence_says_how_many_players_there_were_in_the_tail_the_percentiles_come_from() -> void:
	# F6b review: with 128 players the server runs slower than real time and the swarm, which closed by
	# its own clock, left at tick 8390 of 10 850: the report's percentiles (ticks 8803 to 10 850) were for 118
	# players. The player_list entries say who was there at each tick.
	var players: Array = []
	for i: int in 118:
		players.append({"fake": true, "joined_tick": 0, "left_tick": 10850})
	for i: int in 10:
		players.append({"fake": false, "joined_tick": 166 + 5 * i, "left_tick": 8390})
	var tail: Dictionary = LoadTestSummary.presence(players, 8803, 10850, 10850)
	assert_eq(tail, {"min": 118, "max": 118, "ticks": 2048, "ticks_at_max": 2048},
			"in the last 2048 ticks, 118 all the time (the fakes remain until closing)")
	var window: Dictionary = LoadTestSummary.presence(players, 3530, 10640, 10850)
	assert_eq(window["min"], 118)
	assert_eq(window["max"], 128)
	assert_eq(window["ticks_at_max"], 8390 - 3530, "with all 128 until the bots leave")
	# With the swarm closed by the server tick they leave at 10 640: the final stretch has almost the entire peak.
	for entry: Dictionary in players:
		if not bool(entry["fake"]):
			entry["left_tick"] = 10640
	var fixed: Dictionary = LoadTestSummary.presence(players, 8803, 10850, 10850)
	assert_eq(fixed["max"], 128)
	assert_eq(fixed["ticks_at_max"], 10640 - 8803)
	assert_eq(LoadTestSummary.presence([{"joined_tick": 50, "left_tick": -1}], 0, 99, 200),
			{"min": 0, "max": 1, "ticks": 100, "ticks_at_max": 50}, "one that enters at 50 and is still there at closing")
	assert_true(LoadTestSummary.presence(players, 10, 5, 100).is_empty(), "an empty stretch")


func test_the_swarm_of_the_load_test_leaves_by_the_server_tick() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	var factor: float = float(script.get_script_constant_map().get("SLOW_SERVER_FACTOR", 0.0))
	assert_true(factor >= 2.0, "it withstands a server slower than real time (%.1f times)" % factor)
	assert_eq(script.call("swarm_quit_args", 10640), PackedStringArray([
		"--quit-at-server-tick=10640", "--quit-after-ticks=%d" % ceili(10640.0 * factor)]),
			"the swarm closes when the server reaches the exit tick; its own clock is only the bound")
	var config: ClientConfig = ClientConfig.from_args(PackedStringArray(["--bots=2", "--quit-at-server-tick=9000"]))
	assert_eq(config.quit_at_server_tick, 9000)
	assert_true(config.warnings.is_empty())
	assert_eq(ClientConfig.from_args(PackedStringArray(["--bots=2"])).quit_at_server_tick, 0, "by default, no")
	var options: Dictionary = BootScript.parse_client_options(PackedStringArray(["--bots=2", "--quit-at-server-tick=9000"]))
	assert_eq(options["warnings"], PackedStringArray(), "boot does not consider it unknown")


func test_the_siege_server_has_its_npcs_only_with_the_npcs_option() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	# F6a (without --npcs): without NPCs and with the command that opens the circle at the start of the window.
	var without: PackedStringArray = script.call("siege_server_args", false, "/tmp/b.jsonl", 3530)
	assert_eq(without, PackedStringArray(["--battle-log=/tmp/b.jsonl", "--no-npcs", "--run-at=3530:fort_kill_captain"]))
	# F6b (--npcs): the zone's NPCs and the fort without aids.
	var with_npcs: PackedStringArray = script.call("siege_server_args", true, "/tmp/b.jsonl", 3530)
	assert_eq(with_npcs, PackedStringArray(["--battle-log=/tmp/b.jsonl"]), "neither --no-npcs nor fort_kill_captain")
	var sections: Array = script.get_script_constant_map().get("SECTIONS", [])
	for section: String in ["war", "npc_brains", "npc"]:
		assert_true(sections.has(section), "the summary shows the %s section" % section)


func test_fort_arrivals_count_the_real_bots_that_reached_the_fort_before_the_window() -> void:
	var swarms: Array = [
		{"clients": [{"fort_reached_tick": 2400}, {"fort_reached_tick": 3530}, {"fort_reached_tick": 3600}]},
		{"clients": [{"fort_reached_tick": -1}, {"world_ticks": 900}]},
		{},
	]
	assert_eq(LoadTestSummary.fort_arrivals(swarms, 3530),
			{"bots": 4, "arrived": 3, "before_window": 2, "last_tick": 3600},
			"four of siege (the one that is not does not count), three arrive and two before the window (the tick of its start included)")
	assert_eq(LoadTestSummary.fort_arrivals([], 100), {"bots": 0, "arrived": 0, "before_window": 0, "last_tick": -1})
