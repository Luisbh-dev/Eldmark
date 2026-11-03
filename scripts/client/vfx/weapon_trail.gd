class_name WeaponTrail
extends MeshInstance3D
## Estela del arma (ART-09, solo cliente): una cinta con degradado que sigue el arco del filo.
## [br][br]
## Cada fotograma que está activa toma dos puntos de [member target] (la base y la punta de la hoja,
## [member base_offset] y [member tip_offset] en el espacio local del objetivo) y los guarda con su
## instante. La cinta es la tira de triángulos que une esas muestras, suavizada con una curva de
## Catmull-Rom (a 60 fotogramas el arco de un tajo son pocas cuerdas rectas) y pintada por
## [code]vfx_trail.gdshader[/code]: la cola se deshace con la edad ([member max_age]) y la luz se
## concentra en el filo de la punta. Al terminar el golpe, [method end] deja de añadir muestras y la
## cinta se apaga sola; no deja nada en pantalla ni gasta tiempo cuando está inactiva.
## [br][br]
## [b]Qué tramo se pinta.[/b] Con [member min_speed] > 0 solo se guardan muestras mientras la punta se
## mueve a esa velocidad o más, así que la cinta sigue el tramo rápido del tajo que enseña la animación
## aunque la ventana activa de la simulación no coincida con él (docs/calidad.md, sección 1: los clips de
## ataque no están ajustados a los ticks). Con 0 se pinta todo el tiempo que esté activa.
## [br][br]
## Los colores salen del reino ([method set_realm], [VfxPalette]) o de [method set_colors]; son
## parámetros de instancia, así que todas las estelas comparten el mismo material. Reutilizable: se
## puede volver a lanzar con [method begin] sin crear nada.
## [br][br]
## Para engancharla al arma, en el propio nodo: el [BoneAttachment3D] de la espada es el objetivo, y
## [code]swing_active_changed[/code] de [CombatFeedback] (o el cambio de acción a ligero o fuerte, con
## [member min_speed]) llama a [method begin] y [method end]. Con la espada provisional ([WeaponProps]) la
## hoja sale por +X de la mano: la base está a 0,15 m y la punta a 0,9 m.

## Segundos que dura la cinta (lo que tarda una muestra en desaparecer).
@export var max_age: float = 0.2
## Muestras que se guardan como máximo.
@export_range(4, 64) var max_samples: int = 32
## Puntos que se interpolan entre dos muestras.
@export_range(1, 8) var subdivisions: int = 3
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

var _target: Node3D = null
var _active: bool = false
var _clock: float = 0.0
var _bases: PackedVector3Array = PackedVector3Array()
var _tips: PackedVector3Array = PackedVector3Array()
var _times: PackedFloat32Array = PackedFloat32Array()
var _immediate: ImmediateMesh = ImmediateMesh.new()
var _core: Color = Color.WHITE
var _edge: Color = Color(0.62, 0.7, 0.82)
var _last_tip: Vector3 = Vector3.ZERO
var _has_last_tip: bool = false


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


## Empieza a seguir [param target] (el nodo de la espada). Con la estela ya activa solo cambia de objetivo.
func begin(target: Node3D) -> void:
	_target = target
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
	_bases.clear()
	_tips.clear()
	_times.clear()
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
	if _active and is_instance_valid(_target):
		_push_sample(delta)
	while not _times.is_empty() and (_clock - _times[0] > max_age or _times.size() > max_samples):
		_bases.remove_at(0)
		_tips.remove_at(0)
		_times.remove_at(0)
	if _times.size() < 2:
		_immediate.clear_surfaces()
		if not _active and _times.is_empty():
			visible = false
			set_process(false)
		return
	_rebuild()


func _push_sample(delta: float) -> void:
	var xform: Transform3D = _target.global_transform
	var base: Vector3 = xform * base_offset
	var tip: Vector3 = xform * tip_offset
	var speed: float = 0.0
	if _has_last_tip and delta > 0.0:
		speed = tip.distance_to(_last_tip) / delta
	_last_tip = tip
	_has_last_tip = true
	if min_speed > 0.0 and speed < min_speed:
		return
	var last: int = _times.size() - 1
	if last >= 0 and _clock - _times[last] > break_gap:
		# Otro tajo: no se une con la cinta del anterior.
		_bases.clear()
		_tips.clear()
		_times.clear()
		last = -1
	if last >= 0 and base.distance_to(_bases[last]) < min_step and tip.distance_to(_tips[last]) < min_step:
		return
	_bases.append(base)
	_tips.append(tip)
	_times.append(_clock)


# Reconstruye la cinta: una tira de triángulos con dos vértices por punto (base y punta), con la edad
# en UV.x y la posición a lo ancho en UV.y.
func _rebuild() -> void:
	_immediate.clear_surfaces()
	var count: int = _times.size()
	_immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for index: int in range(count - 1, -1, -1):
		# De la muestra más nueva a la más vieja; entre cada pareja, los puntos interpolados.
		var steps: int = subdivisions if index > 0 else 1
		for step: int in steps:
			var t: float = float(step) / float(steps)
			# Recorrido hacia atrás: de la muestra [index] a la [index - 1].
			var p1: int = index
			var p2: int = maxi(index - 1, 0)
			var p0: int = mini(index + 1, count - 1)
			var p3: int = maxi(index - 2, 0)
			var base: Vector3 = _catmull(_bases[p0], _bases[p1], _bases[p2], _bases[p3], t)
			var tip: Vector3 = _catmull(_tips[p0], _tips[p1], _tips[p2], _tips[p3], t)
			var time: float = lerpf(_times[p1], _times[p2], t)
			var age: float = clampf((_clock - time) / max_age, 0.0, 1.0)
			_immediate.surface_set_uv(Vector2(age, 0.0))
			_immediate.surface_add_vertex(base)
			_immediate.surface_set_uv(Vector2(age, 1.0))
			_immediate.surface_add_vertex(tip)
	_immediate.surface_end()


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
