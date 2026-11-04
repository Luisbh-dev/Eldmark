class_name CombatPoseModifier
extends SkeletonModifier3D
## Pone sobre el esqueleto la pose de combate de la [CombatAnimationLayer], después de que el
## [AnimationTree] haya puesto la de la locomoción (como [SpineTwistModifier]). Solo cliente.
## [br][br]
## Cada [CombatAnimationLayer.Slot] con peso mayor que 0 aporta su clip, muestreado en su instante
## ([member CombatAnimationLayer.Slot.time_s]): para cada hueso del clip, la rotación del hueso se
## mezcla con la actual ([method Quaternion.slerp]) según el peso del clip. Un clip de
## [b]parte superior[/b] solo toca la columna, los brazos, las manos y la cabeza (todos los huesos
## que cuelgan de [constant ROOT_OF_UPPER_BODY]), así se ataca y se bloquea andando; uno de cuerpo
## entero toca todos los huesos y además la posición de las caderas (que es lo que baja el cuerpo al
## rodar o caer muerto).
## [br][br]
## [b]Ataques con los pies plantados[/b] (ART-46): un clip de parte superior con
## [member CombatAnimationLayer.Slot.lower_weight] mayor que 0 toma también la cadera y las piernas, con ese
## peso por lo que quede de [code]1 - move_request[/code] ([member CombatAnimationLayer.move_request]): si la
## entrada no pide andar, el tajo sale con el cuerpo entero (pies plantados, caderas que giran y bajan); en cuanto
## pide andar, las piernas vuelven a la locomoción. Con [member CombatAnimationLayer.Slot.keep_left_arm] el clip
## no toca el brazo izquierdo: lo pone la postura armada, que mantiene el escudo delante del pecho.
## [br][br]
## Los clips de UAL son poses locales por hueso, las mismas que el [AnimationPlayer] pone en el
## esqueleto, así que muestrear sus pistas y aplicarlas directamente es equivalente a reproducirlos.
## Las pistas se identifican por su ruta [code]%GeneralSkeleton:Hueso[/code]; la tabla de pistas de
## cada clip se calcula una vez por esqueleto.

## Hueso de cuyo subárbol (él incluido) se compone la parte superior del cuerpo.
const ROOT_OF_UPPER_BODY: StringName = &"Spine"
## Hueso cuya posición también se aplica en los clips de cuerpo entero.
const HIPS_BONE: StringName = &"Hips"
## Hueso de cuyo subárbol (él incluido) es el brazo izquierdo, el del escudo (ART-46).
const LEFT_ARM_ROOT: StringName = &"LeftShoulder"

## Capa de la que se leen los clips. La pone [CharacterAnimator].
var layer: CombatAnimationLayer = null

var _cached_skeleton: Skeleton3D = null
var _upper_mask: PackedInt32Array = PackedInt32Array()
var _is_upper: Dictionary[int, bool] = {}
var _is_left_arm: Dictionary[int, bool] = {}
# Animation -> PackedInt32Array de ternas (hueso, pista de rotación o -1, pista de posición o -1).
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


## Huesos de la parte superior del cuerpo del esqueleto actual (índices).
func get_upper_body_bones() -> PackedInt32Array:
	return _upper_mask


## Veces que se ha aplicado un clip a los huesos desde que existe (para las pruebas).
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
			# Cadera y piernas: solo con el peso de parte inferior del tramo.
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


# Calcula la máscara de la parte superior del cuerpo del esqueleto: Spine y todo lo que cuelga de él.
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


# Tabla de pistas del clip para este esqueleto (se hace una vez).
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
