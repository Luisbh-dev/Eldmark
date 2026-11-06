class_name Nameplate
extends Control
## A player's plate above their head (UI-07, UI-13): the name in their realm's color and, below,
## the health bar. It is a drawing with no logic: [Nameplates] places it on screen and tells it what
## to show with [method configure]. It is reused (pool): releasing it hides it.
## [br][br]
## Phase 4 (UI-45, docs/abilities.md, section 6.4): above the name, up to 4 icons of their effects
## (harmful ones first, [method set_statuses]); when knocked down ([method set_downed]), the bar is their
## knocked-down health, in orange, with a knocked-down icon on its left.
## [br][br]
## Phase 5 (docs/progression.md §7.3): in front of the name, the player's level ([method set_level]) in gray, only if
## known (an enemy's does not cross the network and arrives as 0).

## Size of the plate (px) and of the bar.
const PLATE_SIZE: Vector2 = Vector2(160.0, 56.0)
## Effect icons that fit on a plate.
const MAX_STATUS_ICONS: int = 4
const DOWNED_BAR_COLOR: Color = Color(0.78, 0.74, 0.92, 1.0)
const BAR_SIZE: Vector2 = Vector2(84.0, 7.0)
## Bar of someone nearby (less than [constant NEAR_RANGE] m): slightly larger, to read it at a glance.
const BAR_SIZE_NEAR: Vector2 = Vector2(108.0, 9.0)
const NEAR_RANGE: float = 15.0
const FONT_SIZE: int = 15
const OUTLINE_SIZE: int = 4
const BAR_BACK_COLOR: Color = Color(0.03, 0.03, 0.04, 0.75)
const ALLY_BAR_COLOR: Color = UIPalette.ALLY
const ENEMY_BAR_COLOR: Color = UIPalette.ENEMY
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
## Color of the level in front of the name. # TODO(art): provisional.
const LEVEL_COLOR: Color = Color(0.78, 0.76, 0.7, 1.0)
const TEXT_LEVEL: String = "Nv %d"

## Side mark above the head (UI-56): none, ally (circle) or enemy (diamond).
enum Mark { NONE, ALLY, ENEMY }
## Side (px) of the mark.
const MARK_SIZE: float = 11.0

var _mark: int = Mark.NONE
var _mark_color: Color = Color.WHITE
var _near: bool = false
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
var _level: int = 0


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


## What to show: the name [param text] in color [param color] (if [param show_name]), the bar
## with [param health_fraction] (if [param show_bar]; green for allies, red for enemies) and the
## opacity [param alpha]. [param net_id] is the entity it corresponds to.
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


## Places the plate so that its bottom center edge lands on [param screen_point].
func place(screen_point: Vector2) -> void:
	position = screen_point - Vector2(size.x * 0.5, size.y)


## Hides the plate (back to the pool).
func release() -> void:
	visible = false
	_net_id = 0
	_downed = false
	_level = 0
	_mark = Mark.NONE
	_near = false
	var none: Array[StatusTracker.Entry] = []
	_statuses.show_entries(none, 0)


## The effects of [param tracker] alive at [param tick] (the draw tick): up to [constant MAX_STATUS_ICONS],
## harmful ones first. Returns how many it shows.
func set_statuses(tracker: StatusTracker, tick: int) -> int:
	return _statuses.show_tracker(tracker, tick)


## Row of effect icons of the plate.
func get_status_icons() -> StatusIcons:
	return _statuses


## Knocked down: orange knocked-down health bar and the knocked-down icon.
func set_downed(downed: bool) -> void:
	if _downed != downed:
		_downed = downed
		queue_redraw()


func is_downed() -> bool:
	return _downed


## Level shown in front of the name (0 = none).
func set_level(level: int) -> void:
	if _level != level:
		_level = maxi(level, 0)
		queue_redraw()


func get_level() -> int:
	return _level


## Level text ("Nv 12", i.e. "Lv 12"; empty without a level).
func get_level_text() -> String:
	return TEXT_LEVEL % _level if _level > 0 else ""


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


## Side mark above the head ([enum Mark]) in the realm's color; [constant Mark.NONE] removes it.
func set_mark(mark: int, color: Color = Color.WHITE) -> void:
	if _mark != mark or _mark_color != color:
		_mark = mark
		_mark_color = color
		queue_redraw()


func get_mark() -> int:
	return _mark


## Near (less than [constant NEAR_RANGE] m): the bar is drawn slightly larger.
func set_near(near: bool) -> void:
	if _near != near:
		_near = near
		queue_redraw()


func is_near() -> bool:
	return _near


## Size of the health bar right now.
func get_bar_size() -> Vector2:
	return BAR_SIZE_NEAR if _near else BAR_SIZE


## Rectangle (in plate coordinates) that what is drawn actually occupies: mark, name and bar. [Nameplates] uses it
## to stack the plates that touch.
func get_content_rect() -> Rect2:
	var bar_size: Vector2 = get_bar_size()
	var bottom: float = size.y
	var top: float = size.y
	var width: float = 0.0
	if _show_bar:
		top = size.y - bar_size.y - 2.0
		width = bar_size.x
	if _show_name and not _text.is_empty():
		var text: String = _text if _level <= 0 else "%s %s" % [get_level_text(), _text]
		var name_width: float = UIFonts.body_semibold().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				FONT_SIZE).x
		width = maxf(width, name_width)
		top -= FONT_SIZE + 7.0
	if _mark != Mark.NONE:
		top -= MARK_SIZE + 3.0
		width = maxf(width, MARK_SIZE)
	return Rect2((size.x - width) * 0.5, top, width, bottom - top)


func _draw() -> void:
	var font: Font = UIFonts.body_semibold()
	var bar_size: Vector2 = get_bar_size()
	var bar_top: float = size.y - bar_size.y - 2.0
	if _show_name and not _text.is_empty():
		var baseline: float = bar_top - 5.0 if _show_bar else size.y - 6.0
		var level_text: String = get_level_text()
		if level_text.is_empty():
			draw_string_outline(font, Vector2(0.0, baseline), _text, HORIZONTAL_ALIGNMENT_CENTER,
					size.x, FONT_SIZE, OUTLINE_SIZE, OUTLINE_COLOR)
			draw_string(font, Vector2(0.0, baseline), _text, HORIZONTAL_ALIGNMENT_CENTER, size.x,
					FONT_SIZE, _color)
		else:
			# Centered "Nv 12 Nombre" ("Lv 12 Name"): the level in gray and the name in its color.
			var prefix: String = level_text + " "
			var prefix_width: float = font.get_string_size(prefix, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE).x
			var name_width: float = font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE).x
			var start: float = maxf((size.x - prefix_width - name_width) * 0.5, 0.0)
			draw_string_outline(font, Vector2(start, baseline), prefix, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
					FONT_SIZE, OUTLINE_SIZE, OUTLINE_COLOR)
			draw_string(font, Vector2(start, baseline), prefix, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE,
					LEVEL_COLOR)
			var name_x: float = start + prefix_width
			draw_string_outline(font, Vector2(name_x, baseline), _text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
					FONT_SIZE, OUTLINE_SIZE, OUTLINE_COLOR)
			draw_string(font, Vector2(name_x, baseline), _text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE,
					_color)
	if _mark != Mark.NONE:
		var mark_bottom: float = bar_top - 2.0
		if _show_name and not _text.is_empty():
			mark_bottom -= FONT_SIZE + 5.0
		_draw_mark(Vector2(size.x * 0.5, mark_bottom - MARK_SIZE * 0.5 - 1.0))
	if _show_bar:
		var rect := Rect2(Vector2((size.x - bar_size.x) * 0.5, bar_top), bar_size)
		draw_rect(rect, BAR_BACK_COLOR)
		var fill: Color = ALLY_BAR_COLOR if _ally else ENEMY_BAR_COLOR
		if _downed:
			fill = DOWNED_BAR_COLOR
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * _fraction, rect.size.y)), fill)
		draw_rect(rect, OUTLINE_COLOR, false, 1.0)
		if _downed:
			# Knocked-down icon: a lavender triangle pointing down (someone who fell) to the left of the bar. Not a diamond,
			# which is the enemy mark, and not amber, which is the telegraph (Q13).
			var center := Vector2(rect.position.x - 9.0, rect.get_center().y)
			var diamond := PackedVector2Array([center + Vector2(-6.0, -5.0), center + Vector2(6.0, -5.0),
					center + Vector2(0.0, 6.0)])
			draw_colored_polygon(diamond, CombatIcons.DOWNED_COLOR)
			draw_polyline(diamond + PackedVector2Array([diamond[0]]), OUTLINE_COLOR, 1.0, true)


# The side mark: a circle with a light ring for allies and a diamond with a dark ring for enemies,
# both in the realm's color. The shape can be told apart without reading the color (color blindness) and at 20 m without aiming.
func _draw_mark(center: Vector2) -> void:
	var half: float = MARK_SIZE * 0.5
	if _mark == Mark.ALLY:
		draw_circle(center, half + 1.5, OUTLINE_COLOR)
		draw_circle(center, half, _mark_color)
		draw_arc(center, half, 0.0, TAU, 20, Color(1.0, 1.0, 1.0, 0.85), 1.5, true)
	else:
		var outer := PackedVector2Array([center + Vector2(0.0, -half - 1.5), center + Vector2(half + 1.5, 0.0),
				center + Vector2(0.0, half + 1.5), center + Vector2(-half - 1.5, 0.0)])
		draw_colored_polygon(outer, OUTLINE_COLOR)
		var inner := PackedVector2Array([center + Vector2(0.0, -half), center + Vector2(half, 0.0),
				center + Vector2(0.0, half), center + Vector2(-half, 0.0)])
		draw_colored_polygon(inner, _mark_color)
