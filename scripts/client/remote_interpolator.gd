class_name RemoteInterpolator
extends RefCounted
## Interpolation of a remote player (docs/networking.md, section 7).
##
## Keeps the last [constant BUFFER_SIZE] samples [code](tick, EntityRecord)[/code] ordered by tick,
## without duplicates or samples older than the window, and [method sample] returns the record to draw
## at a given instant (in ticks, with fraction):
## [br]- [b]Between two samples[/b] with the same teleport counter: [code]lerp[/code] of position and
## velocity, [code]lerp_angle[/code] of the yaw (correct when crossing ±PI) and the flags (grounded)
## from the nearest sample.
## [br]- [b]If the teleport counter changes[/b] between the two, there is no interpolation: it stays on
## the first until the instant reaches the second.
## [br]- [b]Behind the first sample[/b] it stays on it.
## [br]- [b]Ahead of the last one[/b] it extrapolates horizontally with its velocity up to
## [constant MAX_EXTRAPOLATION_TICKS] ticks (100 ms) and then stands still: extrapolating further
## would mislead aiming.
## [br][br]
## The records that are stored are neither modified nor copied: whoever pushes them must not touch them
## afterwards. [method sample] always returns a new record.

## Samples that are kept.
const BUFFER_SIZE: int = 32
## Maximum ticks to extrapolate ahead of the last sample.
const MAX_EXTRAPOLATION_TICKS: int = 6

var _ticks: PackedInt64Array = PackedInt64Array()
var _records: Array[EntityRecord] = []


## Stores the sample for [param tick]. Duplicates are discarded (the first wins) and so are those older
## than the window when the buffer is full. Samples that arrive out of order are inserted in their
## place.
func push(tick: int, record: EntityRecord) -> void:
	if record == null:
		return
	var index: int = _ticks.size()
	while index > 0 and _ticks[index - 1] > tick:
		index -= 1
	if index > 0 and _ticks[index - 1] == tick:
		return
	if _ticks.size() >= BUFFER_SIZE:
		if index == 0:
			return
		_ticks.remove_at(0)
		_records.remove_at(0)
		index -= 1
	_ticks.insert(index, tick)
	_records.insert(index, record)


## Record to draw at instant [param render_time] (ticks with fraction), or null if there are no
## samples.
func sample(render_time: float) -> EntityRecord:
	var count: int = _ticks.size()
	if count == 0:
		return null
	if render_time <= float(_ticks[0]):
		return _copy(_records[0])
	var last: int = count - 1
	if render_time >= float(_ticks[last]):
		return _extrapolate(_records[last], render_time - float(_ticks[last]))

	# Last sample with tick <= render_time; there is a next one because render_time < the last.
	var a: int = last - 1
	while a > 0 and float(_ticks[a]) > render_time:
		a -= 1
	var from: EntityRecord = _records[a]
	var to: EntityRecord = _records[a + 1]
	if from.get_teleport_counter() != to.get_teleport_counter():
		return _copy(from)
	var span: float = float(_ticks[a + 1] - _ticks[a])
	var weight: float = clampf((render_time - float(_ticks[a])) / span, 0.0, 1.0)
	return EntityRecord.interpolate(from, to, weight)


## Tick of the newest sample, or 0 if there is none.
func get_newest_tick() -> int:
	if _ticks.is_empty():
		return 0
	return _ticks[_ticks.size() - 1]


## Tick of the oldest sample, or 0 if there is none.
func get_oldest_tick() -> int:
	if _ticks.is_empty():
		return 0
	return _ticks[0]


## Number of stored samples.
func get_sample_count() -> int:
	return _ticks.size()


## Position of each stored sample, as it arrived (not interpolated), from oldest to newest. Network
## debugging uses it to mark the samples.
func get_sample_positions() -> PackedVector3Array:
	var positions := PackedVector3Array()
	positions.resize(_records.size())
	for i: int in _records.size():
		positions[i] = _records[i].position
	return positions


## Discards all the samples.
func clear() -> void:
	_ticks.clear()
	_records.clear()


# Extrapolates horizontally with the last sample's velocity up to MAX_EXTRAPOLATION_TICKS; after that
# time it stands still.
func _extrapolate(newest: EntityRecord, ticks_ahead: float) -> EntityRecord:
	var record: EntityRecord = _copy(newest)
	if ticks_ahead <= 0.0:
		return record
	var seconds: float = minf(ticks_ahead, float(MAX_EXTRAPOLATION_TICKS)) \
			/ float(Engine.physics_ticks_per_second)
	record.position += Vector3(newest.velocity.x, 0.0, newest.velocity.z) * seconds
	if ticks_ahead > float(MAX_EXTRAPOLATION_TICKS):
		record.velocity = Vector3.ZERO
	return record


static func _copy(source: EntityRecord) -> EntityRecord:
	var record := EntityRecord.new()
	record.net_id = source.net_id
	record.kind = source.kind
	record.position = source.position
	record.yaw = source.yaw
	record.velocity = source.velocity
	record.flags = source.flags
	record.action = source.action
	record.health_q = source.health_q
	return record
