class_name VfxPool
extends Node3D
## Reuse pool of a [VfxEffect] (ART-09, client only): creates [member size] copies of [member scene] once
## and relaunches them. [method spawn] instantiates nothing: it takes a free copy and places it at the
## contact point; if all are playing, it restarts the oldest instead of growing.
## [br][br]
## One pool per scene (metal spark, dust...) and sized enough for the hits that fit in one instant of
## combat: 6 to 8 for impacts, 2 to 3 for parries.

## Effect scene: the root must be a [VfxEffect].
@export var scene: PackedScene
## Copies that are created.
@export_range(1, 64) var size: int = 6

var _items: Array[VfxEffect] = []
var _cursor: int = 0
# Tint requested with [method set_tint]; without it, each copy keeps its scene's (flesh is red).
var _tint: Color = Color.WHITE
var _has_tint: bool = false


func _ready() -> void:
	if scene != null and _items.is_empty():
		_fill()


## Creates the copies now (if the pool is assembled in code before entering the tree).
func setup(effect_scene: PackedScene, copies: int) -> void:
	scene = effect_scene
	size = maxi(copies, 1)
	if _items.is_empty():
		_fill()


## Launches a free copy at [param position] with its +Z axis along [param normal] and, if given, +X along
## [param direction] (where the blow was heading; see [method VfxEffect.play_at]) and returns it. Returns
## null if the pool has no scene.
func spawn(position: Vector3, normal: Vector3 = Vector3.UP, direction: Vector3 = Vector3.ZERO) -> VfxEffect:
	var effect: VfxEffect = acquire()
	if effect == null:
		return null
	effect.play_at(position, normal, direction)
	return effect


## Takes a free copy WITHOUT launching it (the oldest if all are playing), for effects with their own way of
## being launched, like [method DustKick.play_dodge].
func acquire() -> VfxEffect:
	if _items.is_empty():
		if scene == null:
			return null
		_fill()
		if _items.is_empty():
			return null
	for offset: int in _items.size():
		var index: int = (_cursor + offset) % _items.size()
		if not _items[index].is_playing():
			_cursor = index + 1
			return _items[index]
	# All are playing: the one that has been running longest is restarted (the next in the ring).
	var oldest: VfxEffect = _items[_cursor % _items.size()]
	_cursor += 1
	oldest.reset()
	return oldest


## Tints all the copies, also those created later (the following shots come out in that color).
func set_tint(value: Color) -> void:
	_tint = value
	_has_tint = true
	for item: VfxEffect in _items:
		item.tint = value


## How many copies are playing right now.
func get_active_count() -> int:
	var active: int = 0
	for item: VfxEffect in _items:
		if item.is_playing():
			active += 1
	return active


## Turns off all the copies at once.
func release_all() -> void:
	for item: VfxEffect in _items:
		item.reset()


func get_items() -> Array[VfxEffect]:
	return _items


func _fill() -> void:
	for index: int in size:
		var item: VfxEffect = scene.instantiate() as VfxEffect
		if item == null:
			push_error("[VfxPool] La escena %s no tiene un VfxEffect en la raíz" % scene.resource_path)
			return
		if _has_tint:
			item.tint = _tint
		add_child(item)
		_items.append(item)
