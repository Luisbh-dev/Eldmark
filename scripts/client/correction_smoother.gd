class_name CorrectionSmoother
extends RefCounted
## Smooths reconciliation corrections (docs/red.md, section 6.6).
##
## The character's body is corrected at once, because the server's collision rules. What the player
## sees is not: the error (old position minus new position, in world coordinates) is
## stored here as an offset and applied to the local nodes that draw the character
## ([code]Visual[/code] and [code]CameraTarget[/code], never [code]Collision[/code]). Since the offset
## is in the world and those nodes hang from the character, every tick it is recomputed in local space,
## because the yaw changes:
## [code]target.position = base_position + character.basis.inverse() * offset[/code].
## [br][br]
## The offset decays on every physics tick with a half-life of [constant HALF_LIFE_TICKS] ticks and is
## zeroed below [constant MIN_OFFSET]. It is written inside the physics tick, so physics
## interpolation interpolates it like everything else and
## [code]reset_physics_interpolation()[/code] is not needed.
## [br][br]
## [b]Order within the tick.[/b] The offset added by [method add_offset] (this tick's correction)
## does not decay until the next [method physics_step]: on the correction tick the body
## jumps from the old point to the new one and the offset goes from 0 to "old minus new", so the visible
## position does not jump; afterwards it converges without stutter.

## Half-life of the offset (ticks).
const HALF_LIFE_TICKS: float = 6.0
## Below this length (m) the offset is zeroed.
const MIN_OFFSET: float = 0.001

var _character: PlayerCharacter = null
var _targets: Array[Node3D] = []
var _bases: PackedVector3Array = PackedVector3Array()
## Offset (world) that has already been applied in some [method physics_step].
var _offset: Vector3 = Vector3.ZERO
## Corrections added since the last [method physics_step]: they do not decay yet.
var _pending: Vector3 = Vector3.ZERO
## true if the nodes are displaced from their base position.
var _applied: bool = false
var _decay_per_tick: float = pow(0.5, 1.0 / HALF_LIFE_TICKS)


## Stores the base local position of each target (for example, [code]Visual[/code] and
## [code]CameraTarget[/code]) and zeroes any offset.
func setup(character: PlayerCharacter, targets: Array[Node3D]) -> void:
	_character = character
	_targets.assign(targets)
	_bases = PackedVector3Array()
	for target: Node3D in _targets:
		_bases.append(target.position)
	_offset = Vector3.ZERO
	_pending = Vector3.ZERO
	_applied = false


## Adds [param world_offset] (error in world coordinates: old position minus new position)
## to the current offset.
func add_offset(world_offset: Vector3) -> void:
	_pending += world_offset


## Zeroes the offset and returns the nodes to their base position (teleport, error of more than 3 m).
func clear() -> void:
	_offset = Vector3.ZERO
	_pending = Vector3.ZERO
	_apply()


## Inside the physics tick: decays the already-applied offset, adds the new corrections to it and
## applies it to the targets as [code]base + basis.inverse() * offset[/code].
func physics_step() -> void:
	_offset = _offset * _decay_per_tick + _pending
	_pending = Vector3.ZERO
	if _offset.length() < MIN_OFFSET:
		_offset = Vector3.ZERO
	_apply()


## Current offset in world coordinates, including corrections not yet applied.
func get_offset() -> Vector3:
	return _offset + _pending


func _apply() -> void:
	if _offset == Vector3.ZERO and not _applied:
		return
	if not is_instance_valid(_character):
		return
	var local_offset: Vector3 = _character.basis.inverse() * _offset
	for i: int in _targets.size():
		var target: Node3D = _targets[i]
		if is_instance_valid(target):
			target.position = _bases[i] + local_offset
	_applied = _offset != Vector3.ZERO
