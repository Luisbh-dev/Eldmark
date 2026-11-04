class_name GameIcon
extends Texture2D
## Icono de juego (ART-12): una figura de `assets/ui/icons/` (PNG de 128 px sin fondo) sobre el fondo de su
## categoría (`assets/ui/icons/backgrounds/`, a sangre y sin marco). Es una [Texture2D] que se dibuja a sí
## misma, así que entra en cualquier [UIIconSlot] igual que un [PlaceholderIcon] y los barridos de
## reutilización se pintan encima. El fondo se estira a la casilla; la figura, también (los iconos se
## hicieron cuadrados). Solo cliente.

## Lado (px) con el que se declara la textura.
const SIZE: int = 128

## Figura sin fondo.
@export var figure: Texture2D = null:
	set(value):
		figure = value
		emit_changed()
## Fondo de la categoría (puede faltar: la figura se dibuja sola).
@export var background: Texture2D = null:
	set(value):
		background = value
		emit_changed()


## Un icono con la figura [param figure_texture] sobre [param background_texture].
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
