class_name Crosshair
extends Control
## Punto de mira: un punto pequeño y un anillo fino en el centro de la pantalla.
##
## Se dibuja en el centro exacto del viewport, que es por donde pasa el rayo de
## apuntado de la cámara ([method CameraRig.get_aim_ray]). Ocupa toda la pantalla
## pero ignora el ratón para no bloquear clics. El HUD lo oculta mientras el
## cursor está libre.

const _RING_SEGMENTS: int = 48

## Radio del punto central, en píxeles.
@export var dot_radius: float = 2.0
## Radio del anillo, en píxeles.
@export var ring_radius: float = 10.0
## Grosor del trazo del anillo, en píxeles.
@export var ring_width: float = 1.5
## Grosor del contorno oscuro que rodea punto y anillo para que se lean sobre fondos claros.
@export var outline_width: float = 1.5
## Color principal del punto de mira.
@export var color: Color = Color(1.0, 1.0, 1.0, 0.95)
## Color del contorno.
@export var outline_color: Color = Color(0.0, 0.0, 0.0, 0.55)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	var center: Vector2 = size * 0.5
	# Primero los contornos oscuros y encima el trazo claro.
	var outline_ring_width: float = ring_width + outline_width * 2.0
	draw_arc(center, ring_radius, 0.0, TAU, _RING_SEGMENTS, outline_color, outline_ring_width, true)
	draw_circle(center, dot_radius + outline_width, outline_color, true, -1.0, true)
	draw_arc(center, ring_radius, 0.0, TAU, _RING_SEGMENTS, color, ring_width, true)
	draw_circle(center, dot_radius, color, true, -1.0, true)
