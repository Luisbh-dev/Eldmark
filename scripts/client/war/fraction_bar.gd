class_name FractionBar
extends Control
## Barra horizontal de una fracción (0 a 1) con un texto opcional encima, para el HUD de guerra (barra
## de captura, vida de la puerta, barra de jefe). Se dibuja con [method _draw]: fondo, relleno del
## color pedido y borde. Solo muestra; no lee nada.
## [br][br]
## Los colores, el grosor y el tamaño de letra son provisionales (a revisar con el arte de la
## interfaz, UI-02/ART-12).

const BACK_COLOR: Color = Color(0.04, 0.04, 0.05, 0.7)
const BORDER_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const TEXT_OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.85)

## Color del relleno.
var fill_color: Color = Color(0.78, 0.13, 0.15, 1.0):
	set(value):
		fill_color = value
		queue_redraw()
## Texto centrado sobre la barra (vacío = ninguno).
var text: String = "":
	set(value):
		text = value
		queue_redraw()
## Tamaño de letra del texto.
var font_size: int = 13

var _fraction: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(120.0, 12.0)


## Fracción rellena (0 a 1).
func set_fraction(value: float) -> void:
	var clamped: float = clampf(value, 0.0, 1.0)
	if is_equal_approx(clamped, _fraction):
		return
	_fraction = clamped
	queue_redraw()


func get_fraction() -> float:
	return _fraction


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	draw_rect(area, BACK_COLOR)
	if _fraction > 0.0:
		draw_rect(Rect2(area.position, Vector2(area.size.x * _fraction, area.size.y)), fill_color)
	draw_rect(area, BORDER_COLOR, false, 1.0)
	if text.is_empty():
		return
	var font: Font = get_theme_default_font()
	var text_size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var baseline := Vector2((size.x - text_size.x) * 0.5,
			(size.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5)
	draw_string_outline(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, 3, TEXT_OUTLINE)
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, TEXT_COLOR)
