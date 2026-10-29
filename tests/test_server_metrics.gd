extends TestCase
## Pruebas de [ServerMetrics] (docs/red.md, secciones 8.1 y 13): percentiles por sección con un
## reloj falso, contadores, resumen y monitores personalizados del editor.

const TICK: StringName = ServerMetrics.SECTION_TICK

# Reloj falso: un array de un elemento que las funciones lambda modifican.
var _now: Array[int] = [0]


func before_each() -> void:
	_now[0] = 1000


func after_each() -> void:
	# Los monitores son globales: no deben sobrevivir a la prueba que los registra.
	for id: StringName in [&"eldmark/tick_p50_us", &"eldmark/tick_p99_us", &"eldmark/tick_max_us",
			&"eldmark/players", &"eldmark/substituted_percent"]:
		if Performance.has_custom_monitor(id):
			Performance.remove_custom_monitor(id)


func _make_metrics() -> ServerMetrics:
	var metrics := ServerMetrics.new()
	metrics.clock_usec = func() -> int: return _now[0]
	return metrics


## Un tick de [param duration] µs.
func _tick(metrics: ServerMetrics, tick: int, duration: int) -> void:
	metrics.begin_tick()
	_now[0] += duration
	metrics.end_tick(tick)


func test_percentiles_of_the_tick() -> void:
	var metrics: ServerMetrics = _make_metrics()
	for k: int in range(1, 101):
		_tick(metrics, k, k)
	assert_eq(metrics.get_percentile_us(TICK, 0.5), 50, "p50 de 1..100 µs")
	assert_eq(metrics.get_percentile_us(TICK, 0.99), 99, "p99")
	assert_eq(metrics.get_percentile_us(TICK, 1.0), 100, "p100")
	assert_eq(metrics.get_percentile_us(TICK, 0.0), 1, "p0")
	assert_eq(metrics.get_max_us(TICK), 100, "máximo")


func test_unknown_section_has_no_measures() -> void:
	var metrics: ServerMetrics = _make_metrics()
	assert_eq(metrics.get_percentile_us(&"nada", 0.5), 0, "p50 sin medidas")
	assert_eq(metrics.get_max_us(&"nada"), 0, "máximo sin medidas")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["ticks"], 0, "ningún tick")
	assert_eq(summary["players"], 0, "ningún jugador")
	assert_near(summary["kb_out_per_s"], 0.0, 1e-9, "sin tiempo no hay tasa")
	assert_near(summary["substituted_percent"], 0.0, 1e-9, "sin entradas, 0 %")


func test_sections_are_measured_separately() -> void:
	var metrics: ServerMetrics = _make_metrics()
	for k: int in range(1, 51):
		metrics.begin_tick()
		metrics.begin_section(&"net")
		_now[0] += k
		metrics.end_section(&"net")
		metrics.begin_section(&"sim")
		_now[0] += 10 * k
		metrics.end_section(&"sim")
		_now[0] += 3
		metrics.end_tick(k)
	assert_eq(metrics.get_max_us(&"net"), 50, "máximo de net")
	assert_eq(metrics.get_max_us(&"sim"), 500, "máximo de sim")
	assert_eq(metrics.get_percentile_us(&"net", 0.5), 25, "p50 de net")
	assert_eq(metrics.get_percentile_us(&"sim", 0.5), 250, "p50 de sim")
	assert_eq(metrics.get_max_us(TICK), 11 * 50 + 3, "el tick entero suma sus secciones y el resto")


func test_a_section_opened_twice_in_a_tick_adds_up() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.begin_tick()
	for _i: int in 3:
		metrics.begin_section(&"net")
		_now[0] += 7
		metrics.end_section(&"net")
		_now[0] += 100
	metrics.end_tick(1)
	assert_eq(metrics.get_max_us(&"net"), 21, "3 × 7 µs en un solo tick")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["sections"]["net"]["samples"], 1, "una muestra por tick, no por apertura")


func test_end_section_without_begin_is_ignored() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.begin_tick()
	metrics.end_section(&"fantasma")
	metrics.end_tick(1)
	assert_false(metrics.summary()["sections"].has("fantasma"), "no se crea la sección")


func test_unclosed_sections_do_not_leak_into_the_next_tick() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.begin_tick()
	metrics.begin_section(&"net")
	_now[0] += 50
	metrics.end_tick(1)
	metrics.begin_tick()
	_now[0] += 5
	metrics.end_section(&"net")
	metrics.end_tick(2)
	assert_eq(metrics.get_percentile_us(&"net", 1.0), 0, "una sección sin cerrar no se mide")


func test_window_forgets_old_samples_but_not_the_historic_maximum() -> void:
	var metrics: ServerMetrics = _make_metrics()
	for k: int in ServerMetrics.WINDOW_TICKS:
		_tick(metrics, k + 1, 10000)
	for k: int in ServerMetrics.WINDOW_TICKS:
		_tick(metrics, ServerMetrics.WINDOW_TICKS + k + 1, 5)
	assert_eq(metrics.get_percentile_us(TICK, 0.99), 5, "la ventana ya solo recuerda lo reciente")
	assert_eq(metrics.get_max_us(TICK), 5, "y su máximo también")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["sections"]["tick"]["max_all"], 10000, "el máximo histórico se conserva")
	assert_eq(summary["sections"]["tick"]["samples"], ServerMetrics.WINDOW_TICKS, "ventana llena")
	assert_eq(summary["ticks"], 2 * ServerMetrics.WINDOW_TICKS, "todos los ticks medidos")


func test_counters() -> void:
	var metrics: ServerMetrics = _make_metrics()
	assert_eq(metrics.get_counter(&"nada"), 0, "contador inexistente")
	metrics.add_counter(&"bytes_out", 100)
	metrics.add_counter(&"bytes_out", 250)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 3)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, -1)
	assert_eq(metrics.get_counter(&"bytes_out"), 350, "se suman")
	assert_eq(metrics.get_counter(ServerMetrics.COUNTER_PLAYERS), 2, "y admiten restas")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["counters"]["bytes_out"], 350, "el resumen trae los totales")
	assert_eq(summary["players"], 2, "jugadores")


func test_summary_rates_and_substitution_percentage() -> void:
	var metrics: ServerMetrics = _make_metrics()
	# 10 segundos de reloj falso: 600 ticks de 16 666 µs (el último acaba a 10 s).
	for k: int in range(1, 601):
		_tick(metrics, k, 16667 if k % 3 != 0 else 16666)
	metrics.add_counter(ServerMetrics.COUNTER_BYTES_OUT, 10 * 1024 * 20)
	metrics.add_counter(ServerMetrics.COUNTER_BYTES_IN, 10 * 1024 * 5)
	metrics.add_counter(ServerMetrics.COUNTER_INPUTS, 200)
	metrics.add_counter(ServerMetrics.COUNTER_SUBSTITUTIONS, 5)
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["ticks"], 600, "ticks")
	assert_eq(summary["last_tick"], 600, "último tick")
	assert_near(summary["seconds"], 10.0, 0.001, "segundos medidos")
	assert_near(summary["kb_out_per_s"], 20.0, 0.01, "KB/s de salida")
	assert_near(summary["kb_in_per_s"], 5.0, 0.01, "KB/s de entrada")
	assert_near(summary["substituted_percent"], 2.5, 1e-6, "5 de 200 entradas")
	assert_near(metrics.get_substituted_percent(), 2.5, 1e-6, "get_substituted_percent")
	var tick_stats: Dictionary = summary["sections"]["tick"]
	assert_eq(tick_stats["p50"], 16667, "p50 del tick")
	assert_eq(tick_stats["p99"], 16667, "p99 del tick")
	assert_eq(tick_stats["max"], 16667, "máximo del tick")
	assert_eq(tick_stats["samples"], 600, "muestras")


func test_summary_can_be_written_as_json() -> void:
	var metrics: ServerMetrics = _make_metrics()
	for k: int in range(1, 11):
		_tick(metrics, k, 100 * k)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 4)
	var text: String = JSON.stringify(metrics.summary())
	var parsed: Variant = JSON.parse_string(text)
	if assert_true(parsed is Dictionary, "el resumen es JSON válido"):
		assert_eq((parsed as Dictionary)["players"], 4, "y conserva los datos")


func test_default_clock_is_the_real_one() -> void:
	var metrics := ServerMetrics.new()
	metrics.begin_tick()
	metrics.begin_section(&"net")
	metrics.end_section(&"net")
	metrics.end_tick(1)
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["ticks"], 1, "un tick medido")
	assert_true(summary["sections"]["tick"]["max"] >= 0, "duración no negativa")
	assert_true(summary["sections"].has("net"), "y su sección")


# --- Monitores personalizados -----------------------------------------------------------------

func test_register_monitors_exposes_the_measures() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.register_monitors()
	for k: int in range(1, 101):
		_tick(metrics, k, k)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 7)
	metrics.add_counter(ServerMetrics.COUNTER_INPUTS, 100)
	metrics.add_counter(ServerMetrics.COUNTER_SUBSTITUTIONS, 10)
	assert_true(Performance.has_custom_monitor(&"eldmark/tick_p99_us"), "monitor registrado")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/tick_p50_us")), 50.0, 1e-6, "p50")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/tick_p99_us")), 99.0, 1e-6, "p99")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/tick_max_us")), 100.0, 1e-6, "máx")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 7.0, 1e-6, "jugadores")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/substituted_percent")), 10.0, 1e-6,
			"sustituidas")
	metrics.unregister_monitors()
	assert_false(Performance.has_custom_monitor(&"eldmark/tick_p99_us"), "y se pueden quitar")


func test_register_monitors_twice_does_not_raise_errors() -> void:
	var first: ServerMetrics = _make_metrics()
	first.register_monitors()
	first.register_monitors()
	assert_true(Performance.has_custom_monitor(&"eldmark/players"), "sigue registrado")
	# Otra instancia con los mismos nombres (por ejemplo, un segundo servidor en el mismo proceso).
	var second: ServerMetrics = _make_metrics()
	second.add_counter(ServerMetrics.COUNTER_PLAYERS, 3)
	second.register_monitors()
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 3.0, 1e-6,
			"los monitores pasan a la última instancia")
	# La primera ya no es la dueña: quitar los suyos no toca los de la segunda.
	first.unregister_monitors()
	assert_true(Performance.has_custom_monitor(&"eldmark/players"), "los de la segunda siguen")
	second.unregister_monitors()
	assert_false(Performance.has_custom_monitor(&"eldmark/players"), "hasta que ella los quita")


func test_freeing_the_metrics_leaves_harmless_monitors() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 5)
	metrics.register_monitors()
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 5.0, 1e-6, "vivo")
	metrics = null
	assert_true(Performance.has_custom_monitor(&"eldmark/players"), "el monitor sigue registrado")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 0.0, 1e-6,
			"pero ya no apunta a un objeto liberado: devuelve 0 sin errores")
	# Otra instancia retoma los monitores sin registrarlos otra vez.
	var next_metrics: ServerMetrics = _make_metrics()
	next_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 2)
	next_metrics.register_monitors()
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 2.0, 1e-6,
			"la nueva instancia los lee")
	next_metrics.unregister_monitors()


func test_freeing_an_old_instance_keeps_the_new_ones_monitors() -> void:
	var old_metrics: ServerMetrics = _make_metrics()
	old_metrics.register_monitors()
	var new_metrics: ServerMetrics = _make_metrics()
	new_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 9)
	new_metrics.register_monitors()
	old_metrics = null
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 9.0, 1e-6,
			"liberar la instancia vieja no afecta a los monitores de la nueva")
	new_metrics.unregister_monitors()
