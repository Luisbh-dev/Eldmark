class_name Nameplate
extends Control
## Placa de un jugador sobre su cabeza (UI-07, UI-13): el nombre con el color de su reino y, debajo,
## la barra de vida. Es un dibujo sin lógica: [Nameplates] la coloca en la pantalla y le dice qué
## enseñar con [method configure]. Se reutiliza (pool): al soltarla se oculta.
## [br][br]
## Fase 4 (UI-45, docs/habilidades.md, sección 6.4): encima del nombre, hasta 4 iconos de sus efectos
## (primero los perjudiciales, [method set_statuses]); derribado ([method set_downed]), la barra es la de
## su vida de derribado, en naranja, con un icono de derribado a su izquierda.

## Tamaño de la placa (px) y de la barra.
const PLATE_SIZE: Vector2 = Vector2(160.0, 56.0)
## Iconos de efectos que caben en una placa.
const MAX_STATUS_ICONS: int = 4
const DOWNED_BAR_COLOR: Color = Color(0.95, 0.55, 0.15, 1.0)
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
var _downed: bool = false
var _statuses: StatusIcons = null


func _init() -> void:
	size = PLATE_SIZE
	custom_minimum_size = PLATE_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_statuses = StatusIcons.new()
	_statuses.name = "Efectos"
	_statuses.compact = true
	_statuses.harmful_first = true
	_statuses.max_icons = MAX_STATUS_ICONS
	_statuses.position = Vector2(0.0, 0.0)
	_statuses.size = Vector2(PLATE_SIZE.x, StatusIcons.COMPACT_ICON_SIZE)
	add_child(_statuses)


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
	_downed = false
	var none: Array[StatusTracker.Entry] = []
	_statuses.show_entries(none, 0)


## Los efectos de [param tracker] vivos en [param tick] (el de dibujo): hasta [constant MAX_STATUS_ICONS],
## primero los perjudiciales. Devuelve cuántos enseña.
func set_statuses(tracker: StatusTracker, tick: int) -> int:
	return _statuses.show_tracker(tracker, tick)


## Fila de iconos de efectos de la placa.
func get_status_icons() -> StatusIcons:
	return _statuses


## Derribado: barra de vida de derribado en naranja y el icono de derribado.
func set_downed(downed: bool) -> void:
	if _downed != downed:
		_downed = downed
		queue_redraw()


func is_downed() -> bool:
	return _downed


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
		if _downed:
			fill = DOWNED_BAR_COLOR
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * _fraction, rect.size.y)), fill)
		draw_rect(rect, OUTLINE_COLOR, false, 1.0)
		if _downed:
			# Icono de derribado: un rombo naranja a la izquierda de la barra.
			var center := Vector2(rect.position.x - 9.0, rect.get_center().y)
			var diamond := PackedVector2Array([center + Vector2(0.0, -6.0), center + Vector2(6.0, 0.0),
					center + Vector2(0.0, 6.0), center + Vector2(-6.0, 0.0)])
			draw_colored_polygon(diamond, CombatIcons.DOWNED_COLOR)
			draw_polyline(diamond + PackedVector2Array([diamond[0]]), OUTLINE_COLOR, 1.0, true)
