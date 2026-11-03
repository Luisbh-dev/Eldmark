class_name CameraRig
extends Node3D
## Cámara de acción en tercera persona por encima del hombro (estilo New World).
##
## Solo cliente. Jerarquía de la escena:
## [codeblock]
## CameraRig (top_level, sigue al objetivo)
##     Yaw (rotation.y = yaw)
##         Pitch (rotation.x = pitch, positivo mira hacia arriba)
##             Arm (SpringArm3D: forma, margen, máscara y exclusiones)
##                 Camera (Camera3D, h_offset = hombro)
## [/codeblock]
## - El pivote sigue cada frame la posición [b]interpolada[/b] del objetivo
##   ([method Node3D.get_global_transform_interpolated]) con un suavizado
##   exponencial, así la imagen va fluida a cualquier tasa de refresco aunque el
##   personaje solo se mueva en los ticks de física.
## - Al saltar, el pivote solo sube una parte del salto ([member air_follow_ratio])
##   y nunca más de lo que deja un techo bajo, para que la cámara no se meta en la
##   cabeza del personaje al saltar en un pasillo o bajo una puerta.
## - El ratón capturado gira [code]Yaw[/code] y [code]Pitch[/code] sin
##   suavizado: apuntar es inmediato.
## - El brazo sale centrado en la cabeza y el desplazamiento al hombro se hace
##   con [member Camera3D.h_offset]; así el barrido de colisión nunca empieza
##   dentro de una pared.
## - Colisión: cada frame se barre la esfera del brazo hacia atrás y después
##   hacia el hombro. Si algo se interpone, la cámara se acerca al instante; al
##   liberarse el hueco vuelve con suavidad. Nunca atraviesa paredes.
## - Si una pared tapa el hombro elegido y el otro está libre, la cámara pasa
##   temporalmente al otro hombro para que el personaje no tape el punto de mira.
## [br][br]El [SpringArm3D] de Godot solo recalcula su longitud en los ticks de
## física (60 Hz) y, con el rig moviéndose en [method _process], eso produce
## saltos a tasas de refresco altas y permite atravesar paredes durante un
## frame. Por eso se desactiva su procesado interno y el barrido equivalente se
## hace aquí cada frame, usando la configuración del propio nodo [code]Arm[/code].

## Fracción del desplazamiento del hombro que debe estar libre para usar ese lado
## (al cambiar de hombro automáticamente y al volver al elegido).
const AUTO_SWAP_CLEAR_RATIO: float = 0.9
## Metros de histéresis al volver a mostrar el nodo oculto por cercanía.
const HIDE_HYSTERESIS: float = 0.15
## Grupo en el que está toda cámara de acción: los ajustes ([ClientSettings]) lo usan para aplicarles
## sensibilidad, invertir Y, campo de visión y hombro por defecto en vivo.
const GROUP: StringName = &"camera_rig"
## Radianes por píxel con la sensibilidad del ratón a 1 en los ajustes.
const DEFAULT_MOUSE_SENSITIVITY: float = 0.0025
## Frecuencia (rad/s) de las dos ondas que forman la sacudida de impacto.
const SHAKE_FREQUENCY_X: float = 61.0
const SHAKE_FREQUENCY_Y: float = 47.0
## Amplitud máxima (m) de una sacudida, por muy fuerte que sea el golpe.
const MAX_SHAKE_AMPLITUDE: float = 0.25
## Fracción del campo de visión configurado con la puntería del arco al máximo
## ([method set_aim_zoom] a 1; docs/habilidades.md, sección 6.5).
const AIM_ZOOM_FOV_SCALE: float = 0.75

## Radianes de giro por píxel de movimiento del ratón.
@export var mouse_sensitivity: float = DEFAULT_MOUSE_SENSITIVITY
## Invierte el eje vertical del ratón.
@export var invert_y: bool = false

@export_group("Seguimiento")
## Rapidez (1/s) con la que el pivote alcanza al objetivo. Más alto, más rígido.
@export var follow_sharpness: float = 25.0
## Si el objetivo salta más lejos que esto (teletransporte, corrección del
## servidor), la cámara se recoloca de golpe en lugar de deslizarse.
@export var snap_distance: float = 6.0
## Fracción de la subida de un salto que sigue el pivote (0 = no sube al saltar,
## 1 = sigue todo el salto). Seguir solo una parte deja el horizonte más quieto al
## apuntar en el aire. Al caer por debajo de la altura de partida se sigue entero.
@export_range(0.0, 1.0, 0.05) var air_follow_ratio: float = 0.5

@export_group("Ángulos")
## Inclinación mínima en grados (negativo mira hacia abajo).
@export_range(-89.0, 0.0, 0.5) var min_pitch_degrees: float = -75.0
## Inclinación máxima en grados (positivo mira hacia arriba).
@export_range(0.0, 89.0, 0.5) var max_pitch_degrees: float = 60.0

@export_group("Zoom")
## Metros que cambia la distancia con cada paso de la rueda.
@export var zoom_step: float = 0.5
## Distancia mínima del brazo.
@export var min_distance: float = 1.5
## Distancia máxima del brazo.
@export var max_distance: float = 6.0
## Rapidez (1/s) con la que la distancia alcanza el zoom pedido.
@export var zoom_sharpness: float = 12.0
## Rapidez (1/s) con la que el campo de visión sigue a la puntería del arco ([method set_aim_zoom]).
@export var aim_zoom_sharpness: float = 10.0

@export_group("Sacudida")
## Si es false, [method add_shake] no mueve la cámara (opción del jugador).
@export var shake_enabled: bool = true

@export_group("Hombro y colisión")
## Rapidez (1/s) del cambio de hombro.
@export var shoulder_sharpness: float = 10.0
## Rapidez (1/s) con la que la cámara recupera su sitio cuando un obstáculo deja
## de taparla. Acercarse por colisión siempre es instantáneo.
@export var collision_recover_sharpness: float = 8.0
## Si una pared le quita al hombro elegido más de esta fracción del desplazamiento
## y el otro lado está libre, la cámara pasa temporalmente al otro hombro.
@export_range(0.0, 1.0, 0.05) var auto_swap_blocked_ratio: float = 0.5
## Segundos que el hombro elegido debe estar libre antes de volver a él.
@export var auto_swap_return_delay: float = 0.6
## Distancia (m) entre la cámara y el objetivo por debajo de la cual se oculta el
## nodo de [method set_hide_when_close], para no ver el interior del personaje.
@export var hide_target_distance: float = 0.8

var _target: Node3D = null
## Cuerpo del objetivo (el excluido de la colisión), para saber si está en el aire.
var _target_body: CharacterBody3D = null
## Altura del objetivo la última vez que su cuerpo pisaba el suelo.
var _ground_height: float = 0.0
var _snap_pending: bool = true
var _yaw: float = 0.0
var _pitch: float = 0.0

## Cursor liberado de forma persistente (Esc, pérdida de foco, arranque sin foco).
var _free_toggled: bool = false
## Cursor liberado mientras se mantiene la tecla (Alt).
var _free_held: bool = false
## La vista la controla un guion (demo): no se captura ni se lee el ratón.
var _scripted_look: bool = false
## Quién de la interfaz (la pantalla de muerte, una ventana, un diálogo) pide el cursor libre
## mientras está abierto: id de instancia del solicitante -> true. Varios pueden pedirlo a la vez y
## el ratón solo se recaptura cuando ya no queda ninguno.
var _ui_cursor_holders: Dictionary = {}

var _zoom_target: float = 3.5
var _zoom_distance: float = 3.5
var _shoulder_offset: float = 0.6
var _shoulder_side: float = 1.0
var _shoulder_blend: float = 1.0
## Hombro temporal (-1 o 1) cuando el elegido está tapado; 0 = se usa el elegido.
var _shoulder_override: float = 0.0
## Segundos seguidos que el hombro elegido lleva libre mientras se usa el otro.
var _override_clear_time: float = 0.0
## Posición del ojo de la cámara respecto al pivote en el último frame (global).
var _eye_offset: Vector3 = Vector3.ZERO
## Nodo que se oculta cuando la cámara está demasiado cerca del objetivo.
var _hide_node: Node3D = null
## Metros que la colisión le quita a la distancia y al hombro ahora mismo.
var _distance_pull: float = 0.0
var _offset_pull: float = 0.0

## Sacudida de impacto: amplitud inicial (m), duración y tiempo que le queda (s), reloj de sus
## ondas y desplazamiento (x = horizontal, y = vertical) que se suma a la cámara.
var _shake_amplitude: float = 0.0
var _shake_duration: float = 0.0
var _shake_time_left: float = 0.0
var _shake_clock: float = 0.0
var _shake_offset: Vector2 = Vector2.ZERO
## Desplazamiento vertical de la cámara de la escena (sin sacudida).
var _base_v_offset: float = 0.0
## Campo de visión vertical configurado (escena o ajustes), sin la puntería del arco.
var _configured_fov: float = 72.0
## Puntería del arco pedida (0 a 1) y la que se aplica ahora (la sigue con suavidad).
var _aim_zoom_target: float = 0.0
var _aim_zoom: float = 0.0

var _exclude: Array[RID] = []
var _query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
var _fallback_shape: SphereShape3D = null

@onready var _yaw_node: Node3D = $Yaw
@onready var _pitch_node: Node3D = $Yaw/Pitch
@onready var _arm: SpringArm3D = $Yaw/Pitch/Arm
@onready var _camera: Camera3D = $Yaw/Pitch/Arm/Camera


func _ready() -> void:
	InputBindings.ensure_defaults()
	add_to_group(GROUP)
	# Se mueve en _process con la posición ya interpolada: no debe volver a
	# interpolarse. Los hijos (brazo y cámara) heredan el modo.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	top_level = true

	_disable_builtin_spring()
	_arm.tree_entered.connect(_disable_builtin_spring)
	for rid: RID in _exclude:
		_arm.add_excluded_object(rid)

	_zoom_target = clampf(_arm.spring_length, min_distance, max_distance)
	_zoom_distance = _zoom_target
	_shoulder_offset = absf(_camera.h_offset)
	_base_v_offset = _camera.v_offset
	_configured_fov = _camera.fov
	_shoulder_side = -1.0 if _camera.h_offset < 0.0 else 1.0
	_shoulder_blend = _shoulder_side

	_query.collide_with_bodies = true
	_query.collide_with_areas = false

	# Una ventana que se abre sin foco (una captura automática, otra instancia) no se queda con el
	# ratón de quien está trabajando en otra ventana: empieza con el cursor suelto y un clic lo captura.
	if starts_with_free_cursor(get_window()):
		_free_toggled = true
	_apply_look()
	_refresh_mouse_mode()
	# Lo que el jugador tiene guardado en los ajustes (solo lo que ha cambiado él).
	ClientSettings.current().apply_to_camera(self, true)


func _process(delta: float) -> void:
	_poll_free_cursor()
	_update_follow(delta)
	_zoom_distance = lerpf(_zoom_distance, _zoom_target, _smoothing(zoom_sharpness, delta))
	_update_aim_zoom(delta)
	_update_shake(delta)
	_update_collision(delta)


func _input(event: InputEvent) -> void:
	# La tecla de liberar el cursor se atiende aquí (antes que la interfaz) para
	# que soltarla siempre recapture el ratón.
	if event.is_action(&"free_cursor"):
		_set_free_held(event.is_pressed())
		return
	# El giro con el ratón también va aquí: mientras el ratón está capturado
	# ningún control de la interfaz debe poder quedarse con el movimiento.
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion == null or not _is_mouse_look_active():
		return
	# screen_relative: píxeles reales, sin el escalado del modo de estiramiento,
	# para que la sensibilidad no cambie con el tamaño de la ventana.
	var turn: Vector2 = motion.screen_relative * mouse_sensitivity
	var pitch_sign: float = 1.0 if invert_y else -1.0
	set_look(_yaw - turn.x, _pitch + turn.y * pitch_sign)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_cursor"):
		_free_toggled = not _free_toggled
		_refresh_mouse_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"shoulder_swap"):
		_shoulder_side = -_shoulder_side
		_shoulder_override = 0.0
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"zoom_in"):
		_zoom_target = clampf(_zoom_target - zoom_step, min_distance, max_distance)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"zoom_out"):
		_zoom_target = clampf(_zoom_target + zoom_step, min_distance, max_distance)
		get_viewport().set_input_as_handled()
	elif _free_toggled and not _scripted_look:
		# Con el cursor suelto, un clic que no ha usado la interfaz recaptura.
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_free_toggled = false
			_refresh_mouse_mode()
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			# Al cambiar de ventana se suelta el ratón; un clic lo recaptura.
			_free_toggled = true
			_free_held = false
			_refresh_mouse_mode()
		NOTIFICATION_EXIT_TREE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			if is_instance_valid(_hide_node):
				_hide_node.visible = true


## Sigue a [param target] (normalmente el marcador de la cabeza del personaje).
## [param exclude] es el cuerpo del propio personaje, que la cámara ignora al
## comprobar colisiones; si es un [CharacterBody3D], también se usa para saber
## cuándo está en el aire. El primer frame se coloca sin suavizado.
func set_target(target: Node3D, exclude: CollisionObject3D = null) -> void:
	_target = target
	_target_body = exclude as CharacterBody3D
	_snap_pending = true
	if exclude != null:
		var rid: RID = exclude.get_rid()
		if not _exclude.has(rid):
			_exclude.append(rid)
			if is_node_ready():
				_arm.add_excluded_object(rid)
	if is_inside_tree() and _has_target():
		_update_follow(0.0)


## Yaw de la vista en radianes, en [-PI, PI]. Misma convención que
## [member Node3D.rotation].y: 0 mira hacia -Z.
func get_yaw() -> float:
	return wrapf(_yaw, -PI, PI)


## Inclinación de la vista en radianes; positivo mira hacia arriba.
func get_pitch() -> float:
	return _pitch


## Campo de visión vertical configurado, en grados (el de los ajustes: sin el cierre de la puntería del
## arco, que lo reduce en la cámara mientras se tensa).
func get_fov() -> float:
	return _configured_fov


## Fija el campo de visión vertical configurado, en grados (ajustes del jugador). La puntería del arco
## lo cierra después sobre este valor.
func set_fov(degrees: float) -> void:
	_configured_fov = degrees
	_apply_fov()


## Puntería del arco (docs/habilidades.md, sección 6.5): con [param amount] de 0 (nada) a 1 (tensado), el
## campo de visión de la cámara se cierra hasta [constant AIM_ZOOM_FOV_SCALE] del configurado, con
## suavidad ([member aim_zoom_sharpness]). No toca el brazo ni el hombro: el rayo canónico de la puntería
## no cambia.
func set_aim_zoom(amount: float) -> void:
	_aim_zoom_target = clampf(amount, 0.0, 1.0)


## Puntería del arco pedida (0 a 1, [method set_aim_zoom]).
func get_aim_zoom() -> float:
	return _aim_zoom_target


## Campo de visión vertical que tiene ahora la cámara (el configurado con el cierre de la puntería).
func get_effective_fov() -> float:
	return _camera.fov if _camera != null else _configured_fov


## Hombro elegido: 1 derecho, -1 izquierdo (sin contar el cambio temporal por una pared).
func get_chosen_shoulder() -> int:
	return -1 if _shoulder_side < 0.0 else 1


## Hombro por el que se mira ahora: 1 derecho, -1 izquierdo, contando el cambio temporal por una pared.
## Es el que pone el bit [constant PlayerInput.AIM_LEFT] de las entradas (docs/habilidades.md, sección
## 6.5).
func get_effective_shoulder() -> int:
	return -1 if _get_shoulder_side() < 0.0 else 1


## Elige el hombro por el que se mira, 1 derecho o -1 izquierdo (el valor por defecto de los
## ajustes; la tecla de cambio de hombro lo alterna después). El cambio es suave.
func set_default_shoulder(side: int) -> void:
	_shoulder_side = -1.0 if side < 0 else 1.0
	_shoulder_override = 0.0


## Fija la vista. El pitch se limita a [[member min_pitch_degrees],
## [member max_pitch_degrees]].
func set_look(yaw: float, pitch: float) -> void:
	_yaw = wrapf(yaw, -PI, PI)
	_pitch = clampf(pitch, deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
	_apply_look()


## true si el jugador ha liberado el cursor (Alt mantenido, Esc o pérdida de
## foco): la cámara no gira y los clics son para la interfaz.
func is_cursor_free() -> bool:
	if _scripted_look:
		return false
	return _free_toggled or _free_held or _has_ui_cursor_holders()


## Un elemento de la interfaz ([param holder]: la pantalla de muerte, una ventana, un diálogo) libera
## el cursor mientras esté abierto: la cámara no gira, los clics son para él y el punto de mira se
## oculta. Al cerrarlo ([param enabled] a false) deja de pedirlo, y el ratón se recaptura solo si no
## queda ningún otro solicitante ni lo ha soltado el jugador a mano. Cada solicitante cuenta una
## sola vez, pida cuantas veces pida.
func set_ui_cursor_release(enabled: bool, holder: Object) -> void:
	var key: int = holder.get_instance_id()
	if enabled:
		_ui_cursor_holders[key] = true
	else:
		_ui_cursor_holders.erase(key)
	_refresh_mouse_mode()


## true si algún elemento de la interfaz (una ventana, un diálogo, la pantalla de muerte, el mapa o la línea
## del chat) tiene el cursor libre en este momento ([method set_ui_cursor_release]). No cuenta el cursor
## que suelta el jugador a mano (Alt o Esc), ni el que pide [param ignored_holder] si se da.
func is_ui_holding_cursor(ignored_holder: Object = null) -> bool:
	if not _has_ui_cursor_holders():
		return false
	if ignored_holder == null:
		return true
	var ignored_key: int = ignored_holder.get_instance_id()
	for key: int in _ui_cursor_holders.keys():
		if key != ignored_key:
			return true
	return false


# true si algún solicitante vivo sigue pidiendo el cursor libre. Descarta a los que se han liberado
# sin avisar (su id de instancia ya no apunta a nada).
func _has_ui_cursor_holders() -> bool:
	for key: int in _ui_cursor_holders.keys():
		if not is_instance_id_valid(key):
			_ui_cursor_holders.erase(key)
	return not _ui_cursor_holders.is_empty()


func get_camera() -> Camera3D:
	return get_node_or_null(^"Yaw/Pitch/Arm/Camera") as Camera3D


## Rayo de puntería que pasa por el centro de la pantalla (el punto de mira).
## Devuelve [code]{"origin": Vector3, "direction": Vector3}[/code] con la
## dirección normalizada, en coordenadas globales.
func get_aim_ray() -> Dictionary:
	var camera: Camera3D = get_camera()
	if camera == null or not camera.is_inside_tree():
		var look_basis: Basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
		return {"origin": global_position, "direction": look_basis * Vector3.FORWARD}
	var center: Vector2 = camera.get_viewport().get_visible_rect().size * 0.5
	return {
		"origin": camera.project_ray_origin(center),
		"direction": camera.project_ray_normal(center).normalized(),
	}


## Oculta [param node] (normalmente el modelo del personaje) mientras la cámara
## está a menos de [member hide_target_distance] del objetivo, por ejemplo con la
## espalda contra una esquina. null deja de ocultar nada.
func set_hide_when_close(node: Node3D) -> void:
	if is_instance_valid(_hide_node) and _hide_node != node:
		_hide_node.visible = true
	_hide_node = node


## Sacude la cámara un instante, por ejemplo al recibir un golpe (ART-09, básico). Mueve la vista
## [param amplitude] metros (como mucho [constant MAX_SHAKE_AMPLITUDE]) con una oscilación rápida que
## decae a cero en [param duration] segundos. Una sacudida nueva no apaga la que está en curso: se
## queda con la más fuerte de las dos. No hace nada con [member shake_enabled] a false.
func add_shake(amplitude: float, duration: float) -> void:
	if not shake_enabled or amplitude <= 0.0 or duration <= 0.0:
		return
	var remaining: float = _current_shake_amplitude()
	_shake_amplitude = maxf(remaining, minf(amplitude, MAX_SHAKE_AMPLITUDE))
	_shake_duration = duration
	_shake_time_left = duration


## Desplazamiento (m) que la sacudida suma ahora a la cámara: x en horizontal, y en vertical.
func get_shake_offset() -> Vector2:
	return _shake_offset


## true mientras dura una sacudida.
func is_shaking() -> bool:
	return _shake_time_left > 0.0


## Vista guionizada (demo y pruebas automáticas): la cámara no captura el ratón
## ni lee su movimiento y la vista solo cambia con [method set_look].
## [method is_cursor_free] devuelve false para que el punto de mira se siga
## dibujando y la escena se vea igual que jugando.
func set_scripted_look(enabled: bool) -> void:
	_scripted_look = enabled
	_refresh_mouse_mode()


func _has_target() -> bool:
	return is_instance_valid(_target) and _target.is_inside_tree()


func _apply_look() -> void:
	if not is_node_ready():
		return
	_yaw_node.rotation.y = _yaw
	_pitch_node.rotation.x = _pitch


func _update_follow(delta: float) -> void:
	if not _has_target():
		return
	var goal: Vector3 = _target.get_global_transform_interpolated().origin
	var snap: bool = _snap_pending \
			or global_position.distance_squared_to(goal) > snap_distance * snap_distance
	# En el aire el pivote solo sube una parte de lo que suba el objetivo sobre su
	# altura en el suelo; si cae por debajo de ella (un borde), la sigue entera.
	if snap or not _is_target_airborne() or goal.y < _ground_height:
		_ground_height = goal.y
	goal.y = _ground_height + (goal.y - _ground_height) * air_follow_ratio
	if snap:
		global_position = goal
		_snap_pending = false
		# Sin historia previa: la colisión debe resolverse ya, sin suavizar.
		_distance_pull = 0.0
		_offset_pull = 0.0
	else:
		global_position = global_position.lerp(goal, _smoothing(follow_sharpness, delta))
	_clamp_below_ceiling()


## Mientras el pivote está por encima de la altura de suelo del objetivo (en un
## salto), no lo deja subir más de lo que permite el techo, ni a él ni al ojo de
## la cámara. Sin esto, bajo un techo bajo el barrido hacia atrás choca con el
## techo y acorta el brazo de golpe hasta meter la cámara en la cabeza.
func _clamp_below_ceiling() -> void:
	var rise: float = global_position.y - _ground_height
	if rise <= 0.0:
		return
	var base := Vector3(global_position.x, _ground_height, global_position.z)
	var room: float = minf(_sweep(base, Vector3.UP, rise),
			_sweep(base + _eye_offset, Vector3.UP, rise))
	if room < rise:
		global_position.y = _ground_height + room


func _is_target_airborne() -> bool:
	return is_instance_valid(_target_body) and not _target_body.is_on_floor()


## La puntería del arco sigue a la pedida con suavidad y cierra el campo de visión.
func _update_aim_zoom(delta: float) -> void:
	if is_equal_approx(_aim_zoom, _aim_zoom_target):
		if _aim_zoom != _aim_zoom_target:
			_aim_zoom = _aim_zoom_target
			_apply_fov()
		return
	_aim_zoom = lerpf(_aim_zoom, _aim_zoom_target, _smoothing(aim_zoom_sharpness, delta))
	if absf(_aim_zoom - _aim_zoom_target) < 0.001:
		_aim_zoom = _aim_zoom_target
	_apply_fov()


## Campo de visión de la cámara: el configurado, cerrado por la puntería del arco.
func _apply_fov() -> void:
	if _camera == null:
		return
	_camera.fov = _configured_fov * lerpf(1.0, AIM_ZOOM_FOV_SCALE, _aim_zoom)


## Avanza la sacudida de impacto y calcula su desplazamiento de este fotograma.
func _update_shake(delta: float) -> void:
	if _shake_time_left <= 0.0:
		_shake_offset = Vector2.ZERO
		return
	_shake_time_left = maxf(_shake_time_left - delta, 0.0)
	_shake_clock += delta
	var amplitude: float = _current_shake_amplitude()
	_shake_offset = Vector2(sin(_shake_clock * SHAKE_FREQUENCY_X),
			cos(_shake_clock * SHAKE_FREQUENCY_Y)).limit_length(1.0) * amplitude


# Amplitud de la sacudida ahora: decae linealmente hasta 0.
func _current_shake_amplitude() -> float:
	if _shake_time_left <= 0.0 or _shake_duration <= 0.0:
		return 0.0
	return _shake_amplitude * clampf(_shake_time_left / _shake_duration, 0.0, 1.0)


## Coloca la cámara a lo largo del brazo y en el hombro sin meterla en la
## geometría: primero barre hacia atrás desde el pivote y después, desde el
## extremo del brazo, hacia el lado del hombro. Todo el camino
## pivote -> brazo -> ojo queda libre, así el ojo nunca acaba dentro de un muro.
func _update_collision(delta: float) -> void:
	var desired_distance: float = _zoom_distance
	_arm.spring_length = desired_distance

	var pivot: Vector3 = _arm.global_position
	var arm_basis: Basis = _arm.global_basis.orthonormalized()
	var back: Vector3 = arm_basis.z
	var right: Vector3 = arm_basis.x
	var recover: float = _smoothing(collision_recover_sharpness, delta)

	var free_distance: float = _sweep(pivot, back, desired_distance)
	_distance_pull = _resolve_pull(_distance_pull, desired_distance - free_distance, recover)
	var distance: float = maxf(desired_distance - _distance_pull, 0.0)
	var arm_end: Vector3 = pivot + back * distance

	_update_shoulder_override(arm_end, right, delta)
	var side_weight: float = _smoothing(shoulder_sharpness, delta)
	_shoulder_blend = lerpf(_shoulder_blend, _get_shoulder_side(), side_weight)
	var desired_offset: float = _shoulder_offset * _shoulder_blend
	var offset_side: float = signf(desired_offset)
	var offset_length: float = absf(desired_offset)

	var free_offset: float = offset_length
	if offset_length > 0.001:
		free_offset = _sweep(arm_end, right * offset_side, offset_length)
	_offset_pull = _resolve_pull(_offset_pull, offset_length - free_offset, recover)
	var offset: float = offset_side * maxf(offset_length - _offset_pull, 0.0)

	_camera.position = Vector3(0.0, 0.0, distance)
	_camera.h_offset = offset + _shake_offset.x
	_camera.v_offset = _base_v_offset + _shake_offset.y
	_eye_offset = back * distance + right * offset
	_update_hidden_node()


## Hombro que se usa ahora: el temporal si hay uno, si no el elegido.
func _get_shoulder_side() -> float:
	return _shoulder_override if _shoulder_override != 0.0 else _shoulder_side


## Cambio automático de hombro. Si una pared tapa el hombro elegido y el otro está
## libre, se usa el otro; se vuelve al elegido cuando lleva
## [member auto_swap_return_delay] segundos libre, o antes si el otro se tapa más.
## Así el personaje no queda entre la cámara y el punto de mira junto a una pared.
func _update_shoulder_override(arm_end: Vector3, right: Vector3, delta: float) -> void:
	var full: float = _shoulder_offset
	if full <= 0.001:
		_shoulder_override = 0.0
		return
	var free_preferred: float = _sweep(arm_end, right * _shoulder_side, full)
	if _shoulder_override == 0.0:
		if free_preferred < full * auto_swap_blocked_ratio:
			var free_other: float = _sweep(arm_end, right * -_shoulder_side, full)
			if free_other >= full * AUTO_SWAP_CLEAR_RATIO:
				_shoulder_override = -_shoulder_side
				_override_clear_time = 0.0
		return
	if free_preferred >= full * AUTO_SWAP_CLEAR_RATIO:
		_override_clear_time += delta
	else:
		_override_clear_time = 0.0
	var free_override: float = _sweep(arm_end, right * _shoulder_override, full)
	if _override_clear_time >= auto_swap_return_delay or free_override < free_preferred:
		_shoulder_override = 0.0


## Oculta el nodo de [method set_hide_when_close] con la cámara pegada al objetivo
## (con un poco de histéresis para que no parpadee en el límite).
func _update_hidden_node() -> void:
	if not is_instance_valid(_hide_node) or not _has_target():
		return
	var eye: Vector3 = global_position + _eye_offset
	var target_position: Vector3 = _target.get_global_transform_interpolated().origin
	var eye_distance: float = eye.distance_to(target_position)
	if _hide_node.visible and eye_distance < hide_target_distance:
		_hide_node.visible = false
	elif not _hide_node.visible and eye_distance > hide_target_distance + HIDE_HYSTERESIS:
		_hide_node.visible = true


## Distancia libre (en metros, hasta [param distance]) al barrer la esfera del
## brazo desde [param from] en la dirección [param direction], dejando el
## margen del brazo respecto a lo que golpee.
func _sweep(from: Vector3, direction: Vector3, distance: float) -> float:
	if distance <= 0.0 or not is_inside_tree():
		return distance
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return distance
	var margin: float = maxf(_arm.margin, 0.0)
	var travel: float = distance + margin
	_query.shape = _get_sweep_shape()
	_query.collision_mask = _arm.collision_mask
	_query.exclude = _exclude
	_query.transform = Transform3D(Basis.IDENTITY, from)
	_query.motion = direction * travel
	var fractions: PackedFloat32Array = space.cast_motion(_query)
	if fractions.is_empty() or fractions[0] >= 1.0:
		return distance
	return clampf(travel * fractions[0] - margin, 0.0, distance)


func _get_sweep_shape() -> Shape3D:
	if _arm.shape != null:
		return _arm.shape
	if _fallback_shape == null:
		_fallback_shape = SphereShape3D.new()
		_fallback_shape.radius = 0.2
	return _fallback_shape


## La colisión acerca la cámara al instante y la deja volver con suavidad.
static func _resolve_pull(current: float, wanted: float, recover: float) -> float:
	wanted = maxf(wanted, 0.0)
	if wanted >= current:
		return wanted
	return lerpf(current, wanted, recover)


## Factor de suavizado exponencial independiente de la tasa de frames.
static func _smoothing(sharpness: float, delta: float) -> float:
	return 1.0 - exp(-sharpness * delta)


## El SpringArm3D vuelve a activar su procesado interno cada vez que entra en
## el árbol; la colisión de la cámara se resuelve en [method _update_collision].
func _disable_builtin_spring() -> void:
	_arm.set_physics_process_internal(false)


## true si el ratón no debe capturarse al arrancar: arranque con [code]--sin-raton[/code] o con
## [code]ELDMARK_SIN_RATON=1[/code], o una ventana real que no tiene el foco. Sin ventana (pruebas
## headless) se mantiene la captura de siempre.
static func starts_with_free_cursor(window: Window) -> bool:
	if OS.get_cmdline_user_args().has("--sin-raton") or OS.get_environment("ELDMARK_SIN_RATON") == "1":
		return true
	return DisplayServer.get_name() != "headless" and window != null and not window.has_focus()


func _is_mouse_look_active() -> bool:
	return not _scripted_look and not is_cursor_free() \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _poll_free_cursor() -> void:
	# Respaldo por si se pierde el evento de soltar (por ejemplo, Alt+Tab).
	var held: bool = Input.is_action_pressed(&"free_cursor")
	if held != _free_held:
		_set_free_held(held)


func _set_free_held(held: bool) -> void:
	if held == _free_held:
		return
	_free_held = held
	_refresh_mouse_mode()


func _refresh_mouse_mode() -> void:
	if not is_inside_tree():
		return
	var wanted: Input.MouseMode = Input.MOUSE_MODE_CAPTURED
	if _scripted_look or is_cursor_free():
		wanted = Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != wanted:
		Input.mouse_mode = wanted
