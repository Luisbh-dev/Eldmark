extends TestCase
## Pruebas de las herramientas de carga ([code]tools/load_test.gd[/code], que se lanza a mano fuera del
## ejecutor) y de [LoadTestSummary], la parte de su resumen que se puede probar sin lanzar procesos.
## [br][br]
## [b]Humo[/b]: el script de la herramienta se carga y se puede instanciar, así que un error de sintaxis
## en él rompe la suite y no se descubre al lanzar la batería de varios minutos.
## [br][br]
## [b]Ventana de medida[/b]: el porcentaje de entradas sustituidas del informe del servidor es de toda
## la sesión, con el arranque dentro (cada bot pierde unas decenas de entradas mientras [TickSync]
## encuentra su antelación, más con 100 ms de RTT). El criterio de la fase 2 (red.md, 16) se mide en
## régimen: [method LoadTestSummary.window_substituted] resta lo acumulado al empezar la ventana, a
## partir de las líneas «Métricas (tick N)» que el servidor escribe cada 600 ticks.

const LOAD_TEST_PATH: String = "res://tools/load_test.gd"

const METRICS_LINE_600: String = "[Eldmark] Métricas (tick 600): 74 jugadores, tick p50 3200 µs / p99 5100 µs / máx 9000 µs (p99 por sección: tick 5100, net 300), entradas sustituidas 4.00 %, subida 85.5 KB/s, bajada 10.0 KB/s"
const METRICS_LINE_1800: String = "[Eldmark] Métricas (tick 1800): 74 jugadores, tick p50 3300 µs / p99 5200 µs / máx 9100 µs (p99 por sección: tick 5200, net 310), entradas sustituidas 1.39 %, subida 86.0 KB/s, bajada 10.1 KB/s"


# --- Humo ------------------------------------------------------------------------------------

func test_load_test_script_loads_and_can_be_instantiated() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script, "%s se carga (un error de sintaxis lo dejaría en null)" % LOAD_TEST_PATH):
		return
	assert_true(script.can_instantiate(), "y se puede instanciar")
	assert_true(script.get_script_method_list().any(
			func(method: Dictionary) -> bool: return method["name"] == "_initialize"),
			"es un script de línea de comandos (SceneTree._initialize)")


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
	assert_true(rtt_100_cluster_64, "hay un escenario con 64 falsos agrupados, bots y 100 ms de RTT (el criterio de la fase 2)")
	for count: int in [64, 128, 256]:
		assert_true(fakes.has(count), "la batería incluye %d jugadores falsos" % count)
	assert_eq(int(constants.get("MATRIX_SECONDS", 0)), 120, "120 s de medida por escenario en --matrix")


# --- Líneas de métricas del servidor --------------------------------------------------------------

func test_cumulative_substituted_percent_is_read_from_the_server_log() -> void:
	var text: String = "\n".join([
		"[Eldmark] Servidor de la zona 'vado_gris' escuchando en el puerto UDP 25000",
		METRICS_LINE_600,
		"[Eldmark] Alta de Bot-01 (net_id 5)",
		METRICS_LINE_1800,
		"[Eldmark] Métricas (tick 2400): sin porcentaje en esta línea",
	])
	assert_eq(LoadTestSummary.parse_metrics_log(text), {600: 4.0, 1800: 1.39},
			"tick -> porcentaje acumulado, y solo de las líneas de métricas")
	assert_eq(LoadTestSummary.parse_metrics_log(""), {})


# --- Ventana de medida ------------------------------------------------------------------------

## Diez bots que entraron en el tick 10 y siguen dentro, y un jugador falso (que no cuenta).
func _players() -> Array:
	var players: Array = []
	for i: int in 10:
		players.append({"fake": false, "joined_tick": 10, "left_tick": -1})
	players.append({"fake": true, "joined_tick": 0, "left_tick": -1})
	return players


func test_consumed_inputs_count_every_tick_a_real_player_was_in() -> void:
	var players: Array = _players()
	assert_eq(LoadTestSummary.consumed_until(players, 600, 3000), 10 * 590, "10 bots desde el tick 10")
	assert_eq(LoadTestSummary.consumed_until(players, 5, 3000), 0, "antes de entrar no consumen")
	players.append({"fake": false, "joined_tick": 100, "left_tick": 400})
	assert_eq(LoadTestSummary.consumed_until(players, 600, 3000), 10 * 590 + 300,
			"uno que se fue en el 400 solo cuenta hasta entonces")
	var unfinished: Array = [{"fake": false, "joined_tick": 10, "left_tick": -1}]
	assert_eq(LoadTestSummary.consumed_until(unfinished, 5000, 1010), 1000,
			"los que siguen dentro cuentan hasta el último tick del servidor")


func test_window_percent_subtracts_what_was_accumulated_at_the_start() -> void:
	var cumulative: Dictionary = {600: 4.0, 1200: 2.2, 1800: 1.39}
	var window: Dictionary = LoadTestSummary.window_substituted(cumulative, _players(), 500, 1900, 2000)
	assert_eq(int(window.get("from_tick", 0)), 600, "empieza en la primera línea de métricas tras el arranque")
	assert_eq(int(window.get("to_tick", 0)), 1800, "y acaba en la última antes del final de los bots")
	# 5900 entradas consumidas en el tick 600 (236 sustituidas) y 17900 en el 1800 (249).
	assert_eq(int(window.get("inputs", 0)), 17900 - 5900)
	assert_eq(int(window.get("substituted", -1)), 249 - 236)
	assert_near(float(window["percent"]), 100.0 * 13.0 / 12000.0, 1e-9, "13 de 12000: 0,11 %")
	assert_true(float(window["percent"]) < 1.0, "muy por debajo de la sesión entera (1,39 %)")


func test_window_percent_is_unavailable_without_two_metric_lines_in_range() -> void:
	var cumulative: Dictionary = {600: 4.0, 1800: 1.39}
	assert_true(LoadTestSummary.window_substituted({}, _players(), 500, 1900, 2000).is_empty(), "sin líneas")
	assert_true(LoadTestSummary.window_substituted({600: 4.0}, _players(), 500, 1900, 2000).is_empty(),
			"con una sola")
	assert_true(LoadTestSummary.window_substituted(cumulative, _players(), 700, 1700, 2000).is_empty(),
			"o si el rango no contiene dos")
	assert_true(LoadTestSummary.window_substituted(cumulative, [], 500, 1900, 2000).is_empty(),
			"o si no hay jugadores de red")


# --- Refriegas (TEC-15) -----------------------------------------------------------------------

func test_brawl_matrix_has_fights_of_32_64_and_128_combatants() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	var constants: Dictionary = script.get_script_constant_map()
	var totals: Array[int] = []
	for entry: Array in constants.get("BRAWL_MATRIX", []):
		assert_eq(entry[0], "brawl", "todos son refriegas")
		assert_true(int(entry[2]) > 0, "con clientes reales que reciben snapshots y eventos")
		totals.append(int(entry[1]) + int(entry[2]))
	assert_eq(totals, [32, 64, 128] as Array[int], "falsos más bots reales")
	assert_true(int(constants.get("BRAWL_SECONDS", 0)) >= 60, "al menos un minuto de medida")
	assert_true(String(constants.get("BRAWL_CENTER", "")).contains(","), "el corro tiene su punto (x,z)")


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
	assert_near(float(figures["event_kb_per_s"]), 2048.0 * 60.0 / 1024.0 / 60.0, 1e-9, "KB/s de eventos")
	assert_eq(figures["hit_tests"], 4000)
	assert_eq(figures["resolve_busy_ticks"], 500)
	assert_near(float(figures["resolve_us_per_test"]), 30.0, 1e-9, "120000 µs entre 4000 comprobaciones")
	assert_near(float(figures["resolve_share"]), 0.3, 1e-9, "una parte de la sección de combate")
	assert_near(float(figures["events_us_per_event"]), 100.0, 1e-9, "20000 µs entre 200 eventos")


func test_combat_figures_of_a_quiet_server_do_not_divide_by_zero() -> void:
	var figures: Dictionary = LoadTestSummary.combat_figures({}, 0.0)
	for key: String in ["hits", "events", "hit_tests"]:
		assert_eq(figures[key], 0)
	for key: String in ["event_kb_per_s", "resolve_us_per_test", "resolve_share", "events_us_per_event"]:
		assert_eq(float(figures[key]), 0.0, key)


# --- Asedios (GUE-16) ----------------------------------------------------------------------------

func test_siege_matrix_has_sieges_of_32_and_64_a_side() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	var constants: Dictionary = script.get_script_constant_map()
	var sides: Array[int] = []
	for entry: Array in constants.get("SIEGE_MATRIX", []):
		assert_eq(entry[0], "siege", "todos son asedios")
		assert_true(int(entry[2]) > 0, "con clientes reales que reciben el OBJECT_STATE del fuerte")
		assert_eq((int(entry[1]) + int(entry[2])) % 2, 0, "los dos bandos, iguales")
		sides.append((int(entry[1]) + int(entry[2])) / 2)
	assert_eq(sides, [32, 64] as Array[int], "32 contra 32 y 64 contra 64")
	assert_eq(int(constants.get("SIEGE_SECONDS", 0)), 120, "120 s de medida")
	assert_true(float(constants.get("SIEGE_EXTRA_SETTLE_SECONDS", 0.0)) >= 40.0, "los bots tienen tiempo de llegar a la puerta")


func test_the_tick_timeline_is_read_from_the_metric_lines() -> void:
	var text: String = "\n".join([
		METRICS_LINE_600,
		"[Eldmark] Métricas (tick 1200): 74 jugadores, tick p50 3250 µs / p99 6000 µs / máx 9500 µs (p99 por sección: tick 6000), entradas sustituidas 0.00 %, subida 9.0 KB/s, bajada 1.0 KB/s, 21 PNJ",
		METRICS_LINE_1800,
		"[Eldmark] Métricas (tick 2400): sin datos del tick",
		"[Eldmark] Métricas (tick 3000): 80 jugadores, tick p50 9000 µs / p99 16000 µs / máx 30000 µs (p99 por sección: tick 16000), bajada 1.0 KB/s, 9 PNJ\r",
	])
	var marks: Array[Dictionary] = LoadTestSummary.parse_tick_timeline(text)
	assert_eq(marks.size(), 4, "las líneas sin datos del tick no cuentan")
	assert_eq(marks[0], {"tick": 600, "players": 74, "npcs": -1, "p50_us": 3200, "p99_us": 5100, "max_us": 9000},
			"una línea de antes de F6b no dice los PNJ")
	assert_eq(marks[1]["npcs"], 21, "los PNJ, al final de la línea (GUE-16)")
	assert_eq(marks[3]["players"], 80)
	assert_eq(marks[3]["npcs"], 9)
	var window: Dictionary = LoadTestSummary.timeline_window(marks, 1000, 3000)
	assert_eq(window["marks"], 3, "las marcas 1200, 1800 y 3000")
	assert_eq(window["p50_us"], 3300, "mediana de los p50")
	assert_eq(window["p99_us"], 6000, "mediana de los p99")
	assert_eq(window["worst_p99_us"], 16000, "el peor p99")
	assert_eq(window["max_us"], 30000, "el mayor máximo")
	assert_eq(window["npcs_min"], 9, "el mínimo de PNJ de las marcas que lo dicen")
	assert_eq(window["npcs_max"], 21)
	assert_eq(LoadTestSummary.timeline_window(marks, 0, 1000)["npcs_min"], -1, "sin marcas con PNJ, -1")
	assert_true(LoadTestSummary.timeline_window(marks, 4000, 5000).is_empty(), "sin marcas en la ventana, nada")
	assert_true(LoadTestSummary.parse_tick_timeline("").is_empty())


func test_the_siege_server_has_its_npcs_only_with_the_npcs_option() -> void:
	var script: GDScript = load(LOAD_TEST_PATH) as GDScript
	if not assert_not_null(script):
		return
	# F6a (sin --npcs): sin PNJ y con la orden que abre el círculo al empezar la ventana.
	var without: PackedStringArray = script.call("siege_server_args", false, "/tmp/b.jsonl", 3530)
	assert_eq(without, PackedStringArray(["--battle-log=/tmp/b.jsonl", "--no-npcs", "--run-at=3530:fort_kill_captain"]))
	# F6b (--npcs): los PNJ de la zona y el fuerte sin ayudas.
	var with_npcs: PackedStringArray = script.call("siege_server_args", true, "/tmp/b.jsonl", 3530)
	assert_eq(with_npcs, PackedStringArray(["--battle-log=/tmp/b.jsonl"]), "ni --no-npcs ni fort_kill_captain")
	var sections: Array = script.get_script_constant_map().get("SECTIONS", [])
	for section: String in ["war", "npc_brains", "npc"]:
		assert_true(sections.has(section), "el resumen muestra la sección %s" % section)


func test_fort_arrivals_count_the_real_bots_that_reached_the_fort_before_the_window() -> void:
	var swarms: Array = [
		{"clients": [{"fort_reached_tick": 2400}, {"fort_reached_tick": 3530}, {"fort_reached_tick": 3600}]},
		{"clients": [{"fort_reached_tick": -1}, {"world_ticks": 900}]},
		{},
	]
	assert_eq(LoadTestSummary.fort_arrivals(swarms, 3530),
			{"bots": 4, "arrived": 3, "before_window": 2, "last_tick": 3600},
			"cuatro de asedio (el que no lo es no cuenta), tres llegan y dos antes de la ventana (el tick de su principio incluido)")
	assert_eq(LoadTestSummary.fort_arrivals([], 100), {"bots": 0, "arrived": 0, "before_window": 0, "last_tick": -1})
