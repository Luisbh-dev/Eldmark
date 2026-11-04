class_name ArmedStanceModifier
extends SkeletonModifier3D
## Postura armada (ART-45, solo cliente): pone sobre la pose del [AnimationTree] la guardia con escudo y espada que
## la locomoción sin arma no trae. Va después del árbol y antes de [CombatPoseModifier] (que, si hay un golpe o una
## esquiva, la pisa).
## [br][br]
## [b]Reposo de combate.[/b] Parado, todo el cuerpo es la guardia de [member rest_clip] (por defecto
## [code]ual2/Idle_Shield_Loop[/code]: el escudo delante del pecho), con peso [member rest_weight]. El brazo derecho
## sale de [member right_arm_clip] ([code]ual1/Sword_Idle[/code]: la espada baja y adelantada), porque la guardia no
## lleva espada en la mano.
## [br][br]
## [b]Capa de brazos.[/b] Andando o corriendo, hombro, brazo y mano de cada lado vienen del clip de su lado con
## peso [member arm_weight] (de 0,6 a 0,9): el escudo se queda delante del torso y la hoja no se va hacia atrás ni
## sobre la cabeza, que es lo que hacían los clips de locomoción sin arma. Las piernas y el tronco siguen siendo la
## locomoción.
## [br][br]
## [b]Agarre.[/b] Los dedos de las dos manos van siempre cerrados sobre la empuñadura y el asa del escudo: el
## primer fotograma de los clips de cada lado, con peso [member grip_weight].
## [br][br]
## [b]Escudo reservado.[/b] [member left_arm_reserved] (de 0 a 1) sube el peso del brazo izquierdo al de la guardia
## completa aunque se ande: la usan los ataques de espada, que no tocan ese brazo ([member
## CombatActionAnim.keep_left_arm]).
## [br][br]
## [b]Perfil zombi[/b] (ART-52): [method use_zombie_profile] cambia el reposo por [code]ual2/Zombie_Idle_Loop[/code],
## quita la guardia del escudo y pone [code]ual2/Zombie_Walk_Fwd_Loop[/code] de cuerpo entero con peso
## [member walk_weight]: el Hueco arrastra los pies en lugar de trotar como un soldado. Solo cuando corre (el zombi
## no esprinta) vuelve la capa del brazo de la espada.
## [br][br]
## Lo conduce [CharacterAnimator], que fija los pesos y los instantes cada fotograma. Los clips salen de un
## [CombatClipSet] ([member clips]); las pistas de cada clip se tabulan una vez por esqueleto.

## Clase de hueso para decidir con qué peso se aplica.
enum Part { BODY, LEFT_ARM, RIGHT_ARM, LEFT_FINGER, RIGHT_FINGER }

const HIPS_BONE: StringName = &"Hips"
const LEFT_ARM_ROOT: StringName = &"LeftShoulder"
const RIGHT_ARM_ROOT: StringName = &"RightShoulder"
const LEFT_HAND: StringName = &"LeftHand"
const RIGHT_HAND: StringName = &"RightHand"

## Clips de la guardia con escudo (el perfil por defecto).
const SHIELD_REST: StringName = &"ual2/Idle_Shield_Loop"
const SWORD_ARM: StringName = &"ual1/Sword_Idle"
## Clips del perfil zombi.
const ZOMBIE_REST: StringName = &"ual2/Zombie_Idle_Loop"
const ZOMBIE_WALK: StringName = &"ual2/Zombie_Walk_Fwd_Loop"

## Juego de clips del que salen las animaciones (el de espada y escudo: tiene las bibliotecas UAL1 y UAL2).
var clips: CombatClipSet = null
## Reposo de cuerpo entero y clips de cada brazo (vacío = sin esa capa).
var rest_clip: StringName = SHIELD_REST
var left_arm_clip: StringName = SHIELD_REST
var right_arm_clip: StringName = SWORD_ARM
## Caminar de cuerpo entero (solo el perfil zombi; vacío = ninguno).
var walk_clip: StringName = &""
## false: la postura no se aplica (el arco, un personaje sin armas).
var enabled: bool = true
## true: en reposo cada brazo también sale de su clip de brazo (la guardia con la espada baja); false: en reposo los
## brazos son los del reposo de cuerpo entero y la capa de brazos solo actúa en movimiento (el zombi).
var arms_at_rest: bool = true

## Peso del reposo de cuerpo entero (0 a 1): 1 parado, 0 en movimiento.
var rest_weight: float = 0.0
## Peso de la capa de brazos en movimiento (0,6 a 0,9).
var arm_weight: float = 0.8
## Peso del brazo izquierdo reservado por un ataque (0 a 1).
var left_arm_reserved: float = 0.0
## Peso del agarre de los dedos (0 a 1).
var grip_weight: float = 1.0
## Peso del caminar de cuerpo entero (0 a 1).
var walk_weight: float = 0.0
## Multiplicador de todo lo anterior (0 a 1): baja en el aire y con clips de cuerpo entero.
var master_weight: float = 1.0
## Instantes (s) de los clips: del reposo, y del caminar de cuerpo entero.
var rest_time: float = 0.0
var walk_time: float = 0.0
## Con el agarre, el instante de los clips del que salen los dedos (fijo: la mano no se abre ni se cierra).
var grip_time: float = 0.0

var _cached_skeleton: Skeleton3D = null
var _parts: Dictionary[int, int] = {}
# Animation -> Dictionary[bone, track de rotación] más la pista de posición de la cadera con clave -1.
var _tables: Dictionary[Animation, Dictionary] = {}
var _applied: int = 0


func _process_modification() -> void:
	if not enabled or clips == null or master_weight <= 0.001:
		return
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	if skeleton != _cached_skeleton:
		_cache_skeleton(skeleton)
	var master: float = clampf(master_weight, 0.0, 1.0)
	var rest: float = clampf(rest_weight, 0.0, 1.0) * master
	var arms: float = clampf(arm_weight, 0.0, 1.0) * master
	var left: float = maxf(maxf(rest if arms_at_rest else 0.0, arms), clampf(left_arm_reserved, 0.0, 1.0) * master)
	var right: float = maxf(rest if arms_at_rest else 0.0, arms)
	var grip: float = clampf(grip_weight, 0.0, 1.0) * master
	if walk_clip != &"":
		_apply(skeleton, clips.get_animation(walk_clip), walk_time, _all(clampf(walk_weight, 0.0, 1.0) * master), true)
	if rest_clip != &"":
		var rest_parts: Dictionary = _all(rest)
		if arms_at_rest:
			if left_arm_clip != &"":
				rest_parts[Part.LEFT_ARM] = left if left_arm_clip == rest_clip else 0.0
				rest_parts[Part.LEFT_FINGER] = 0.0
			if right_arm_clip != &"":
				rest_parts[Part.RIGHT_ARM] = 0.0
				rest_parts[Part.RIGHT_FINGER] = 0.0
		_apply(skeleton, clips.get_animation(rest_clip), rest_time, rest_parts, true)
	if right_arm_clip != &"":
		_apply(skeleton, clips.get_animation(right_arm_clip), rest_time, {Part.RIGHT_ARM: right}, false)
	if left_arm_clip != &"" and left_arm_clip != rest_clip:
		_apply(skeleton, clips.get_animation(left_arm_clip), rest_time, {Part.LEFT_ARM: left}, false)
	if grip > 0.001:
		if left_arm_clip != &"":
			_apply(skeleton, clips.get_animation(left_arm_clip), grip_time, {Part.LEFT_FINGER: grip}, false)
		if right_arm_clip != &"":
			_apply(skeleton, clips.get_animation(right_arm_clip), grip_time, {Part.RIGHT_FINGER: grip}, false)
	_applied += 1


## Veces que se ha aplicado la postura desde que existe (para las pruebas).
func get_applied_count() -> int:
	return _applied


## Perfil de guardia con escudo y espada (el de por defecto).
func use_shield_profile() -> void:
	rest_clip = SHIELD_REST
	left_arm_clip = SHIELD_REST
	right_arm_clip = SWORD_ARM
	walk_clip = &""
	arms_at_rest = true
	enabled = true


## Perfil zombi (el Hueco): reposo y caminar de zombi de cuerpo entero, sin capa de brazos ni agarre.
func use_zombie_profile() -> void:
	rest_clip = ZOMBIE_REST
	left_arm_clip = &""
	right_arm_clip = SWORD_ARM
	walk_clip = ZOMBIE_WALK
	arms_at_rest = false
	enabled = true


# Todas las clases de hueso con el mismo peso.
static func _all(weight: float) -> Dictionary:
	return {Part.BODY: weight, Part.LEFT_ARM: weight, Part.RIGHT_ARM: weight, Part.LEFT_FINGER: weight,
			Part.RIGHT_FINGER: weight}


## Aplica [param animation] en [param time]: cada hueso con el peso de su clase en [param weights] (la que falte, 0).
## Con [param with_hips] también mezcla la posición de la cadera con el peso de [constant Part.BODY].
func _apply(skeleton: Skeleton3D, animation: Animation, time: float, weights: Dictionary,
		with_hips: bool) -> void:
	if animation == null:
		return
	var table: Dictionary = _table_for(skeleton, animation)
	var clamped_time: float = clampf(time, 0.0, animation.length)
	for bone: int in table:
		if bone < 0:
			continue
		var weight: float = float(weights.get(_parts.get(bone, Part.BODY), 0.0))
		if weight <= 0.001:
			continue
		var target: Quaternion = animation.rotation_track_interpolate(int(table[bone]), clamped_time)
		var current: Quaternion = skeleton.get_bone_pose_rotation(bone)
		skeleton.set_bone_pose_rotation(bone, current.slerp(target, weight))
	if with_hips and table.has(-1):
		var hips: int = skeleton.find_bone(HIPS_BONE)
		var hips_weight: float = float(weights.get(Part.BODY, 0.0))
		if hips >= 0 and hips_weight > 0.001:
			var target_position: Vector3 = animation.position_track_interpolate(int(table[-1]), clamped_time)
			skeleton.set_bone_pose_position(hips, skeleton.get_bone_pose_position(hips).lerp(target_position,
					hips_weight))


# Clase de cada hueso: los brazos cuelgan de los hombros y los dedos de las manos.
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


# Tabla de pistas de rotación (hueso -> pista) del clip para este esqueleto; la pista de posición de la cadera va
# con la clave -1.
func _table_for(skeleton: Skeleton3D, animation: Animation) -> Dictionary:
	if _tables.has(animation):
		return _tables[animation]
	var table: Dictionary = {}
	for track: int in animation.get_track_count():
		var type: int = animation.track_get_type(track)
		if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D:
			continue
		var path: String = String(animation.track_get_path(track))
		var bone: int = skeleton.find_bone(path.substr(path.rfind(":") + 1))
		if bone < 0:
			continue
		if type == Animation.TYPE_ROTATION_3D:
			table[bone] = track
		elif skeleton.get_bone_name(bone) == HIPS_BONE:
			table[-1] = track
	_tables[animation] = table
	return table
