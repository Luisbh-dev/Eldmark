class_name Crosshair
extends Control
## Crosshair: a small dot and a thin ring at the center of the screen.
##
## It is drawn at the exact center of the viewport, which is where the camera's
## aiming ray passes ([method CameraRig.get_aim_ray]). It fills the whole screen
## but ignores the mouse so as not to block clicks. The HUD hides it while the
## cursor is free.
## [br][br]
## [b]Bow[/b] (docs/habilidades.md, section 6.5): while drawing, the ring closes with the charge
## ([method set_tension], from 0 to 1) down to [member tense_ring_scale] of its radius.

const _RING_SEGMENTS: int = 48

## Radius of the central dot, in pixels.
@export var dot_radius: float = 2.0
## Radius of the ring, in pixels.
@export var ring_radius: float = 10.0
## Stroke width of the ring, in pixels.
@export var ring_width: float = 1.5
## Width of the dark outline around the dot and ring so they read on light backgrounds.
@export var outline_width: float = 1.5
## Main color of the crosshair.
@export var color: Color = Color(1.0, 1.0, 1.0, 0.95)
## Outline color.
@export var outline_color: Color = Color(0.0, 0.0, 0.0, 0.55)
## Fraction of the ring's radius with the bow drawn to the maximum.
@export var tense_ring_scale: float = 0.35

var _tension: float = 0.0


## Closes the ring with the bow's tension: 0 open (nothing to draw), 1 at maximum.
func set_tension(amount: float) -> void:
	var clamped: float = clampf(amount, 0.0, 1.0)
	if is_equal_approx(clamped, _tension):
		return
	_tension = clamped
	queue_redraw()


func get_tension() -> float:
	return _tension


## Radius of the ring now (px), with the bow's tension.
func get_ring_radius() -> float:
	return ring_radius * lerpf(1.0, tense_ring_scale, _tension)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	var center: Vector2 = size * 0.5
	var radius: float = get_ring_radius()
	# Dark outlines first and the light stroke on top.
	var outline_ring_width: float = ring_width + outline_width * 2.0
	draw_arc(center, radius, 0.0, TAU, _RING_SEGMENTS, outline_color, outline_ring_width, true)
	draw_circle(center, dot_radius + outline_width, outline_color, true, -1.0, true)
	draw_arc(center, radius, 0.0, TAU, _RING_SEGMENTS, color, ring_width, true)
	draw_circle(center, dot_radius, color, true, -1.0, true)
