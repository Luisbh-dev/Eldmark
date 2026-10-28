class_name SpineTwistModifier
extends SkeletonModifier3D
## Gira la columna (Spine, Chest, UpperChest, Neck y Head) alrededor del eje vertical del
## esqueleto, repartiendo [member twist] entre los huesos, después de que el AnimationTree haya
## puesto la pose. Solo cliente.
##
## Lo usa [CharacterAnimator]: como UAL no trae clips laterales, al desplazarse en diagonal o de
## lado las caderas miran hacia donde se corre (los pies no patinan) y la columna se gira en
## sentido contrario para que el pecho y la cabeza sigan mirando hacia el punto de mira.
## Debe ser hijo del [Skeleton3D] (perfil humanoide de Godot).

## Huesos que se giran y fracción del giro que lleva cada uno (suman 1).
const BONES: Dictionary[StringName, float] = {
	&"Spine": 0.2,
	&"Chest": 0.25,
	&"UpperChest": 0.25,
	&"Neck": 0.15,
	&"Head": 0.15,
}

## Giro total (radianes, convención de [member Node3D.rotation].y) que se reparte por la columna.
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
	# De la raíz a la punta: cada hueso hereda el giro de los anteriores y añade su parte.
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
