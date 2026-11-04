class_name CharacterAnimator
extends Node
## Conduce el [AnimationTree] de un [HumanoidVisual] a partir del estado de un [PlayerCharacter].
##
## Solo cliente y solo lectura: cada fotograma lee la velocidad, la orientación interpolada y
## [member PlayerCharacter.grounded] del personaje que decora, y escucha
## [signal PlayerCharacter.jumped]. Nunca escribe en la simulación y el servidor no necesita nada
## de esto. El aterrizaje se deduce del cambio de [member PlayerCharacter.grounded] (y no de
## [signal PlayerCharacter.landed]) para que una reconciliación que repita ticks pasados no
## dispare aterrizajes falsos; por lo mismo, el salto se valida contra el estado actual (en el
## aire y subiendo) y también se detecta sin la señal si se deja el suelo subiendo rápido.
## [br][br]
## [b]Locomoción.[/b] El nodo [code]locomotion[/code] del árbol es un BlendSpace1D por velocidad
## (m/s) con caminar, trotar y esprintar. Cada clip tiene una línea de tiempo propia estirada a
## 1 s, así que todos van en fase (pie izquierdo apoyado al principio del ciclo) y un único
## TimeScale fija los ciclos por segundo. Para que los pies no patinen, ese ritmo es la
## velocidad real dividida entre la zancada mezclada (metros por ciclo de cada clip, a partir de
## [member clip_ground_speeds]).
## [br][br]
## [b]Orientación.[/b] UAL no trae clips de desplazamiento lateral ni hacia atrás. Para que el
## strafe no parezca patinaje, las caderas (el nodo [code]Pivot[/code], no la simulación) giran
## hacia la dirección del movimiento y la columna ([SpineTwistModifier]) gira en sentido contrario
## para que el pecho y la cabeza sigan mirando hacia el punto de mira. Al retroceder (movimiento a
## más de [member backpedal_enter_angle] del yaw de la simulación) el modelo mira hacia delante y
## la locomoción se reproduce al revés: el personaje camina hacia atrás de cara al enemigo en vez de
## darse la vuelta y correr hacia la cámara. Parado, vuelve suavemente al yaw de la simulación. El
## Pivot no usa interpolación física: su giro se aplica cada fotograma sobre la transformación
## interpolada del personaje.
## [br][br]
## [b]Esquiva[/b] (ART-49, solo visual): durante [constant CombatState.Action.DODGE] el modelo mira hacia donde
## se viaja desde el primer fotograma (el rumbo de la esquiva del estado del personaje o, en un remoto, su
## velocidad) y la columna no compensa el giro: la voltereta va de cabeza hacia donde se mueve el cuerpo en
## las cuatro direcciones, también hacia atrás. Al acabar, el modelo vuelve al giro de siempre con el suavizado
## de [member turn_sharpness] y la columna recupera su compensación en [member dodge_twist_return_time]. La
## simulación no se entera: solo se mueve el [code]Pivot[/code].
## [br][br]
## [b]Aire.[/b] Saltar reproduce Jump_Start desde el despegue (sin la anticipación agachada, porque
## la simulación ya ha despegado) y pasa a Jump_Loop al empezar a caer; caer por un borde va
## directo a Jump_Loop. Al aterrizar se mezcla Jump_Land con una intensidad que depende de la
## velocidad de impacto y de si se sigue corriendo.

## [br][br]
## [b]Combate.[/b] Sobre la locomoción va la capa de animación de combate ([CombatAnimationLayer],
## ART-08): ataques, bloqueo, tambaleo y aturdimiento en la parte superior del cuerpo; esquiva y
## muerte en el cuerpo entero. La acción sale del [member PlayerCharacter.combat] del personaje (el
## jugador local y el sandbox) o, en un remoto, del byte [code]action[/code] de su registro
## ([method set_remote_source]). Cada clip se reescala a la duración de la fase en los datos de
## combate; ver [CombatClipPlanner]. La pose la pone el [CombatPoseModifier] después del árbol.
## [br][br]
## [b]Arma activa[/b] (fase 4): la del estado del personaje o, en un remoto, la que da su vista (pareja de
## armas y bit de ranura del registro, [method set_remote_source]). Elige el juego de clips del arma y,
## cuando cambia, avisa por [signal weapon_shown] (el [HumanoidVisual] cambia los accesorios de las manos,
## [WeaponProps]). Si el cambio llega durante la acción [constant CombatState.Action.SWAP] (ART-06), los
## accesorios cambian a mitad del gesto ([member swap_show_fraction]) y no en el primer fotograma; en cualquier
## otro caso (aparecer, un cambio de equipo) cambian al instante.

## Ruta de los parámetros del árbol (ver humanoid_visual.tscn).
const PARAM_LOCOMOTION_BLEND: StringName = &"parameters/locomotion/blend_position"
const PARAM_LOCOMOTION_SCALE: StringName = &"parameters/locomotion_speed/scale"
const PARAM_MOVE: StringName = &"parameters/move/blend_amount"
const PARAM_LAND: StringName = &"parameters/land/blend_amount"
const PARAM_LAND_SEEK: StringName = &"parameters/land_seek/seek_request"
const PARAM_LAND_SCALE: StringName = &"parameters/land_speed/scale"
const PARAM_JUMP_SEEK: StringName = &"parameters/jump_seek/seek_request"
const PARAM_AIR_PHASE: StringName = &"parameters/air_phase/blend_amount"
const PARAM_AIR: StringName = &"parameters/air/blend_amount"
## Nodo BlendSpace1D de locomoción dentro del árbol.
const LOCOMOTION_NODE: StringName = &"locomotion"

## El arma que se ve en las manos ha cambiado (id del catálogo de combate; 0 = ninguna conocida).
signal weapon_shown(weapon_id: int)
## El golpe del arma pasa a estar activo (o deja de estarlo), para el jugador local y para los remotos
## ([method CombatAnimationLayer.is_swing_active]): de aquí cuelga la estela de la espada.
signal swing_active_changed(active: bool)

## El personaje despega del suelo con un salto (para el sonido y el polvo; no sale al caer por un borde).
signal jumped_visual
## El personaje toca el suelo tras estar en el aire, con [param strength] de 0 a 1 según la velocidad del impacto.
signal touched_down(strength: float)
## Un remoto empieza una acción de combate ([param action] es un [enum CombatState.Action]; [param step] el paso del
## combo, la ranura de la habilidad o el contador de reinicio del byte de acción). Solo de los remotos: lo propio lo
## reparte [CombatFeedback].
signal remote_action_started(action: int, step: int)
## La carga del golpe fuerte está en curso ([param active]) con [param fraction] de 0 a 1, o ha terminado. Se emite
## cada fotograma mientras dura. De aquí cuelga el aura de la espada ([ChargeAura]).
signal charge_changed(active: bool, fraction: float)

## Fases del aire.
enum AirState { GROUNDED, JUMPING, FALLING }
## Velocidad horizontal (m/s) por encima de la cual un derribado se arrastra.
const CRAWL_MIN_SPEED: float = 0.2

## Árbol de animación que se conduce.
## Tiempo (s) en que el modelo gira hacia el rumbo de la esquiva al empezar y suavizado de ese giro.
const DODGE_TURN_TIME: float = 0.08
const DODGE_TURN_SHARPNESS: float = 40.0

@export var animation_tree: AnimationTree
## Nodo que se gira para orientar el modelo; su padre debe ser un Node3D que siga al personaje.
@export var pivot: Node3D

## Clips de las acciones de combate (recurso de texto en data/animation/).
@export var clip_set: CombatClipSet

@export_group("Locomoción")
## Velocidad sobre el suelo (m/s) de cada clip a velocidad de reproducción 1, medida sobre el
## modelo instalado (Ranger de 1,84 m) con tools/animation/measure_locomotion_strides.gd: avance
## de las puntas de los pies mientras están apoyadas / duración del ciclo. (Las de la variante con
## root motion del maniquí UAL son un 15 % más cortas y hacían patinar los pies hacia atrás.)
@export var clip_ground_speeds: Dictionary[StringName, float] = {
	&"ual1/Walk_Loop": 1.028,
	&"ual1/Jog_Fwd_Loop": 6.093,
	&"ual1/Sprint_Loop": 9.387,
}
## Rapidez con la que la velocidad usada para mezclar sigue a la real (1/s, suavizado exponencial).
@export var speed_smoothing: float = 14.0
## Por debajo de esta velocidad (m/s) se mezcla con la pose de reposo.
@export var idle_blend_speed: float = 0.7
## Ritmo máximo de la locomoción (ciclos de 1 s por segundo).
@export var max_locomotion_scale: float = 2.5

@export_group("Orientación")
## Velocidad horizontal (m/s) a partir de la cual el modelo mira hacia donde se mueve.
@export var turn_min_speed: float = 0.6
## Rapidez del giro del modelo (1/s, suavizado exponencial del ángulo).
@export var turn_sharpness: float = 12.0
## Velocidad angular máxima del modelo (rad/s).
@export var max_turn_speed: float = 14.0
## Ángulo (grados) entre el movimiento y el yaw de la simulación a partir del cual se retrocede
## de cara (locomoción al revés) en vez de girarse.
@export var backpedal_enter_angle: float = 110.0
## Ángulo (grados) por debajo del cual se deja de retroceder (histéresis).
@export var backpedal_exit_angle: float = 95.0
## Giro máximo (grados) con el que la columna compensa el de las caderas.
@export var max_spine_twist: float = 75.0

@export_group("Esquiva")
## Tiempo (s) que tarda la columna en recuperar su compensación hacia el punto de mira al acabar la esquiva.
@export var dodge_twist_return_time: float = 0.15
## Velocidad horizontal (m/s) a partir de la cual un remoto en esquiva da el rumbo de su movimiento.
@export var dodge_min_speed: float = 0.5

@export_group("Cambio de arma")
## Fracción de la acción de cambio de arma (0 a 1) a la que cambian los accesorios de las manos.
@export_range(0.0, 1.0) var swap_show_fraction: float = 0.5

@export_group("Aire")
## Segundo de Jump_Start en el que los pies dejan el suelo (antes hay una anticipación agachada).
@export var jump_takeoff_time: float = 0.07
## Tiempo en el aire sin saltar antes de considerar que se está cayendo (escalones, rampas).
@export var fall_grace_time: float = 0.15
## Velocidad vertical (m/s) por debajo de la cual el salto pasa a la pose de caída.
@export var fall_blend_velocity: float = -1.0
## Velocidad vertical (m/s) al dejar el suelo a partir de la cual se considera un salto aunque no
## haya llegado la señal (por ejemplo, tras una reconciliación).
@export var jump_detect_velocity: float = 4.0
## Duración de la mezcla suelo -> aire (s).
@export var air_blend_in_time: float = 0.08
## Duración de la mezcla aire -> suelo al aterrizar (s).
@export var air_blend_out_time: float = 0.1
## Duración de la mezcla salto -> caída (s).
@export var fall_blend_time: float = 0.25

@export_group("Aterrizaje")
## Intensidad de Jump_Land al aterrizar parado tras un salto normal (0..1).
@export var land_strength_idle: float = 0.8
## Intensidad de Jump_Land al aterrizar corriendo.
@export var land_strength_moving: float = 0.3
## Velocidad de impacto (m/s) por debajo de la cual no se reproduce el aterrizaje.
@export var land_min_impact: float = 2.0
## Velocidad de impacto (m/s) a partir de la cual el aterrizaje tiene la intensidad completa.
@export var land_full_impact: float = 7.0
## Multiplicador de velocidad de Jump_Land (el clip original es una recepción pesada de 1,3 s).
@export var land_playback_speed: float = 1.6
## Tiempo (s) que el aterrizaje se mantiene a su intensidad antes de desvanecerse.
@export var land_hold_time: float = 0.12
## Duración total (s) del aterrizaje.
@export var land_duration: float = 0.5

var _character: PlayerCharacter = null
var _spine: SpineTwistModifier = null
var _blend_space: AnimationNodeBlendSpace1D = null
## Puntos del BlendSpace ordenados: [posición (m/s), metros por unidad de TimeScale].
var _stride_points: Array[Vector2] = []

var _speed: float = 0.0
var _visual_yaw: float = 0.0
var _yaw_initialized: bool = false
var _air_state: AirState = AirState.GROUNDED
var _air_time: float = 0.0
var _min_vertical_velocity: float = 0.0
var _jump_pending: bool = false
var _air_weight: float = 0.0
var _fall_weight: float = 0.0
var _land_weight: float = 0.0
var _land_time: float = -1.0
var _land_strength: float = 0.0
var _locomotion_scale: float = 0.0
var _move_weight: float = 0.0
var _backpedal: bool = false
## Esquiva en curso (el modelo mira hacia su rumbo) y cuánto de la compensación de la columna se aplica (0 a 1).
var _dodging: bool = false
var _twist_weight: float = 1.0
## Segundos que lleva la acción de cambio de arma en curso.
var _swap_elapsed: float = 0.0
var _combat_layer: CombatAnimationLayer = null
var _combat_modifier: CombatPoseModifier = null
## Origen del byte action de un remoto: devuelve el byte del registro dibujado. Si no es válido, la
## acción sale del [member PlayerCharacter.combat] del personaje.
var _remote_source: Callable = Callable()
## Arma activa de un remoto (devuelve su id); si no es válido, la del estado del personaje.
var _remote_weapon_source: Callable = Callable()
var _shown_weapon: int = -1
# Último valor avisado por [signal swing_active_changed].
var _swing_shown: bool = false
# Última acción de un remoto avisada por [signal remote_action_started] y su paso (-1 = ninguna).
var _remote_action_seen: int = -1
var _remote_step_seen: int = -1
# Carga del fuerte: si se está avisando y los segundos que lleva un remoto cargando.
var _charging: bool = false
var _remote_charge_s: float = 0.0


func _ready() -> void:
	# Antes que el AnimationTree (prioridad 0), para que los parámetros de este fotograma se
	# apliquen en este mismo fotograma y no en el siguiente.
	process_priority = -1
	if animation_tree == null:
		animation_tree = get_node_or_null(^"../AnimationTree") as AnimationTree
	if pivot == null:
		pivot = get_node_or_null(^"../Pivot") as Node3D
	_cache_locomotion_strides()
	if _character == null:
		set_character(_find_character())


## Personaje que se decora. Puede cambiarse en cualquier momento (o pasar null para soltarlo).
func set_character(character: PlayerCharacter) -> void:
	if _character == character:
		return
	if is_instance_valid(_character):
		if _character.jumped.is_connected(_on_jumped):
			_character.jumped.disconnect(_on_jumped)
	_character = character
	_yaw_initialized = false
	_air_state = AirState.GROUNDED
	_air_weight = 0.0
	_fall_weight = 0.0
	_land_weight = 0.0
	_land_time = -1.0
	if is_instance_valid(_character):
		_character.jumped.connect(_on_jumped)


## Personaje decorado (o null).
func get_character() -> PlayerCharacter:
	return _character


## Coloca el modelo al instante mirando como la simulación, sin giro suave. Para después de un
## teletransporte o una reaparición (junto con [method Node.reset_physics_interpolation]).
func reset_facing() -> void:
	_yaw_initialized = false
	_backpedal = false
	_dodging = false
	_twist_weight = 1.0
	if pivot != null:
		pivot.rotation = Vector3.ZERO
	if _spine != null:
		_spine.twist = 0.0


## Modificador que gira la columna (lo crea [HumanoidVisual] bajo su esqueleto).
func set_spine_modifier(modifier: SpineTwistModifier) -> void:
	_spine = modifier


## Modificador que aplica la pose de combate al esqueleto (lo crea [HumanoidVisual] bajo el
## esqueleto, antes del de la columna). Crea la capa de combate con [member clip_set].
func set_combat_modifier(modifier: CombatPoseModifier) -> void:
	_combat_modifier = modifier
	if _combat_layer == null:
		_combat_layer = CombatAnimationLayer.new(clip_set)
	if _combat_modifier != null:
		_combat_modifier.layer = _combat_layer


## Hace que la acción de combate salga del byte [code]action[/code] que devuelve [param source]
## (el registro dibujado de un remoto) en lugar del estado del personaje, y el arma activa de
## [param weapon_source] (el id que dice su vista). Un [Callable] no válido vuelve al estado del personaje.
func set_remote_source(source: Callable, weapon_source: Callable = Callable()) -> void:
	_remote_source = source
	_remote_weapon_source = weapon_source
	if _combat_layer != null:
		_combat_layer.reset()
	_set_swing_shown(false)


## Arma que se ve ahora en las manos (-1 antes del primer fotograma).
func get_shown_weapon() -> int:
	return _shown_weapon


## Capa de animación de combate (null hasta [method set_combat_modifier]).
func get_combat_layer() -> CombatAnimationLayer:
	return _combat_layer


## Modificador que pone la pose de combate (o null).
func get_combat_modifier() -> CombatPoseModifier:
	return _combat_modifier


## Estado interno para depuración y pruebas visuales.
func get_debug_state() -> Dictionary:
	return {
		"speed": _speed,
		"locomotion_scale": _locomotion_scale,
		"move": _move_weight,
		"air_state": AirState.keys()[_air_state],
		"air": _air_weight,
		"fall": _fall_weight,
		"land": _land_weight,
		"facing_offset_deg": rad_to_deg(pivot.rotation.y) if pivot != null else 0.0,
		"backpedal": _backpedal,
		"dodging": _dodging,
		"spine_twist_deg": rad_to_deg(_spine.twist) if _spine != null else 0.0,
		"combat": _combat_debug(),
	}


func _process(delta: float) -> void:
	if not is_instance_valid(_character) or animation_tree == null or pivot == null:
		return
	var velocity: Vector3 = _character.velocity
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var real_speed: float = horizontal.length()
	_speed = lerpf(_speed, real_speed, 1.0 - exp(-speed_smoothing * delta))

	_update_air(delta, velocity.y)
	_update_facing(delta, horizontal, real_speed)
	_update_locomotion()

	animation_tree.set(PARAM_AIR, _air_weight)
	animation_tree.set(PARAM_AIR_PHASE, _fall_weight)
	animation_tree.set(PARAM_LAND, _land_weight)

	_update_combat(delta)


# --- Combate -----------------------------------------------------------------------------------

# Alimenta la capa de combate con la acción de este fotograma.
func _update_combat(delta: float) -> void:
	var weapon_id: int = _character.combat.weapon_id
	if _remote_source.is_valid() and _remote_weapon_source.is_valid():
		weapon_id = int(_remote_weapon_source.call())
	if _current_action() == CombatState.Action.SWAP:
		_swap_elapsed += delta
	else:
		_swap_elapsed = 0.0
	# En pleno cambio de arma los accesorios esperan a la mitad del gesto; si la acción acaba antes (o no hay
	# cambio de arma, sino un equipo nuevo), cambian ya.
	var swapping_in_place: bool = _shown_weapon >= 0 and _swap_elapsed > 0.0 \
			and _swap_elapsed < _swap_show_seconds()
	if weapon_id != _shown_weapon and not swapping_in_place:
		_shown_weapon = weapon_id
		weapon_shown.emit(weapon_id)
	if _combat_layer == null:
		return
	var moving: bool = _character.get_horizontal_speed() > CRAWL_MIN_SPEED
	if _remote_source.is_valid():
		_combat_layer.update_remote(int(_remote_source.call()), delta, weapon_id, moving)
	else:
		_combat_layer.update_local(_character.combat, _character.last_input_tick,
				Engine.get_physics_interpolation_fraction(), delta, moving)
	_set_swing_shown(_combat_layer.is_swing_active())
	_update_charge(delta, weapon_id)
	_observe_remote_action()


# Avisa de la carga del fuerte ([signal charge_changed]): la fracción sale del estado en el jugador local y del
# tiempo que se ve cargar a un remoto.
func _update_charge(delta: float, weapon_id: int) -> void:
	var charging: bool = _current_action() == CombatState.Action.CHARGE
	if not charging:
		_remote_charge_s = 0.0
		if _charging:
			_charging = false
			charge_changed.emit(false, 0.0)
		return
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id) if weapon != null else null
	var full_ticks: float = float(maxi(heavy.charge_max_ticks, 1)) if heavy != null else 72.0
	var elapsed_ticks: float = 0.0
	if _remote_source.is_valid():
		_remote_charge_s += delta
		elapsed_ticks = _remote_charge_s * float(Engine.physics_ticks_per_second)
	else:
		elapsed_ticks = float(_character.last_input_tick - _character.combat.action_tick) \
				+ Engine.get_physics_interpolation_fraction()
	_charging = true
	charge_changed.emit(true, clampf(elapsed_ticks / full_ticks, 0.0, 1.0))


# Avisa de las acciones nuevas de un remoto ([signal remote_action_started]).
func _observe_remote_action() -> void:
	if not _remote_source.is_valid():
		return
	var byte: int = int(_remote_source.call())
	var action: int = byte & 15
	var step: int = ActionWire.step_of(byte)
	if action == CombatState.Action.NONE or action > CombatState.Action.EXECUTE:
		_remote_action_seen = -1
		_remote_step_seen = -1
		return
	if action != _remote_action_seen or step != _remote_step_seen:
		_remote_action_seen = action
		_remote_step_seen = step
		remote_action_started.emit(action, step)


## true si este animador lo conduce un remoto (la acción sale del byte de su registro).
func is_remote() -> bool:
	return _remote_source.is_valid()


# Avisa por [signal swing_active_changed] solo cuando el estado cambia.
func _set_swing_shown(swinging: bool) -> void:
	if swinging != _swing_shown:
		_swing_shown = swinging
		swing_active_changed.emit(swinging)


## Acción de combate de este fotograma (un [enum CombatState.Action]): la del byte del registro dibujado de un remoto
## o la del estado del personaje.
func get_current_action() -> int:
	return _current_action()


# Acción de combate de este fotograma: la del byte del registro dibujado de un remoto o la del estado del
# personaje.
func _current_action() -> int:
	if _remote_source.is_valid():
		return int(_remote_source.call()) & 15
	return _character.combat.action


# Segundos desde el inicio del cambio de arma a los que cambian los accesorios.
func _swap_show_seconds() -> float:
	return float(CombatCatalog.tables().swap_ticks) / float(Engine.physics_ticks_per_second) * swap_show_fraction


func _combat_debug() -> Dictionary:
	if _combat_layer == null:
		return {}
	var current: CombatAnimationLayer.Slot = _combat_layer.get_current()
	if current == null:
		return {"active": false}
	return {
		"active": true,
		"key": current.key,
		"animation": current.animation_name,
		"time": current.time_s,
		"speed": current.speed,
		"weight": current.weight,
		"upper_body": current.upper_body,
	}


# --- Locomoción --------------------------------------------------------------------------------

## Lee los puntos del BlendSpace de locomoción y calcula, para cada uno, cuántos metros avanza el
## clip por cada unidad de TimeScale (zancada / duración de su ciclo en el árbol).
func _cache_locomotion_strides() -> void:
	_stride_points.clear()
	if animation_tree == null:
		return
	var root: AnimationNodeBlendTree = animation_tree.tree_root as AnimationNodeBlendTree
	if root == null or not root.has_node(LOCOMOTION_NODE):
		push_error("[CharacterAnimator] El árbol no tiene el nodo '%s'" % LOCOMOTION_NODE)
		return
	_blend_space = root.get_node(LOCOMOTION_NODE) as AnimationNodeBlendSpace1D
	if _blend_space == null:
		push_error("[CharacterAnimator] '%s' no es un BlendSpace1D" % LOCOMOTION_NODE)
		return
	for i: int in _blend_space.get_blend_point_count():
		var node: AnimationNodeAnimation = _blend_space.get_blend_point_node(i) as AnimationNodeAnimation
		if node == null:
			continue
		var animation: Animation = animation_tree.get_animation(node.animation)
		if animation == null or not clip_ground_speeds.has(node.animation):
			push_warning("[CharacterAnimator] Sin velocidad sobre el suelo para '%s'" % node.animation)
			continue
		var stride: float = clip_ground_speeds[node.animation] * animation.length
		var cycle: float = animation.length
		if node.use_custom_timeline and node.stretch_time_scale:
			cycle = node.timeline_length
		_stride_points.append(Vector2(_blend_space.get_blend_point_position(i), stride / cycle))
	_stride_points.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)


func _update_locomotion() -> void:
	var blend: float = _speed
	if _blend_space != null:
		blend = clampf(_speed, _blend_space.min_space, _blend_space.max_space)
	var meters_per_unit: float = _stride_at(blend)
	_locomotion_scale = 0.0
	if meters_per_unit > 0.0:
		_locomotion_scale = clampf(_speed / meters_per_unit, 0.0, max_locomotion_scale)
	# Retroceso: el mismo ciclo al revés (la zancada vale igual en los dos sentidos).
	if _backpedal:
		_locomotion_scale = -_locomotion_scale
	_move_weight = clampf(_speed / maxf(idle_blend_speed, 0.001), 0.0, 1.0)
	_move_weight = _move_weight * _move_weight * (3.0 - 2.0 * _move_weight)
	animation_tree.set(PARAM_LOCOMOTION_BLEND, blend)
	animation_tree.set(PARAM_LOCOMOTION_SCALE, _locomotion_scale)
	animation_tree.set(PARAM_MOVE, _move_weight)


## Metros por unidad de TimeScale en la posición [param blend], interpolando linealmente entre los
## puntos del BlendSpace igual que lo hace el propio BlendSpace1D.
func _stride_at(blend: float) -> float:
	if _stride_points.is_empty():
		return 0.0
	if blend <= _stride_points[0].x:
		return _stride_points[0].y
	for i: int in range(1, _stride_points.size()):
		var a: Vector2 = _stride_points[i - 1]
		var b: Vector2 = _stride_points[i]
		if blend <= b.x:
			var t: float = (blend - a.x) / maxf(b.x - a.x, 0.0001)
			return lerpf(a.y, b.y, t)
	return _stride_points[_stride_points.size() - 1].y


# --- Orientación -------------------------------------------------------------------------------

func _update_facing(delta: float, horizontal: Vector3, real_speed: float) -> void:
	var parent: Node3D = pivot.get_parent() as Node3D
	if parent == null:
		return
	var base_yaw: float = _yaw_of(parent.get_global_transform_interpolated().basis)
	if not _yaw_initialized:
		_visual_yaw = base_yaw
		_yaw_initialized = true
	# Esquiva: el modelo mira hacia donde se viaja desde el primer fotograma, sin giro suave ni compensación de
	# la columna (ART-49).
	if _current_action() == CombatState.Action.DODGE:
		var dodge_yaw: float = _dodge_heading(horizontal, real_speed)
		if not _dodging:
			_dodging = true
			_backpedal = false
			_twist_weight = 0.0
		if not is_nan(dodge_yaw):
			# El giro de entrada se reparte en unos 0,08 s (antes era un salto de hasta 180 grados en un fotograma).
			var dodge_diff: float = angle_difference(_visual_yaw, dodge_yaw)
			var dodge_step: float = dodge_diff * (1.0 - exp(-DODGE_TURN_SHARPNESS * delta))
			var dodge_max: float = PI / DODGE_TURN_TIME * delta
			_visual_yaw = wrapf(_visual_yaw + clampf(dodge_step, -dodge_max, dodge_max), -PI, PI)
		pivot.rotation = Vector3(0.0, angle_difference(base_yaw, _visual_yaw), 0.0)
		if _spine != null:
			_spine.twist = 0.0
		return
	_dodging = false
	_twist_weight = move_toward(_twist_weight, 1.0, delta / maxf(dodge_twist_return_time, 0.001))
	var target_yaw: float = base_yaw
	if real_speed > turn_min_speed:
		var move_yaw: float = atan2(-horizontal.x, -horizontal.z)
		var relative: float = absf(rad_to_deg(angle_difference(base_yaw, move_yaw)))
		if _backpedal and relative < backpedal_exit_angle:
			_backpedal = false
		elif not _backpedal and relative > backpedal_enter_angle:
			_backpedal = true
		target_yaw = wrapf(move_yaw + PI, -PI, PI) if _backpedal else move_yaw
	elif real_speed < turn_min_speed * 0.5:
		_backpedal = false
	var diff: float = angle_difference(_visual_yaw, target_yaw)
	var step: float = diff * (1.0 - exp(-turn_sharpness * delta))
	var max_step: float = max_turn_speed * delta
	_visual_yaw = wrapf(_visual_yaw + clampf(step, -max_step, max_step), -PI, PI)
	var offset: float = angle_difference(base_yaw, _visual_yaw)
	pivot.rotation = Vector3(0.0, offset, 0.0)
	# La columna devuelve el pecho y la cabeza hacia el punto de mira.
	if _spine != null:
		var limit: float = deg_to_rad(max_spine_twist)
		_spine.twist = -clampf(offset, -limit, limit) * _twist_weight


# Rumbo (yaw) de la esquiva en curso: el del estado del personaje si es el local (la simulación lo fija al
# empezar) o el de su velocidad si es un remoto; NAN si aún no se sabe.
func _dodge_heading(horizontal: Vector3, real_speed: float) -> float:
	if not _remote_source.is_valid():
		return CombatState.dequantize_yaw(_character.combat.action_dir)
	if real_speed > dodge_min_speed:
		return atan2(-horizontal.x, -horizontal.z)
	return NAN


## Yaw (convención de [member Node3D.rotation].y: 0 mira hacia -Z) de una base.
static func _yaw_of(basis: Basis) -> float:
	return atan2(basis.z.x, basis.z.z)


# --- Aire --------------------------------------------------------------------------------------

func _on_jumped() -> void:
	_jump_pending = true


func _update_air(delta: float, vertical_velocity: float) -> void:
	var airborne: bool = not _character.grounded
	if airborne:
		_air_time += delta
		_min_vertical_velocity = minf(_min_vertical_velocity, vertical_velocity)
		var jump_started: bool = _jump_pending and vertical_velocity > 0.0
		if not jump_started and _air_state == AirState.GROUNDED and _air_time <= delta * 1.5:
			jump_started = vertical_velocity > jump_detect_velocity
		if jump_started:
			_start_jump()
		elif _air_state == AirState.GROUNDED and _air_time >= fall_grace_time:
			_start_fall()
		if _air_state == AirState.JUMPING and vertical_velocity < fall_blend_velocity:
			_air_state = AirState.FALLING
	elif _air_state != AirState.GROUNDED:
		_land()
	if not airborne:
		_air_time = 0.0
		_min_vertical_velocity = 0.0
	_jump_pending = false

	var air_target: float = 0.0 if _air_state == AirState.GROUNDED else 1.0
	var air_rate: float = 1.0 / maxf(air_blend_in_time if air_target > _air_weight else air_blend_out_time, 0.001)
	_air_weight = move_toward(_air_weight, air_target, air_rate * delta)
	if _air_state == AirState.FALLING:
		_fall_weight = move_toward(_fall_weight, 1.0, delta / maxf(fall_blend_time, 0.001))

	if _land_time >= 0.0:
		_land_time += delta
		var fade_in: float = clampf(_land_time / 0.04, 0.0, 1.0)
		var fade_out: float = 1.0 - smoothstep(land_hold_time, land_duration, _land_time)
		_land_weight = _land_strength * fade_in * fade_out
		if _land_time >= land_duration:
			_land_time = -1.0
			_land_weight = 0.0


func _start_jump() -> void:
	jumped_visual.emit()
	_air_state = AirState.JUMPING
	_air_time = 0.0
	_min_vertical_velocity = 0.0
	_fall_weight = 0.0
	_land_time = -1.0
	_land_weight = 0.0
	animation_tree.set(PARAM_JUMP_SEEK, jump_takeoff_time)


func _start_fall() -> void:
	_air_state = AirState.FALLING
	if _air_weight <= 0.0:
		_fall_weight = 1.0


func _land() -> void:
	var impact: float = -_min_vertical_velocity
	_air_state = AirState.GROUNDED
	var impact_factor: float = clampf(inverse_lerp(land_min_impact, land_full_impact, impact), 0.0, 1.0)
	var run_factor: float = clampf(_speed / maxf(_character.run_speed, 0.001), 0.0, 1.0)
	_land_strength = lerpf(land_strength_idle, land_strength_moving, run_factor) * impact_factor
	if impact > 0.5:
		touched_down.emit(clampf(maxf(impact_factor, 0.15), 0.0, 1.0))
	if _land_strength > 0.01:
		_land_time = 0.0
		animation_tree.set(PARAM_LAND_SEEK, 0.0)
		animation_tree.set(PARAM_LAND_SCALE, land_playback_speed)


func _find_character() -> PlayerCharacter:
	var node: Node = get_parent()
	while node != null:
		if node is PlayerCharacter:
			return node as PlayerCharacter
		node = node.get_parent()
	return null
