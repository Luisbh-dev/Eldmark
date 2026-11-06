class_name ArmedStanceModifier
extends SkeletonModifier3D
## Combat stance (ART-45, client only): lays over the [AnimationTree] pose the shield-and-sword guard that
## unarmed locomotion lacks. It runs after the tree and before [CombatPoseModifier] (which, if there is a hit or a
## dodge, overrides it).
## [br][br]
## [b]Combat rest.[/b] Standing still, the whole body is the guard from [member rest_clip] (by default
## [code]ual2/Idle_Shield_Loop[/code]: the shield in front of the chest), with weight [member rest_weight]. The right arm
## comes from [member right_arm_clip] ([code]ual1/Sword_Idle[/code]: the sword low and forward), because the guard
## does not hold a sword in the hand.
## [br][br]
## [b]Arm layer.[/b] When walking or running, the shoulder, arm and hand of each side come from the clip of its side with
## weight [member arm_weight] (0.6 to 0.9): the shield stays in front of the torso and the blade does not swing backward or
## over the head, which is what the unarmed locomotion clips did. The legs and trunk remain the
## locomotion.
## [br][br]
## [b]Grip.[/b] The fingers of both hands are always closed around the hilt and the shield handle: the
## first frame of the clips of each side, with weight [member grip_weight].
## [br][br]
## [b]Reserved shield.[/b] [member left_arm_reserved] (0 to 1) raises the weight of the left arm to that of the full guard
## even while walking: sword attacks use it, as they do not touch that arm ([member
## CombatActionAnim.keep_left_arm]).
## [br][br]
## [b]Zombie profile[/b] (ART-52): [method use_zombie_profile] swaps the rest for [code]ual2/Zombie_Idle_Loop[/code],
## removes the shield guard and puts a full-body [code]ual2/Zombie_Walk_Fwd_Loop[/code] with weight
## [member walk_weight]: the Hollow drags its feet instead of jogging like a soldier. Only when it runs (the zombie
## does not sprint) does the sword arm layer come back.
## [br][br]
## Driven by [CharacterAnimator], which sets the weights and the times every frame. The clips come from a
## [CombatClipSet] ([member clips]); the tracks of each clip are tabulated once per skeleton.

## Bone class used to decide the weight it is applied with.
enum Part { BODY, LEFT_ARM, RIGHT_ARM, LEFT_FINGER, RIGHT_FINGER }
const PART_COUNT: int = 5

const HIPS_BONE: StringName = &"Hips"
const LEFT_ARM_ROOT: StringName = &"LeftShoulder"
const RIGHT_ARM_ROOT: StringName = &"RightShoulder"
const LEFT_HAND: StringName = &"LeftHand"
const RIGHT_HAND: StringName = &"RightHand"

## Shield guard clips (the default profile).
const SHIELD_REST: StringName = &"ual2/Idle_Shield_Loop"
const SWORD_ARM: StringName = &"ual1/Sword_Idle"
## Zombie profile clips.
const ZOMBIE_REST: StringName = &"ual2/Zombie_Idle_Loop"
const ZOMBIE_WALK: StringName = &"ual2/Zombie_Walk_Fwd_Loop"

## Clip set the animations come from (the sword-and-shield one: it has the UAL1 and UAL2 libraries).
var clips: CombatClipSet = null
## Full-body rest and the clips of each arm (empty = no such layer).
var rest_clip: StringName = SHIELD_REST
var left_arm_clip: StringName = SHIELD_REST
var right_arm_clip: StringName = SWORD_ARM
## Full-body walk (zombie profile only; empty = none).
var walk_clip: StringName = &""
## false: the stance is not applied (the bow, a character with no weapons).
var enabled: bool = true
## true: at rest each arm also comes from its arm clip (the guard with the sword low); false: at rest the
## arms are those of the full-body rest and the arm layer only acts while moving (the zombie).
var arms_at_rest: bool = true

## Weight of the full-body rest (0 to 1): 1 standing still, 0 moving.
var rest_weight: float = 0.0
## Weight of the arm layer while moving (0.6 to 0.9).
var arm_weight: float = 0.8
## Weight of the left arm reserved by an attack (0 to 1).
var left_arm_reserved: float = 0.0
## Weight of the finger grip (0 to 1).
var grip_weight: float = 1.0
## Weight of the full-body walk (0 to 1).
var walk_weight: float = 0.0
## Multiplier of everything above (0 to 1): drops in the air and with full-body clips.
var master_weight: float = 1.0
## Beyond this distance (m) from the camera the stance is not applied (0 = always). The weight falls to zero over the last
## [constant FADE_METERS], so nothing pops. It is far enough for the Hollow of a distant fort to keep their zombie rest
## and walk. Without a camera (headless) it is always applied.
var cull_distance: float = 160.0
## Length (m) of the fade before [member cull_distance].
const FADE_METERS: float = 25.0
## Times (s) of the clips: of the rest, and of the full-body walk.
var rest_time: float = 0.0
var walk_time: float = 0.0
## With the grip, the time in the clips the fingers come from (fixed: the hand neither opens nor closes).
var grip_time: float = 0.0

var _cached_skeleton: Skeleton3D = null
var _parts: Dictionary[int, int] = {}
# Animation -> tracks by bone class (see _table_for).
var _tables: Dictionary[Animation, Array] = {}
var _weights: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
var _applied: int = 0


func _process_modification() -> void:
	if not enabled or clips == null or master_weight <= 0.001:
		return
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	var fade: float = _distance_fade(skeleton)
	if fade <= 0.001:
		return
	if skeleton != _cached_skeleton:
		_cache_skeleton(skeleton)
	var master: float = clampf(master_weight, 0.0, 1.0) * fade
	var rest: float = clampf(rest_weight, 0.0, 1.0) * master
	var arms: float = clampf(arm_weight, 0.0, 1.0) * master
	var left: float = maxf(maxf(rest if arms_at_rest else 0.0, arms), clampf(left_arm_reserved, 0.0, 1.0) * master)
	var right: float = maxf(rest if arms_at_rest else 0.0, arms)
	var grip: float = clampf(grip_weight, 0.0, 1.0) * master
	if walk_clip != &"":
		_set_all_weights(clampf(walk_weight, 0.0, 1.0) * master)
		_apply(skeleton, clips.get_animation(walk_clip), walk_time, true)
	if rest_clip != &"":
		_set_all_weights(rest)
		if arms_at_rest:
			if left_arm_clip != &"":
				_weights[Part.LEFT_ARM] = left if left_arm_clip == rest_clip else 0.0
				_weights[Part.LEFT_FINGER] = 0.0
			if right_arm_clip != &"":
				_weights[Part.RIGHT_ARM] = 0.0
				_weights[Part.RIGHT_FINGER] = 0.0
		_apply(skeleton, clips.get_animation(rest_clip), rest_time, true)
	if right_arm_clip != &"":
		_set_one_weight(Part.RIGHT_ARM, right)
		_apply(skeleton, clips.get_animation(right_arm_clip), rest_time, false)
	if left_arm_clip != &"" and left_arm_clip != rest_clip:
		_set_one_weight(Part.LEFT_ARM, left)
		_apply(skeleton, clips.get_animation(left_arm_clip), rest_time, false)
	if grip > 0.001:
		if left_arm_clip != &"":
			_set_one_weight(Part.LEFT_FINGER, grip)
			_apply(skeleton, clips.get_animation(left_arm_clip), grip_time, false)
		if right_arm_clip != &"":
			_set_one_weight(Part.RIGHT_FINGER, grip)
			_apply(skeleton, clips.get_animation(right_arm_clip), grip_time, false)
	_applied += 1


## Number of times the stance has been applied since it was created (for the tests).
func get_applied_count() -> int:
	return _applied


## Shield-and-sword guard profile (the default one).
func use_shield_profile() -> void:
	rest_clip = SHIELD_REST
	left_arm_clip = SHIELD_REST
	right_arm_clip = SWORD_ARM
	walk_clip = &""
	arms_at_rest = true
	enabled = true


## Zombie profile (the Hollow): full-body zombie rest and walk, with no arm layer or grip.
func use_zombie_profile() -> void:
	rest_clip = ZOMBIE_REST
	left_arm_clip = &""
	right_arm_clip = SWORD_ARM
	walk_clip = ZOMBIE_WALK
	arms_at_rest = false
	enabled = true


# Every bone class with the same weight (reuses the weights array: no allocation per pass).
func _set_all_weights(weight: float) -> void:
	_weights.fill(weight)


# Only one bone class with weight (the rest 0).
func _set_one_weight(part: int, weight: float) -> void:
	_weights.fill(0.0)
	_weights[part] = weight


## Weight factor (1 near, 0 at [member cull_distance]) for a character [param distance] m from the camera.
func get_distance_fade(distance: float) -> float:
	if cull_distance <= 0.0:
		return 1.0
	return 1.0 - smoothstep(cull_distance - FADE_METERS, cull_distance, distance)


# Fade factor of the character from the camera (1 without a camera).
func _distance_fade(skeleton: Skeleton3D) -> float:
	if cull_distance <= 0.0 or not skeleton.is_inside_tree():
		return 1.0
	var camera: Camera3D = skeleton.get_viewport().get_camera_3d()
	if camera == null:
		return 1.0
	return get_distance_fade(camera.global_position.distance_to(skeleton.global_position))


## Applies [param animation] at [param time]: each bone with the weight of its class in the weights set before the call (0 for
## a class that is not in it). Only the bones of the classes with weight are visited.
## With [param with_hips] it also blends the hip position with the weight of [constant Part.BODY].
func _apply(skeleton: Skeleton3D, animation: Animation, time: float, with_hips: bool) -> void:
	if animation == null:
		return
	var table: Array = _table_for(skeleton, animation)
	var clamped_time: float = clampf(time, 0.0, animation.length)
	for part: int in PART_COUNT:
		var weight: float = _weights[part]
		if weight <= 0.001:
			continue
		var pairs: PackedInt32Array = table[part]
		var index: int = 0
		while index < pairs.size():
			var bone: int = pairs[index]
			var target: Quaternion = animation.rotation_track_interpolate(pairs[index + 1], clamped_time)
			var current: Quaternion = skeleton.get_bone_pose_rotation(bone)
			skeleton.set_bone_pose_rotation(bone, current.slerp(target, weight))
			index += 2
	var hips_track: int = int(table[PART_COUNT])
	if with_hips and hips_track >= 0:
		var hips: int = skeleton.find_bone(HIPS_BONE)
		var hips_weight: float = _weights[Part.BODY]
		if hips >= 0 and hips_weight > 0.001:
			var target_position: Vector3 = animation.position_track_interpolate(hips_track, clamped_time)
			skeleton.set_bone_pose_position(hips, skeleton.get_bone_pose_position(hips).lerp(target_position,
					hips_weight))


# Class of each bone: the arms hang from the shoulders and the fingers from the hands.
func _cache_skeleton(skeleton: Skeleton3D) -> void:
	_cached_skeleton = skeleton
	_tables.clear()
	_parts.clear()
	var left_root: int = skeleton.find_bone(LEFT_ARM_ROOT)
	var right_root: int = skeleton.find_bone(RIGHT_ARM_ROOT)
	var left_hand: int = skeleton.find_bone(LEFT_HAND)
	var right_hand: int = skeleton.find_bone(RIGHT_HAND)
	for bone: int in skeleton.get_bone_count():
		var part: Part = Part.BODY
		var walker: int = skeleton.get_bone_parent(bone)
		var in_left: bool = bone == left_root
		var in_right: bool = bone == right_root
		var below_left_hand: bool = false
		var below_right_hand: bool = false
		while walker >= 0:
			if walker == left_root:
				in_left = true
			elif walker == right_root:
				in_right = true
			if walker == left_hand:
				below_left_hand = true
			elif walker == right_hand:
				below_right_hand = true
			walker = skeleton.get_bone_parent(walker)
		if below_left_hand:
			part = Part.LEFT_FINGER
		elif below_right_hand:
			part = Part.RIGHT_FINGER
		elif in_left:
			part = Part.LEFT_ARM
		elif in_right:
			part = Part.RIGHT_ARM
		_parts[bone] = part


# Tracks of the clip for this skeleton, by bone class: an array with one PackedInt32Array of (bone, rotation track) pairs
# per [enum Part], and at index [constant PART_COUNT] the hip position track (-1 if it has none).
func _table_for(skeleton: Skeleton3D, animation: Animation) -> Array:
	if _tables.has(animation):
		return _tables[animation]
	var table: Array = []
	for part: int in PART_COUNT:
		table.append(PackedInt32Array())
	var hips_track: int = -1
	for track: int in animation.get_track_count():
		var type: int = animation.track_get_type(track)
		if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D:
			continue
		var path: String = String(animation.track_get_path(track))
		var bone: int = skeleton.find_bone(path.substr(path.rfind(":") + 1))
		if bone < 0:
			continue
		if type == Animation.TYPE_ROTATION_3D:
			var pairs: PackedInt32Array = table[int(_parts.get(bone, Part.BODY))]
			pairs.append(bone)
			pairs.append(track)
			table[int(_parts.get(bone, Part.BODY))] = pairs
		elif skeleton.get_bone_name(bone) == HIPS_BONE:
			hips_track = track
	table.append(hips_track)
	_tables[animation] = table
	return table
