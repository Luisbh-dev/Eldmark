class_name CombatEventQueue
extends RefCounted
## Queue of other entities' combat events, ordered by server tick (docs/combat.md, section 6).
## [br][br]
## An ENTITY_EVENT about other players is not shown on arrival, but when the render tick
## ([method InterpolationClock.get_render_tick]) reaches its [code]tick[/code]: that way the flash,
## shake or animation of a remote entity matches what is seen of it on screen (it runs about 100
## ms behind the server). [NetClient] puts here the events that are not its own and, on every physics
## tick, pops the ones that are due with [method pop_due].
## [br][br]
## Events with the same tick come out in the order they arrived. The queue has a cap
## ([constant MAX_PENDING]) so that a render clock that never starts cannot let it grow without limit;
## when full, the oldest is dropped and counted in [member dropped].

## Maximum number of events kept.
const MAX_PENDING: int = 512

## Events dropped because the queue filled up.
var dropped: int = 0

# Pending events ordered by (tick, arrival order).
var _events: Array[NetMessages.EntityEvent] = []


## Stores [param event] in its place according to its tick (after those with the same tick or less).
func push(event: NetMessages.EntityEvent) -> void:
	if event == null:
		return
	var index: int = _events.size()
	while index > 0 and _events[index - 1].tick > event.tick:
		index -= 1
	_events.insert(index, event)
	if _events.size() > MAX_PENDING:
		_events.remove_at(0)
		dropped += 1


## Pops, in order, the events whose tick is less than or equal to [param render_tick]. With a render
## tick that has not started (0 or less) none comes out.
func pop_due(render_tick: float) -> Array[NetMessages.EntityEvent]:
	var due: Array[NetMessages.EntityEvent] = []
	if render_tick <= 0.0:
		return due
	var count: int = 0
	while count < _events.size() and float(_events[count].tick) <= render_tick:
		count += 1
	if count == 0:
		return due
	due.assign(_events.slice(0, count))
	_events = _events.slice(count)
	return due


## Pending events.
func size() -> int:
	return _events.size()


## Tick of the next event, or -1 if there is none.
func peek_next_tick() -> int:
	return _events[0].tick if not _events.is_empty() else -1


## Discards all pending events.
func clear() -> void:
	_events.clear()
