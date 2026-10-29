class_name DpsMeter
extends RefCounted
## Medidor de daño por segundo del jugador local (CMB-11, docs/combate.md sección 7). Suma el
## [code]amount[/code] de los HIT propios en una ventana de [constant WINDOW_TICKS] ticks (30 s) y se
## muestra en el panel de depuración (F3).
## [br][br]
## Todo se mide en ticks del servidor ([code]event.tick[/code]), no en tiempo real, así que la
## medida es determinista y se prueba con ticks inventados. El DPS es el daño de la ventana entre
## el tiempo que lleva dañando: los segundos desde que empezó la racha de golpes (la racha empieza
## con el primer golpe tras una ventana vacía), como poco 1 s para que un solo golpe no dispare la
## cifra y como mucho 30 s. Tras 30 s seguidos atacando, el DPS es exactamente el daño de la
## ventana entre 30.

## Ventana de la suma (30 s a 60 ticks por segundo).
const WINDOW_TICKS: int = 30 * 60
## Tiempo mínimo (s) por el que se divide.
const MIN_SECONDS: float = 1.0

var _ticks: PackedInt64Array = PackedInt64Array()
var _amounts: PackedInt64Array = PackedInt64Array()
var _total_damage: int = 0
var _hit_count: int = 0
# Tick del primer golpe de la racha actual (la que empezó con la ventana vacía).
var _streak_start: int = 0


## Apunta un golpe de [param amount] de daño en el tick [param tick]. Los golpes sin daño (parados)
## no cuentan. Se espera que lleguen en orden de tick; uno atrasado se coloca en su sitio.
func add_hit(tick: int, amount: int) -> void:
	if amount <= 0:
		return
	_prune(tick)
	if _ticks.is_empty():
		_streak_start = tick
	var index: int = _ticks.size()
	while index > 0 and _ticks[index - 1] > tick:
		index -= 1
	_ticks.insert(index, tick)
	_amounts.insert(index, amount)
	_total_damage += amount
	_hit_count += 1


## Daño de los golpes de los últimos [constant WINDOW_TICKS] ticks hasta [param now_tick].
func get_damage(now_tick: int) -> int:
	_prune(now_tick)
	var total: int = 0
	for amount: int in _amounts:
		total += amount
	return total


## Daño por segundo según la ventana que termina en [param now_tick] (ver la descripción de la
## clase). 0 si no hay golpes en la ventana.
func get_dps(now_tick: int) -> float:
	_prune(now_tick)
	if _ticks.is_empty():
		return 0.0
	var total: int = 0
	for amount: int in _amounts:
		total += amount
	var elapsed: float = float(now_tick - _streak_start) / float(Engine.physics_ticks_per_second)
	var window_seconds: float = float(WINDOW_TICKS) / float(Engine.physics_ticks_per_second)
	return float(total) / clampf(elapsed, MIN_SECONDS, window_seconds)


## Golpes en la ventana que termina en [param now_tick].
func get_hit_count(now_tick: int) -> int:
	_prune(now_tick)
	return _ticks.size()


## Daño total y golpes desde que se creó o se reinició el medidor (no solo los de la ventana).
func get_total_damage() -> int:
	return _total_damage


func get_total_hits() -> int:
	return _hit_count


## Borra todo.
func reset() -> void:
	_ticks.clear()
	_amounts.clear()
	_total_damage = 0
	_hit_count = 0
	_streak_start = 0


# Quita los golpes que ya salieron de la ventana.
func _prune(now_tick: int) -> void:
	var drop: int = 0
	while drop < _ticks.size() and _ticks[drop] <= now_tick - WINDOW_TICKS:
		drop += 1
	if drop > 0:
		_ticks = _ticks.slice(drop)
		_amounts = _amounts.slice(drop)
