class_name DamageIndicator
extends Control
## Arcos de dirección del daño alrededor del punto de mira (UI-10). Cada golpe recibido dibuja un
## arco rojo en el borde de un anillo centrado en la pantalla, del lado de donde vino, y se
## desvanece en [constant LIFETIME_SECONDS] s. Los arcos se orientan según la cámara: un golpe por
## detrás sale abajo y, si la cámara gira, el arco gira con ella.
## [br][br]
## [method relative_angle] es la cuenta: el ángulo, respecto a hacia dónde mira la cámara, de la
## dirección en la que está el atacante. 0 es delante (arriba en la pantalla), +PI/2 la derecha,
## -PI/2 la izquierda y ±PI detrás. Se guarda el ángulo [b]respecto al mundo[/b] del golpe
## ([method add_hit]) y se recalcula con la cámara actual en cada fotograma, así el arco sigue
## señalando al atacante aunque se gire la vista.

## Duración (s) de un arco y arcos como mucho a la vez.
const LIFETIME_SECONDS: float = 1.4
const MAX_ARCS: int = 8
## Dibujo: radio del anillo (px), grosor, semiancho del arco (radianes) y tramos del trazo.
const RING_RADIUS: float = 140.0
const ARC_WIDTH: float = 10.0
const ARC_HALF_ANGLE: float = deg_to_rad(24.0)
const ARC_SEGMENTS: int = 20
const ARC_COLOR: Color = Color(0.9, 0.12, 0.1, 1.0)

## Un arco: [code]world_yaw[/code] es el rumbo del atacante visto desde la víctima (misma
## convención que [member Node3D.rotation].y).
class _Arc:
	var world_yaw: float = 0.0
	var age: float = 0.0
	var strength: float = 1.0

var _arcs: Array[_Arc] = []
var _camera_yaw: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	advance(delta)


## Ángulo (radianes, en [-PI, PI]) de la dirección de [param from_position] a [param to_position]
## respecto a hacia dónde mira la cámara ([param camera_yaw], misma convención que
## [member Node3D.rotation].y): 0 delante, +PI/2 a la derecha. Solo cuenta el plano horizontal;
## si las dos posiciones coinciden en él, devuelve 0.
static func relative_angle(camera_yaw: float, from_position: Vector3, to_position: Vector3) -> float:
	var world_yaw: float = world_heading(from_position, to_position)
	return wrapf(world_yaw - camera_yaw, -PI, PI) * -1.0


## Rumbo (yaw) de la dirección de [param from_position] a [param to_position]: 0 es hacia -Z y
## crece hacia -X (la convención de [member Node3D.rotation].y).
static func world_heading(from_position: Vector3, to_position: Vector3) -> float:
	var flat := Vector2(to_position.x - from_position.x, to_position.z - from_position.z)
	if flat.length_squared() < 0.0001:
		return 0.0
	return atan2(-flat.x, -flat.y)


## Apunta un golpe recibido: [param world_yaw] es el rumbo del atacante visto desde la víctima
## ([method world_heading]) y [param strength] (0 a 1) la intensidad del arco.
func add_hit(world_yaw: float, strength: float = 1.0) -> void:
	var arc := _Arc.new()
	arc.world_yaw = world_yaw
	arc.strength = clampf(strength, 0.2, 1.0)
	_arcs.append(arc)
	while _arcs.size() > MAX_ARCS:
		_arcs.remove_at(0)
	queue_redraw()


## Yaw de la cámara con el que se orientan los arcos. El [HUD] lo actualiza en cada fotograma.
func set_camera_yaw(camera_yaw: float) -> void:
	if not is_equal_approx(camera_yaw, _camera_yaw):
		_camera_yaw = camera_yaw
		if not _arcs.is_empty():
			queue_redraw()


## Avanza [param delta] segundos: envejece los arcos y quita los que ya se desvanecieron.
func advance(delta: float) -> void:
	if _arcs.is_empty():
		return
	var still: Array[_Arc] = []
	for arc: _Arc in _arcs:
		arc.age += delta
		if arc.age < LIFETIME_SECONDS:
			still.append(arc)
	_arcs = still
	queue_redraw()


## Quita todos los arcos.
func clear() -> void:
	_arcs.clear()
	queue_redraw()


## Arcos visibles.
func get_arc_count() -> int:
	return _arcs.size()


## Ángulo en pantalla del arco [param index] con la cámara actual (ver [method relative_angle]).
func get_arc_angle(index: int) -> float:
	if index < 0 or index >= _arcs.size():
		return 0.0
	return wrapf(_arcs[index].world_yaw - _camera_yaw, -PI, PI) * -1.0


## Opacidad del arco [param index].
func get_arc_alpha(index: int) -> float:
	if index < 0 or index >= _arcs.size():
		return 0.0
	var arc: _Arc = _arcs[index]
	return arc.strength * (1.0 - smoothstep(0.35, 1.0, arc.age / LIFETIME_SECONDS))


func _draw() -> void:
	var center: Vector2 = size * 0.5
	for i: int in _arcs.size():
		var alpha: float = get_arc_alpha(i)
		if alpha <= 0.0:
			continue
		# Ángulo en pantalla -> ángulo de draw_arc (0 = derecha, sentido horario hacia abajo).
		var screen_angle: float = get_arc_angle(i) - PI * 0.5
		var color: Color = ARC_COLOR
		color.a = alpha
		draw_arc(center, RING_RADIUS, screen_angle - ARC_HALF_ANGLE, screen_angle + ARC_HALF_ANGLE,
				ARC_SEGMENTS, color, ARC_WIDTH, true)
