class_name ServerMetrics
extends RefCounted
## Server measurements (docs/networking.md, sections 8.1, 13 and 14): duration of the tick and of each of its sections
## (network, simulation, history, snapshots...), counters and a summary for the [code]--report[/code] report and for the
## editor's remote debugging monitors.
## [br][br]
## It lives in [code]scripts/server/[/code], so it can read the clock ([method Time.get_ticks_usec]). Usage, once per
## tick:
## [codeblock]
## metrics.begin_tick()
## metrics.begin_section(&"net")
## # ... receive ...
## metrics.end_section(&"net")
## metrics.end_tick(tick)
## [/codeblock]
## A section can be opened several times in a tick: they are added up. Percentiles are computed over the last
## [constant WINDOW_TICKS] ticks of each section.

## Ticks that each section remembers (about 34 s at 60 Hz).
const WINDOW_TICKS: int = 2048
## Name of the section that measures the whole tick.
const SECTION_TICK: StringName = &"tick"

# Counters that [method summary] knows how to interpret. ZoneServer can also use its own.
## Connected players: +1 is added on joining and -1 on leaving.
const COUNTER_PLAYERS: StringName = &"players"
## Bytes received and sent over the network.
const COUNTER_BYTES_IN: StringName = &"bytes_in"
const COUNTER_BYTES_OUT: StringName = &"bytes_out"
## Player inputs consumed by the server and, of those, the ones that had to be substituted.
const COUNTER_INPUTS: StringName = &"inputs"
const COUNTER_SUBSTITUTIONS: StringName = &"substitutions"

## Prefix of the editor's custom monitors.
const MONITOR_PREFIX: String = "eldmark/"
const _MONITOR_KEYS: Array[StringName] = [
	&"tick_p50_us", &"tick_p99_us", &"tick_max_us", &"players", &"substituted_percent",
]

## Clock in microseconds. Empty = [method Time.get_ticks_usec]; tests replace it with their own so that measurements are
## reproducible.
var clock_usec: Callable = Callable()

var _tick_start_usec: int = 0
var _first_usec: int = -1
var _last_usec: int = 0
var _ticks_measured: int = 0
var _last_tick: int = 0
# section -> start of the open measurement (µs).
var _section_start: Dictionary[StringName, int] = {}
# section -> µs accumulated in the current tick.
var _section_accum: Dictionary[StringName, int] = {}
# section -> ring of durations of the last ticks.
var _sections: Dictionary[StringName, Series] = {}
var _counters: Dictionary[StringName, int] = {}

# Who reads each monitor (id -> instance_id): the last instance that registered them.
static var _monitor_owners: Dictionary[StringName, int] = {}


## Ring of durations (µs) of a section and its all-time maximum.
class Series:
	var samples: PackedInt32Array = PackedInt32Array()
	var count: int = 0
	var head: int = 0
	var max_all: int = 0
	## Sum (µs) and number of all measurements since the start (not just those in the window): a section's mean comes from
	## them.
	var total: int = 0
	var pushed: int = 0


	func _init() -> void:
		samples.resize(WINDOW_TICKS)


	func push(value: int) -> void:
		samples[head] = value
		head = (head + 1) % WINDOW_TICKS
		count = mini(count + 1, WINDOW_TICKS)
		max_all = maxi(max_all, value)
		total += value
		pushed += 1


	# Samples of the window, sorted.
	func sorted_window() -> PackedInt32Array:
		var window: PackedInt32Array = samples.slice(0, count) if count < WINDOW_TICKS \
				else samples.duplicate()
		window.sort()
		return window


	# Nearest-rank percentile (0..1); 0 if there are no samples.
	func percentile(fraction: float) -> int:
		if count == 0:
			return 0
		var window: PackedInt32Array = sorted_window()
		var rank: int = clampi(ceili(fraction * float(window.size())) - 1, 0, window.size() - 1)
		return window[rank]


## Starts measuring a tick.
func begin_tick() -> void:
	_tick_start_usec = _now()
	if _first_usec < 0:
		_first_usec = _tick_start_usec


## Opens the measurement of [param section] within the tick.
func begin_section(section: StringName) -> void:
	_section_start[section] = _now()


## Closes the measurement of [param section] and adds it to what it has in this tick. Does nothing if the section was
## not open.
func end_section(section: StringName) -> void:
	if not _section_start.has(section):
		return
	var elapsed: int = maxi(_now() - _section_start[section], 0)
	_section_start.erase(section)
	_section_accum[section] = _section_accum.get(section, 0) + elapsed


## Closes tick [param tick]: stores the duration of each section used in it and that of the whole tick
## ([constant SECTION_TICK]).
func end_tick(tick: int) -> void:
	var now: int = _now()
	_last_usec = now
	_last_tick = tick
	_ticks_measured += 1
	_push(SECTION_TICK, maxi(now - _tick_start_usec, 0))
	for section: StringName in _section_accum:
		_push(section, _section_accum[section])
	_section_accum.clear()
	_section_start.clear()


## Adds [param amount] (may be negative) to the counter [param counter].
func add_counter(counter: StringName, amount: int) -> void:
	_counters[counter] = _counters.get(counter, 0) + amount


## Current value of the counter [param counter] (0 if it does not exist).
func get_counter(counter: StringName) -> int:
	return _counters.get(counter, 0)


## Percentage of consumed inputs that had to be substituted (0 if none has been consumed).
func get_substituted_percent() -> float:
	var inputs: int = get_counter(COUNTER_INPUTS)
	if inputs <= 0:
		return 0.0
	return 100.0 * float(get_counter(COUNTER_SUBSTITUTIONS)) / float(inputs)


## Percentile of [param section] (nearest rank, [param fraction] between 0 and 1), in µs. 0 if the section has no
## measurements.
func get_percentile_us(section: StringName, fraction: float) -> int:
	var series: Series = _sections.get(section)
	return 0 if series == null else series.percentile(fraction)


## Maximum of [param section] in the window of the latest measurements, in µs.
func get_max_us(section: StringName) -> int:
	var series: Series = _sections.get(section)
	if series == null or series.count == 0:
		return 0
	return series.sorted_window()[series.count - 1]


## Summary for the report and the log every 10 s:
## [codeblock]
## {
##   "ticks": int,                  # ticks measured
##   "last_tick": int,
##   "seconds": float,              # real time between the first begin_tick and the last end_tick
##   "sections": { name: {"p50": µs, "p95": µs, "p99": µs, "max": µs, "max_all": µs, "samples": int,
##                        "total_us": µs of the whole run, "pushed": measurements of the whole run} },
##   "counters": { name: int },     # totals
##   "players": int,
##   "kb_in_per_s": float, "kb_out_per_s": float,
##   "substituted_percent": float,  # substituted inputs / consumed inputs
## }
## [/codeblock]
func summary() -> Dictionary:
	var sections: Dictionary = {}
	for section: StringName in _sections:
		var series: Series = _sections[section]
		sections[String(section)] = {
			"p50": series.percentile(0.5),
			"p95": series.percentile(0.95),
			"p99": series.percentile(0.99),
			"max": get_max_us(section),
			"max_all": series.max_all,
			"samples": series.count,
			"total_us": series.total,
			"pushed": series.pushed,
		}
	var counters: Dictionary = {}
	for counter: StringName in _counters:
		counters[String(counter)] = _counters[counter]
	var seconds: float = _elapsed_seconds()
	return {
		"ticks": _ticks_measured,
		"last_tick": _last_tick,
		"seconds": seconds,
		"sections": sections,
		"counters": counters,
		"players": get_counter(COUNTER_PLAYERS),
		"kb_in_per_s": _kb_per_second(get_counter(COUNTER_BYTES_IN), seconds),
		"kb_out_per_s": _kb_per_second(get_counter(COUNTER_BYTES_OUT), seconds),
		"substituted_percent": get_substituted_percent(),
	}


## Registers the editor's custom monitors ("Monitores" (Monitors) tab of the debugger):
## [code]eldmark/tick_p50_us[/code], [code]tick_p99_us[/code], [code]tick_max_us[/code],
## [code]players[/code] and [code]substituted_percent[/code]. Registering the same name twice is an engine error, so each
## monitor is added only once per process and this instance becomes the one that reads. If the instance that was reading
## them is freed, the monitors return 0 until another registers them again.
func register_monitors() -> void:
	for key: StringName in _MONITOR_KEYS:
		var id: StringName = _monitor_id(key)
		if not Performance.has_custom_monitor(id):
			Performance.add_custom_monitor(id, _read_monitor.bind(key))
		_monitor_owners[id] = get_instance_id()


## Removes the monitors that this instance owns (not those of another instance).
func unregister_monitors() -> void:
	for key: StringName in _MONITOR_KEYS:
		var id: StringName = _monitor_id(key)
		if _monitor_owners.get(id, 0) == get_instance_id():
			_monitor_owners.erase(id)
			if Performance.has_custom_monitor(id):
				Performance.remove_custom_monitor(id)


func _now() -> int:
	if clock_usec.is_valid():
		return int(clock_usec.call())
	return Time.get_ticks_usec()


func _push(section: StringName, value: int) -> void:
	var series: Series = _sections.get(section)
	if series == null:
		series = Series.new()
		_sections[section] = series
	series.push(value)


func _elapsed_seconds() -> float:
	if _first_usec < 0 or _ticks_measured == 0:
		return 0.0
	return float(maxi(_last_usec - _first_usec, 0)) / 1000000.0


static func _kb_per_second(total_bytes: int, seconds: float) -> float:
	return float(total_bytes) / 1024.0 / seconds if seconds > 0.0 else 0.0


static func _monitor_id(key: StringName) -> StringName:
	return StringName(MONITOR_PREFIX + String(key))


# What the editor reads: the owning instance is resolved by its id, so a monitor never points to a freed object.
static func _read_monitor(key: StringName) -> float:
	var owner_id: int = _monitor_owners.get(_monitor_id(key), 0)
	var metrics: ServerMetrics = instance_from_id(owner_id) as ServerMetrics
	if metrics == null:
		return 0.0
	return metrics._monitor_value(key)


func _monitor_value(key: StringName) -> float:
	match key:
		&"tick_p50_us":
			return float(get_percentile_us(SECTION_TICK, 0.5))
		&"tick_p99_us":
			return float(get_percentile_us(SECTION_TICK, 0.99))
		&"tick_max_us":
			return float(get_max_us(SECTION_TICK))
		&"players":
			return float(get_counter(COUNTER_PLAYERS))
		&"substituted_percent":
			return get_substituted_percent()
	return 0.0
