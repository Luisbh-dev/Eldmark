class_name PartyFrame
extends Control
## Frame of a party member (SOC-08, docs/social.md, section 12.5): their name in the realm color, the
## leader's crown, health and stamina, and the distance if they are far away. It is dimmed if they are dead, if
## they are far away or if their state is not known yet. It is drawn entirely in [method _draw]; [PartyFrames] places it and
## gives it the data with [method configure].
## [br][br]
## Provisional sizes and colors (pending the user). Client only.

const SIZE: Vector2 = Vector2(224.0, 50.0)
const PADDING: float = 8.0
const FONT_SIZE: int = 15
const SMALL_FONT_SIZE: int = 12
const HEALTH_HEIGHT: float = 11.0
const STAMINA_HEIGHT: float = 5.0
const BAR_GAP: float = 3.0
const CROWN_SIZE: Vector2 = Vector2(14.0, 10.0)
## Opacity of a dimmed frame (far, dead or without data).
const DIM_ALPHA: float = 0.45
## Distance (m) from which the distance is written next to the name.
const DISTANCE_TEXT_FROM: float = 30.0
const CROWN_COLOR: Color = Color(1.0, 0.82, 0.3, 1.0)
const DEAD_COLOR: Color = Color(0.45, 0.45, 0.47, 1.0)
const BACK_COLOR: Color = Color(0.03, 0.03, 0.04, 0.8)
const TEXT_DEAD: String = "Caído"
const TEXT_NO_DATA: String = "…"

var _net_id: int = 0
var _name: String = ""
var _color: Color = Color.WHITE
var _leader: bool = false
var _own: bool = false
var _health: float = 1.0
var _stamina: float = 1.0
var _dead: bool = false
var _has_data: bool = false
var _in_combat: bool = false
var _far: bool = false
var _distance: float = 0.0


func _init() -> void:
	custom_minimum_size = SIZE
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Sets the frame's data and repaints it. [param distance] is the distance (m) to the local player (INF if
## unknown); [param own] marks the player's own frame.
func configure(member: PartyState.Member, is_leader: bool, own: bool, distance: float,
		name_color: Color) -> void:
	_net_id = member.net_id
	_name = member.display_name
	_color = name_color
	_leader = is_leader
	_own = own
	_has_data = member.has_status
	_dead = member.is_dead()
	_in_combat = member.is_in_combat()
	_health = member.get_health_fraction() if _has_data else 1.0
	_stamina = member.get_stamina_fraction() if _has_data else 1.0
	_distance = distance
	_far = _has_data and not own and distance > PartyRules.FAR_DISTANCE
	modulate.a = DIM_ALPHA if (_dead or _far or not _has_data) else 1.0
	queue_redraw()


func get_net_id() -> int:
	return _net_id


func get_name_text() -> String:
	return _name


func get_name_color() -> Color:
	return _color


## true if the frame carries the leader's crown.
func is_leader_shown() -> bool:
	return _leader


## true if it is the player's own frame.
func is_own() -> bool:
	return _own


func get_health_fraction() -> float:
	return _health


func get_stamina_fraction() -> float:
	return _stamina


func is_dead() -> bool:
	return _dead


func is_in_combat() -> bool:
	return _in_combat


## true if the member is farther than [constant PartyRules.FAR_DISTANCE] m.
func is_far() -> bool:
	return _far


## true if the member's state has already arrived (otherwise the frame is dimmed and has no data).
func has_data() -> bool:
	return _has_data


## Distance (m) to the local player (INF if unknown).
func get_distance() -> float:
	return _distance


## true if the frame is shown dimmed (dead, far or without data).
func is_dimmed() -> bool:
	return _dead or _far or not _has_data


func _draw() -> void:
	var font: Font = UIFonts.body_semibold()
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, UIPalette.PANEL_BG)
	var border: Color = UIPalette.ACCENT if _own else UIPalette.BORDER
	draw_rect(rect, border, false, 1.0)
	var text_left: float = PADDING
	if _leader:
		_draw_crown(Vector2(PADDING, PADDING + 2.0))
		text_left += CROWN_SIZE.x + 5.0
	var baseline: float = PADDING + FONT_SIZE - 3.0
	draw_string_outline(font, Vector2(text_left, baseline), _name, HORIZONTAL_ALIGNMENT_LEFT,
			size.x - text_left - PADDING, FONT_SIZE, 3, UIPalette.OUTLINE)
	draw_string(font, Vector2(text_left, baseline), _name, HORIZONTAL_ALIGNMENT_LEFT,
			size.x - text_left - PADDING, FONT_SIZE, DEAD_COLOR if _dead else _color)
	if _has_data and not _own and _distance >= DISTANCE_TEXT_FROM and _distance < INF:
		var distance_text: String = "%d m" % roundi(_distance)
		draw_string(font, Vector2(PADDING, baseline), distance_text, HORIZONTAL_ALIGNMENT_RIGHT,
				size.x - PADDING * 2.0, SMALL_FONT_SIZE, UIPalette.TEXT_DIM)
	var bar_width: float = size.x - PADDING * 2.0
	var health_top: float = PADDING + FONT_SIZE + 3.0
	_draw_bar(Rect2(PADDING, health_top, bar_width, HEALTH_HEIGHT), _health,
			DEAD_COLOR if _dead else UIPalette.HEALTH)
	if _dead:
		draw_string(font, Vector2(PADDING, health_top + HEALTH_HEIGHT - 1.0), TEXT_DEAD,
				HORIZONTAL_ALIGNMENT_CENTER, bar_width, SMALL_FONT_SIZE, UIPalette.TEXT)
	elif not _has_data:
		draw_string(font, Vector2(PADDING, health_top + HEALTH_HEIGHT - 1.0), TEXT_NO_DATA,
				HORIZONTAL_ALIGNMENT_CENTER, bar_width, SMALL_FONT_SIZE, UIPalette.TEXT_DIM)
	_draw_bar(Rect2(PADDING, health_top + HEALTH_HEIGHT + BAR_GAP, bar_width, STAMINA_HEIGHT),
			_stamina, UIPalette.STAMINA if not _dead else DEAD_COLOR)


# A bar with its background and the fill up to [param fraction].
func _draw_bar(rect: Rect2, fraction: float, fill: Color) -> void:
	draw_rect(rect, BACK_COLOR)
	if fraction > 0.0:
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(fraction, 0.0, 1.0), rect.size.y)), fill)


# A three-point crown (the engine's font does not include the symbol).
func _draw_crown(top_left: Vector2) -> void:
	var w: float = CROWN_SIZE.x
	var h: float = CROWN_SIZE.y
	var points := PackedVector2Array([
		top_left + Vector2(0.0, h), top_left + Vector2(0.0, h * 0.25),
		top_left + Vector2(w * 0.25, h * 0.6), top_left + Vector2(w * 0.5, 0.0),
		top_left + Vector2(w * 0.75, h * 0.6), top_left + Vector2(w, h * 0.25),
		top_left + Vector2(w, h),
	])
	draw_colored_polygon(points, CROWN_COLOR)
