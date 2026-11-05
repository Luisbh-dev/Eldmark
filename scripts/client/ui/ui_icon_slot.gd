class_name UIIconSlot
extends Control
## Icon slot (UI-09): the building block of action bars, inventories and effects.
## It draws an icon over a recessed background with a border in its rarity color, a stack counter
## at the bottom right, a key glyph ([UIKeyGlyph]) at the top left and, when on
## cooldown, a clockwise sweep with the seconds remaining. When it becomes ready it gives a
## brief flash.
## [br][br]
## [b]Cooldown.[/b] [method start_cooldown] starts it (predicted on press) and
## [method set_cooldown] sets it to what the server says (it corrects it if the server rejects the action or
## it arrives with a different time); [method clear_cooldown] removes it. Time is driven by [method advance]
## ([method _process] calls it with each frame's delta, only while needed); tests
## call it with exact steps. The sweep is the polygon from [method sweep_polygon].
## [br][br]
## [b]Input.[/b] A single left click on the slot, or accepting while it is focused, emits
## [signal pressed]; the slot does not decide whether the action is valid (that is up to whoever listens). It is
## focusable ([constant Control.FOCUS_ALL]) for keyboard or gamepad navigation ([UIFocus]) and sounds through
## [UISounds] on hover and on press.
## [br][br]
## [b]Tooltip.[/b] [method set_tooltip_info] stores the content and [method bind_tooltip] links it to
## a [UITooltip]; the title carries the rarity color.
## [br][br]
## Client only. Everything is drawn in [method _draw] (no child nodes except the glyph): a bar with
## dozens of slots costs nothing.

## The slot was pressed (left click or accept while focused).
signal pressed
## The cooldown reached zero.
signal cooldown_finished

const SLOT_SIZE: Vector2 = Vector2(52.0, 52.0)
## Seconds the "ready" flash lasts.
const FLASH_SECONDS: float = 0.3
## Margin (px) between the border and the icon.
const ICON_MARGIN: float = 3.0
const BORDER_WIDTH: int = 2
const COUNT_FONT_SIZE: int = 14
const COOLDOWN_FONT_SIZE: int = 18
const COOLDOWN_OVERLAY: Color = Color(0.0, 0.0, 0.0, 0.62)
const DISABLED_TINT: Color = Color(0.45, 0.45, 0.45, 0.8)

## Icon (null: empty slot).
var icon: Texture2D = null:
	set(value):
		icon = value
		queue_redraw()
## Rarity ([enum UIPalette.Rarity]) that gives the border color; -1 = no rarity (metal border).
var rarity: int = -1:
	set(value):
		rarity = value
		queue_redraw()
## Stack size: only drawn if greater than 1.
var count: int = 0:
	set(value):
		count = value
		queue_redraw()
## Action whose key glyph is shown at the top left (empty: no glyph).
var key_action: StringName = &"":
	set(value):
		key_action = value
		_update_glyph()
## If false, the icon is shown dimmed.
var enabled: bool = true:
	set(value):
		enabled = value
		queue_redraw()
## Selected slot (accent border).
var selected: bool = false:
	set(value):
		selected = value
		queue_redraw()
## Tooltip content: [code]title[/code], [code]subtitle[/code] and [code]body[/code].
var tooltip_info: Dictionary = {}

var _cooldown_total: float = 0.0
var _cooldown_left: float = 0.0
var _flash_left: float = 0.0
var _hovered: bool = false
var _glyph: UIKeyGlyph = null
var _box: StyleBoxFlat = StyleBoxFlat.new()


## Text of the seconds remaining: whole numbers rounded up from 1 s ("9") and with one decimal below
## that ("0,7").
static func cooldown_text(seconds: float) -> String:
	if seconds <= 0.0:
		return ""
	if seconds < 1.0:
		return ("%.1f" % seconds).replace(".", ",")
	return str(ceili(seconds))


## Polygon covering the swept part of [param rect], clockwise from 12 o'clock,
## by [param fraction] (0 to 1) of a full turn: with 1 it is the whole rectangle, with 0.5 the right
## half, with 0 empty. It is a fan from the center that follows the rectangle's edge.
static func sweep_polygon(rect: Rect2, fraction: float) -> PackedVector2Array:
	var amount: float = clampf(fraction, 0.0, 1.0)
	if amount <= 0.0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return PackedVector2Array()
	var center: Vector2 = rect.get_center()
	var start_angle: float = -PI / 2.0
	var end_angle: float = start_angle + TAU * amount
	var points: PackedVector2Array = PackedVector2Array([center, _edge_point(rect, start_angle)])
	# The corners that fall inside the arc, in increasing angle order.
	var corners: Array[Vector2] = [rect.position + Vector2(rect.size.x, 0.0), rect.end,
			rect.position + Vector2(0.0, rect.size.y), rect.position]
	for corner: Vector2 in corners:
		var angle: float = (corner - center).angle()
		while angle <= start_angle + 0.00001:
			angle += TAU
		if angle < end_angle - 0.00001:
			points.append(corner)
	points.append(_edge_point(rect, end_angle))
	return points


# Point on the edge of [param rect] in direction [param angle] from its center.
static func _edge_point(rect: Rect2, angle: float) -> Vector2:
	var center: Vector2 = rect.get_center()
	var direction: Vector2 = Vector2(cos(angle), sin(angle))
	var half: Vector2 = rect.size * 0.5
	var scale_x: float = half.x / absf(direction.x) if absf(direction.x) > 0.000001 else INF
	var scale_y: float = half.y / absf(direction.y) if absf(direction.y) > 0.000001 else INF
	return center + direction * minf(scale_x, scale_y)


func _init() -> void:
	custom_minimum_size = SLOT_SIZE
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


func _ready() -> void:
	# The engine enables _process on entering the tree if the script defines it: it is turned off until
	# needed (a cooldown in progress or a flash).
	set_process(_cooldown_left > 0.0 or _flash_left > 0.0)


func _process(delta: float) -> void:
	advance(delta)


# --- Cooldown ---------------------------------------------------------------------------------

## Starts a cooldown of [param seconds] seconds (the prediction on press).
func start_cooldown(seconds: float) -> void:
	if seconds <= 0.0:
		clear_cooldown()
		return
	_cooldown_total = seconds
	_cooldown_left = seconds
	_flash_left = 0.0
	set_process(true)
	queue_redraw()


## Sets the cooldown to what the server says: [param remaining] s of [param total] remain.
## With [param remaining] at 0 or less it removes it without a flash (for example, the server rejected the
## action and it was never spent).
func set_cooldown(remaining: float, total: float) -> void:
	if remaining <= 0.0:
		clear_cooldown()
		return
	_cooldown_total = maxf(total, remaining)
	_cooldown_left = remaining
	set_process(true)
	queue_redraw()


## Removes the cooldown without a flash.
func clear_cooldown() -> void:
	_cooldown_total = 0.0
	_cooldown_left = 0.0
	queue_redraw()


## Advances the cooldown and the flash by [param delta] seconds. On reaching zero it emits
## [signal cooldown_finished] and gives the flash.
func advance(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(_cooldown_left - delta, 0.0)
		if _cooldown_left <= 0.0:
			_cooldown_total = 0.0
			_flash_left = FLASH_SECONDS
			cooldown_finished.emit()
		queue_redraw()
	elif _flash_left > 0.0:
		_flash_left = maxf(_flash_left - delta, 0.0)
		queue_redraw()
	if _cooldown_left <= 0.0 and _flash_left <= 0.0:
		set_process(false)


func is_on_cooldown() -> bool:
	return _cooldown_left > 0.0


## Seconds remaining.
func get_cooldown_remaining() -> float:
	return _cooldown_left


## Fraction of the cooldown that remains (1 just started, 0 ready).
func get_cooldown_fraction() -> float:
	return _cooldown_left / _cooldown_total if _cooldown_total > 0.0 else 0.0


## Current opacity of the "ready" flash (0 with no flash).
func get_flash_alpha() -> float:
	return clampf(_flash_left / FLASH_SECONDS, 0.0, 1.0)


## Key glyph in the corner (null while there is no [member key_action]).
func get_glyph() -> UIKeyGlyph:
	return _glyph


func is_hovered() -> bool:
	return _hovered


## Border color right now: the rarity's (or the metal one without it), the accent one if selected and
## slightly lighter with the mouse over it.
func get_border_color() -> Color:
	var border: Color = UIPalette.rarity_color(rarity) if rarity >= 0 else UIPalette.BORDER
	if selected:
		return UIPalette.ACCENT
	if _hovered:
		return border.lightened(0.25)
	return border


## Text of the stack counter: empty if the stack is 1 or less.
func get_count_text() -> String:
	return str(count) if count > 1 else ""


# --- Tooltip ----------------------------------------------------------------------------------

## Stores the tooltip content: [param title], [param body] (BBCode) and [param subtitle].
func set_tooltip_info(title: String, body: String = "", subtitle: String = "") -> void:
	tooltip_info = {"title": title, "body": body, "subtitle": subtitle}


## The content the [UITooltip] asks for: the stored one plus the rarity color for the title;
## empty if there is no title.
func get_tooltip_content() -> Dictionary:
	if String(tooltip_info.get("title", "")).is_empty():
		return {}
	var content: Dictionary = tooltip_info.duplicate()
	content["accent"] = UIPalette.rarity_color(rarity) if rarity >= 0 else UIPalette.TITLE
	return content


## Links the slot to [param tooltip] (on mouse hover or focus it shows it).
func bind_tooltip(tooltip: UITooltip) -> void:
	tooltip.bind_source(self, get_tooltip_content)


# --- Input ------------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click != null and click.button_index == MOUSE_BUTTON_LEFT and not click.pressed \
			and Rect2(Vector2.ZERO, size).has_point(click.position):
		_press()
		accept_event()
	elif event.is_action_pressed(&"ui_accept") and has_focus():
		_press()
		accept_event()


func _press() -> void:
	UISounds.play(UISounds.CLICK)
	pressed.emit()


func _on_mouse_entered() -> void:
	_hovered = true
	UISounds.play(UISounds.HOVER)
	queue_redraw()


func _on_mouse_exited() -> void:
	_hovered = false
	queue_redraw()


# --- Drawing ----------------------------------------------------------------------------------

func _update_glyph() -> void:
	if key_action == &"":
		if _glyph != null:
			_glyph.queue_free()
			_glyph = null
		return
	if _glyph == null:
		_glyph = UIKeyGlyph.new()
		_glyph.compact = true
		_glyph.position = Vector2(3.0, 3.0)
		add_child(_glyph)
	_glyph.action = key_action


func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	_box.bg_color = UIPalette.INSET_BG
	_box.border_color = get_border_color()
	_box.set_border_width_all(BORDER_WIDTH)
	_box.set_corner_radius_all(3)
	_box.anti_aliasing = true
	draw_style_box(_box, rect)
	var inner: Rect2 = rect.grow(-float(BORDER_WIDTH))
	if icon != null:
		draw_texture_rect(icon, rect.grow(-ICON_MARGIN), false,
				Color.WHITE if enabled else DISABLED_TINT)
	var font: Font = get_theme_default_font()
	if _cooldown_left > 0.0:
		var points: PackedVector2Array = sweep_polygon(inner, get_cooldown_fraction())
		if points.size() >= 3:
			draw_colored_polygon(points, COOLDOWN_OVERLAY)
		var text: String = cooldown_text(_cooldown_left)
		var text_size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0,
				COOLDOWN_FONT_SIZE)
		var origin: Vector2 = Vector2((size.x - text_size.x) * 0.5,
				(size.y - text_size.y) * 0.5 + font.get_ascent(COOLDOWN_FONT_SIZE))
		draw_string_outline(font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				COOLDOWN_FONT_SIZE, 4, UIPalette.OUTLINE)
		draw_string(font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, COOLDOWN_FONT_SIZE,
				UIPalette.TEXT)
	var count_text: String = get_count_text()
	if not count_text.is_empty():
		var count_origin: Vector2 = Vector2(0.0, size.y - 5.0)
		draw_string_outline(font, count_origin, count_text, HORIZONTAL_ALIGNMENT_RIGHT,
				size.x - 5.0, COUNT_FONT_SIZE, 4, UIPalette.OUTLINE)
		draw_string(font, count_origin, count_text, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 5.0,
				COUNT_FONT_SIZE, UIPalette.TEXT)
	if _flash_left > 0.0:
		draw_rect(inner, UIPalette.with_alpha(Color.WHITE, 0.55 * get_flash_alpha()))
	if has_focus():
		var ring: StyleBoxFlat = StyleBoxFlat.new()
		ring.draw_center = false
		ring.border_color = UIPalette.ACCENT.lightened(0.15)
		ring.set_border_width_all(2)
		ring.set_corner_radius_all(3)
		draw_style_box(ring, rect.grow(1.0))
