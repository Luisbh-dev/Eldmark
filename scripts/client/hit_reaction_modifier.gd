class_name HitReactionModifier
extends SkeletonModifier3D
## Procedural body reactions (client only, ART-48 and ART-50), on top of any clip: applied after
## [CombatPoseModifier] and before [SpineTwistModifier]. It touches neither the simulation nor the clips: it only adds rotations to the
## bones in skeleton space.
## [br][br]
## [b]Hit received[/b] ([method trigger_hit], ART-50): spine and head lean back by [constant HIT_MIN_DEG] to
## [constant HIT_MAX_DEG] degrees away from the attacker and return with an elastic rebound in
## [constant HIT_RETURN_S] seconds. It applies to every hit with damage from any weapon or NPC, including light ones that
## impose no stagger.
## [br][br]
## [b]Blocked hit[/b] ([method trigger_block], ART-48): the left arm (the shield one) and the spine receive
## a push backward of [constant BLOCK_ARM_DEG] and [constant BLOCK_SPINE_DEG] degrees for
## [constant BLOCK_S] seconds (0.15 s or more: the minimum of the bar for it to read).
## [br][br]
## [b]Shield at head height[/b] ([member guard_raise]): when blocking, the shield arm rises
## [constant GUARD_RAISE_DEG] degrees to cover the head too as seen from the attacker, not just the chest.
## [br][br]
## [b]Step back[/b]: done by the [CharacterAnimator] by moving the [code]Pivot[/code]; here only the body rotation.

## Spine rotation on a hit: from the softest hit to the hardest.
const HIT_MIN_DEG: float = 8.0
const HIT_MAX_DEG: float = 12.0
## Damage at which the rotation reaches [constant HIT_MAX_DEG].
const HIT_FULL_DAMAGE: float = 150.0
## Time (s) to the maximum rotation and total duration of the return with rebound.
const HIT_PEAK_S: float = 0.045
const HIT_RETURN_S: float = 0.25
## Shield push on a blocked hit: degrees of the arm and of the spine and duration (s).
const BLOCK_ARM_DEG: float = 14.0
const BLOCK_SPINE_DEG: float = 5.0
const BLOCK_S: float = 0.18
## Degrees the shield arm rises when blocking (toward the head) and time (s) to get there.
const GUARD_RAISE_DEG: float = 30.0
const GUARD_RAISE_S: float = 0.1

## Spine bones and the fraction of the rotation each one takes (they add up to 1).
const SPINE_BONES: Dictionary[StringName, float] = {
	&"Spine": 0.2,
	&"Chest": 0.3,
	&"UpperChest": 0.25,
	&"Neck": 0.1,
	&"Head": 0.15,
}
const LEFT_ARM_BONE: StringName = &"LeftShoulder"

## How much of the raised shield is applied now (0 to 1): set by the animator while blocking.
var guard_raise: float = 0.0

# Hit: time since it started (-1 = none), amplitude (rad) and direction (world space, horizontal).
var _hit_time: float = -1.0
var _hit_amplitude: float = 0.0
var _hit_direction: Vector3 = Vector3.ZERO
var _block_time: float = -1.0
var _block_direction: Vector3 = Vector3.ZERO
var _guard: float = 0.0
var _cached_skeleton: Skeleton3D = null
var _spine_ids: Array[int] = []
var _spine_weights: Array[float] = []
var _arm_id: int = -1
var _applied: int = 0


## A hit with [param amount] damage coming from [param attacker_direction] (horizontal world vector, from
## the victim toward the attacker; zero if unknown): the body recoils, to the opposite side.
func trigger_hit(attacker_direction: Vector3, amount: float = 0.0) -> void:
	_hit_time = 0.0
	_hit_amplitude = deg_to_rad(lerpf(HIT_MIN_DEG, HIT_MAX_DEG, clampf(amount / HIT_FULL_DAMAGE, 0.0, 1.0)))
	_hit_direction = _recoil_of(attacker_direction)


## A blocked or parried hit coming from [param attacker_direction]: push of the shield arm.
func trigger_block(attacker_direction: Vector3) -> void:
	_block_time = 0.0
	_block_direction = _recoil_of(attacker_direction)


## true while any reaction is in progress (for tests).
func is_reacting() -> bool:
	return _hit_time >= 0.0 or _block_time >= 0.0


## Times it has been applied to the bones (for tests).
func get_applied_count() -> int:
	return _applied


## Fraction (0 to 1) of the hit rotation at instant [param time] s since it arrived: rises in [constant HIT_PEAK_S],
## falls with a rebound (passes a little to the other side) and fades out in [constant HIT_RETURN_S].
static func hit_envelope(time: float) -> float:
	if time < 0.0 or time >= HIT_RETURN_S:
		return 0.0
	if time < HIT_PEAK_S:
		return smoothstep(0.0, HIT_PEAK_S, time)
	var t: float = (time - HIT_PEAK_S) / (HIT_RETURN_S - HIT_PEAK_S)
	# Damped cosine: from 1 to a small rebound on the other side and to 0.
	return (1.0 - t) * (1.0 - t) * cos(t * PI * 1.35)


## Fraction (0 to 1) of the block push at [param time] s: a fast peak and a smooth return in [constant BLOCK_S].
static func block_envelope(time: float) -> float:
	if time < 0.0 or time >= BLOCK_S:
		return 0.0
	var peak: float = BLOCK_S * 0.3
	if time < peak:
		return smoothstep(0.0, peak, time)
	return 1.0 - smoothstep(peak, BLOCK_S, time)


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	var delta: float = get_process_delta_time()
	if _hit_time >= 0.0:
		_hit_time += delta
		if _hit_time >= HIT_RETURN_S:
			_hit_time = -1.0
	if _block_time >= 0.0:
		_block_time += delta
		if _block_time >= BLOCK_S:
			_block_time = -1.0
	_guard = move_toward(_guard, clampf(guard_raise, 0.0, 1.0), delta / GUARD_RAISE_S)
	var hit: float = hit_envelope(_hit_time) * _hit_amplitude
	var block: float = block_envelope(_block_time)
	if is_zero_approx(hit) and is_zero_approx(block) and _guard <= 0.001:
		return
	if skeleton != _cached_skeleton:
		_cache(skeleton)
	var to_local: Basis = skeleton.global_transform.basis.orthonormalized().inverse()
	# Spine: the hit and the block push are added in the same recoil direction.
	if not is_zero_approx(hit):
		_tilt_spine(skeleton, to_local * _hit_direction, hit)
	if not is_zero_approx(block):
		_tilt_spine(skeleton, to_local * _block_direction, deg_to_rad(BLOCK_SPINE_DEG) * block)
		_tilt_bone(skeleton, _arm_id, to_local * _block_direction, deg_to_rad(BLOCK_ARM_DEG) * block)
	if _guard > 0.001 and _arm_id >= 0:
		# The arm rises forward and up: rotation around the skeleton's lateral axis (X), with the sign
		# that raises the left hand.
		var pose: Transform3D = skeleton.get_bone_global_pose(_arm_id)
		pose.basis = Basis(Vector3.RIGHT, -deg_to_rad(GUARD_RAISE_DEG) * _guard) * pose.basis
		skeleton.set_bone_global_pose(_arm_id, pose)
	_applied += 1


# Recoil direction (world space, horizontal and unit length): opposite the attacker; zero if unknown.
static func _recoil_of(attacker_direction: Vector3) -> Vector3:
	var flat := Vector3(attacker_direction.x, 0.0, attacker_direction.z)
	if flat.length_squared() < 0.0001:
		return Vector3.ZERO
	return -flat.normalized()


# Tilts the spine toward [param direction] (skeleton space, horizontal) by [param angle] radians in total.
func _tilt_spine(skeleton: Skeleton3D, direction: Vector3, angle: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		return
	var axis: Vector3 = Vector3.UP.cross(flat.normalized()).normalized()
	for i: int in _spine_ids.size():
		_tilt_bone(skeleton, _spine_ids[i], flat, angle * _spine_weights[i], axis)


# Rotates the bone [param bone] by [param angle] radians to tilt it toward [param direction].
func _tilt_bone(skeleton: Skeleton3D, bone: int, direction: Vector3, angle: float,
		axis: Vector3 = Vector3.ZERO) -> void:
	if bone < 0 or is_zero_approx(angle):
		return
	var tilt_axis: Vector3 = axis
	if tilt_axis == Vector3.ZERO:
		var flat := Vector3(direction.x, 0.0, direction.z)
		if flat.length_squared() < 0.0001:
			return
		tilt_axis = Vector3.UP.cross(flat.normalized()).normalized()
	var pose: Transform3D = skeleton.get_bone_global_pose(bone)
	pose.basis = Basis(tilt_axis, angle) * pose.basis
	skeleton.set_bone_global_pose(bone, pose)


func _cache(skeleton: Skeleton3D) -> void:
	_cached_skeleton = skeleton
	_spine_ids.clear()
	_spine_weights.clear()
	for bone_name: StringName in SPINE_BONES:
		var bone: int = skeleton.find_bone(bone_name)
		if bone >= 0:
			_spine_ids.append(bone)
			_spine_weights.append(SPINE_BONES[bone_name])
	_arm_id = skeleton.find_bone(LEFT_ARM_BONE)
