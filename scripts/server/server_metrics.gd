class_name ServerMetrics
extends RefCounted
## Medidas del servidor (docs/red.md, secciones 8.1, 13 y 14): duración del tick y de cada una de
## sus secciones (red, simulación, historial, snapshots...), contadores y un resumen para el
## informe [code]--report[/code] y para los monitores de la depuración remota del editor.
## [br][br]
## Está en [code]scripts/server/[/code], así que puede leer el reloj ([method Time.get_ticks_usec]).
## Uso, una vez por tick:
## [codeblock]
## metrics.begin_tick()
## metrics.begin_section(&"net")
## # ... recibir ...
## metrics.end_section(&"net")
## metrics.end_tick(tick)
## [/codeblock]
## Una sección puede abrirse varias veces en un tick: se suman. Los percentiles se calculan sobre
## los últimos [constant WINDOW_TICKS] ticks de cada sección.

## Ticks que recuerda cada sección (unos 34 s a 60 Hz).
const WINDOW_TICKS: int = 2048
## Nombre de la sección que mide el tick entero.
const SECTION_TICK: StringName = &"tick"

# Contadores que [method summary] sabe interpretar. ZoneServer puede usar los suyos además.
## Jugadores conectados: se suma +1 al entrar y -1 al salir.
const COUNTER_PLAYERS: StringName = &"players"
## Bytes recibidos y enviados por la red.
const COUNTER_BYTES_IN: StringName = &"bytes_in"
const COUNTER_BYTES_OUT: StringName = &"bytes_out"
## Entradas de jugadores consumidas por el servidor y, de ellas, las que hubo que sustituir.
const COUNTER_INPUTS: StringName = &"inputs"
const COUNTER_SUBSTITUTIONS: StringName = &"substitutions"

## Prefijo de los monitores personalizados del editor.
const MONITOR_PREFIX: String = "eldmark/"
const _MONITOR_KEYS: Array[StringName] = [
	&"tick_p50_us", &"tick_p99_us", &"tick_max_us", &"players", &"substituted_percent",
]

## Reloj en microsegundos. Vacío = [method Time.get_ticks_usec]; las pruebas lo sustituyen por
## uno propio para que las medidas sean reproducibles.
var clock_usec: Callable = Callable()

var _tick_start_usec: int = 0
var _first_usec: int = -1
var _last_usec: int = 0
var _ticks_measured: int = 0
var _last_tick: int = 0
# sección -> inicio de la medida abierta (µs).
var _section_start: Dictionary[StringName, int] = {}
# sección -> µs acumulados en el tick actual.
var _section_accum: Dictionary[StringName, int] = {}
# sección -> anillo de duraciones de los últimos ticks.
var _sections: Dictionary[StringName, Series] = {}
var _counters: Dictionary[StringName, int] = {}

# Quién lee cada monitor (id -> instance_id): la última instancia que los registró.
static var _monitor_owners: Dictionary[StringName, int] = {}


## Anillo de duraciones (µs) de una sección y su máximo histórico.
class Series:
	var samples: PackedInt32Array = PackedInt32Array()
	var count: int = 0
	var head: int = 0
	var max_all: int = 0


	func _init() -> void:
		samples.resize(WINDOW_TICKS)


	func push(value: int) -> void:
		samples[head] = value
		head = (head + 1) % WINDOW_TICKS
		count = mini(count + 1, WINDOW_TICKS)
		max_all = maxi(max_all, value)


	# Muestras de la ventana, ordenadas.
	func sorted_window() -> PackedInt32Array:
		var window: PackedInt32Array = samples.slice(0, count) if count < WINDOW_TICKS \
				else samples.duplicate()
		window.sort()
		return window


	# Percentil por rango más cercano (0..1); 0 si no hay muestras.
	func percentile(fraction: float) -> int:
		if count == 0:
			return 0
		var window: PackedInt32Array = sorted_window()
		var rank: int = clampi(ceili(fraction * float(window.size())) - 1, 0, window.size() - 1)
		return window[rank]


## Empieza a medir un tick.
func begin_tick() -> void:
	_tick_start_usec = _now()
	if _first_usec < 0:
		_first_usec = _tick_start_usec


## Abre la medida de [param section] dentro del tick.
func begin_section(section: StringName) -> void:
	_section_start[section] = _now()


## Cierra la medida de [param section] y la suma a lo que lleva en este tick. No hace nada si la
## sección no estaba abierta.
func end_section(section: StringName) -> void:
	if not _section_start.has(section):
		return
	var elapsed: int = maxi(_now() - _section_start[section], 0)
	_section_start.erase(section)
	_section_accum[section] = _section_accum.get(section, 0) + elapsed


## Cierra el tick [param tick]: guarda la duración de cada sección que se usó en él y la del
## tick entero ([constant SECTION_TICK]).
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


## Suma [param amount] (puede ser negativo) al contador [param counter].
func add_counter(counter: StringName, amount: int) -> void:
	_counters[counter] = _counters.get(counter, 0) + amount


## Valor actual del contador [param counter] (0 si no existe).
func get_counter(counter: StringName) -> int:
	return _counters.get(counter, 0)


## Porcentaje de entradas consumidas que hubo que sustituir (0 si no se ha consumido ninguna).
func get_substituted_percent() -> float:
	var inputs: int = get_counter(COUNTER_INPUTS)
	if inputs <= 0:
		return 0.0
	return 100.0 * float(get_counter(COUNTER_SUBSTITUTIONS)) / float(inputs)


## Percentil de [param section] (rango más cercano, [param fraction] entre 0 y 1), en µs. 0 si
## la sección no tiene medidas.
func get_percentile_us(section: StringName, fraction: float) -> int:
	var series: Series = _sections.get(section)
	return 0 if series == null else series.percentile(fraction)


## Máximo de [param section] en la ventana de las últimas medidas, en µs.
func get_max_us(section: StringName) -> int:
	var series: Series = _sections.get(section)
	if series == null or series.count == 0:
		return 0
	return series.sorted_window()[series.count - 1]


## Resumen para el informe y el registro de cada 10 s:
## [codeblock]
## {
##   "ticks": int,                  # ticks medidos
##   "last_tick": int,
##   "seconds": float,              # tiempo real entre el primer begin_tick y el último end_tick
##   "sections": { nombre: {"p50": µs, "p99": µs, "max": µs, "max_all": µs, "samples": int} },
##   "counters": { nombre: int },   # totales
##   "players": int,
##   "kb_in_per_s": float, "kb_out_per_s": float,
##   "substituted_percent": float,  # entradas sustituidas / entradas consumidas
## }
## [/codeblock]
func summary() -> Dictionary:
	var sections: Dictionary = {}
	for section: StringName in _sections:
		var series: Series = _sections[section]
		sections[String(section)] = {
			"p50": series.percentile(0.5),
			"p99": series.percentile(0.99),
			"max": get_max_us(section),
			"max_all": series.max_all,
			"samples": series.count,
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


## Registra los monitores personalizados del editor (pestaña «Monitores» del depurador):
## [code]eldmark/tick_p50_us[/code], [code]tick_p99_us[/code], [code]tick_max_us[/code],
## [code]players[/code] y [code]substituted_percent[/code]. Registrar dos veces el mismo nombre es
## un error del motor, así que cada monitor se añade una sola vez por proceso y esta instancia
## pasa a ser la que lee. Si la instancia que los leía se libera, los monitores devuelven 0
## hasta que otra los vuelva a registrar.
func register_monitors() -> void:
	for key: StringName in _MONITOR_KEYS:
		var id: StringName = _monitor_id(key)
		if not Performance.has_custom_monitor(id):
			Performance.add_custom_monitor(id, _read_monitor.bind(key))
		_monitor_owners[id] = get_instance_id()


## Quita los monitores de los que esta instancia es la dueña (los de otra instancia, no).
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


# Lo que lee el editor: se resuelve la instancia dueña por su id, así que un monitor nunca apunta
# a un objeto liberado.
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
