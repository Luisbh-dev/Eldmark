extends TestCase
## Battle telemetry (GUE-17; docs/fuerte.md, section 7): the JSON Lines log ([BattleLog]) and
## its summary ([BattleSummary] and [code]tools/war/summarize_battle.gd[/code]): time to capture,
## deaths by route (bridge, ford, walkway) and time to break the gate.

const LOG_PATH: String = "res://build/test_battle_summary.jsonl"
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
const FORTRESS_ID: StringName = &"vado_gris_fort"
const FORT_POSITION: Vector3 = Vector3(0.0, 10.2, 0.0)
const GATE_POSITION: Vector3 = Vector3(-20.0, 10.2, 0.0)
const CIRCLE_POSITION: Vector3 = Vector3(-8.5, 10.25, 0.0)
const BRIDGE_DEATH: Vector3 = Vector3(0.0, 6.0, -55.0)
const FORD_DEATH: Vector3 = Vector3(-91.0, 4.0, -25.0)
const WALKWAY_DEATH: Vector3 = Vector3(-8.5, 13.8, 3.0)
const FAR_DEATH: Vector3 = Vector3(200.0, 5.0, 200.0)


## Test entity (player or NPC) with a name and realm.
func _entity(net_id: int, display_name: String, realm: int, kind: int) -> NetEntity:
	var entity := NetEntity.new()
	entity.net_id = net_id
	entity.display_name = display_name
	entity.realm = realm
	entity.kind = kind
	return entity


## Writes a battle log with two capture cycles, a broken gate and deaths in four places.
func _write_sample_log() -> String:
	var battle_log: BattleLog = BattleLog.open(LOG_PATH)
	var fortresses: Array[Dictionary] = [{"id": FORTRESS_ID, "position": FORT_POSITION,
			"gate": GATE_POSITION, "circle": CIRCLE_POSITION, "radius": 5.0}]
	battle_log.log_start("vado_gris", fortresses)
	battle_log.log_gate_damage_started(600, FORTRESS_ID, GATE_POSITION)
	battle_log.log_war(600, WarEvents.UNDER_ATTACK, 1, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.log_war(3900, WarEvents.GATE_BROKEN, 1, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.log_war(4000, WarEvents.CAPTAIN_DOWN, 1, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.log_war(4100, WarEvents.CAPTURE_STARTED, 1, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.log_war(5900, WarEvents.FORT_CAPTURED, 1, FORTRESS_ID, CIRCLE_POSITION)
	var ana: NetEntity = _entity(2, "Ana", NetProtocol.Realm.SOLMARCH, NetProtocol.EntityKind.PLAYER)
	var bob: NetEntity = _entity(3, "Bob", NetProtocol.Realm.VARDHEIM, NetProtocol.EntityKind.PLAYER)
	var hollow: NetEntity = _entity(4, "Hueco", 0, NetProtocol.EntityKind.NPC)
	battle_log.log_death(4500, ana, bob, 2, BRIDGE_DEATH)
	battle_log.log_death(4600, ana, bob, 2, FORD_DEATH)
	battle_log.log_death(4700, bob, ana, 2, WALKWAY_DEATH)
	battle_log.log_death(4800, ana, null, 0, FAR_DEATH)
	battle_log.log_death(4900, hollow, bob, 2, WALKWAY_DEATH)
	battle_log.log_war(9000, WarEvents.FORT_RESET, 0, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.log_war(9500, WarEvents.CAPTAIN_DOWN, 2, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.log_war(9600, WarEvents.CAPTURE_STARTED, 2, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.log_war(10200, WarEvents.FORT_CAPTURED, 2, FORTRESS_ID, CIRCLE_POSITION)
	battle_log.close()
	return FileAccess.get_file_as_string(LOG_PATH)


func test_the_log_is_one_json_object_per_line_with_tick_and_event() -> void:
	var text: String = _write_sample_log()
	var lines: PackedStringArray = text.strip_edges().split("\n")
	assert_eq(lines.size(), 16)
	for line: String in lines:
		var entry: Variant = JSON.parse_string(line)
		if not assert_true(entry is Dictionary, "readable line: %s" % line):
			return
		assert_true((entry as Dictionary).has("tick") and (entry as Dictionary).has("event"))
	var first: Dictionary = JSON.parse_string(lines[0])
	assert_eq(first["event"], "battle_start")
	assert_eq(first["zone"], "vado_gris")
	var fortress: Dictionary = (first["fortresses"] as Array)[0]
	assert_eq(fortress["id"], "vado_gris_fort")
	assert_eq(fortress["circle"], [-8.5, 10.25, 0.0])
	assert_eq(fortress["radius"], 5.0)
	var war: Dictionary = JSON.parse_string(lines[3])
	assert_eq(war["event"], "war")
	assert_eq(war["war"], "gate_broken")
	assert_eq(int(war["tick"]), 3900)
	assert_eq(int(war["realm"]), 1)
	assert_eq(war["fortress"], "vado_gris_fort")
	var death: Dictionary = JSON.parse_string(lines[7])
	assert_eq(death["event"], "death")
	assert_eq(death["victim_name"], "Ana")
	assert_eq(death["victim_kind"], "player")
	assert_eq(int(death["victim_realm"]), NetProtocol.Realm.SOLMARCH)
	assert_eq(death["killer_name"], "Bob")
	assert_eq(int(death["killer_realm"]), NetProtocol.Realm.VARDHEIM)
	assert_eq(death["position"], [0.0, 6.0, -55.0])
	var environment: Dictionary = JSON.parse_string(lines[10])
	assert_eq(int(environment["killer"]), 0, "the environment has no killer")
	assert_eq((JSON.parse_string(lines[11]) as Dictionary)["victim_kind"], "npc")


func test_a_log_that_cannot_be_opened_is_null() -> void:
	assert_null(BattleLog.open(""))
	var closed: BattleLog = BattleLog.open(LOG_PATH)
	closed.close()
	closed.log_war(1, WarEvents.FORT_RESET, 0, FORTRESS_ID, Vector3.ZERO)
	assert_false(closed.is_open(), "writing to a closed one does nothing")


func test_the_summary_gives_capture_times_gate_time_and_deaths_by_route() -> void:
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	if not assert_not_null(routes, "the Vado Gris routes"):
		return
	var summary: Dictionary = BattleSummary.summarize(_write_sample_log(), routes)
	assert_eq(summary["zone"], "vado_gris")
	assert_eq(int(summary["ticks"]), 10200)
	assert_near(summary["duration_s"], 170.0, 1e-6)
	assert_eq(int(summary["bad_lines"]), 0)
	var captures: Array = summary["captures"]
	if not assert_eq(captures.size(), 2, "two captures"):
		return
	var first: Dictionary = captures[0]
	assert_eq(int(first["realm"]), 1)
	assert_near(first["seconds_from_cycle_start"], 5900.0 / 60.0, 1e-6, "since the start of the battle")
	assert_near(first["seconds_from_captain_down"], 1900.0 / 60.0, 1e-6, "since the captain's fall")
	assert_near(first["seconds_capturing"], 1800.0 / 60.0, 1e-6, "the capture proper: 30 s")
	var second: Dictionary = captures[1]
	assert_eq(int(second["realm"]), 2)
	assert_near(second["seconds_from_cycle_start"], 1200.0 / 60.0, 1e-6, "the cycle counts from the reset")
	var breaks: Array = summary["gate_breaks"]
	if assert_eq(breaks.size(), 1):
		assert_near(breaks[0]["seconds"], 3300.0 / 60.0, 1e-6, "from the first hit to the break: 55 s")
		assert_eq(breaks[0]["fortress"], "vado_gris_fort")
	var deaths: Dictionary = summary["deaths"]
	assert_eq(int(deaths["players"]), 4)
	assert_eq(int(deaths["npcs"]), 1, "NPCs apart")
	var by_route: Dictionary = deaths["by_route"]
	assert_eq(int(by_route.get("bridge", 0)), 1)
	assert_eq(int(by_route.get("ford", 0)), 1)
	assert_eq(int(by_route.get("walkway", 0)), 1)
	assert_eq(int(by_route.get("other", 0)), 1)
	assert_eq(deaths["npcs_by_route"], {"walkway": 1}, "and the NPCs, by place (GUE-45: the Hollow fell on the walkway)")
	var by_realm: Dictionary = deaths["by_realm"]
	assert_eq(int(by_realm[str(NetProtocol.Realm.SOLMARCH)]), 3)
	assert_eq(int(by_realm[str(NetProtocol.Realm.VARDHEIM)]), 1)
	var war_events: Dictionary = summary["war_events"]
	assert_eq(int(war_events["fort_captured"]), 2)
	assert_eq(int(war_events["gate_broken"]), 1)


func test_without_routes_only_the_walkway_is_told_apart() -> void:
	var summary: Dictionary = BattleSummary.summarize(_write_sample_log())
	var by_route: Dictionary = (summary["deaths"] as Dictionary)["by_route"]
	assert_eq(int(by_route.get("walkway", 0)), 1)
	assert_eq(int(by_route.get("other", 0)), 3)
	assert_false(by_route.has("bridge"))


func test_classify_route_by_position() -> void:
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	var fortress: Dictionary = {"circle": [-8.5, 10.25, 0.0]}
	assert_eq(BattleSummary.classify_route([0.0, 6.0, -55.0], fortress, routes), &"bridge")
	assert_eq(BattleSummary.classify_route([0.0, 6.0, 55.0], fortress, routes), &"bridge", "the mirror image, from the other side")
	assert_eq(BattleSummary.classify_route([-91.0, 4.0, -25.0], fortress, routes), &"ford")
	assert_eq(BattleSummary.classify_route([-8.5, 13.8, 3.0], fortress, routes), &"walkway")
	assert_eq(BattleSummary.classify_route([-8.5, 10.3, 3.0], fortress, routes) != &"walkway", true,
			"the courtyard, at ground level, is not the walkway")
	assert_eq(BattleSummary.classify_route([-8.5, 10.3, 3.0], fortress, routes), &"gate", "it is the courtyard")
	assert_eq(BattleSummary.classify_route([-25.0, 10.2, -2.0], fortress, routes), &"gate",
			"and the esplanade, where both routes end, counts neither as bridge nor as ford")
	assert_eq(BattleSummary.classify_route([-25.0, 10.2, 0.0], fortress, null), &"gate", "also without routes")
	assert_eq(BattleSummary.classify_route([-44.0, 8.0, 0.0], fortress, routes), &"ford",
			"more than 25 m from the circle, the ford by which one arrives")
	assert_eq(BattleSummary.classify_route([-12.0, 8.0, -47.0], fortress, routes), &"bridge",
			"and the slope rising from the bridge")
	assert_eq(BattleSummary.classify_route([200.0, 5.0, 200.0], fortress, routes), &"other")
	# GUE-45: the walkway the bots walk along, from ramp to ramp above the gate.
	assert_eq(BattleSummary.classify_route([-18.77, 13.55, -18.77], fortress, routes), &"walkway", "the northwest corner")
	assert_eq(BattleSummary.classify_route([-18.9, 13.55, 1.0], fortress, routes), &"walkway", "above the gate")
	assert_eq(BattleSummary.classify_route([7.0, 13.5, 18.77], fortress, routes), &"walkway", "the top of the south ramp")
	assert_eq(BattleSummary.classify_route([-18.77, 10.2, -10.0], fortress, routes), &"gate",
			"and below the walkway, in the courtyard, is not the walkway")
	# With routes that know a walkway far from the circle, its axis counts even if it is more than 30 m away.
	var far_walkway := ApproachRoutes.new()
	far_walkway.walkway_height = 13.55
	far_walkway.walkway_path = PackedVector2Array([Vector2(18.77, -18.77), Vector2(18.77, 18.77)])
	var ramps: Array[PackedVector2Array] = [PackedVector2Array([Vector2(10.0, -5.0), Vector2(18.77, -5.0)])]
	far_walkway.walkway_ramps = ramps
	assert_eq(BattleSummary.classify_route([18.77, 13.55, -18.77], fortress, far_walkway), &"walkway",
			"the northeast corner, along the axis")
	assert_eq(BattleSummary.classify_route([18.77, 13.55, -18.77], fortress, null), &"other",
			"which without the routes is far from the circle")
	assert_eq(BattleSummary.classify_route([1.0], fortress, routes), &"other", "an incomplete position")


func test_unreadable_lines_are_counted_and_skipped() -> void:
	var summary: Dictionary = BattleSummary.summarize("esto no es json\n{\"tick\":5,\"event\":\"war\",\"war\":\"fort_reset\",\"fortress\":\"x\"}\n\n[1,2]")
	assert_eq(int(summary["bad_lines"]), 2)
	assert_eq(int((summary["war_events"] as Dictionary)["fort_reset"]), 1)
	assert_eq(int(summary["ticks"]), 5)


func test_the_text_summary_is_in_spanish_and_lists_everything() -> void:
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	var text: String = BattleSummary.format(BattleSummary.summarize(_write_sample_log(), routes))
	assert_true(text.contains("Capturas: 2"), text)
	assert_true(text.contains("Puertas rotas: 1"))
	assert_true(text.contains("55.0 s desde el primer golpe hasta romperla"))
	assert_true(text.contains("puente: 1") and text.contains("vado: 1") and text.contains("pasarela: 1"))
	assert_true(text.contains("PNJ: pasarela 1"), "with the NPCs by place: %s" % text)
	assert_true(text.contains("Vardheim") and text.contains("Solmarch"))


func test_the_tool_reads_a_log_and_prints_the_summary() -> void:
	_write_sample_log()
	var project: String = ProjectSettings.globalize_path("res://")
	var log_file: String = ProjectSettings.globalize_path(LOG_PATH)
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path", project, "-s",
			"res://tools/war/summarize_battle.gd", "--", log_file], output, true)
	var text: String = "\n".join(PackedStringArray(output))
	assert_eq(code, 0, text)
	assert_true(text.contains("Capturas: 2"), text)
	assert_true(text.contains("Muertes: 4 de jugadores y 1 de PNJ"), text)
	assert_true(text.contains("pasarela: 1"))
	var missing: Array = []
	var missing_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path", project, "-s",
			"res://tools/war/summarize_battle.gd", "--", "no_existe.jsonl"], missing, true)
	assert_eq(missing_code, 1, "with no file, an error")
