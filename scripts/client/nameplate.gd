class_name Nameplate
extends Control
## Placa de un jugador sobre su cabeza (UI-07, UI-13): el nombre con el color de su reino y, debajo,
## la barra de vida. Es un dibujo sin lógica: [Nameplates] la coloca en la pantalla y le dice qué
## enseñar con [method configure]. Se reutiliza (pool): al soltarla se oculta.

## Tamaño de la placa (px) y de la barra.
const PLATE_SIZE: Vector2 = Vector2(160.0, 34.0)
const BAR_SIZE: Vector2 = Vector2(84.0, 7.0)
const FONT_SIZE: int = 15
const OUTLINE_SIZE: int = 4
const BAR_BACK_COLOR: Color = Color(0.03, 0.03, 0.04, 0.75)
const ALLY_BAR_COLOR: Color = Color(0.36, 0.8, 0.38, 1.0)
const ENEMY_BAR_COLOR: Color = Color(0.86, 0.2, 0.18, 1.0)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)

var _text: String = ""
var _color: Color = Color.WHITE
var _show_name: bool = true
var _show_bar: bool = true
var _fraction: float = 1.0
var _ally: bool = false
var _alpha: float = 1.0
var _net_id: int = 0


func _init() -> void:
	size = PLATE_SIZE
	custom_minimum_size = PLATE_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


## Qué enseñar: el nombre [param text] con el color [param color] (si [param show_name]), la barra
## con [param health_fraction] (si [param show_bar]; verde para aliados, roja para enemigos) y la
## opacidad [param alpha]. [param net_id] es la entidad a la que corresponde.
func configure(net_id: int, text: String, color: Color, show_name: bool, show_bar: bool,
		health_fraction: float, ally: bool, alpha: float) -> void:
	_net_id = net_id
	_text = text
	_color = color
	_show_name = show_name
	_show_bar = show_bar
	_fraction = clampf(health_fraction, 0.0, 1.0)
	_ally = ally
	_alpha = clampf(alpha, 0.0, 1.0)
	modulate.a = _alpha
	queue_redraw()


## Coloca la placa de modo que su borde inferior central quede en [param screen_point].
func place(screen_point: Vector2) -> void:
	position = screen_point - Vector2(size.x * 0.5, size.y)


## Oculta la placa (vuelve al pool).
func release() -> void:
	visible = false
	_net_id = 0


func get_net_id() -> int:
	return _net_id


func get_name_text() -> String:
	return _text


func is_name_shown() -> bool:
	return _show_name


func is_bar_shown() -> bool:
	return _show_bar


func get_health_fraction() -> float:
	return _fraction


func get_color() -> Color:
	return _color


func get_alpha() -> float:
	return _alpha


func is_ally() -> bool:
	return _ally


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	var bar_top: float = size.y - BAR_SIZE.y - 2.0
	if _show_name and not _text.is_empty():
		var baseline: float = bar_top - 5.0 if _show_bar else size.y - 6.0
		draw_string_outline(font, Vector2(0.0, baseline), _text, HORIZONTAL_ALIGNMENT_CENTER,
				size.x, FONT_SIZE, OUTLINE_SIZE, OUTLINE_COLOR)
		draw_string(font, Vector2(0.0, baseline), _text, HORIZONTAL_ALIGNMENT_CENTER, size.x,
				FONT_SIZE, _color)
	if _show_bar:
		var rect := Rect2(Vector2((size.x - BAR_SIZE.x) * 0.5, bar_top), BAR_SIZE)
		draw_rect(rect, BAR_BACK_COLOR)
		var fill: Color = ALLY_BAR_COLOR if _ally else ENEMY_BAR_COLOR
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * _fraction, rect.size.y)), fill)
		draw_rect(rect, OUTLINE_COLOR, false, 1.0)
