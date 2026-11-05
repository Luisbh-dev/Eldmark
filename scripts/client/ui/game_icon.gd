class_name GameIcon
extends Texture2D
## Game icon (ART-12): a figure from `assets/ui/icons/` (128 px PNG with no background) over the background of its
## category (`assets/ui/icons/backgrounds/`, full-bleed and frameless). It is a [Texture2D] that draws itself,
## so it fits in any [UIIconSlot] just like a [PlaceholderIcon] and the cooldown sweeps are painted on top. The background is
## stretched to the slot; so is the figure (the icons were made square). Client only.

## Side (px) the texture is declared with.
const SIZE: int = 128

## Figure without background.
@export var figure: Texture2D = null:
	set(value):
		figure = value
		emit_changed()
## Category background (may be missing: the figure is drawn alone).
@export var background: Texture2D = null:
	set(value):
		background = value
		emit_changed()


## An icon with the figure [param figure_texture] over [param background_texture].
static func make(figure_texture: Texture2D, background_texture: Texture2D) -> GameIcon:
	var icon := GameIcon.new()
	icon.figure = figure_texture
	icon.background = background_texture
	return icon


func _get_width() -> int:
	return SIZE


func _get_height() -> int:
	return SIZE


func _has_alpha() -> bool:
	return false


func _draw(to_canvas_item: RID, pos: Vector2, modulate: Color, _transpose: bool) -> void:
	_paint(to_canvas_item, Rect2(pos, Vector2(SIZE, SIZE)), modulate)


func _draw_rect(to_canvas_item: RID, rect: Rect2, _tile: bool, modulate: Color,
		_transpose: bool) -> void:
	_paint(to_canvas_item, rect, modulate)


func _draw_rect_region(to_canvas_item: RID, rect: Rect2, _src_rect: Rect2, modulate: Color,
		_transpose: bool, _clip_uv: bool) -> void:
	_paint(to_canvas_item, rect, modulate)


func _paint(canvas_item: RID, rect: Rect2, modulate: Color) -> void:
	if background != null:
		background.draw_rect(canvas_item, rect, false, modulate)
	if figure != null:
		figure.draw_rect(canvas_item, rect, false, modulate)
