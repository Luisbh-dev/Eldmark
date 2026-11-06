class_name FractionBar
extends Control
## Horizontal bar of a fraction (0 to 1) with optional text on top, for the war HUD (capture bar, gate
## health, boss bar). It is drawn with [method _draw]: background, fill in the requested color and border.
## It only displays; it reads nothing.
## [br][br]
## The colors, thickness and font size are provisional (to be revised with the interface art, UI-02/ART-12).

const BACK_COLOR: Color = Color(0.04, 0.04, 0.05, 0.7)
const BORDER_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const TEXT_OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.85)

## Fill color.
var fill_color: Color = Color(0.78, 0.13, 0.15, 1.0):
	set(value):
		fill_color = value
		queue_redraw()
## Text centered over the bar (empty = none).
var text: String = "":
	set(value):
		text = value
		queue_redraw()
## Font size of the text.
var font_size: int = 13
## Thickness (px) of the dark outline around the text; thicker where the text sits on a bright fill.
var outline_size: int = 3

var _fraction: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(120.0, 12.0)


## Filled fraction (0 to 1).
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
	draw_string_outline(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, outline_size, TEXT_OUTLINE)
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, TEXT_COLOR)
