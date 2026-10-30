class_name Crosshair
extends Control
## Punto de mira: un punto pequeño y un anillo fino en el centro de la pantalla.
##
## Se dibuja en el centro exacto del viewport, que es por donde pasa el rayo de
## apuntado de la cámara ([method CameraRig.get_aim_ray]). Ocupa toda la pantalla
## pero ignora el ratón para no bloquear clics. El HUD lo oculta mientras el
## cursor está libre.
## [br][br]
## [b]Arco[/b] (docs/habilidades.md, sección 6.5): tensando, el anillo se cierra con la carga
## ([method set_tension], de 0 a 1) hasta [member tense_ring_scale] de su radio.

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
## Fracción del radio del anillo con el arco tensado al máximo.
@export var tense_ring_scale: float = 0.35

var _tension: float = 0.0


## Cierra el anillo con la tensión del arco: 0 abierto (nada que tensar), 1 al máximo.
func set_tension(amount: float) -> void:
	var clamped: float = clampf(amount, 0.0, 1.0)
	if is_equal_approx(clamped, _tension):
		return
	_tension = clamped
	queue_redraw()


func get_tension() -> float:
	return _tension


## Radio del anillo ahora (px), con la tensión del arco.
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
	# Primero los contornos oscuros y encima el trazo claro.
	var outline_ring_width: float = ring_width + outline_width * 2.0
	draw_arc(center, radius, 0.0, TAU, _RING_SEGMENTS, outline_color, outline_ring_width, true)
	draw_circle(center, dot_radius + outline_width, outline_color, true, -1.0, true)
	draw_arc(center, radius, 0.0, TAU, _RING_SEGMENTS, color, ring_width, true)
	draw_circle(center, dot_radius, color, true, -1.0, true)
