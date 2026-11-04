class_name NetEntityRegistry
extends RefCounted
## Registry of the zone's network entities (docs/red.md, section 9.1).
## [br][br]
## It assigns ids from 1 to 65535 (0 means "none") walking the range in a circle, so an
## id takes a while to come out again even without quarantine. A released id also stays in
## quarantine for [constant ID_QUARANTINE_TICKS] ticks (10 s): the snapshot and reliable
## message channels are not ordered relative to each other, and a straggling record of the old entity cannot
## be attributed to the new one.
## [br][br]
## [method get_sorted] gives the entities by ascending [code]net_id[/code]: that is the server's fixed
## simulation order.
## [br][br]
## [b]Transient ids[/b] (docs/habilidades.md, section 4.4): projectiles take their id from the same space
## with [method allocate_transient_id], without entering the entity list (they have no [NetEntity] and are not in
## the snapshot), and return it with [method release_transient_id] to the same quarantine: a straggling
## DESPAWN of an arrow is never attributed to the entity that later receives its id, nor the other way around.

## Ticks a released id cannot be reused (10 s at 60 Hz).
const ID_QUARANTINE_TICKS: int = 600
## First and last id that are assigned.
const FIRST_ID: int = 1
const LAST_ID: int = 65535

var _entities: Dictionary[int, NetEntity] = {}
# Transient ids in use (projectiles).
var _transient: Dictionary[int, bool] = {}
# net_id -> tick at which it was released.
var _quarantine: Dictionary[int, int] = {}
# Release order (ticks never decrease), to pop the ids that have served their time.
var _quarantine_order: PackedInt32Array = PackedInt32Array()
var _quarantine_head: int = 0
var _next_id: int = FIRST_ID
var _sorted: Array[NetEntity] = []
var _sorted_dirty: bool = false


## Creates an entity of type [param kind] (an [enum NetProtocol.EntityKind]) added at
## tick [param now_tick] and assigns it a free id. null if none remain (all 65535 are in
## use or in quarantine).
func allocate(kind: int, now_tick: int) -> NetEntity:
	_release_expired(now_tick)
	var span: int = LAST_ID - FIRST_ID + 1
	var candidate: int = _next_id
	for _i: int in span:
		if _is_free(candidate):
			var entity := NetEntity.new()
			entity.net_id = candidate
			entity.kind = kind
			entity.spawn_tick = now_tick
			_entities[candidate] = entity
			_next_id = candidate + 1 if candidate < LAST_ID else FIRST_ID
			_sorted_dirty = true
			return entity
		candidate = candidate + 1 if candidate < LAST_ID else FIRST_ID
	return null


## Reserves an id from the entity space at tick [param now_tick] without creating any entity (a
## projectile's), with the same circular search and the same quarantine as [method allocate]. 0 if none
## remain.
func allocate_transient_id(now_tick: int) -> int:
	_release_expired(now_tick)
	var span: int = LAST_ID - FIRST_ID + 1
	var candidate: int = _next_id
	for _i: int in span:
		if _is_free(candidate):
			_transient[candidate] = true
			_next_id = candidate + 1 if candidate < LAST_ID else FIRST_ID
			return candidate
		candidate = candidate + 1 if candidate < LAST_ID else FIRST_ID
	return 0


## Returns the transient id [param net_id] at tick [param now_tick] and puts it in quarantine. Does
## nothing if it is not a transient id in use.
func release_transient_id(net_id: int, now_tick: int) -> void:
	if not _transient.erase(net_id):
		return
	_quarantine[net_id] = now_tick
	_quarantine_order.append(net_id)


## true if [param net_id] is a transient id in use.
func is_transient(net_id: int) -> bool:
	return _transient.has(net_id)


## Transient ids in use.
func transient_count() -> int:
	return _transient.size()


## Removes entity [param net_id] from the registry at tick [param now_tick] and puts its id in
## quarantine. Does nothing if the id is not in use.
func release(net_id: int, now_tick: int) -> void:
	if not _entities.erase(net_id):
		return
	_quarantine[net_id] = now_tick
	_quarantine_order.append(net_id)
	_sorted_dirty = true


## The entity with that id, or null.
func get_entity(net_id: int) -> NetEntity:
	return _entities.get(net_id)


## All entities by ascending [code]net_id[/code]. The array is a cache that is
## rebuilt after each addition and removal: the caller must not modify it, and must know that it is
## replaced by another array (not changed in place) when the registry changes.
func get_sorted() -> Array[NetEntity]:
	if _sorted_dirty:
		var ids: Array[int] = []
		ids.assign(_entities.keys())
		ids.sort()
		var rebuilt: Array[NetEntity] = []
		rebuilt.resize(ids.size())
		for i: int in ids.size():
			rebuilt[i] = _entities[ids[i]]
		_sorted = rebuilt
		_sorted_dirty = false
	return _sorted


## Number of entities in the registry.
func size() -> int:
	return _entities.size()


## true if [param net_id] is in quarantine (released fewer than
## [constant ID_QUARANTINE_TICKS] ticks ago) at tick [param now_tick].
func is_quarantined(net_id: int, now_tick: int) -> bool:
	return _quarantine.has(net_id) and now_tick - _quarantine[net_id] < ID_QUARANTINE_TICKS


# true if nobody uses [param net_id]: not an entity, nor a projectile, nor the quarantine.
func _is_free(net_id: int) -> bool:
	return not _entities.has(net_id) and not _transient.has(net_id) and not _quarantine.has(net_id)


# Takes out of quarantine the ids that have been released for ID_QUARANTINE_TICKS ticks or more.
func _release_expired(now_tick: int) -> void:
	while _quarantine_head < _quarantine_order.size():
		var net_id: int = _quarantine_order[_quarantine_head]
		if now_tick - _quarantine[net_id] < ID_QUARANTINE_TICKS:
			break
		_quarantine.erase(net_id)
		_quarantine_head += 1
	# Compacts the queue once most of it has been used.
	if _quarantine_head > 1024 and _quarantine_head * 2 > _quarantine_order.size():
		_quarantine_order = _quarantine_order.slice(_quarantine_head)
		_quarantine_head = 0
