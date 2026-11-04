class_name SwordTrail
extends Node3D
## Estela del golpe de la espada (ART-09, docs/calidad.md decisión 8). Solo cliente.
## [br][br]
## Es una cinta entre las marcas [code]TrailBase[/code] y [code]TrailTip[/code] del modelo
## ([SwordModel]): cada fotograma de la fase activa del golpe guarda una muestra (el arranque del filo y la
## punta) y la malla une las muestras, curvando el giro de la hoja entre dos fotogramas, en una cinta que
## se apaga en [constant FADE_SECONDS]. Tiene cinco líneas ([constant EDGE_FRACTIONS]): desde un 50 % del
## filo, transparente, hasta la punta (el núcleo claro, con la opacidad subiendo en curva para que sea un
## filo de luz y no un plano), y un borde exterior alargado hacia fuera [constant REACH_EXTENSION] m más
## allá de la punta (un velo tenue). Sin sombra ni luz, de mezcla aditiva
## y teñida por reino. La espada
## dibujada llega a 1,1 m y el golpe conecta mucho más lejos: la cinta es lo que enseña ese alcance, así que
## su borde exterior llega a unos 2,2 m del eje del personaje sin tocar el alcance real, que sale de los
## datos de combate y no de esta malla.
## [br][br]
## No decide cuándo hay golpe: lo activa quien lo sabe con [method set_active]. En el jugador local lo
## decide la misma comprobación que [signal CombatFeedback.swing_active_changed]
## ([method ActionMachine.is_attack_active]) y en los remotos la fase activa del byte de acción
## (ambas las unifica [CombatAnimationLayer.is_swing_active], que avisa el animador). Cuelga del nodo de la
## espada pero va por su cuenta ([member Node3D.top_level]): las muestras están en coordenadas del mundo.

## Segundos que tarda en apagarse cada muestra (entre 0,12 y 0,15 s según la decisión 8).
const FADE_SECONDS: float = 0.13
## Cuánto se alarga el borde exterior más allá de la punta, en metros, siguiendo la hoja.
const REACH_EXTENSION: float = 0.62
## Las líneas de la cinta como fracción del largo entre TrailBase y TrailTip (0 = arranque del filo, 1 =
## punta) y su opacidad relativa: la cinta cubre el tramo exterior del filo, no toda la hoja.
const EDGE_FRACTIONS: Array[float] = [0.50, 0.76, 0.92, 1.0]
const EDGE_ALPHAS: Array[float] = [0.0, 0.06, 0.30, 1.0]
## Tramos en que se parte cada salto entre dos muestras para que el giro salga curvo y no una cuerda.
const SUBDIVISIONS: int = 4
## Tope de muestras vivas (a 240 fps, 0,13 s son 32).
const MAX_SAMPLES: int = 40
## Opacidad de la punta de la muestra más nueva, y del borde exterior (el velo del alcance). El borde
## interior es 0.
const PEAK_ALPHA: float = 0.85
const REACH_ALPHA: float = 0.14
## Color por variante de la espada (ids de [constant SwordModel.MODELS]).
const DEFAULT_COLOR: Color = Color(0.70, 0.86, 1.00, 1.0)
const COLORS: Dictionary[StringName, Color] = {
	&"base": Color(0.70, 0.86, 1.00, 1.0),
	&"vardheim": Color(0.55, 0.85, 1.00, 1.0),
	&"solmarch": Color(1.00, 0.82, 0.40, 1.0),
	&"askarra": Color(1.00, 0.36, 0.10, 1.0),
}

var _base: Node3D = null
var _tip: Node3D = null
var _active: bool = false
var _color: Color = DEFAULT_COLOR
# Muestras de la más vieja a la más nueva: [base: Vector3, tip: Vector3, age: float].
var _samples: Array[Array] = []
var _mesh: ImmediateMesh = ImmediateMesh.new()
var _instance: MeshInstance3D = MeshInstance3D.new()


func _init() -> void:
	name = "SwordTrail"
	top_level = true
	_instance.name = "Ribbon"
	_instance.mesh = _mesh
	_instance.material_override = _make_material()
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visible = false
	# La cinta puede estar lejos del origen del nodo (que no se mueve): nunca se recorta por la caja.
	_instance.extra_cull_margin = 16384.0
	add_child(_instance)
	set_process(false)


## Color de la estela de la variante [param variant] de la espada ([constant COLORS]; el base si no existe).
static func color_for(variant: StringName) -> Color:
	return COLORS.get(variant, DEFAULT_COLOR)


## Busca las marcas [code]TrailBase[/code] y [code]TrailTip[/code] en el modelo de la espada [param model].
## Con otro modelo (otra variante) se vuelve a llamar y se olvidan las muestras.
func bind(model: Node) -> void:
	_base = model.find_child(String(SwordModel.TRAIL_BASE_NAME), true, false) as Node3D
	_tip = model.find_child(String(SwordModel.TRAIL_TIP_NAME), true, false) as Node3D
	_samples.clear()
	_rebuild()


## Tiñe la estela con [param color] (el alfa se ignora).
func set_tint(color: Color) -> void:
	_color = Color(color.r, color.g, color.b, 1.0)


## Empieza o corta el barrido. Al cortarlo, lo que queda de cinta se apaga solo.
func set_active(active: bool) -> void:
	if active == _active:
		return
	_active = active
	if _active:
		set_process(true)
		# Una muestra nada más empezar: el primer fotograma ya dibuja arranque de cinta.
		add_sample()


func is_active() -> bool:
	return _active


## Muestras vivas ahora mismo.
func get_sample_count() -> int:
	return _samples.size()


## Guarda una muestra con la posición actual de las marcas (si el modelo las tiene) y la cinta nueva.
func add_sample() -> void:
	if _base == null or _tip == null or not is_instance_valid(_base) or not is_instance_valid(_tip):
		return
	add_sample_points(_base.global_position, _tip.global_position)


## Guarda una muestra con el arranque del filo [param base] y la punta [param tip] (en coordenadas del
## mundo). Las pruebas la usan sin modelo.
func add_sample_points(base: Vector3, tip: Vector3) -> void:
	_samples.append([base, tip, 0.0])
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()
	_rebuild()


## Envejece las muestras [param delta] segundos y quita las apagadas. [method _process] lo llama cada
## fotograma; las pruebas, a mano.
func advance(delta: float) -> void:
	for sample: Array in _samples:
		sample[2] = float(sample[2]) + delta
	while not _samples.is_empty() and float((_samples[0] as Array)[2]) >= FADE_SECONDS:
		_samples.pop_front()
	_rebuild()


func _process(delta: float) -> void:
	advance(delta)
	if _active:
		add_sample()
	elif _samples.is_empty():
		set_process(false)


## Los puntos de la muestra [param index], del interior a la punta ([constant EDGE_FRACTIONS]) y el último,
## el borde exterior alargado.
func get_edges(index: int) -> PackedVector3Array:
	var sample: Array = _samples[index]
	return _edges(sample[0] as Vector3, sample[1] as Vector3)


static func _edges(base: Vector3, tip: Vector3) -> PackedVector3Array:
	var along: Vector3 = tip - base
	var direction: Vector3 = along.normalized() if along.length() > 0.001 else Vector3.UP
	var points := PackedVector3Array()
	for fraction: float in EDGE_FRACTIONS:
		points.append(base + along * fraction)
	points.append(tip + direction * REACH_EXTENSION)
	return points


# La muestra con el arranque y la punta de [param a] y [param b] mezclados en [param t]: la posición se mezcla
# en línea recta y la dirección de la hoja en arco (el giro del filo), y la edad en línea recta.
static func _blend(a: Array, b: Array, t: float) -> Array:
	var base_a: Vector3 = a[0] as Vector3
	var base_b: Vector3 = b[0] as Vector3
	var dir_a: Vector3 = (a[1] as Vector3) - base_a
	var dir_b: Vector3 = (b[1] as Vector3) - base_b
	var base: Vector3 = base_a.lerp(base_b, t)
	var direction: Vector3 = dir_a if dir_a.length() < 0.001 or dir_b.length() < 0.001 			else dir_a.slerp(dir_b, t)
	return [base, base + direction, lerpf(float(a[2]), float(b[2]), t)]


# Reconstruye la cinta: por cada par de muestras, dos cuadriláteros (borde interior a punta y punta a
# borde exterior), con el salto entre las dos partido en SUBDIVISIONS tramos. El borde interior es
# transparente, la punta es el núcleo claro y el exterior un velo; todo se apaga con la edad.
func _rebuild() -> void:
	_mesh.clear_surfaces()
	if _samples.size() < 2:
		_instance.visible = false
		return
	_instance.visible = true
	var dense: Array[Array] = []
	for index: int in range(_samples.size() - 1):
		for step: int in range(SUBDIVISIONS):
			dense.append(_blend(_samples[index], _samples[index + 1], float(step) / float(SUBDIVISIONS)))
	dense.append(_samples[_samples.size() - 1])
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for index: int in range(dense.size() - 1):
		var first: Array = dense[index]
		var second: Array = dense[index + 1]
		var edges_a: PackedVector3Array = _edges(first[0] as Vector3, first[1] as Vector3)
		var edges_b: PackedVector3Array = _edges(second[0] as Vector3, second[1] as Vector3)
		var fade_a: float = _fade(float(first[2]))
		var fade_b: float = _fade(float(second[2]))
		# Una franja entre cada par de líneas contiguas, la última hacia el velo del alcance.
		var lines: int = edges_a.size()
		for line: int in range(lines - 1):
			var alpha_in: float = PEAK_ALPHA * EDGE_ALPHAS[line]
			var alpha_out: float = REACH_ALPHA
			if line + 1 < lines - 1:
				alpha_out = PEAK_ALPHA * EDGE_ALPHAS[line + 1]
			_quad(edges_a[line], edges_a[line + 1], edges_b[line + 1], edges_b[line],
					alpha_in * fade_a, alpha_out * fade_a, alpha_out * fade_b, alpha_in * fade_b)
	_mesh.surface_end()


# Opacidad (de 0 a 1) de una muestra de [param age] segundos: cae al cuadrado hasta apagarse.
static func _fade(age: float) -> float:
	var fade: float = clampf(1.0 - age / FADE_SECONDS, 0.0, 1.0)
	return fade * fade


# Un cuadrilátero a-b-c-d (dos triángulos) con el alfa de cada esquina.
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, alpha_a: float, alpha_b: float,
		alpha_c: float, alpha_d: float) -> void:
	var points: Array[Vector3] = [a, b, c, d]
	var alphas: Array[float] = [alpha_a, alpha_b, alpha_c, alpha_d]
	for corner: int in [0, 1, 2, 0, 2, 3]:
		_mesh.surface_set_color(Color(_color.r, _color.g, _color.b, alphas[corner]))
		_mesh.surface_add_vertex(points[corner])


static func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true
	return material
