class_name StatusTracker
extends RefCounted
## Active status effects of an entity as the server counts them (UI-45, docs/habilidades.md, section
## 6.4): one per entity, fed by [NetClient] with the already-timed ENTITY_EVENTs (the local player
## entity's on arrival; a remote's at its draw tick, also the player's own, so they arrive in the
## server's tick order: this tracker applies them in the order they reach it).
## [br][br]
## A STATUS 1 (applied or refreshed) stores or updates the effect with its stacks and its
## [code]until_tick[/code]; a STATUS 2 removes it. The entity's DEATH, DOWNED and RESPAWN remove them all
## (the server clears them without sending individual STATUS messages, section 4.3); the ENTITY_DESPAWN is
## handled by whoever keeps the trackers ([NetClient]), which drops that entity's.
## [br][br]
## Expiry needs no event: [method get_active] only returns those still alive at the tick passed to it (the
## estimated server tick for the local player, the draw tick for a remote) and [method prune] forgets
## those that have already ended. Client only.

## An active effect.
class Entry:
	## Id of the effect in the combat catalog ([method CombatCatalog.status]).
	var status_id: int = 0
	## Stacks (at least 1).
	var stacks: int = 1
	## Server tick at which it ends (exclusive).
	var until_tick: int = 0
	## Server tick of the last STATUS 1 (applied or refreshed).
	var applied_tick: int = 0
	## Who applied it (net_id; 0 = no source).
	var source_entity: int = 0

	## true if the effect harms whoever carries it ([method StatusTicks.is_harmful]; an unknown one counts as
	## harmful).
	func is_harmful() -> bool:
		var status: StatusTicks = CombatCatalog.status(status_id)
		return status == null or status.is_harmful()

	## Ticks it has left at [param tick] (0 if it has already ended).
	func ticks_left(tick: int) -> int:
		return maxi(until_tick - tick, 0)


var _entries: Array[Entry] = []
var _events: int = 0


## Handles an ENTITY_EVENT of this entity: STATUS (apply, refresh or remove) and DEATH, DOWNED and
## RESPAWN (remove all). The others change nothing. Returns true if something changed.
func handle_event(event: NetMessages.EntityEvent) -> bool:
	if event == null:
		return false
	match event.event:
		NetMessages.EntityEvent.Kind.STATUS:
			_events += 1
			if event.op == NetMessages.EntityEvent.StatusOp.APPLIED:
				apply(event.status_id, event.stacks, event.until_tick, event.tick, event.source_entity)
				return true
			if event.op == NetMessages.EntityEvent.StatusOp.REMOVED:
				return remove(event.status_id)
		NetMessages.EntityEvent.Kind.DEATH, NetMessages.EntityEvent.Kind.DOWNED, \
				NetMessages.EntityEvent.Kind.RESPAWN:
			if _entries.is_empty():
				return false
			clear()
			return true
	return false


## Stores (or updates, if already present) effect [param status_id] with [param stacks] stacks until
## [param until_tick] (exclusive). Keeps the order in which each effect first arrived.
func apply(status_id: int, stacks: int, until_tick: int, applied_tick: int = 0,
		source_entity: int = 0) -> void:
	var entry: Entry = _find(status_id)
	if entry == null:
		entry = Entry.new()
		entry.status_id = status_id
		_entries.append(entry)
	entry.stacks = maxi(stacks, 1)
	entry.until_tick = until_tick
	entry.applied_tick = applied_tick
	entry.source_entity = source_entity


## Removes effect [param status_id]. Returns true if it was there.
func remove(status_id: int) -> bool:
	for index: int in _entries.size():
		if _entries[index].status_id == status_id:
			_entries.remove_at(index)
			return true
	return false


## Removes all of them.
func clear() -> void:
	_entries.clear()


## Forgets the effects that have already ended at [param tick]. Returns how many it removed.
func prune(tick: int) -> int:
	var kept: Array[Entry] = []
	for entry: Entry in _entries:
		if entry.until_tick > tick:
			kept.append(entry)
	var removed: int = _entries.size() - kept.size()
	_entries = kept
	return removed


## The effects alive at [param tick] ([code]until_tick > tick[/code]), in the order they arrived or,
## with [param harmful_first], the harmful ones first (and within each group, the one ending soonest).
func get_active(tick: int, harmful_first: bool = false) -> Array[Entry]:
	var active: Array[Entry] = []
	for entry: Entry in _entries:
		if entry.until_tick > tick:
			active.append(entry)
	if harmful_first:
		active.sort_custom(func(a: Entry, b: Entry) -> bool:
			var a_harmful: bool = a.is_harmful()
			if a_harmful != b.is_harmful():
				return a_harmful
			return a.until_tick < b.until_tick)
	return active


## Effect [param status_id] if known (even if it has already expired), or null.
func get_entry(status_id: int) -> Entry:
	return _find(status_id)


## Stored effects (also already expired ones that have not been pruned).
func size() -> int:
	return _entries.size()


## STATUS messages received since it was created.
func get_event_count() -> int:
	return _events


func _find(status_id: int) -> Entry:
	for entry: Entry in _entries:
		if entry.status_id == status_id:
			return entry
	return null
