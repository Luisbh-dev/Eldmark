class_name VfxEffect
extends Node3D
## Efecto visual reutilizable de combate (ART-09, solo cliente): raíz de las escenas de
## [code]scenes/vfx/[/code]. Pensado para un grupo de reutilización ([VfxPool]): se crea una vez y se
## relanza con [method play] o [method play_at] sin instanciar nada.
## [br][br]
## Un efecto es un nodo con hijos de dos clases: [GPUParticles3D] (de un disparo, o continuos si el
## efecto es [member looping]) y mallas con sombreador animadas por el parámetro de instancia
## [code]progress[/code] ([code]MeshInstance3D[/code] con un [QuadMesh], por ejemplo). Como el avance y
## el tinte son parámetros de [b]instancia[/b], todas las copias de un efecto comparten los mismos
## materiales y se pueden recolorear sin duplicarlos.
## [br][br]
## [b]Metadatos de los hijos[/b] (en el .tscn, [code]metadata/...[/code]):
## [br]- [code]vfx_time[/code] ([Vector2]): retardo y duración en segundos. En una malla es lo que dura su
## [code]progress[/code] de 0 a 1 (se oculta fuera de ese intervalo); en unas partículas, cuándo se lanzan.
## [br]- [code]vfx_cue[/code] ([StringName]): aviso que lo dispara. Por defecto [constant CUE_START], que
## arranca con [method play]; los demás se lanzan con [method trigger] (el pulso de carga del aura, por
## ejemplo).
## [br]- [code]vfx_tint[/code] ([Color]) y [code]vfx_tint_weight[/code] (0 a 1): color base del tinte de
## instancia del hijo y cuánto le afecta [member tint] (0 = nada: un destello blanco sigue blanco).
## [br]- [code]vfx_no_tint[/code] ([bool]): el hijo no lleva el parámetro [code]tint[/code] (una distorsión de calor
## no tiene color): el efecto no se lo pone.
## [br]- [code]vfx_variants[/code] ([int]) y [code]vfx_variant_offset[/code] ([int]): la malla tiene un atlas de
## variantes (filas) y el efecto elige una en cada disparo (parámetros de instancia [code]variant[/code] y
## [code]flip[/code]), de forma determinista: dos disparos seguidos no repiten el mismo chorro.
## [br][br]
## [b]Orientación.[/b] El eje +Z local es la normal del impacto: hacia donde salen las chispas, hacia
## quien golpeó. [method play_at] lo orienta desde una posición y una normal de mundo y, si se le da la
## dirección del golpe, deja el eje +X local a lo largo de ella (un chorro de sangre sale hacia donde iba
## el tajo) y, con [member direction_bias], inclina el +Z hacia ella (las chispas de un tajo salen
## desviadas en el sentido del filo).
## [br][br]
## No se conecta al combate todavía: quien lo haga ([CombatFeedback], por ejemplo) pide
## [method VfxPool.spawn] en el punto de contacto.

## Se emite cuando el efecto acaba (las partículas y las formas han terminado) y ya se puede reutilizar.
signal finished

## Aviso por defecto: lo que arranca con [method play].
const CUE_START: StringName = &"start"
const META_TIME: StringName = &"vfx_time"
const META_CUE: StringName = &"vfx_cue"
const META_TINT: StringName = &"vfx_tint"
const META_TINT_WEIGHT: StringName = &"vfx_tint_weight"
const META_NO_TINT: StringName = &"vfx_no_tint"
const META_VARIANTS: StringName = &"vfx_variants"
const META_VARIANT_OFFSET: StringName = &"vfx_variant_offset"
const PARAM_PROGRESS: StringName = &"progress"
const PARAM_TINT: StringName = &"tint"
const PARAM_VARIANT: StringName = &"variant"
const PARAM_FLIP: StringName = &"flip"

## Segundos hasta que el efecto se da por terminado y se puede reutilizar (en los continuos, lo que
## tarda en apagarse tras [method stop] sale de la vida de sus partículas).
@export var duration: float = 0.6
## Un efecto continuo no acaba solo: sigue hasta [method stop] (auras, por ejemplo).
@export var looping: bool = false
## Color con el que se tiñen los hijos (según su [code]vfx_tint_weight[/code]).
@export var tint: Color = Color.WHITE:
	set = set_tint
## Cuánto inclina [method play_at] el eje +Z hacia la dirección del golpe (0 = nada; 1 = a 45 grados).
@export_range(0.0, 2.0, 0.05) var direction_bias: float = 0.0

# Una malla animada por progreso.
class _Shape extends RefCounted:
	var node: GeometryInstance3D
	var enabled: bool = true
	var cue: StringName = CUE_START
	var delay: float = 0.0
	var length: float = 0.1
	var started: float = -1.0

# Unas partículas, con su aviso y el retardo con que se lanzan.
class _Burst extends RefCounted:
	var node: GPUParticles3D
	var enabled: bool = true
	var cue: StringName = CUE_START
	var delay: float = 0.0
	var start_at: float = -1.0

var _shapes: Array[_Shape] = []
var _bursts: Array[_Burst] = []
var _tintables: Array[GeometryInstance3D] = []
var _variant_nodes: Array[GeometryInstance3D] = []
var _play_count: int = 0
var _cue_lengths: Dictionary[StringName, float] = {}
var _tail: float = 0.0
var _is_setup: bool = false
var _playing: bool = false
var _stopping: bool = false
var _elapsed: float = 0.0
var _end_time: float = 0.0
# Instante en que acaba lo último que han lanzado los avisos (para que stop() no lo corte).
var _cue_end: float = 0.0


func _ready() -> void:
	_ensure_setup()
	reset()


## Lanza el efecto desde el principio en su sitio actual. Si ya sonaba, lo reinicia.
func play() -> void:
	_ensure_setup()
	_elapsed = 0.0
	_end_time = duration
	_cue_end = 0.0
	_playing = true
	_stopping = false
	visible = true
	for shape: _Shape in _shapes:
		shape.started = -1.0
		shape.node.visible = false
	_apply_variants()
	_play_count += 1
	trigger(CUE_START)
	set_process(true)


## Pone el efecto en [param position] con su eje +Z en [param normal] (la normal del impacto, en
## mundo) y lo lanza. El tinte es el de [member tint]. Con [param direction] (hacia dónde iba el golpe, en
## mundo; se proyecta sobre el plano del impacto) el eje +X queda a lo largo de ella y, si el efecto tiene
## [member direction_bias], el +Z se inclina hacia ella.
func play_at(position: Vector3, normal: Vector3 = Vector3.UP, direction: Vector3 = Vector3.ZERO) -> void:
	var facing: Vector3 = normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
	var tangent: Vector3 = direction - facing * direction.dot(facing)
	if tangent.length_squared() < 0.0001:
		var up: Vector3 = Vector3.UP if absf(facing.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		global_transform = Transform3D(Basis.looking_at(-facing, up), position)
		play()
		return
	tangent = tangent.normalized()
	if direction_bias > 0.0:
		facing = (facing + tangent * direction_bias).normalized()
		tangent = (tangent - facing * tangent.dot(facing)).normalized()
	global_transform = Transform3D(Basis(tangent, facing.cross(tangent), facing), position)
	play()


## Lanza lo que lleve el aviso [param cue] (formas y partículas con ese [code]vfx_cue[/code]). Solo vale
## con el efecto en marcha.
func trigger(cue: StringName) -> void:
	_ensure_setup()
	if not _playing:
		return
	for shape: _Shape in _shapes:
		if shape.cue == cue and shape.enabled:
			shape.started = _elapsed
	for burst: _Burst in _bursts:
		if burst.cue != cue or not burst.enabled:
			continue
		if burst.delay <= 0.0:
			_fire(burst)
		else:
			burst.start_at = _elapsed + burst.delay
	var cue_end: float = _elapsed + float(_cue_lengths.get(cue, 0.0))
	_cue_end = maxf(_cue_end, cue_end)
	_end_time = maxf(_end_time, cue_end)


## Enciende o apaga una parte del efecto por el nombre de su nodo (una forma o unas partículas): una parte
## apagada no se lanza con su aviso. Sirve para que un efecto de varios usos ([DustKick]) deje fuera lo que
## no toca (el anillo de polvo solo en las caídas fuertes).
func set_part_enabled(part_name: StringName, enabled: bool) -> void:
	_ensure_setup()
	for shape: _Shape in _shapes:
		if shape.node.name == part_name:
			shape.enabled = enabled
	for burst: _Burst in _bursts:
		if burst.node.name == part_name:
			burst.enabled = enabled


## Deja de emitir y acaba cuando se apaguen las últimas partículas (en los efectos continuos).
func stop() -> void:
	if not _playing or _stopping:
		return
	_stopping = true
	_end_time = maxf(_elapsed + _tail, _cue_end)
	for burst: _Burst in _bursts:
		burst.start_at = -1.0
		burst.node.emitting = false


## Lo apaga todo de golpe y lo deja listo para reutilizarse (oculto, sin emitir).
func reset() -> void:
	_ensure_setup()
	_playing = false
	_stopping = false
	_elapsed = 0.0
	for burst: _Burst in _bursts:
		burst.start_at = -1.0
		burst.node.emitting = false
	for shape: _Shape in _shapes:
		shape.started = -1.0
		shape.node.visible = false
	visible = false
	set_process(false)


## True mientras el efecto está sonando (de [method play] hasta [signal finished]).
func is_playing() -> bool:
	return _playing


## Segundos desde el último [method play].
func get_elapsed() -> float:
	return _elapsed


func set_tint(value: Color) -> void:
	tint = value
	if _is_setup:
		_apply_tint()


func _process(delta: float) -> void:
	if not _playing:
		set_process(false)
		return
	_elapsed += delta
	for burst: _Burst in _bursts:
		if burst.start_at >= 0.0 and _elapsed >= burst.start_at:
			burst.start_at = -1.0
			_fire(burst)
	for shape: _Shape in _shapes:
		if shape.started < 0.0:
			continue
		var progress: float = (_elapsed - shape.started - shape.delay) / shape.length
		var live: bool = progress >= 0.0 and progress < 1.0
		if shape.node.visible != live:
			shape.node.visible = live
		if live:
			shape.node.set_instance_shader_parameter(PARAM_PROGRESS, progress)
		elif progress >= 1.0:
			shape.started = -1.0
	if _elapsed >= _end_time and (_stopping or not looping):
		_finish()


func _fire(burst: _Burst) -> void:
	burst.node.restart()


func _finish() -> void:
	reset()
	finished.emit()


# Recorre los hijos una sola vez (también la hace [method _ready]; así un efecto se puede usar antes de
# entrar en el árbol).
func _ensure_setup() -> void:
	if _is_setup:
		return
	_is_setup = true
	for node: Node in find_children("*", "", true, false):
		_register(node)
	for burst: _Burst in _bursts:
		_tail = maxf(_tail, burst.node.lifetime / maxf(burst.node.speed_scale, 0.01))
	_apply_tint()


func _register(node: Node) -> void:
	var cue: StringName = StringName(node.get_meta(META_CUE, CUE_START))
	var timing: Vector2 = node.get_meta(META_TIME, Vector2.ZERO)
	var length: float = 0.0
	if node is GPUParticles3D:
		var particles: GPUParticles3D = node as GPUParticles3D
		var burst := _Burst.new()
		burst.node = particles
		burst.cue = cue
		burst.delay = timing.x
		_bursts.append(burst)
		particles.emitting = false
		length = timing.x + particles.lifetime / maxf(particles.speed_scale, 0.01)
		_tintables.append(particles)
	elif node is GeometryInstance3D:
		var instance: GeometryInstance3D = node as GeometryInstance3D
		if not bool(node.get_meta(META_NO_TINT, false)):
			_tintables.append(instance)
		if node.has_meta(META_VARIANTS):
			_variant_nodes.append(instance)
		if node.has_meta(META_TIME):
			var shape := _Shape.new()
			shape.node = instance
			shape.cue = cue
			shape.delay = timing.x
			shape.length = maxf(timing.y, 0.01)
			_shapes.append(shape)
			instance.visible = false
			length = timing.x + shape.length
	if length > 0.0:
		_cue_lengths[cue] = maxf(float(_cue_lengths.get(cue, 0.0)), length)


func _apply_tint() -> void:
	for instance: GeometryInstance3D in _tintables:
		var base: Color = instance.get_meta(META_TINT, Color.WHITE)
		var weight: float = float(instance.get_meta(META_TINT_WEIGHT, 1.0))
		var mixed: Color = Color.WHITE.lerp(tint, weight)
		instance.set_instance_shader_parameter(PARAM_TINT,
				Color(base.r * mixed.r, base.g * mixed.g, base.b * mixed.b, base.a * mixed.a))


# Elige la variante (fila del atlas) y el reflejo de cada malla con atlas de variantes, de forma que dos
# disparos seguidos no repitan chorro. Determinista: depende del número de disparos de esta copia.
func _apply_variants() -> void:
	for instance: GeometryInstance3D in _variant_nodes:
		var count: int = maxi(int(instance.get_meta(META_VARIANTS)), 1)
		var order: int = _play_count + int(instance.get_meta(META_VARIANT_OFFSET, 0))
		instance.set_instance_shader_parameter(PARAM_VARIANT, float(order % count))
		instance.set_instance_shader_parameter(PARAM_FLIP, -1.0 if floori(float(order) / float(count)) % 2 == 1 else 1.0)
