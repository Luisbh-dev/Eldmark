class_name DpsMeter
extends RefCounted
## Damage-per-second meter for the local player (CMB-11, docs/combat.md section 7). Sums the
## [code]amount[/code] of their own HITs over a window of [constant WINDOW_TICKS] ticks (30 s) and is
## shown in the debug panel (F3).
## [br][br]
## Everything is measured in server ticks ([code]event.tick[/code]), not real time, so the
## measurement is deterministic and can be tested with made-up ticks. DPS is the window's damage divided by
## the time spent dealing damage: the seconds since the streak of hits started (the streak starts
## with the first hit after an empty window), at least 1 s so that a single hit does not spike the
## figure and at most 30 s. After 30 s of continuous attacking, DPS is exactly the window's
## damage divided by 30.

## Sum window (30 s at 60 ticks per second).
const WINDOW_TICKS: int = 30 * 60
## Minimum time (s) divided by.
const MIN_SECONDS: float = 1.0

var _ticks: PackedInt64Array = PackedInt64Array()
var _amounts: PackedInt64Array = PackedInt64Array()
var _total_damage: int = 0
var _hit_count: int = 0
# Tick of the first hit of the current streak (the one that started with an empty window).
var _streak_start: int = 0


## Records a hit of [param amount] damage at tick [param tick]. Hits with no damage (parried)
## do not count. They are expected to arrive in tick order; a late one is placed in its spot.
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


## Damage of the hits in the last [constant WINDOW_TICKS] ticks up to [param now_tick].
func get_damage(now_tick: int) -> int:
	_prune(now_tick)
	var total: int = 0
	for amount: int in _amounts:
		total += amount
	return total


## Damage per second according to the window ending at [param now_tick] (see the class
## description). 0 if there are no hits in the window.
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


## Hits in the window ending at [param now_tick].
func get_hit_count(now_tick: int) -> int:
	_prune(now_tick)
	return _ticks.size()


## Total damage and hits since the meter was created or reset (not only those in the window).
func get_total_damage() -> int:
	return _total_damage


func get_total_hits() -> int:
	return _hit_count


## Clears everything.
func reset() -> void:
	_ticks.clear()
	_amounts.clear()
	_total_damage = 0
	_hit_count = 0
	_streak_start = 0


# Removes the hits that have already left the window.
func _prune(now_tick: int) -> void:
	var drop: int = 0
	while drop < _ticks.size() and _ticks[drop] <= now_tick - WINDOW_TICKS:
		drop += 1
	if drop > 0:
		_ticks = _ticks.slice(drop)
		_amounts = _amounts.slice(drop)
