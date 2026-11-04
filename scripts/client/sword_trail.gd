class_name SwordTrail
extends Node3D
## Estela del golpe de la espada (ART-09, docs/calidad.md decisión 8). Solo cliente.
## [br][br]
## Es una cinta que nace de la propia hoja: va del [constant INNER_FRACTION] (40 %) del filo entre las
## marcas [code]TrailBase[/code] y [code]TrailTip[/code] del modelo ([SwordModel]) hasta la punta, y no pasa de
## ella. Cada fotograma de la fase activa guarda una muestra (arranque del filo y punta); una curva
## Catmull-Rom une las muestras y se parte en tramos según el tiempo que separa cada par (no según los
## fotogramas), así que a 30 fps el giro sale curvo y no una cuerda de rectas. La cinta lleva una textura de
## degradado ([method _gradient_texture]: u = edad, v = a lo largo de la hoja) con la cola deshecha por ruido
## y un alfa máximo de [constant PEAK_ALPHA], en mezcla normal con el color del reino saturado (la aditiva
## sobre un cielo claro da blanco). Encima, una línea fina y caliente en el filo de la punta, esa sí aditiva.
## Sin sombra ni luz.
## [br][br]
## La pose se lee DESPUÉS de que el esqueleto aplique el [CombatPoseModifier]: la estela se conecta a
## [signal Skeleton3D.skeleton_updated] del esqueleto en el que cuelga (si no hay esqueleto, como en las
## pruebas, lo mueve [method _process]). Muestrear en [method _process] leía la pose del fotograma anterior y
## dejaba la estela a 0,3-0,5 m de la hoja en un tajo rápido.
## [br][br]
## No decide cuándo hay golpe: lo activa quien lo sabe con [method set_active]. En el jugador local lo
## decide la misma comprobación que [signal CombatFeedback.swing_active_changed]
## ([method ActionMachine.is_attack_active]) y en los remotos la fase activa del byte de acción
## (ambas las unifica [CombatAnimationLayer.is_swing_active], que avisa el animador). Cuelga del nodo de la
## espada pero va por su cuenta ([member Node3D.top_level]): las muestras están en coordenadas del mundo.
## El alcance real del golpe (decisión 8) sale de los datos de combate y no de esta malla.

## Segundos que tarda en apagarse cada muestra (entre 0,12 y 0,15 s según la decisión 8).
const FADE_SECONDS: float = 0.13
## Dónde nace el cuerpo de la cinta, como fracción del largo entre TrailBase y TrailTip.
const INNER_FRACTION: float = 0.40
## Dónde empieza la línea caliente del filo de la punta (fracción del mismo largo).
const LINE_FRACTION: float = 0.94
## Tramos máximos y segundos por tramo con que se parte cada salto entre dos muestras.
const MAX_SUBDIVISIONS: int = 12
const SUBDIVISION_SECONDS: float = 1.0 / 240.0
## Tope de muestras vivas (a 240 fps, 0,13 s son 32).
const MAX_SAMPLES: int = 48
## Opacidad máxima del cuerpo de la cinta y de la línea del filo.
const PEAK_ALPHA: float = 0.5
const LINE_ALPHA: float = 0.85
## Cuánto se aclara el color del reino en la línea del filo (0 = igual, 1 = blanco).
const LINE_LIGHTEN: float = 0.45
## Tamaño de la textura del degradado (u = edad, v = a lo largo de la hoja).
const TEXTURE_SIZE: Vector2i = Vector2i(128, 64)
## Color por variante de la espada (ids de [constant SwordModel.MODELS]), saturado: lo que no se ve en la
## textura (que es blanca con alfa) lo pone este tinte.
const DEFAULT_COLOR: Color = Color(0.30, 0.62, 1.00, 1.0)
const COLORS: Dictionary[StringName, Color] = {
	&"base": Color(0.30, 0.62, 1.00, 1.0),
	&"vardheim": Color(0.16, 0.60, 1.00, 1.0),
	&"solmarch": Color(1.00, 0.68, 0.12, 1.0),
	&"askarra": Color(1.00, 0.26, 0.04, 1.0),
}

static var _texture: ImageTexture = null

var _base: Node3D = null
var _tip: Node3D = null
var _skeleton: Skeleton3D = null
var _active: bool = false
var _color: Color = DEFAULT_COLOR
var _last_update_frame: int = -100
# Muestras de la más vieja a la más nueva: [base: Vector3, tip: Vector3, age: float].
var _samples: Array[Array] = []
var _mesh: ImmediateMesh = ImmediateMesh.new()
var _instance: MeshInstance3D = MeshInstance3D.new()
var _body_material: StandardMaterial3D = _make_body_material()
var _line_material: StandardMaterial3D = _make_line_material()


func _init() -> void:
	name = "SwordTrail"
	top_level = true
	_instance.name = "Ribbon"
	_instance.mesh = _mesh
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visible = false
	# La cinta puede estar lejos del origen del nodo (que no se mueve): nunca se recorta por la caja.
	_instance.extra_cull_margin = 16384.0
	add_child(_instance)
	set_process(false)


func _enter_tree() -> void:
	# Los padres ya han entrado: el BoneAttachment3D se conectó antes que nosotros y coloca la espada primero.
	var node: Node = get_parent()
	while node != null and not node is Skeleton3D:
		node = node.get_parent()
	_skeleton = node as Skeleton3D
	if _skeleton != null and not _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _exit_tree() -> void:
	if _skeleton != null and is_instance_valid(_skeleton) \
			and _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.disconnect(_on_skeleton_updated)
	_skeleton = null


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
		# Con esqueleto, la primera muestra es la del próximo fotograma ya posado; sin él, esta misma.
		if _skeleton == null:
			add_sample()


func is_active() -> bool:
	return _active


## Muestras vivas ahora mismo.
func get_sample_count() -> int:
	return _samples.size()


## Guarda una muestra con la posición actual de las marcas (si el modelo las tiene) y la cinta nueva.
func add_sample() -> void:
	if _push_current():
		_rebuild()


## Guarda una muestra con el arranque del filo [param base] y la punta [param tip] (en coordenadas del
## mundo). Las pruebas la usan sin modelo.
func add_sample_points(base: Vector3, tip: Vector3) -> void:
	_push(base, tip)
	_rebuild()


## Envejece las muestras [param delta] segundos y quita las apagadas. Lo llama el esqueleto al actualizarse (o
## [method _process] sin esqueleto); las pruebas, a mano.
func advance(delta: float) -> void:
	_age(delta)
	_rebuild()


func _process(delta: float) -> void:
	# Con esqueleto manda skeleton_updated; solo se cae a esto si el esqueleto lleva rato sin actualizarse.
	if _skeleton != null and Engine.get_process_frames() - _last_update_frame <= 2:
		return
	_age(delta)
	if _active:
		_push_current()
	_rebuild()
	if not _active and _samples.is_empty():
		set_process(false)


# El esqueleto acaba de aplicar todos sus modificadores (el de la pose de combate incluido): la espada ya está
# donde se va a dibujar este fotograma.
func _on_skeleton_updated() -> void:
	if not is_inside_tree() or (not _active and _samples.is_empty()):
		return
	_last_update_frame = Engine.get_process_frames()
	_age(get_process_delta_time())
	if _active:
		_push_current()
	_rebuild()


func _age(delta: float) -> void:
	for sample: Array in _samples:
		sample[2] = float(sample[2]) + delta
	while not _samples.is_empty() and float((_samples[0] as Array)[2]) >= FADE_SECONDS:
		_samples.pop_front()


func _push_current() -> bool:
	if _base == null or _tip == null or not is_instance_valid(_base) or not is_instance_valid(_tip):
		return false
	_push(_base.global_position, _tip.global_position)
	return true


func _push(base: Vector3, tip: Vector3) -> void:
	_samples.append([base, tip, 0.0])
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


## Los dos puntos de la muestra [param index] en la hoja: el arranque de la cinta ([constant INNER_FRACTION])
## y la punta.
func get_ribbon_edges(index: int) -> PackedVector3Array:
	var sample: Array = _samples[index]
	return _edges(sample[0] as Vector3, sample[1] as Vector3)


static func _edges(base: Vector3, tip: Vector3) -> PackedVector3Array:
	var along: Vector3 = tip - base
	return PackedVector3Array([base + along * INNER_FRACTION, tip])


# Catmull-Rom uniforme entre [param p1] y [param p2] en [param t] (de 0 a 1).
static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)


# La curva densa por las muestras: [base, tip, age] cada pocos milisegundos de barrido, con la posición por
# Catmull-Rom y la edad en línea recta. El número de tramos de cada salto sale del tiempo que lo separa.
func _dense_samples() -> Array[Array]:
	var dense: Array[Array] = []
	var last: int = _samples.size() - 1
	for index: int in range(last):
		var s0: Array = _samples[maxi(index - 1, 0)]
		var s1: Array = _samples[index]
		var s2: Array = _samples[index + 1]
		var s3: Array = _samples[mini(index + 2, last)]
		var seconds: float = absf(float(s1[2]) - float(s2[2]))
		var steps: int = clampi(ceili(seconds / SUBDIVISION_SECONDS), 2, MAX_SUBDIVISIONS)
		for step: int in range(steps):
			var t: float = float(step) / float(steps)
			dense.append([
				_catmull(s0[0] as Vector3, s1[0] as Vector3, s2[0] as Vector3, s3[0] as Vector3, t),
				_catmull(s0[1] as Vector3, s1[1] as Vector3, s2[1] as Vector3, s3[1] as Vector3, t),
				lerpf(float(s1[2]), float(s2[2]), t),
			])
	dense.append(_samples[last])
	return dense


# Reconstruye la cinta: una tira para el cuerpo (del 40 % de la hoja a la punta, con la textura de degradado) y
# otra, aditiva, para la línea caliente del filo de la punta.
func _rebuild() -> void:
	_mesh.clear_surfaces()
	if _samples.size() < 2:
		_instance.visible = false
		return
	_instance.visible = true
	var dense: Array[Array] = _dense_samples()
	var body_color: Color = _color
	var line_color: Color = _color.lerp(Color.WHITE, LINE_LIGHTEN)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _body_material)
	for sample: Array in dense:
		var age: float = float(sample[2])
		var fade: float = _fade(age)
		var u: float = clampf(age / FADE_SECONDS, 0.0, 1.0)
		var edges: PackedVector3Array = _edges(sample[0] as Vector3, sample[1] as Vector3)
		_mesh.surface_set_color(Color(body_color.r, body_color.g, body_color.b, PEAK_ALPHA * fade))
		_mesh.surface_set_uv(Vector2(u, 0.0))
		_mesh.surface_add_vertex(edges[0])
		_mesh.surface_set_color(Color(body_color.r, body_color.g, body_color.b, PEAK_ALPHA * fade))
		_mesh.surface_set_uv(Vector2(u, 1.0))
		_mesh.surface_add_vertex(edges[1])
	_mesh.surface_end()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _line_material)
	for sample: Array in dense:
		var age: float = float(sample[2])
		var fade: float = _fade(age)
		var base: Vector3 = sample[0] as Vector3
		var tip: Vector3 = sample[1] as Vector3
		# La línea se apaga más deprisa que el cuerpo: una chispa en el filo, no una cola.
		var alpha: float = LINE_ALPHA * fade * fade
		_mesh.surface_set_color(Color(line_color.r, line_color.g, line_color.b, 0.0))
		_mesh.surface_add_vertex(base + (tip - base) * LINE_FRACTION)
		_mesh.surface_set_color(Color(line_color.r, line_color.g, line_color.b, alpha))
		_mesh.surface_add_vertex(tip)
	_mesh.surface_end()


# Opacidad (de 0 a 1) de una muestra de [param age] segundos: cae al cuadrado hasta apagarse.
static func _fade(age: float) -> float:
	var fade: float = clampf(1.0 - age / FADE_SECONDS, 0.0, 1.0)
	return fade * fade


# Textura blanca con alfa: u = edad (0 = recién pasada la punta, 1 = a punto de apagarse), v = a lo largo del
# cuerpo (0 = el 40 % de la hoja, 1 = la punta). El alfa sube hacia la punta y la cola se deshace en vetas por
# ruido alargado en el sentido del barrido.
static func _gradient_texture() -> ImageTexture:
	if _texture != null:
		return _texture
	var noise := FastNoiseLite.new()
	noise.seed = 1307
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0
	var image: Image = Image.create(TEXTURE_SIZE.x, TEXTURE_SIZE.y, false, Image.FORMAT_RGBA8)
	for y: int in range(TEXTURE_SIZE.y):
		var v: float = (float(y) + 0.5) / float(TEXTURE_SIZE.y)
		# De la hoja hacia la punta: nada hasta un tercio, luego sube en curva hasta casi 1.
		var across: float = pow(smoothstep(0.10, 1.0, v), 1.7)
		for x: int in range(TEXTURE_SIZE.x):
			var u: float = (float(x) + 0.5) / float(TEXTURE_SIZE.x)
			# Vetas largas a lo largo de u, cortas a lo ancho de la hoja (v).
			var streak: float = noise.get_noise_2d(u * 3.2, v * 15.0) * 0.5 + 0.5
			var dissolve: float = clampf((1.0 - u) * 1.5 - 0.30 + (streak - 0.5) * 1.1 * u, 0.0, 1.0)
			var alpha: float = across * smoothstep(0.0, 0.85, dissolve)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	_texture = ImageTexture.create_from_image(image)
	return _texture


func _make_body_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _gradient_texture()
	material.texture_repeat = false
	material.disable_receive_shadows = true
	return material


func _make_line_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true
	return material
