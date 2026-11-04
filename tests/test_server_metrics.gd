extends TestCase
## Tests for [ServerMetrics] (docs/red.md, sections 8.1 and 13): per-section percentiles with a
## fake clock, counters, summary and custom editor monitors.

const TICK: StringName = ServerMetrics.SECTION_TICK

# Fake clock: a one-element array that the lambda functions modify.
var _now: Array[int] = [0]


func before_each() -> void:
	_now[0] = 1000


func after_each() -> void:
	# Monitors are global: they must not outlive the test that registers them.
	for id: StringName in [&"eldmark/tick_p50_us", &"eldmark/tick_p99_us", &"eldmark/tick_max_us",
			&"eldmark/players", &"eldmark/substituted_percent"]:
		if Performance.has_custom_monitor(id):
			Performance.remove_custom_monitor(id)


func _make_metrics() -> ServerMetrics:
	var metrics := ServerMetrics.new()
	metrics.clock_usec = func() -> int: return _now[0]
	return metrics


## A tick of [param duration] µs.
func _tick(metrics: ServerMetrics, tick: int, duration: int) -> void:
	metrics.begin_tick()
	_now[0] += duration
	metrics.end_tick(tick)


func test_percentiles_of_the_tick() -> void:
	var metrics: ServerMetrics = _make_metrics()
	for k: int in range(1, 101):
		_tick(metrics, k, k)
	assert_eq(metrics.get_percentile_us(TICK, 0.5), 50, "p50 of 1..100 µs")
	assert_eq(metrics.get_percentile_us(TICK, 0.95), 95, "p95")
	assert_eq(metrics.get_percentile_us(TICK, 0.99), 99, "p99")
	assert_eq((metrics.summary()["sections"] as Dictionary)["tick"]["p95"], 95, "the summary carries the p95")
	assert_eq(metrics.get_percentile_us(TICK, 1.0), 100, "p100")
	assert_eq(metrics.get_percentile_us(TICK, 0.0), 1, "p0")
	assert_eq(metrics.get_max_us(TICK), 100, "maximum")


func test_unknown_section_has_no_measures() -> void:
	var metrics: ServerMetrics = _make_metrics()
	assert_eq(metrics.get_percentile_us(&"nada", 0.5), 0, "p50 with no measurements")
	assert_eq(metrics.get_max_us(&"nada"), 0, "maximum with no measurements")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["ticks"], 0, "no ticks")
	assert_eq(summary["players"], 0, "no players")
	assert_near(summary["kb_out_per_s"], 0.0, 1e-9, "without time there is no rate")
	assert_near(summary["substituted_percent"], 0.0, 1e-9, "without inputs, 0 %")


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
	assert_eq(metrics.get_max_us(&"net"), 50, "net maximum")
	assert_eq(metrics.get_max_us(&"sim"), 500, "sim maximum")
	assert_eq(metrics.get_percentile_us(&"net", 0.5), 25, "net p50")
	assert_eq(metrics.get_percentile_us(&"sim", 0.5), 250, "sim p50")
	assert_eq(metrics.get_max_us(TICK), 11 * 50 + 3, "the whole tick adds up its sections and the rest")


func test_a_section_opened_twice_in_a_tick_adds_up() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.begin_tick()
	for _i: int in 3:
		metrics.begin_section(&"net")
		_now[0] += 7
		metrics.end_section(&"net")
		_now[0] += 100
	metrics.end_tick(1)
	assert_eq(metrics.get_max_us(&"net"), 21, "3 × 7 µs in a single tick")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["sections"]["net"]["samples"], 1, "one sample per tick, not per opening")


func test_end_section_without_begin_is_ignored() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.begin_tick()
	metrics.end_section(&"fantasma")
	metrics.end_tick(1)
	assert_false(metrics.summary()["sections"].has("fantasma"), "the section is not created")


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
	assert_eq(metrics.get_percentile_us(&"net", 1.0), 0, "an unclosed section is not measured")


func test_window_forgets_old_samples_but_not_the_historic_maximum() -> void:
	var metrics: ServerMetrics = _make_metrics()
	for k: int in ServerMetrics.WINDOW_TICKS:
		_tick(metrics, k + 1, 10000)
	for k: int in ServerMetrics.WINDOW_TICKS:
		_tick(metrics, ServerMetrics.WINDOW_TICKS + k + 1, 5)
	assert_eq(metrics.get_percentile_us(TICK, 0.99), 5, "the window now only remembers recent data")
	assert_eq(metrics.get_max_us(TICK), 5, "and so does its maximum")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["sections"]["tick"]["max_all"], 10000, "the historical maximum is kept")
	assert_eq(summary["sections"]["tick"]["samples"], ServerMetrics.WINDOW_TICKS, "full window")
	assert_eq(summary["ticks"], 2 * ServerMetrics.WINDOW_TICKS, "all ticks measured")


func test_counters() -> void:
	var metrics: ServerMetrics = _make_metrics()
	assert_eq(metrics.get_counter(&"nada"), 0, "nonexistent counter")
	metrics.add_counter(&"bytes_out", 100)
	metrics.add_counter(&"bytes_out", 250)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 3)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, -1)
	assert_eq(metrics.get_counter(&"bytes_out"), 350, "they add up")
	assert_eq(metrics.get_counter(ServerMetrics.COUNTER_PLAYERS), 2, "and allow subtractions")
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["counters"]["bytes_out"], 350, "the summary carries the totals")
	assert_eq(summary["players"], 2, "players")


func test_summary_rates_and_substitution_percentage() -> void:
	var metrics: ServerMetrics = _make_metrics()
	# 10 seconds of fake clock: 600 ticks of 16,666 µs (the last one ends at 10 s).
	for k: int in range(1, 601):
		_tick(metrics, k, 16667 if k % 3 != 0 else 16666)
	metrics.add_counter(ServerMetrics.COUNTER_BYTES_OUT, 10 * 1024 * 20)
	metrics.add_counter(ServerMetrics.COUNTER_BYTES_IN, 10 * 1024 * 5)
	metrics.add_counter(ServerMetrics.COUNTER_INPUTS, 200)
	metrics.add_counter(ServerMetrics.COUNTER_SUBSTITUTIONS, 5)
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["ticks"], 600, "ticks")
	assert_eq(summary["last_tick"], 600, "last tick")
	assert_near(summary["seconds"], 10.0, 0.001, "seconds measured")
	assert_near(summary["kb_out_per_s"], 20.0, 0.01, "KB/s out")
	assert_near(summary["kb_in_per_s"], 5.0, 0.01, "KB/s in")
	assert_near(summary["substituted_percent"], 2.5, 1e-6, "5 of 200 inputs")
	assert_near(metrics.get_substituted_percent(), 2.5, 1e-6, "get_substituted_percent")
	var tick_stats: Dictionary = summary["sections"]["tick"]
	assert_eq(tick_stats["p50"], 16667, "tick p50")
	assert_eq(tick_stats["p95"], 16667, "tick p95")
	assert_eq(tick_stats["p99"], 16667, "tick p99")
	assert_eq(tick_stats["max"], 16667, "tick maximum")
	assert_eq(tick_stats["samples"], 600, "samples")


func test_summary_can_be_written_as_json() -> void:
	var metrics: ServerMetrics = _make_metrics()
	for k: int in range(1, 11):
		_tick(metrics, k, 100 * k)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 4)
	var text: String = JSON.stringify(metrics.summary())
	var parsed: Variant = JSON.parse_string(text)
	if assert_true(parsed is Dictionary, "the summary is valid JSON"):
		assert_eq((parsed as Dictionary)["players"], 4, "and keeps the data")


func test_default_clock_is_the_real_one() -> void:
	var metrics := ServerMetrics.new()
	metrics.begin_tick()
	metrics.begin_section(&"net")
	metrics.end_section(&"net")
	metrics.end_tick(1)
	var summary: Dictionary = metrics.summary()
	assert_eq(summary["ticks"], 1, "one tick measured")
	assert_true(summary["sections"]["tick"]["max"] >= 0, "non-negative duration")
	assert_true(summary["sections"].has("net"), "and its section")


# --- Custom monitors --------------------------------------------------------------------------

func test_register_monitors_exposes_the_measures() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.register_monitors()
	for k: int in range(1, 101):
		_tick(metrics, k, k)
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 7)
	metrics.add_counter(ServerMetrics.COUNTER_INPUTS, 100)
	metrics.add_counter(ServerMetrics.COUNTER_SUBSTITUTIONS, 10)
	assert_true(Performance.has_custom_monitor(&"eldmark/tick_p99_us"), "monitor registered")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/tick_p50_us")), 50.0, 1e-6, "p50")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/tick_p99_us")), 99.0, 1e-6, "p99")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/tick_max_us")), 100.0, 1e-6, "max")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 7.0, 1e-6, "players")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/substituted_percent")), 10.0, 1e-6,
			"substituted")
	metrics.unregister_monitors()
	assert_false(Performance.has_custom_monitor(&"eldmark/tick_p99_us"), "and they can be removed")


func test_register_monitors_twice_does_not_raise_errors() -> void:
	var first: ServerMetrics = _make_metrics()
	first.register_monitors()
	first.register_monitors()
	assert_true(Performance.has_custom_monitor(&"eldmark/players"), "still registered")
	# Another instance with the same names (for example, a second server in the same process).
	var second: ServerMetrics = _make_metrics()
	second.add_counter(ServerMetrics.COUNTER_PLAYERS, 3)
	second.register_monitors()
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 3.0, 1e-6,
			"the monitors move to the latest instance")
	# The first is no longer the owner: removing its own does not touch the second's.
	first.unregister_monitors()
	assert_true(Performance.has_custom_monitor(&"eldmark/players"), "the second's remain")
	second.unregister_monitors()
	assert_false(Performance.has_custom_monitor(&"eldmark/players"), "until it removes them")


func test_freeing_the_metrics_leaves_harmless_monitors() -> void:
	var metrics: ServerMetrics = _make_metrics()
	metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 5)
	metrics.register_monitors()
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 5.0, 1e-6, "alive")
	metrics = null
	assert_true(Performance.has_custom_monitor(&"eldmark/players"), "the monitor is still registered")
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 0.0, 1e-6,
			"but it no longer points to a freed object: it returns 0 without errors")
	# Another instance takes over the monitors without registering them again.
	var next_metrics: ServerMetrics = _make_metrics()
	next_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 2)
	next_metrics.register_monitors()
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 2.0, 1e-6,
			"the new instance reads them")
	next_metrics.unregister_monitors()


func test_freeing_an_old_instance_keeps_the_new_ones_monitors() -> void:
	var old_metrics: ServerMetrics = _make_metrics()
	old_metrics.register_monitors()
	var new_metrics: ServerMetrics = _make_metrics()
	new_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 9)
	new_metrics.register_monitors()
	old_metrics = null
	assert_near(float(Performance.get_custom_monitor(&"eldmark/players")), 9.0, 1e-6,
			"freeing the old instance does not affect the new one's monitors")
	new_metrics.unregister_monitors()


func test_summary_keeps_the_total_and_count_of_the_whole_run_not_only_the_window() -> void:
	var metrics: ServerMetrics = _make_metrics()
	var ticks: int = ServerMetrics.WINDOW_TICKS + 100
	for k: int in range(1, ticks + 1):
		metrics.begin_tick()
		metrics.begin_section(&"combat_resolve")
		_now[0] += 5
		metrics.end_section(&"combat_resolve")
		metrics.end_tick(k)
	var section: Dictionary = metrics.summary()["sections"]["combat_resolve"]
	assert_eq(section["samples"], ServerMetrics.WINDOW_TICKS, "the window remains bounded")
	assert_eq(section["pushed"], ticks, "but all measurements are counted")
	assert_eq(section["total_us"], 5 * ticks, "and all are summed (the mean comes from there)")
