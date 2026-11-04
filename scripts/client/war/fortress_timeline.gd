class_name FortressTimeline
extends RefCounted
## History of changes of a fortress as the client knows it (docs/fortress.md, sections 2 and 3.2). Pure, no
## nodes: [FortressView] keeps one per fortress.
## [br][br]
## Each OBJECT_STATE (and the structure's ENTITY_SPAWN, which carries all the fields) is recorded with its
## [code]tick[/code]: the server tick [b]after[/b] which the state holds. Two different questions come out
## of this:
## [br]- [method state_at]: the state valid after tick [code]t[/code] (the last change with
## [code]tick ≤ t[/code]). The interface and the banners request it with the draw tick, so they apply
## when [code]render_tick[/code] reaches that of the message, not on arrival.
## [br]- [method gate_layers_for_tick]: the gate's layers for [i]simulating[/i] tick [code]t[/code]. A change
## with [code]tick = s[/code] holds from [code]s + 1[/code] (the server applies it in step 4b of tick
## [code]s[/code]), so the state after [code]t - 1[/code] is looked at. Prediction asks for it on every
## simulated tick, also in replays, so client and server simulate each tick with the same gate.
## [br][br]
## [b]What is stored.[/b] Per change, the fields it brought and the accumulated state after applying them
## (a [FortressState] rebuilt with [method FortressState.initial] and the [FortressFields] fields; what
## does not travel comes from the definition). If a message arrives out of order (reliable channel, it
## should not) it is inserted in its place and the following ones are recomputed. The history is pruned by
## age ([constant RETAIN_TICKS] relative to the newest change) and by count ([constant MAX_ENTRIES]); the
## oldest remaining entry serves as the base, and a message older than it is ignored.
## [br][br]
## The state returned by [method state_at] is the stored one: it must not be modified.
## [br][br]
## Client only, but with no dependencies on interface nodes.

## Changes remembered at most.
const MAX_ENTRIES: int = 512
## Age in ticks (relative to the newest change) from which it is pruned: 30 s, more than enough for the
## reconciliation replays (256-tick rings).
const RETAIN_TICKS: int = 1800


## A change: the tick, the fields it brought and the accumulated state after applying them.
class Entry extends RefCounted:
	var tick: int = 0
	var fields: Array[NetMessages.ObjectField] = []
	var state: FortressState = null


var _definition: FortressDefinition = null
var _initial: FortressState = null
var _entries: Array[Entry] = []
var _version: int = 0
var _applied_total: int = 0
var _pruned: bool = false


func _init(definition: FortressDefinition) -> void:
	_definition = definition
	_initial = FortressState.initial(definition, 0)


## Definition with which the states are rebuilt.
func get_definition() -> FortressDefinition:
	return _definition


## true if any state has already arrived (the structure's SPAWN or an OBJECT_STATE).
func has_state() -> bool:
	return not _entries.is_empty()


## Stored changes.
func get_entry_count() -> int:
	return _entries.size()


## Counter that rises with each recorded change: used to know whether there is anything new without comparing states.
func get_version() -> int:
	return _version


## Known fields applied since it was created (those skipped because of unknown type or id do not count).
func get_applied_fields() -> int:
	return _applied_total


## Tick of the newest change (-1 if there is none).
func get_latest_tick() -> int:
	return _entries[_entries.size() - 1].tick if not _entries.is_empty() else -1


## Tick of the oldest change that is kept (-1 if there is none).
func get_oldest_tick() -> int:
	return _entries[0].tick if not _entries.is_empty() else -1


## Records the OBJECT_STATE [param object_state] (or the SPAWN converted with
## [method NetMessages.EntitySpawn.to_object_state]). Returns how many known fields it applied; 0 if it
## carries none and nothing is recorded.
func apply_object_state(object_state: NetMessages.ObjectState) -> int:
	if object_state == null:
		return 0
	return apply_fields(object_state.tick, object_state.fields)


## Records the fields [param fields] as a change at tick [param tick]. Unknown ids and fields with a value
## type other than their own are skipped (forward compatibility). Returns how many fields it applied; with
## 0 nothing is recorded.
func apply_fields(tick: int, fields: Array[NetMessages.ObjectField]) -> int:
	var index: int = _insert_index(tick)
	if _pruned and index == 0:
		# Earlier than the base that remains after pruning: it can no longer be rebuilt in place.
		return 0
	var state: FortressState = _state_before(index).duplicate_state()
	var applied: int = _apply_to(state, fields)
	if applied == 0:
		return 0
	var entry := Entry.new()
	entry.tick = tick
	entry.fields = fields.duplicate()
	entry.state = state
	_entries.insert(index, entry)
	_applied_total += applied
	_version += 1
	if index < _entries.size() - 1:
		_rebuild_from(index + 1)
	_prune()
	return applied


## State valid after tick [param tick]: that of the last change with [code]tick ≤ tick[/code]. Before the
## first known change it returns that first one (the SPAWN carries the full state and it is the best that
## is known); with no change at all, the definition's initial state (neutral, intact). It must not be
## modified.
func state_at(tick: int) -> FortressState:
	if _entries.is_empty():
		return _initial
	return _entries[maxi(_floor_index(tick), 0)].state


## Tick of the change that [method state_at] gives for [param tick] (-1 if there is none yet).
func change_tick_at(tick: int) -> int:
	if _entries.is_empty():
		return -1
	return _entries[maxi(_floor_index(tick), 0)].tick


## Movement collision layers of the gate for [i]simulating[/i] tick [param tick] (see the class
## description): [method FortGate.layers_for] with the owner and the breakage of the state after
## [code]tick - 1[/code].
func gate_layers_for_tick(tick: int) -> int:
	var state: FortressState = state_at(tick - 1)
	return FortGate.layers_for(state.owner, state.is_gate_broken())


## Capture progress (0 to [member FortressState.progress_max]) at draw instant [param render_time] (ticks
## with fraction): the formula [code]clamp(p0 + rate · (t − t0), 0, P)[/code] of the state in force at
## that instant.
func progress_at(render_time: float) -> int:
	return state_at(floori(render_time)).progress_at(render_time)


## Progress from 0 to 1 at [param render_time].
func progress_fraction_at(render_time: float) -> float:
	var state: FortressState = state_at(floori(render_time))
	if state.progress_max <= 0:
		return 0.0
	return clampf(float(state.progress_at(render_time)) / float(state.progress_max), 0.0, 1.0)


# --- Internal ---------------------------------------------------------------------------------

# First position whose tick is greater than [param tick]: where a new change goes (after those with the
# same tick, which are applied first).
func _insert_index(tick: int) -> int:
	var low: int = 0
	var high: int = _entries.size()
	while low < high:
		var middle: int = (low + high) >> 1
		if _entries[middle].tick <= tick:
			low = middle + 1
		else:
			high = middle
	return low


# Position of the last change with tick ≤ [param tick], or -1 if all are later.
func _floor_index(tick: int) -> int:
	return _insert_index(tick) - 1


# Accumulated state right before position [param index] (the initial one if it is the first).
func _state_before(index: int) -> FortressState:
	return _entries[index - 1].state if index > 0 else _initial


func _apply_to(state: FortressState, fields: Array[NetMessages.ObjectField]) -> int:
	var applied: int = 0
	for field: NetMessages.ObjectField in fields:
		if FortressFields.is_known(field.field_id) \
				and FortressFields.value_type(field.field_id) == field.value_type \
				and FortressFields.set_value(state, field.field_id, field.value):
			applied += 1
	return applied


# Recomputes the accumulated states from position [param first] (after inserting one in the middle).
func _rebuild_from(first: int) -> void:
	for index: int in range(first, _entries.size()):
		var state: FortressState = _state_before(index).duplicate_state()
		_apply_to(state, _entries[index].fields)
		_entries[index].state = state


# Removes the very old, always leaving a base entry.
func _prune() -> void:
	var newest: int = _entries[_entries.size() - 1].tick
	while _entries.size() > 1 and (_entries.size() > MAX_ENTRIES
			or _entries[1].tick < newest - RETAIN_TICKS):
		_entries.remove_at(0)
		_pruned = true
