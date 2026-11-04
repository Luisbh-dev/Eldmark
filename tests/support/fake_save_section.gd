class_name FakeSaveSection
extends RefCounted
## A test save section for [CharacterSaver] (docs/platform.md §15 P5: "tested with a fake
## section"). It builds the six [code]pvp[/code] totals of each body, so [FakeZonePlatform] returns it on
## the next claim as the last thing applied. It is dirty from when it changes until the
## [code]seq[/code] that carried the change is confirmed; it records every [CharacterSaver] call (with the tick of
## [member tick_source]) so tests can see when and for whom it is built, confirmed or queried.

## Name of the section (the body's key).
var name: StringName = &"pvp"
## If valid, [code]() -> int[/code]: the tick recorded in each call.
var tick_source: Callable = Callable()
## net_id -> true: [method build] returns [code]{}[/code] (it cannot be built right now).
var unbuildable: Dictionary[int, bool] = {}
## Calls to [method build]: [code][net_id, seq, tick, built][/code].
var builds: Array[Array] = []
## Calls to [method acknowledge]: [code][net_id, seq][/code].
var acknowledged: Array[Array] = []
## net_id of each call to [method is_dirty].
var dirty_checks: Array[int] = []

var _kills: Dictionary[int, int] = {}
var _version: Dictionary[int, int] = {}
var _confirmed: Dictionary[int, int] = {}
var _built: Dictionary[String, int] = {}


## Registers the section in [param saver].
func attach(saver: CharacterSaver) -> void:
	saver.register_section(name, build, acknowledge, is_dirty)


## Changes the totals of [param net_id] (the kills): it becomes dirty.
func set_kills(net_id: int, kills: int) -> void:
	_kills[net_id] = kills
	_version[net_id] = _version.get(net_id, 0) + 1


## The totals it would build now for [param net_id].
func totals(net_id: int) -> Dictionary:
	return {"kills": _kills.get(net_id, 0), "deaths": 0, "assists": 0, "captures": 0, "gate_damage": 0,
			"defend_s": 0}


func build(net_id: int, seq: int) -> Dictionary:
	if unbuildable.get(net_id, false):
		builds.append([net_id, seq, _tick(), false])
		return {}
	builds.append([net_id, seq, _tick(), true])
	_built["%d:%d" % [net_id, seq]] = _version.get(net_id, 0)
	return totals(net_id)


func acknowledge(net_id: int, seq: int) -> void:
	acknowledged.append([net_id, seq])
	_confirmed[net_id] = maxi(_confirmed.get(net_id, 0), _built.get("%d:%d" % [net_id, seq], 0))


func is_dirty(net_id: int) -> bool:
	dirty_checks.append(net_id)
	return _version.get(net_id, 0) > _confirmed.get(net_id, 0)


## The ticks at which a body was (successfully) built for [param net_id].
func build_ticks(net_id: int) -> Array[int]:
	var ticks: Array[int] = []
	for call: Array in builds:
		if int(call[0]) == net_id and bool(call[3]):
			ticks.append(int(call[2]))
	return ticks


## How many calls (of any kind) it has received for [param net_id].
func calls_for(net_id: int) -> int:
	var count: int = dirty_checks.count(net_id)
	for call: Array in builds:
		if int(call[0]) == net_id:
			count += 1
	for call: Array in acknowledged:
		if int(call[0]) == net_id:
			count += 1
	return count


func _tick() -> int:
	return int(tick_source.call()) if tick_source.is_valid() else -1
