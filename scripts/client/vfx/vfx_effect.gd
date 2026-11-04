class_name VfxEffect
extends Node3D
## Reusable combat visual effect (ART-09, client only): root of the scenes in [code]scenes/vfx/[/code].
## Designed for a reuse pool ([VfxPool]): it is created once and relaunched with [method play] or
## [method play_at] without instantiating anything.
## [br][br]
## An effect is a node with children of two kinds: [GPUParticles3D] (one-shot, or continuous if the effect
## is [member looping]) and shader meshes animated by the instance parameter [code]progress[/code]
## ([code]MeshInstance3D[/code] with a [QuadMesh], for example). Since progress and tint are
## [b]instance[/b] parameters, all copies of an effect share the same materials and can be recolored
## without duplicating them.
## [br][br]
## [b]Children's metadata[/b] (in the .tscn, [code]metadata/...[/code]):
## [br]- [code]vfx_time[/code] ([Vector2]): delay and duration in seconds. On a mesh it is how long its
## [code]progress[/code] lasts from 0 to 1 (hidden outside that interval); on particles, when they fire.
## [br]- [code]vfx_cue[/code] ([StringName]): the cue that triggers it. By default [constant CUE_START],
## which starts with [method play]; the others are fired with [method trigger] (the aura's charge pulse,
## for example).
## [br]- [code]vfx_tint[/code] ([Color]) and [code]vfx_tint_weight[/code] (0 to 1): base color of the
## child's instance tint and how much [member tint] affects it (0 = not at all: a white flash stays white).
## [br]- [code]vfx_no_tint[/code] ([bool]): the child does not carry the [code]tint[/code] parameter (a heat
## distortion has no color): the effect does not set it.
## [br]- [code]vfx_variants[/code] ([int]) and [code]vfx_variant_offset[/code] ([int]): the mesh has an
## atlas of variants (rows) and the effect picks one on each shot (instance parameters [code]variant[/code]
## and [code]flip[/code]), deterministically: two consecutive shots do not repeat the same spurt.
## [br][br]
## [b]Orientation.[/b] The local +Z axis is the impact normal: where the sparks go, toward whoever struck.
## [method play_at] orients it from a world position and normal and, if given the blow's direction, leaves
## the local +X axis along it (a spurt of blood goes where the slash was heading) and, with
## [member direction_bias], tilts +Z toward it (the sparks of a slash fly off skewed in the direction of
## the edge).
## [br][br]
## It is not connected to combat yet: whoever does so ([CombatFeedback], for example) requests
## [method VfxPool.spawn] at the contact point.

## Emitted when the effect ends (the particles and shapes have finished) and it can be reused.
signal finished

## Default cue: what starts with [method play].
const CUE_START: StringName = &"start"
const META_TIME: StringName = &"vfx_time"
const META_CUE: StringName = &"vfx_cue"
const META_TINT: StringName = &"vfx_tint"
const META_TINT_WEIGHT: StringName = &"vfx_tint_weight"
const META_NO_TINT: StringName = &"vfx_no_tint"
const META_VARIANTS: StringName = &"vfx_variants"
const META_VARIANT_OFFSET: StringName = &"vfx_variant_offset"
const PARAM_PROGRESS: StringName = &"progress"
const PARAM_TINT: StringName = &"tint"
const PARAM_VARIANT: StringName = &"variant"
const PARAM_FLIP: StringName = &"flip"

## Seconds until the effect is considered finished and can be reused (for continuous ones, the time they
## take to fade out after [method stop] comes from their particles' lifetime).
@export var duration: float = 0.6
## A continuous effect does not end on its own: it goes on until [method stop] (auras, for example).
@export var looping: bool = false
## Color the children are tinted with (according to their [code]vfx_tint_weight[/code]).
@export var tint: Color = Color.WHITE:
	set = set_tint
## How much [method play_at] tilts the +Z axis toward the blow's direction (0 = none; 1 = at 45 degrees).
@export_range(0.0, 2.0, 0.05) var direction_bias: float = 0.0

# A mesh animated by progress.
class _Shape extends RefCounted:
	var node: GeometryInstance3D
	var enabled: bool = true
	var cue: StringName = CUE_START
	var delay: float = 0.0
	var length: float = 0.1
	var started: float = -1.0

# Some particles, with their cue and the delay with which they are fired.
class _Burst extends RefCounted:
	var node: GPUParticles3D
	var enabled: bool = true
	var cue: StringName = CUE_START
	var delay: float = 0.0
	var start_at: float = -1.0

var _shapes: Array[_Shape] = []
var _bursts: Array[_Burst] = []
var _tintables: Array[GeometryInstance3D] = []
var _variant_nodes: Array[GeometryInstance3D] = []
var _play_count: int = 0
var _cue_lengths: Dictionary[StringName, float] = {}
var _tail: float = 0.0
var _is_setup: bool = false
var _playing: bool = false
var _stopping: bool = false
var _elapsed: float = 0.0
var _end_time: float = 0.0
# Instant at which the last thing launched by the cues ends (so that stop() does not cut it off).
var _cue_end: float = 0.0


func _ready() -> void:
	_ensure_setup()
	reset()


## Launches the effect from the start at its current place. If it was already playing, it restarts it.
func play() -> void:
	_ensure_setup()
	_elapsed = 0.0
	_end_time = duration
	_cue_end = 0.0
	_playing = true
	_stopping = false
	visible = true
	for shape: _Shape in _shapes:
		shape.started = -1.0
		shape.node.visible = false
	_apply_variants()
	_play_count += 1
	trigger(CUE_START)
	set_process(true)


## Places the effect at [param position] with its +Z axis along [param normal] (the impact normal, in
## world space) and launches it. The tint is that of [member tint]. With [param direction] (where the blow
## was heading, in world space; projected onto the impact plane) the +X axis lies along it and, if the
## effect has [member direction_bias], +Z tilts toward it.
func play_at(position: Vector3, normal: Vector3 = Vector3.UP, direction: Vector3 = Vector3.ZERO) -> void:
	var facing: Vector3 = normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
	var tangent: Vector3 = direction - facing * direction.dot(facing)
	if tangent.length_squared() < 0.0001:
		var up: Vector3 = Vector3.UP if absf(facing.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		global_transform = Transform3D(Basis.looking_at(-facing, up), position)
		play()
		return
	tangent = tangent.normalized()
	if direction_bias > 0.0:
		facing = (facing + tangent * direction_bias).normalized()
		tangent = (tangent - facing * tangent.dot(facing)).normalized()
	global_transform = Transform3D(Basis(tangent, facing.cross(tangent), facing), position)
	play()


## Fires whatever carries the cue [param cue] (shapes and particles with that [code]vfx_cue[/code]). Only
## valid while the effect is running.
func trigger(cue: StringName) -> void:
	_ensure_setup()
	if not _playing:
		return
	for shape: _Shape in _shapes:
		if shape.cue == cue and shape.enabled:
			shape.started = _elapsed
	for burst: _Burst in _bursts:
		if burst.cue != cue or not burst.enabled:
			continue
		if burst.delay <= 0.0:
			_fire(burst)
		else:
			burst.start_at = _elapsed + burst.delay
	var cue_end: float = _elapsed + float(_cue_lengths.get(cue, 0.0))
	_cue_end = maxf(_cue_end, cue_end)
	_end_time = maxf(_end_time, cue_end)


## Turns a part of the effect on or off by its node name (a shape or some particles): a part that is off
## is not fired by its cue. It lets a multi-use effect ([DustKick]) leave out what does not apply (the dust
## ring only on hard falls).
func set_part_enabled(part_name: StringName, enabled: bool) -> void:
	_ensure_setup()
	for shape: _Shape in _shapes:
		if shape.node.name == part_name:
			shape.enabled = enabled
	for burst: _Burst in _bursts:
		if burst.node.name == part_name:
			burst.enabled = enabled


## Stops emitting and ends when the last particles fade out (for continuous effects).
func stop() -> void:
	if not _playing or _stopping:
		return
	_stopping = true
	_end_time = maxf(_elapsed + _tail, _cue_end)
	for burst: _Burst in _bursts:
		burst.start_at = -1.0
		burst.node.emitting = false


## Turns everything off at once and leaves it ready for reuse (hidden, not emitting).
func reset() -> void:
	_ensure_setup()
	_playing = false
	_stopping = false
	_elapsed = 0.0
	for burst: _Burst in _bursts:
		burst.start_at = -1.0
		burst.node.emitting = false
	for shape: _Shape in _shapes:
		shape.started = -1.0
		shape.node.visible = false
	visible = false
	set_process(false)


## True while the effect is playing (from [method play] until [signal finished]).
func is_playing() -> bool:
	return _playing


## Seconds since the last [method play].
func get_elapsed() -> float:
	return _elapsed


func set_tint(value: Color) -> void:
	tint = value
	if _is_setup:
		_apply_tint()


func _process(delta: float) -> void:
	if not _playing:
		set_process(false)
		return
	_elapsed += delta
	for burst: _Burst in _bursts:
		if burst.start_at >= 0.0 and _elapsed >= burst.start_at:
			burst.start_at = -1.0
			_fire(burst)
	for shape: _Shape in _shapes:
		if shape.started < 0.0:
			continue
		var progress: float = (_elapsed - shape.started - shape.delay) / shape.length
		var live: bool = progress >= 0.0 and progress < 1.0
		if shape.node.visible != live:
			shape.node.visible = live
		if live:
			shape.node.set_instance_shader_parameter(PARAM_PROGRESS, progress)
		elif progress >= 1.0:
			shape.started = -1.0
	if _elapsed >= _end_time and (_stopping or not looping):
		_finish()


func _fire(burst: _Burst) -> void:
	burst.node.restart()


func _finish() -> void:
	reset()
	finished.emit()


# Walks the children only once (also done by [method _ready]; this way an effect can be used before
# entering the tree).
func _ensure_setup() -> void:
	if _is_setup:
		return
	_is_setup = true
	for node: Node in find_children("*", "", true, false):
		_register(node)
	for burst: _Burst in _bursts:
		_tail = maxf(_tail, burst.node.lifetime / maxf(burst.node.speed_scale, 0.01))
	_apply_tint()


func _register(node: Node) -> void:
	var cue: StringName = StringName(node.get_meta(META_CUE, CUE_START))
	var timing: Vector2 = node.get_meta(META_TIME, Vector2.ZERO)
	var length: float = 0.0
	if node is GPUParticles3D:
		var particles: GPUParticles3D = node as GPUParticles3D
		var burst := _Burst.new()
		burst.node = particles
		burst.cue = cue
		burst.delay = timing.x
		_bursts.append(burst)
		particles.emitting = false
		length = timing.x + particles.lifetime / maxf(particles.speed_scale, 0.01)
		_tintables.append(particles)
	elif node is GeometryInstance3D:
		var instance: GeometryInstance3D = node as GeometryInstance3D
		if not bool(node.get_meta(META_NO_TINT, false)):
			_tintables.append(instance)
		if node.has_meta(META_VARIANTS):
			_variant_nodes.append(instance)
		if node.has_meta(META_TIME):
			var shape := _Shape.new()
			shape.node = instance
			shape.cue = cue
			shape.delay = timing.x
			shape.length = maxf(timing.y, 0.01)
			_shapes.append(shape)
			instance.visible = false
			length = timing.x + shape.length
	if length > 0.0:
		_cue_lengths[cue] = maxf(float(_cue_lengths.get(cue, 0.0)), length)


func _apply_tint() -> void:
	for instance: GeometryInstance3D in _tintables:
		var base: Color = instance.get_meta(META_TINT, Color.WHITE)
		var weight: float = float(instance.get_meta(META_TINT_WEIGHT, 1.0))
		var mixed: Color = Color.WHITE.lerp(tint, weight)
		instance.set_instance_shader_parameter(PARAM_TINT,
				Color(base.r * mixed.r, base.g * mixed.g, base.b * mixed.b, base.a * mixed.a))


# Picks the variant (atlas row) and the flip of each mesh with an atlas of variants, so that two
# consecutive shots do not repeat the spurt. Deterministic: it depends on the number of shots of this copy.
func _apply_variants() -> void:
	for instance: GeometryInstance3D in _variant_nodes:
		var count: int = maxi(int(instance.get_meta(META_VARIANTS)), 1)
		var order: int = _play_count + int(instance.get_meta(META_VARIANT_OFFSET, 0))
		instance.set_instance_shader_parameter(PARAM_VARIANT, float(order % count))
		instance.set_instance_shader_parameter(PARAM_FLIP, -1.0 if floori(float(order) / float(count)) % 2 == 1 else 1.0)
