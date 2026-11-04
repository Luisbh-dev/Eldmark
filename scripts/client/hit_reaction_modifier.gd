class_name HitReactionModifier
extends SkeletonModifier3D
## Reacciones procedurales del cuerpo (solo cliente, ART-48 y ART-50), encima de cualquier clip: se aplica después de
## [CombatPoseModifier] y antes de [SpineTwistModifier]. No toca la simulación ni los clips: solo añade giros a los
## huesos en espacio del esqueleto.
## [br][br]
## [b]Golpe recibido[/b] ([method trigger_hit], ART-50): columna y cabeza se echan atrás de [constant HIT_MIN_DEG] a
## [constant HIT_MAX_DEG] grados en dirección contraria al atacante y vuelven con un rebote elástico en
## [constant HIT_RETURN_S] segundos. Vale para todo golpe con daño de cualquier arma o PNJ, también los ligeros que
## no imponen tambaleo.
## [br][br]
## [b]Golpe bloqueado[/b] ([method trigger_block], ART-48): el brazo izquierdo (el del escudo) y la columna reciben
## un empujón hacia atrás de [constant BLOCK_ARM_DEG] y [constant BLOCK_SPINE_DEG] grados durante
## [constant BLOCK_S] segundos (0,15 s o más: lo mínimo del listón para que se lea).
## [br][br]
## [b]Escudo a la altura de la cabeza[/b] ([member guard_raise]): al bloquear, el brazo del escudo sube
## [constant GUARD_RAISE_DEG] grados para tapar también la cabeza vista desde el atacante, no solo el pecho.
## [br][br]
## [b]Paso atrás[/b]: lo da el [CharacterAnimator] moviendo el [code]Pivot[/code]; aquí solo el giro del cuerpo.

## Giro de la columna con un golpe: del golpe más suave al más fuerte.
const HIT_MIN_DEG: float = 8.0
const HIT_MAX_DEG: float = 12.0
## Daño con el que el giro llega a [constant HIT_MAX_DEG].
const HIT_FULL_DAMAGE: float = 150.0
## Tiempo (s) hasta el giro máximo y duración total de la vuelta con rebote.
const HIT_PEAK_S: float = 0.045
const HIT_RETURN_S: float = 0.25
## Empuje del escudo en un golpe bloqueado: grados del brazo y de la columna y duración (s).
const BLOCK_ARM_DEG: float = 14.0
const BLOCK_SPINE_DEG: float = 5.0
const BLOCK_S: float = 0.18
## Grados que sube el brazo del escudo al bloquear (hacia la cabeza) y tiempo (s) en llegar.
const GUARD_RAISE_DEG: float = 30.0
const GUARD_RAISE_S: float = 0.1

## Huesos de la columna y fracción del giro que lleva cada uno (suman 1).
const SPINE_BONES: Dictionary[StringName, float] = {
	&"Spine": 0.2,
	&"Chest": 0.3,
	&"UpperChest": 0.25,
	&"Neck": 0.1,
	&"Head": 0.15,
}
const LEFT_ARM_BONE: StringName = &"LeftShoulder"

## Cuánto del escudo alzado se aplica ahora (0 a 1): lo fija el animador mientras se bloquea.
var guard_raise: float = 0.0

# Golpe: tiempo desde que empezó (-1 = ninguno), amplitud (rad) y dirección (espacio del mundo, horizontal).
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


## Un golpe con [param amount] de daño que llega desde [param attacker_direction] (vector horizontal del mundo, de
## la víctima hacia el atacante; cero si no se sabe): el cuerpo se echa atrás, al lado contrario.
func trigger_hit(attacker_direction: Vector3, amount: float = 0.0) -> void:
	_hit_time = 0.0
	_hit_amplitude = deg_to_rad(lerpf(HIT_MIN_DEG, HIT_MAX_DEG, clampf(amount / HIT_FULL_DAMAGE, 0.0, 1.0)))
	_hit_direction = _recoil_of(attacker_direction)


## Un golpe bloqueado o parado que llega desde [param attacker_direction]: empujón del brazo del escudo.
func trigger_block(attacker_direction: Vector3) -> void:
	_block_time = 0.0
	_block_direction = _recoil_of(attacker_direction)


## true mientras alguna reacción está en curso (para las pruebas).
func is_reacting() -> bool:
	return _hit_time >= 0.0 or _block_time >= 0.0


## Veces que se ha aplicado a los huesos (para las pruebas).
func get_applied_count() -> int:
	return _applied


## Fracción (0 a 1) del giro de golpe en el instante [param time] s desde que llegó: sube en [constant HIT_PEAK_S],
## baja con un rebote (pasa un poco al otro lado) y se apaga en [constant HIT_RETURN_S].
static func hit_envelope(time: float) -> float:
	if time < 0.0 or time >= HIT_RETURN_S:
		return 0.0
	if time < HIT_PEAK_S:
		return smoothstep(0.0, HIT_PEAK_S, time)
	var t: float = (time - HIT_PEAK_S) / (HIT_RETURN_S - HIT_PEAK_S)
	# Coseno amortiguado: de 1 a un rebote pequeño del otro lado y a 0.
	return (1.0 - t) * (1.0 - t) * cos(t * PI * 1.35)


## Fracción (0 a 1) del empujón de bloqueo en [param time] s: un pico rápido y vuelta suave en [constant BLOCK_S].
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
	# Columna: el golpe y el empujón del bloqueo se suman en la misma dirección de retroceso.
	if not is_zero_approx(hit):
		_tilt_spine(skeleton, to_local * _hit_direction, hit)
	if not is_zero_approx(block):
		_tilt_spine(skeleton, to_local * _block_direction, deg_to_rad(BLOCK_SPINE_DEG) * block)
		_tilt_bone(skeleton, _arm_id, to_local * _block_direction, deg_to_rad(BLOCK_ARM_DEG) * block)
	if _guard > 0.001 and _arm_id >= 0:
		# El brazo sube hacia delante y arriba: giro alrededor del eje lateral del esqueleto (X), con el signo
		# que levanta la mano izquierda.
		var pose: Transform3D = skeleton.get_bone_global_pose(_arm_id)
		pose.basis = Basis(Vector3.RIGHT, -deg_to_rad(GUARD_RAISE_DEG) * _guard) * pose.basis
		skeleton.set_bone_global_pose(_arm_id, pose)
	_applied += 1


# Dirección de retroceso (espacio del mundo, horizontal y unitaria): contraria al atacante; cero si no se sabe.
static func _recoil_of(attacker_direction: Vector3) -> Vector3:
	var flat := Vector3(attacker_direction.x, 0.0, attacker_direction.z)
	if flat.length_squared() < 0.0001:
		return Vector3.ZERO
	return -flat.normalized()


# Inclina la columna hacia [param direction] (espacio del esqueleto, horizontal) [param angle] radianes en total.
func _tilt_spine(skeleton: Skeleton3D, direction: Vector3, angle: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		return
	var axis: Vector3 = Vector3.UP.cross(flat.normalized()).normalized()
	for i: int in _spine_ids.size():
		_tilt_bone(skeleton, _spine_ids[i], flat, angle * _spine_weights[i], axis)


# Gira el hueso [param bone] [param angle] radianes para inclinarlo hacia [param direction].
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
