class_name CombatPoseModifier
extends SkeletonModifier3D
## Puts the combat pose of the [CombatAnimationLayer] on the skeleton, after the
## [AnimationTree] has put the locomotion one (like [SpineTwistModifier]). Client only.
## [br][br]
## Each [CombatAnimationLayer.Slot] with a weight greater than 0 contributes its clip, sampled at its instant
## ([member CombatAnimationLayer.Slot.time_s]): for each bone of the clip, the bone's rotation is
## blended with the current one ([method Quaternion.slerp]) according to the clip's weight. An
## [b]upper body[/b] clip only touches the spine, arms, hands and head (all the bones
## hanging from [constant ROOT_OF_UPPER_BODY]), so you attack and block while walking; a full-body one
## touches all the bones and also the position of the hips (which is what lowers the body when
## rolling or falling dead).
## [br][br]
## [b]Attacks with feet planted[/b] (ART-46): an upper body clip with
## [member CombatAnimationLayer.Slot.lower_weight] greater than 0 also takes the hips and legs, with that
## weight times whatever is left of [code]1 - move_request[/code] ([member CombatAnimationLayer.move_request]): if the
## input does not ask to walk, the slash comes out with the whole body (feet planted, hips that turn and lower); as soon as it
## asks to walk, the legs go back to locomotion. With [member CombatAnimationLayer.Slot.keep_left_arm] the clip
## does not touch the left arm: the combat stance sets it, keeping the shield in front of the chest.
## [br][br]
## UAL clips are local per-bone poses, the same ones the [AnimationPlayer] puts on the
## skeleton, so sampling their tracks and applying them directly is equivalent to playing them.
## Tracks are identified by their path [code]%GeneralSkeleton:Bone[/code]; the track table of
## each clip is computed once per skeleton.

## Bone whose subtree (itself included) makes up the upper body.
const ROOT_OF_UPPER_BODY: StringName = &"Spine"
## Bone whose position is also applied in full-body clips.
const HIPS_BONE: StringName = &"Hips"
## Bone whose subtree (itself included) is the left arm, the shield one (ART-46).
const LEFT_ARM_ROOT: StringName = &"LeftShoulder"

## Layer the clips are read from. [CharacterAnimator] sets it.
var layer: CombatAnimationLayer = null

var _cached_skeleton: Skeleton3D = null
var _upper_mask: PackedInt32Array = PackedInt32Array()
var _is_upper: Dictionary[int, bool] = {}
var _is_left_arm: Dictionary[int, bool] = {}
# Animation -> PackedInt32Array of triples (bone, rotation track or -1, position track or -1).
var _track_tables: Dictionary[Animation, PackedInt32Array] = {}
var _applied_count: int = 0


func _process_modification() -> void:
	if layer == null:
		return
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	if skeleton != _cached_skeleton:
		_cache_skeleton(skeleton)
	for slot: CombatAnimationLayer.Slot in layer.get_slots():
		_apply_slot(skeleton, slot)


## Upper body bones of the current skeleton (indices).
func get_upper_body_bones() -> PackedInt32Array:
	return _upper_mask


## Times a clip has been applied to the bones since it exists (for tests).
func get_applied_count() -> int:
	return _applied_count


func _apply_slot(skeleton: Skeleton3D, slot: CombatAnimationLayer.Slot) -> void:
	var animation: Animation = slot.animation
	if animation == null or slot.weight <= 0.0:
		return
	var table: PackedInt32Array = _table_for(skeleton, animation)
	var weight: float = clampf(slot.weight, 0.0, 1.0)
	var lower: float = weight * clampf(slot.lower_current, 0.0, 1.0) * (1.0 - clampf(layer.move_request, 0.0, 1.0))
	var time: float = clampf(slot.time_s, 0.0, animation.length)
	var index: int = 0
	while index < table.size():
		var bone: int = table[index]
		var rotation_track: int = table[index + 1]
		var position_track: int = table[index + 2]
		index += 3
		var bone_weight: float = weight
		if slot.upper_body and not _is_upper.get(bone, false):
			# Hips and legs: only with the span's lower body weight.
			bone_weight = lower
			if bone_weight <= 0.001:
				continue
		if slot.keep_left_arm and _is_left_arm.get(bone, false):
			continue
		if rotation_track >= 0:
			var target: Quaternion = animation.rotation_track_interpolate(rotation_track, time)
			var current: Quaternion = skeleton.get_bone_pose_rotation(bone)
			skeleton.set_bone_pose_rotation(bone, current.slerp(target, bone_weight))
		if position_track >= 0 and (not slot.upper_body or lower > 0.001):
			var target_position: Vector3 = animation.position_track_interpolate(position_track, time)
			var current_position: Vector3 = skeleton.get_bone_pose_position(bone)
			skeleton.set_bone_pose_position(bone, current_position.lerp(target_position, bone_weight))
	_applied_count += 1


# Computes the skeleton's upper body mask: Spine and everything hanging from it.
func _cache_skeleton(skeleton: Skeleton3D) -> void:
	_cached_skeleton = skeleton
	_track_tables.clear()
	_upper_mask.clear()
	_is_upper.clear()
	_is_left_arm.clear()
	var root_bone: int = skeleton.find_bone(ROOT_OF_UPPER_BODY)
	var arm_root: int = skeleton.find_bone(LEFT_ARM_ROOT)
	for bone: int in skeleton.get_bone_count():
		var walker: int = bone
		while walker >= 0:
			if walker == root_bone:
				_upper_mask.append(bone)
				_is_upper[bone] = true
			if walker == arm_root:
				_is_left_arm[bone] = true
			walker = skeleton.get_bone_parent(walker)


# Track table of the clip for this skeleton (done once).
func _table_for(skeleton: Skeleton3D, animation: Animation) -> PackedInt32Array:
	if _track_tables.has(animation):
		return _track_tables[animation]
	var by_bone: Dictionary[int, Vector2i] = {}
	for track: int in animation.get_track_count():
		var track_type: int = animation.track_get_type(track)
		if track_type != Animation.TYPE_ROTATION_3D and track_type != Animation.TYPE_POSITION_3D:
			continue
		var path: String = String(animation.track_get_path(track))
		var colon: int = path.rfind(":")
		if colon < 0:
			continue
		var bone: int = skeleton.find_bone(path.substr(colon + 1))
		if bone < 0:
			continue
		var pair: Vector2i = by_bone.get(bone, Vector2i(-1, -1))
		if track_type == Animation.TYPE_ROTATION_3D:
			pair.x = track
		elif skeleton.get_bone_name(bone) == HIPS_BONE:
			pair.y = track
		by_bone[bone] = pair
	var table := PackedInt32Array()
	for bone: int in by_bone:
		var pair: Vector2i = by_bone[bone]
		table.append(bone)
		table.append(pair.x)
		table.append(pair.y)
	_track_tables[animation] = table
	return table
