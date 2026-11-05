class_name PlaceholderIcon
extends Texture2D
## Placeholder icon (docs/habilidades.md, sections 6.3 and 6.4; until the ART-12 icons): a square
## in the color of the weapon or effect with the action's initial on top. It is a [Texture2D] that draws
## itself, so it fits in any [UIIconSlot] and the cooldown sweeps are painted on top
## as with a real icon. No image: it costs no video memory. Client only.

## Side (px) the texture is declared with (it stretches to whatever the drawer asks).
const SIZE: int = 64
## Fraction of the side that the letter takes up.
const LETTER_SCALE: float = 0.55
const LETTER_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const LETTER_OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.7)

## Initial that is drawn (one or two letters).
@export var letter: String = "":
	set(value):
		letter = value
		emit_changed()
## Color of the square.
@export var color: Color = Color(0.4, 0.4, 0.45, 1.0):
	set(value):
		color = value
		emit_changed()


## An icon with the initial of [param text] (its first letter, uppercase) over [param fill].
static func make(text: String, fill: Color) -> PlaceholderIcon:
	var icon := PlaceholderIcon.new()
	icon.letter = text.strip_edges().left(1).to_upper()
	icon.color = fill
	return icon


func _get_width() -> int:
	return SIZE


func _get_height() -> int:
	return SIZE


func _has_alpha() -> bool:
	return false


func _is_pixel_opaque(_x: int, _y: int) -> bool:
	return true


func _draw(to_canvas_item: RID, pos: Vector2, modulate: Color, _transpose: bool) -> void:
	_paint(to_canvas_item, Rect2(pos, Vector2(SIZE, SIZE)), modulate)


func _draw_rect(to_canvas_item: RID, rect: Rect2, _tile: bool, modulate: Color,
		_transpose: bool) -> void:
	_paint(to_canvas_item, rect, modulate)


func _draw_rect_region(to_canvas_item: RID, rect: Rect2, _src_rect: Rect2, modulate: Color,
		_transpose: bool, _clip_uv: bool) -> void:
	_paint(to_canvas_item, rect, modulate)


# The square with a two-tone gradient (lighter at the top) and the letter centered with an outline.
func _paint(canvas_item: RID, rect: Rect2, modulate: Color) -> void:
	RenderingServer.canvas_item_add_rect(canvas_item, rect, color * modulate)
	var top := Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.45))
	RenderingServer.canvas_item_add_rect(canvas_item, top, color.lightened(0.18) * modulate)
	if letter.is_empty():
		return
	var font: Font = UIFonts.title_bold()
	if font == null:
		return
	var font_size: int = maxi(int(rect.size.y * LETTER_SCALE), 6)
	var ascent: float = font.get_ascent(font_size)
	var height: float = font.get_height(font_size)
	var baseline := Vector2(rect.position.x, rect.position.y + (rect.size.y - height) * 0.5 + ascent)
	font.draw_string_outline(canvas_item, baseline, letter, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x,
			font_size, 4, LETTER_OUTLINE * modulate)
	font.draw_string(canvas_item, baseline, letter, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x,
			font_size, LETTER_COLOR * modulate)
