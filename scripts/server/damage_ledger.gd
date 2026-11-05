class_name DamageLedger
extends RefCounted
## Log of the damage a victim has received (docs/combat.md, section 5; GUE-05): who did it
## how much and when, during the last [constant WINDOW_TICKS] ticks (15 s).
## [br][br]
## With it, on death, the server splits the credit: the killing blow goes to whoever dealt the lethal
## hit (or, if it died to the environment, to the last enemy that hit it) and assists go
## to those who did at least [constant ASSIST_PERCENT] % of the window's damage.
## [br][br]
## Only damage that reaches health and from a specific attacker is recorded: the environment (id 0) and
## self-harm do not count. Allies never appear because there is no friendly fire
## ([FactionRules]).

## Log window (15 s at 60 Hz).
const WINDOW_TICKS: int = 900
## Minimum percentage of the window's damage to count as an assist.
const ASSIST_PERCENT: int = 10
## Maximum assistants returned (with a 10 % minimum there are never more than 10).
const MAX_ASSISTANTS: int = 10

# One entry per hit, in chronological order. Ticks are 64-bit (they are u32 on the server).
var _ticks: PackedInt64Array = PackedInt64Array()
var _attackers: PackedInt32Array = PackedInt32Array()
var _amounts: PackedInt32Array = PackedInt32Array()
# First valid entry; anything earlier is discarded when compacting.
var _head: int = 0
# net_id of the victim: its own hits do not count.
var _victim_id: int = 0


func _init(victim_id: int = 0) -> void:
	_victim_id = victim_id


## Records [param amount] of damage from [param attacker_id] at tick [param tick]. Does nothing with
## a non-positive amount, with the environment (id 0) or with self-harm.
func record(tick: int, attacker_id: int, amount: int) -> void:
	if amount <= 0 or attacker_id <= 0 or attacker_id == _victim_id:
		return
	_ticks.append(tick)
	_attackers.append(attacker_id)
	_amounts.append(amount)
	_prune(tick)


## Total damage in the window ending at [param tick].
func total_damage(tick: int) -> int:
	var total: int = 0
	for i: int in range(_first_valid(tick), _ticks.size()):
		total += _amounts[i]
	return total


## Damage that [param attacker_id] did in the window ending at [param tick].
func damage_by(attacker_id: int, tick: int) -> int:
	var total: int = 0
	for i: int in range(_first_valid(tick), _ticks.size()):
		if _attackers[i] == attacker_id:
			total += _amounts[i]
	return total


## Assistants of the death at [param tick]: those who (except [param killer_id]) did at least
## [constant ASSIST_PERCENT] % of the window's total damage, sorted by descending damage and, with
## equal damage, by id.
func get_assistants(killer_id: int, tick: int) -> PackedInt32Array:
	var by_attacker: Dictionary[int, int] = {}
	var total: int = 0
	for i: int in range(_first_valid(tick), _ticks.size()):
		by_attacker[_attackers[i]] = by_attacker.get(_attackers[i], 0) + _amounts[i]
		total += _amounts[i]
	var assistants: Array[Dictionary] = []
	for attacker_id: int in by_attacker:
		var damage: int = by_attacker[attacker_id]
		if attacker_id != killer_id and damage * 100 >= total * ASSIST_PERCENT:
			assistants.append({"id": attacker_id, "damage": damage})
	assistants.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["damage"] != b["damage"]:
			return a["damage"] > b["damage"]
		return a["id"] < b["id"])
	var result := PackedInt32Array()
	for entry: Dictionary in assistants:
		if result.size() >= MAX_ASSISTANTS:
			break
		result.append(entry["id"])
	return result


## Contributors to the death at [param tick] (docs/progression.md §0 and §6.2): those who did at least
## [constant ASSIST_PERCENT] % of the window's total damage, the killing blow's author included if they qualify, by ascending
## id. They are the ones who collect an NPC's reward (each one, in full). With a 10 % minimum there are never more than 10.
func contributors(tick: int) -> PackedInt32Array:
	var by_attacker: Dictionary[int, int] = {}
	var total: int = 0
	for i: int in range(_first_valid(tick), _ticks.size()):
		by_attacker[_attackers[i]] = by_attacker.get(_attackers[i], 0) + _amounts[i]
		total += _amounts[i]
	var result := PackedInt32Array()
	for attacker_id: int in by_attacker:
		if by_attacker[attacker_id] * 100 >= total * ASSIST_PERCENT:
			result.append(attacker_id)
	result.sort()
	return result


## Last attacker that damaged it (id), or 0 if there is none in the window.
func last_attacker(tick: int) -> int:
	if _ticks.size() > _first_valid(tick):
		return _attackers[_ticks.size() - 1]
	return 0


## Number of hits recorded in the window ending at [param tick].
func entry_count(tick: int) -> int:
	return _ticks.size() - _first_valid(tick)


## Erases everything recorded from [param attacker_id] (it has left the server: its id may be reused).
func forget_attacker(attacker_id: int) -> void:
	var kept_ticks := PackedInt64Array()
	var kept_attackers := PackedInt32Array()
	var kept_amounts := PackedInt32Array()
	for i: int in range(_head, _ticks.size()):
		if _attackers[i] != attacker_id:
			kept_ticks.append(_ticks[i])
			kept_attackers.append(_attackers[i])
			kept_amounts.append(_amounts[i])
	_ticks = kept_ticks
	_attackers = kept_attackers
	_amounts = kept_amounts
	_head = 0


## Empties the log (on respawning).
func clear() -> void:
	_ticks.clear()
	_attackers.clear()
	_amounts.clear()
	_head = 0


# Index of the first entry within the window ending at [param tick].
func _first_valid(tick: int) -> int:
	var index: int = _head
	while index < _ticks.size() and tick - _ticks[index] >= WINDOW_TICKS:
		index += 1
	return index


# Discards what has left the window and compacts the arrays when what was discarded is half.
func _prune(tick: int) -> void:
	_head = _first_valid(tick)
	if _head > 32 and _head * 2 > _ticks.size():
		_ticks = _ticks.slice(_head)
		_attackers = _attackers.slice(_head)
		_amounts = _amounts.slice(_head)
		_head = 0
