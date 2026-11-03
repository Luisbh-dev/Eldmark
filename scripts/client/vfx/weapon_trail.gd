class_name WeaponTrail
extends MeshInstance3D
## Estela del arma (ART-09, solo cliente): una cinta con degradado que sigue el arco del filo.
## [br][br]
## Cada fotograma que está activa toma dos puntos de [member target] (la base y la punta de la hoja,
## [member base_offset] y [member tip_offset] en el espacio local del objetivo) y los guarda con su
## instante. La cinta es la tira de triángulos que une esas muestras, suavizada con una curva de
## Catmull-Rom y pintada por [code]vfx_trail.gdshader[/code]. Al terminar el golpe, [method end] deja de
## añadir muestras y la cinta se apaga sola; no deja nada en pantalla ni gasta tiempo cuando está inactiva.
## [br][br]
## [b]Cuándo se pinta.[/b] La arranca y la para quien la maneja con la ventana activa del golpe
## ([signal CombatFeedback.swing_active_changed], o la marca de la animación): [method begin] al abrirse y
## [method end] al cerrarse, así no aparece en la anticipación ni en la recuperación. Con [member min_speed]
## > 0 además solo se guardan muestras mientras la punta va a esa velocidad o más (recorta el tramo lento
## de los bordes de la ventana, que no coincide al milímetro con el barrido que enseña la animación).
## [br][br]
## [b]Forma.[/b] No se dibuja con menos de [member min_samples] muestras (con dos, la cinta es un
## cuadrilátero recto). La cola se estrecha y se apaga según el número de muestra además de la edad, así
## acaba en punta y no en una escoba; el movimiento a lo largo del propio eje de la hoja (una estocada) casi
## no deja cinta; el arco que se dibuja no pasa de [member max_length] y un salto de la punta de más de
## [member max_jump] en un fotograma (un cambio de pose) corta la cinta en vez de tender un cable.
## [br][br]
## [b]Sincronía.[/b] Las muestras se toman cuando el esqueleto acaba de actualizar la pose
## ([signal Skeleton3D.skeleton_updated]), con la transformación interpolada del personaje, y la cinta se
## reconstruye en ese mismo instante: así va pegada a la hoja que se ve en este fotograma, no al anterior.
## Sin esqueleto (un nodo suelto, las pruebas) se toma en [method Node._process].
## [br][br]
## Los colores salen del reino ([method set_realm], [VfxPalette]) o de [method set_colors]; son
## parámetros de instancia, así que todas las estelas comparten el mismo material. Reutilizable: se
## puede volver a lanzar con [method begin] sin crear nada. Con la espada provisional ([WeaponProps]) la
## hoja sale por +X de la mano: la base está a 0,15 m y la punta a 0,9 m.

## Radianes de giro de la hoja que cubre cada tramo interpolado de la cinta, y tramos como máximo por muestra.
const MAX_STEP_ANGLE: float = 0.1
const MAX_STEPS: int = 14

## Segundos que dura la cinta (lo que tarda una muestra en desaparecer).
@export var max_age: float = 0.12
## Muestras que se guardan como máximo.
@export_range(4, 64) var max_samples: int = 24
## Puntos que se interpolan entre dos muestras.
@export_range(1, 8) var subdivisions: int = 4
## Punto de la hoja más cercano a la mano, en el espacio local del objetivo.
@export var base_offset: Vector3 = Vector3(0.15, 0.0, 0.0)
## Punta de la hoja, en el espacio local del objetivo.
@export var tip_offset: Vector3 = Vector3(0.9, 0.0, 0.0)
## Reino que decide los colores (ver [VfxPalette]).
@export var realm: int = 0:
	set = set_realm
## Lo que tiene que moverse la hoja (m) entre dos muestras para guardar otra.
@export var min_step: float = 0.004
## Velocidad mínima de la punta (m/s) para dejar cinta; 0 = sin límite (ver la descripción de la clase).
@export var min_speed: float = 0.0
## Si pasa más de esto (s) sin muestras, la cinta siguiente es otro tajo: se descarta la anterior en vez de
## unirlos con un puente.
@export var break_gap: float = 0.07
## Muestras que hacen falta para dibujar la cinta (con menos sería un cuadrilátero de bordes rectos).
@export_range(2, 8) var min_samples: int = 3
## Longitud máxima (m) del arco de la punta que se dibuja.
@export var max_length: float = 2.4
## Lo que puede saltar la punta (m) entre dos muestras seguidas sin cortar la cinta.
@export var max_jump: float = 2.0

var _target: Node3D = null
var _skeleton: Skeleton3D = null
var _active: bool = false
var _clock: float = 0.0
var _bases: PackedVector3Array = PackedVector3Array()
var _tips: PackedVector3Array = PackedVector3Array()
var _times: PackedFloat32Array = PackedFloat32Array()
var _lateral: PackedFloat32Array = PackedFloat32Array()
var _immediate: ImmediateMesh = ImmediateMesh.new()
var _core: Color = Color.WHITE
var _edge: Color = Color(0.62, 0.7, 0.82)
var _last_tip: Vector3 = Vector3.ZERO
var _last_tip_clock: float = 0.0
var _has_last_tip: bool = false
var _speed: float = 0.0
var _built_frame: int = -1


func _ready() -> void:
	# La cinta se dibuja en coordenadas de mundo: no hereda el movimiento de quien la cuelga.
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _immediate
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Después de la pose animada de este fotograma (el hueso de la mano ya está en su sitio).
	process_priority = 1000
	set_realm(realm)
	visible = false
	set_process(false)


func _exit_tree() -> void:
	_disconnect_skeleton()


## Empieza a seguir [param target] (el nodo de la espada). Con la estela ya activa solo cambia de objetivo.
func begin(target: Node3D) -> void:
	_target = target
	_connect_skeleton(_find_skeleton(target))
	if not _active:
		_has_last_tip = false
	_active = true
	visible = true
	set_process(true)


## Deja de añadir muestras: la cinta que hay se deshace sola.
func end() -> void:
	_active = false


## Apaga la estela de golpe, sin esperar a que se deshaga.
func clear() -> void:
	_active = false
	_has_last_tip = false
	_clear_samples()
	_immediate.clear_surfaces()
	visible = false
	set_process(false)


## True mientras sigue al arma o le queda cinta por apagarse.
func is_active() -> bool:
	return _active or not _times.is_empty()


## Colores por reino (ver [VfxPalette]).
func set_realm(value: int) -> void:
	realm = value
	var colors: Array[Color] = VfxPalette.trail(value)
	set_colors(colors[0], colors[1])


## Pone los dos colores a mano: [param core] caliente en el filo y [param edge] en el cuerpo.
func set_colors(core: Color, edge: Color) -> void:
	_core = core
	_edge = edge
	set_instance_shader_parameter(&"core_color", core)
	set_instance_shader_parameter(&"edge_color", edge)


func _process(delta: float) -> void:
	_clock += delta
	# Con esqueleto, las muestras las toma la señal de actualización de la pose (ver _on_skeleton_updated);
	# aquí solo se envejece la cinta cuando esa señal no ha llegado en este fotograma.
	if _skeleton == null and _active and is_instance_valid(_target):
		_push_sample()
	if _built_frame == Engine.get_process_frames() and _skeleton != null:
		return
	_trim()
	_rebuild_or_idle()


func _on_skeleton_updated() -> void:
	if not _active or not is_instance_valid(_target):
		return
	_push_sample()
	_trim()
	_rebuild_or_idle()
	_built_frame = Engine.get_process_frames()


func _rebuild_or_idle() -> void:
	if _times.size() < min_samples:
		_immediate.clear_surfaces()
		if not _active and _times.is_empty():
			visible = false
			set_process(false)
		return
	_rebuild()


func _push_sample() -> void:
	var xform: Transform3D = _target_transform()
	var base: Vector3 = xform * base_offset
	var tip: Vector3 = xform * tip_offset
	if _has_last_tip:
		var elapsed: float = _clock - _last_tip_clock
		# Varias actualizaciones en el mismo fotograma no dan una velocidad fiable: se conserva la anterior.
		if elapsed > 1.0 / 240.0:
			_speed = tip.distance_to(_last_tip) / elapsed
			_last_tip_clock = _clock
		if tip.distance_to(_last_tip) > max_jump:
			# Cambio de pose o teletransporte: no es un tajo, se corta la cinta en vez de tender un cable.
			_clear_samples()
			_last_tip = tip
			_last_tip_clock = _clock
			return
	else:
		_speed = 0.0
		_last_tip_clock = _clock
	_last_tip = tip
	_has_last_tip = true
	if min_speed > 0.0 and _speed < min_speed:
		return
	var last: int = _times.size() - 1
	if last >= 0 and _clock - _times[last] > break_gap:
		# Otro tajo: no se une con la cinta del anterior.
		_clear_samples()
		last = -1
	if last >= 0 and base.distance_to(_bases[last]) < min_step and tip.distance_to(_tips[last]) < min_step:
		return
	_bases.append(base)
	_tips.append(tip)
	_times.append(_clock)
	_lateral.append(_lateral_factor(base, tip, last))


# 1 si la hoja barre de lado, 0 si se mueve a lo largo de su propio eje (una estocada: la cinta sería un
# cuadrilátero sin ancho real).
func _lateral_factor(base: Vector3, tip: Vector3, last: int) -> float:
	if last < 0:
		return 1.0
	var move: Vector3 = tip - _tips[last]
	var axis: Vector3 = tip - base
	if move.length_squared() < 0.000001 or axis.length_squared() < 0.0001:
		return 1.0
	var along: float = absf(move.normalized().dot(axis.normalized()))
	return 1.0 - smoothstep(0.55, 0.95, along)


# Quita lo que ha envejecido y recorta el arco a [member max_length] por la parte vieja.
func _trim() -> void:
	while not _times.is_empty() and (_clock - _times[0] > max_age or _times.size() > max_samples):
		_remove_oldest()
	# Nunca se recorta por debajo de [member min_samples]: con la hoja a 70 m/s las muestras quedan a más de un
	# metro y tres ya pasan del tope, pero con menos no se dibujaría ni el tajo entero.
	var total: float = 0.0
	for index: int in range(_times.size() - 1, 0, -1):
		total += _tips[index].distance_to(_tips[index - 1])
		if total > max_length:
			var removable: int = mini(index, _times.size() - min_samples)
			for _removed: int in maxi(removable, 0):
				_remove_oldest()
			return


func _remove_oldest() -> void:
	_bases.remove_at(0)
	_tips.remove_at(0)
	_times.remove_at(0)
	_lateral.remove_at(0)


func _clear_samples() -> void:
	_bases.clear()
	_tips.clear()
	_times.clear()
	_lateral.clear()


# La transformación del arma en este fotograma. Con el hueso del esqueleto se lee la pose recién
# calculada y la transformación INTERPOLADA del personaje (con la interpolación de física, la de
# global_transform es la del último tick, que no es la que se ve).
func _target_transform() -> Transform3D:
	if _skeleton != null and _target is BoneAttachment3D:
		var bone: int = (_target as BoneAttachment3D).get_bone_idx()
		if bone >= 0 and bone < _skeleton.get_bone_count():
			return _skeleton.get_global_transform_interpolated() * _skeleton.get_bone_global_pose(bone)
	return _target.get_global_transform_interpolated()


func _find_skeleton(node: Node) -> Skeleton3D:
	var current: Node = node
	while current != null:
		if current is Skeleton3D:
			return current as Skeleton3D
		current = current.get_parent()
	return null


func _connect_skeleton(skeleton: Skeleton3D) -> void:
	if skeleton == _skeleton:
		return
	_disconnect_skeleton()
	_skeleton = skeleton
	if _skeleton != null:
		_skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _disconnect_skeleton() -> void:
	if _skeleton != null and is_instance_valid(_skeleton) \
			and _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.disconnect(_on_skeleton_updated)
	_skeleton = null


# Reconstruye la cinta: una tira de triángulos con dos vértices por punto (base y punta), con la edad
# en UV.x, la posición a lo ancho en UV.y y, en el color, lo que queda de cuerpo según el número de
# muestra (rojo) y lo lateral que es el movimiento (verde).
# La base se suaviza con una curva de Catmull-Rom; la punta NO se interpola en línea recta entre muestras:
# se interpola la DIRECCIÓN de la hoja y la punta es la base más esa dirección por el largo de la hoja, así la
# punta recorre un arco alrededor de la mano (lo que hace una espada) aunque el tajo solo tenga tres o cuatro
# muestras, con una pose que salta un metro de un fotograma al siguiente. Cuanto más gira la hoja entre dos
# muestras, más puntos se interpolan.
func _rebuild() -> void:
	_immediate.clear_surfaces()
	var count: int = _times.size()
	var span: float = float(maxi(count - 1, 1))
	_immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for index: int in range(count - 1, -1, -1):
		# Recorrido hacia atrás: de la muestra [index] a la [index - 1].
		var p1: int = index
		var p2: int = maxi(index - 1, 0)
		var p0: int = mini(index + 1, count - 1)
		var p3: int = maxi(index - 2, 0)
		var d0: Vector3 = (_tips[p0] - _bases[p0])
		var d1: Vector3 = (_tips[p1] - _bases[p1])
		var d2: Vector3 = (_tips[p2] - _bases[p2])
		var d3: Vector3 = (_tips[p3] - _bases[p3])
		var steps: int = 1
		if index > 0:
			steps = clampi(ceili(d1.angle_to(d2) / MAX_STEP_ANGLE), subdivisions, MAX_STEPS)
		for step: int in steps:
			var t: float = float(step) / float(steps)
			var base: Vector3 = _catmull(_bases[p0], _bases[p1], _bases[p2], _bases[p3], t)
			var direction: Vector3 = _catmull(d0.normalized(), d1.normalized(), d2.normalized(),
					d3.normalized(), t)
			direction = direction.normalized() if direction.length_squared() > 0.000001 else d1.normalized()
			var tip: Vector3 = base + direction * lerpf(d1.length(), d2.length(), t)
			var time: float = lerpf(_times[p1], _times[p2], t)
			var age: float = clampf((_clock - time) / max_age, 0.0, 1.0)
			var order: float = (float(count - 1 - index) + t) / span
			var body: float = pow(clampf(1.0 - order, 0.0, 1.0), 0.9)
			var lateral: float = lerpf(_lateral[p1], _lateral[p2], t)
			_immediate.surface_set_color(Color(body, lateral, 0.0, 1.0))
			_immediate.surface_set_uv(Vector2(age, 0.0))
			_immediate.surface_add_vertex(base)
			_immediate.surface_set_color(Color(body, lateral, 0.0, 1.0))
			_immediate.surface_set_uv(Vector2(age, 1.0))
			_immediate.surface_add_vertex(tip)
	_immediate.surface_end()


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
