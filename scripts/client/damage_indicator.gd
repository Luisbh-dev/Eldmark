class_name DamageIndicator
extends Control
## Damage direction arcs around the crosshair (UI-10). Each hit received draws a red
## arc on the edge of a ring centered on the screen, on the side it came from, and it
## fades out in [constant LIFETIME_SECONDS] s. The arcs are oriented according to the camera: a hit from
## behind appears at the bottom and, if the camera turns, the arc turns with it.
## [br][br]
## [method relative_angle] is the computation: the angle, relative to where the camera faces, of the
## direction the attacker is in. 0 is ahead (up on the screen), +PI/2 the right,
## -PI/2 the left and ±PI behind. The hit's angle [b]relative to the world[/b] is stored
## ([method add_hit]) and recomputed with the current camera every frame, so the arc keeps
## pointing at the attacker even if the view turns.

## Duration (s) of an arc and maximum number of arcs at once.
const LIFETIME_SECONDS: float = 1.4
const MAX_ARCS: int = 8
## Drawing: ring radius (px), thickness, arc half-width (radians) and stroke segments.
const RING_RADIUS: float = 140.0
const ARC_WIDTH: float = 10.0
const ARC_HALF_ANGLE: float = deg_to_rad(24.0)
const ARC_SEGMENTS: int = 20
const ARC_COLOR: Color = Color(0.9, 0.12, 0.1, 1.0)

## An arc: [code]world_yaw[/code] is the attacker's heading as seen from the victim (same
## convention as [member Node3D.rotation].y).
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


## Angle (radians, in [-PI, PI]) of the direction from [param from_position] to [param to_position]
## relative to where the camera faces ([param camera_yaw], same convention as
## [member Node3D.rotation].y): 0 ahead, +PI/2 to the right. Only the horizontal plane counts;
## if the two positions coincide in it, returns 0.
static func relative_angle(camera_yaw: float, from_position: Vector3, to_position: Vector3) -> float:
	var world_yaw: float = world_heading(from_position, to_position)
	return wrapf(world_yaw - camera_yaw, -PI, PI) * -1.0


## Heading (yaw) of the direction from [param from_position] to [param to_position]: 0 is toward -Z and
## grows toward -X (the convention of [member Node3D.rotation].y).
static func world_heading(from_position: Vector3, to_position: Vector3) -> float:
	var flat := Vector2(to_position.x - from_position.x, to_position.z - from_position.z)
	if flat.length_squared() < 0.0001:
		return 0.0
	return atan2(-flat.x, -flat.y)


## Records a hit received: [param world_yaw] is the attacker's heading as seen from the victim
## ([method world_heading]) and [param strength] (0 to 1) the arc's intensity.
func add_hit(world_yaw: float, strength: float = 1.0) -> void:
	var arc := _Arc.new()
	arc.world_yaw = world_yaw
	arc.strength = clampf(strength, 0.2, 1.0)
	_arcs.append(arc)
	while _arcs.size() > MAX_ARCS:
		_arcs.remove_at(0)
	queue_redraw()


## Camera yaw the arcs are oriented with. The [HUD] updates it every frame.
func set_camera_yaw(camera_yaw: float) -> void:
	if not is_equal_approx(camera_yaw, _camera_yaw):
		_camera_yaw = camera_yaw
		if not _arcs.is_empty():
			queue_redraw()


## Advances [param delta] seconds: ages the arcs and removes those that have already faded.
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


## Removes all arcs.
func clear() -> void:
	_arcs.clear()
	queue_redraw()


## Visible arcs.
func get_arc_count() -> int:
	return _arcs.size()


## On-screen angle of arc [param index] with the current camera (see [method relative_angle]).
func get_arc_angle(index: int) -> float:
	if index < 0 or index >= _arcs.size():
		return 0.0
	return wrapf(_arcs[index].world_yaw - _camera_yaw, -PI, PI) * -1.0


## Opacity of arc [param index].
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
		# On-screen angle -> draw_arc angle (0 = right, clockwise going down).
		var screen_angle: float = get_arc_angle(i) - PI * 0.5
		var color: Color = ARC_COLOR
		color.a = alpha
		draw_arc(center, RING_RADIUS, screen_angle - ARC_HALF_ANGLE, screen_angle + ARC_HALF_ANGLE,
				ARC_SEGMENTS, color, ARC_WIDTH, true)
