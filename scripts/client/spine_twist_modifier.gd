class_name SpineTwistModifier
extends SkeletonModifier3D
## Twists the spine (Spine, Chest, UpperChest, Neck and Head) around the skeleton's vertical axis,
## distributing [member twist] among the bones, after the AnimationTree has set the pose. Client only.
##
## Used by [CharacterAnimator]: since UAL has no sideways clips, when moving diagonally or sideways the
## hips face the direction of travel (the feet do not slide) and the spine is twisted the opposite way
## so that the chest and head keep facing the crosshair.
## It must be a child of the [Skeleton3D] (Godot humanoid profile).

## Bones that are twisted and the fraction of the twist each one carries (they add up to 1).
const BONES: Dictionary[StringName, float] = {
	&"Spine": 0.2,
	&"Chest": 0.25,
	&"UpperChest": 0.25,
	&"Neck": 0.15,
	&"Head": 0.15,
}

## Total twist (radians, [member Node3D.rotation].y convention) distributed along the spine.
var twist: float = 0.0

var _bone_ids: Array[int] = []
var _weights: Array[float] = []
var _cached_skeleton: Skeleton3D = null


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null or is_zero_approx(twist):
		return
	if skeleton != _cached_skeleton:
		_cache_bones(skeleton)
	# From root to tip: each bone inherits the twist of the previous ones and adds its own share.
	for i: int in _bone_ids.size():
		var bone: int = _bone_ids[i]
		var pose: Transform3D = skeleton.get_bone_global_pose(bone)
		pose.basis = Basis(Vector3.UP, twist * _weights[i]) * pose.basis
		skeleton.set_bone_global_pose(bone, pose)


func _cache_bones(skeleton: Skeleton3D) -> void:
	_cached_skeleton = skeleton
	_bone_ids.clear()
	_weights.clear()
	for bone_name: StringName in BONES:
		var bone: int = skeleton.find_bone(bone_name)
		if bone >= 0:
			_bone_ids.append(bone)
			_weights.append(BONES[bone_name])
