extends TestCase
## Telemetría de la batalla (GUE-17; docs/fuerte.md, sección 7): el registro JSON Lines ([BattleLog]) y
## su resumen ([BattleSummary] y [code]tools/war/summarize_battle.gd[/code]): tiempo hasta la captura,
## muertes por ruta (puente, vado, pasarela) y tiempo hasta romper la puerta.

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


## Entidad de pruebas (jugador o PNJ) con nombre y reino.
func _entity(net_id: int, display_name: String, realm: int, kind: int) -> NetEntity:
	var entity := NetEntity.new()
	entity.net_id = net_id
	entity.display_name = display_name
	entity.realm = realm
	entity.kind = kind
	return entity


## Escribe un registro de batalla con dos ciclos de captura, una puerta rota y muertes en cuatro sitios.
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
		if not assert_true(entry is Dictionary, "línea legible: %s" % line):
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
	assert_eq(int(environment["killer"]), 0, "el entorno no tiene asesino")
	assert_eq((JSON.parse_string(lines[11]) as Dictionary)["victim_kind"], "npc")


func test_a_log_that_cannot_be_opened_is_null() -> void:
	assert_null(BattleLog.open(""))
	var closed: BattleLog = BattleLog.open(LOG_PATH)
	closed.close()
	closed.log_war(1, WarEvents.FORT_RESET, 0, FORTRESS_ID, Vector3.ZERO)
	assert_false(closed.is_open(), "escribir en uno cerrado no hace nada")


func test_the_summary_gives_capture_times_gate_time_and_deaths_by_route() -> void:
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	if not assert_not_null(routes, "las rutas del Vado Gris"):
		return
	var summary: Dictionary = BattleSummary.summarize(_write_sample_log(), routes)
	assert_eq(summary["zone"], "vado_gris")
	assert_eq(int(summary["ticks"]), 10200)
	assert_near(summary["duration_s"], 170.0, 1e-6)
	assert_eq(int(summary["bad_lines"]), 0)
	var captures: Array = summary["captures"]
	if not assert_eq(captures.size(), 2, "dos capturas"):
		return
	var first: Dictionary = captures[0]
	assert_eq(int(first["realm"]), 1)
	assert_near(first["seconds_from_cycle_start"], 5900.0 / 60.0, 1e-6, "desde el inicio de la batalla")
	assert_near(first["seconds_from_captain_down"], 1900.0 / 60.0, 1e-6, "desde la caída del capitán")
	assert_near(first["seconds_capturing"], 1800.0 / 60.0, 1e-6, "la captura propiamente dicha: 30 s")
	var second: Dictionary = captures[1]
	assert_eq(int(second["realm"]), 2)
	assert_near(second["seconds_from_cycle_start"], 1200.0 / 60.0, 1e-6, "el ciclo cuenta desde el reinicio")
	var breaks: Array = summary["gate_breaks"]
	if assert_eq(breaks.size(), 1):
		assert_near(breaks[0]["seconds"], 3300.0 / 60.0, 1e-6, "del primer golpe a la rotura: 55 s")
		assert_eq(breaks[0]["fortress"], "vado_gris_fort")
	var deaths: Dictionary = summary["deaths"]
	assert_eq(int(deaths["players"]), 4)
	assert_eq(int(deaths["npcs"]), 1, "los PNJ aparte")
	var by_route: Dictionary = deaths["by_route"]
	assert_eq(int(by_route.get("bridge", 0)), 1)
	assert_eq(int(by_route.get("ford", 0)), 1)
	assert_eq(int(by_route.get("walkway", 0)), 1)
	assert_eq(int(by_route.get("other", 0)), 1)
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
	assert_eq(BattleSummary.classify_route([0.0, 6.0, 55.0], fortress, routes), &"bridge", "el reflejo, del otro bando")
	assert_eq(BattleSummary.classify_route([-91.0, 4.0, -25.0], fortress, routes), &"ford")
	assert_eq(BattleSummary.classify_route([-8.5, 13.8, 3.0], fortress, routes), &"walkway")
	assert_eq(BattleSummary.classify_route([-8.5, 10.3, 3.0], fortress, routes) != &"walkway", true,
			"el patio, a ras de suelo, no es la pasarela")
	assert_eq(BattleSummary.classify_route([200.0, 5.0, 200.0], fortress, routes), &"other")
	assert_eq(BattleSummary.classify_route([1.0], fortress, routes), &"other", "una posición incompleta")


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
	assert_eq(missing_code, 1, "sin archivo, error")
