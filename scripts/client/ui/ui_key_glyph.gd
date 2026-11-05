class_name UIKeyGlyph
extends Control
## Key glyph (UI-09): a "key" drawn with the real name of whatever the player has
## bound to an action, so that the HUD help and hints do not say "E" when the key is another one.
## [br][br]
## It reads the binding from the [InputMap] ([method label_for_action]): the action's first key, mouse button or
## gamepad button, with modifiers if it has them. For physical keys
## ([member InputEventKey.physical_keycode], the ones [InputBindings] uses) it asks the system which
## letter is at that position with [method DisplayServer.keyboard_get_label_from_physical]: on an
## AZERTY keyboard the "W" key shows "Z". Without a display (headless mode, which does not support it and
## would log an error) or if the system does not know, it uses the physical key's name as is.
## [br][br]
## Names are given in Spanish ([constant KEY_NAMES], [method mouse_button_name]). If keys are
## rebound, [method refresh_all] (or [method refresh] on one) re-reads the [InputMap].
## [br][br]
## Client only.

## Group that holds all live glyphs (for [method refresh_all]).
const GROUP: StringName = &"ui_key_glyphs"
## Text when the action does not exist or has nothing bound.
const UNASSIGNED_TEXT: String = "?"
## Spanish name of the keys whose English name is not usable as is.
const KEY_NAMES: Dictionary = {
	KEY_SHIFT: "Mayús", KEY_CTRL: "Ctrl", KEY_ALT: "Alt", KEY_META: "Win", KEY_SPACE: "Espacio",
	KEY_ESCAPE: "Esc", KEY_ENTER: "Intro", KEY_KP_ENTER: "Intro", KEY_TAB: "Tab",
	KEY_BACKSPACE: "Retroceso", KEY_DELETE: "Supr", KEY_INSERT: "Ins", KEY_HOME: "Inicio",
	KEY_END: "Fin", KEY_PAGEUP: "Re Pág", KEY_PAGEDOWN: "Av Pág", KEY_UP: "↑", KEY_DOWN: "↓",
	KEY_LEFT: "←", KEY_RIGHT: "→", KEY_CAPSLOCK: "Bloq Mayús", KEY_PRINT: "Imp Pant",
	KEY_QUOTELEFT: "º", KEY_BRACKETLEFT: "[", KEY_BRACKETRIGHT: "]",
}
const FONT_SIZE: int = 14
const COMPACT_FONT_SIZE: int = 11
## Key margins and minimum height (px).
const PADDING_X: float = 7.0
const MIN_HEIGHT: float = 22.0
const COMPACT_MIN_HEIGHT: float = 16.0
const MIN_WIDTH: float = 22.0
const COMPACT_MIN_WIDTH: float = 16.0
## Dimensions (px) of the mouse drawn in compact click glyphs.
const MOUSE_ICON_SIZE: Vector2 = Vector2(11.0, 15.0)

## Action whose binding is shown. Empty: [member text_override] is shown.
var action: StringName = &"":
	set(value):
		action = value
		refresh()
## Fixed text for when there is no action (or to force one: "Rueda" ("Wheel") in the zoom help).
var text_override: String = "":
	set(value):
		text_override = value
		refresh()
## Reduced size (action bar slots).
var compact: bool = false:
	set(value):
		compact = value
		refresh()

var _label: String = UNASSIGNED_TEXT
## In compact mode, the mouse button drawn as an icon instead of writing "Clic izq." ("Left click")
## (MOUSE_BUTTON_NONE: the text is written).
var _mouse_icon: MouseButton = MOUSE_BUTTON_NONE


## Creates a glyph already configured for [param action_name].
static func for_action(action_name: StringName, is_compact: bool = false) -> UIKeyGlyph:
	var glyph: UIKeyGlyph = UIKeyGlyph.new()
	glyph.compact = is_compact
	glyph.action = action_name
	return glyph


## Text of the key bound to [param action_name] in the [InputMap]; [constant
## UNASSIGNED_TEXT] if the action does not exist or has no keyboard, mouse or gamepad events.
static func label_for_action(action_name: StringName) -> String:
	if not InputMap.has_action(action_name):
		return UNASSIGNED_TEXT
	var events: Array[InputEvent] = InputMap.action_get_events(action_name)
	# Keyboard before mouse and gamepad: it is what is shown as "the action's key".
	for kind: int in 3:
		for event: InputEvent in events:
			if _kind_of(event) == kind:
				var text: String = label_for_event(event)
				if not text.is_empty():
					return text
	return UNASSIGNED_TEXT


## Text of an input event: key (with modifiers), mouse button or gamepad button.
## Empty string if it is of another type.
static func label_for_event(event: InputEvent) -> String:
	var key_event: InputEventKey = event as InputEventKey
	if key_event != null:
		return _key_label(key_event)
	var mouse_event: InputEventMouseButton = event as InputEventMouseButton
	if mouse_event != null:
		return _with_modifiers(mouse_event, mouse_button_name(mouse_event.button_index))
	var pad_event: InputEventJoypadButton = event as InputEventJoypadButton
	if pad_event != null:
		return "Mando %d" % int(pad_event.button_index)
	return ""


## Spanish name of a mouse button.
static func mouse_button_name(button: MouseButton) -> String:
	match button:
		MOUSE_BUTTON_LEFT:
			return "Clic izq."
		MOUSE_BUTTON_RIGHT:
			return "Clic der."
		MOUSE_BUTTON_MIDDLE:
			return "Clic central"
		MOUSE_BUTTON_WHEEL_UP:
			return "Rueda ↑"
		MOUSE_BUTTON_WHEEL_DOWN:
			return "Rueda ↓"
		MOUSE_BUTTON_XBUTTON1:
			return "Ratón 4"
		MOUSE_BUTTON_XBUTTON2:
			return "Ratón 5"
	return "Ratón %d" % int(button)


## Spanish name of key [param key] (a code from [enum Key]).
static func key_name(key: Key) -> String:
	if KEY_NAMES.has(key):
		return KEY_NAMES[key]
	return OS.get_keycode_string(key)


## Re-reads the binding of all live glyphs in [param tree] (after rebinding keys).
static func refresh_all(tree: SceneTree) -> void:
	for node: Node in tree.get_nodes_in_group(GROUP):
		(node as UIKeyGlyph).refresh()


# Preference order when choosing which event to show: 0 keyboard, 1 mouse, 2 gamepad, 3 other.
static func _kind_of(event: InputEvent) -> int:
	if event is InputEventKey:
		return 0
	if event is InputEventMouseButton:
		return 1
	if event is InputEventJoypadButton:
		return 2
	return 3


static func _key_label(event: InputEventKey) -> String:
	var key: Key = KEY_NONE
	if event.physical_keycode != KEY_NONE:
		key = _layout_key(event.physical_keycode)
	elif event.keycode != KEY_NONE:
		key = event.keycode
	elif event.key_label != KEY_NONE:
		key = event.key_label
	if key == KEY_NONE:
		return ""
	return _with_modifiers(event, key_name(key))


# The key at physical position [param physical] with the current keyboard layout.
# Without a display, or if the system returns nothing, the physical key itself.
static func _layout_key(physical: Key) -> Key:
	if DisplayServer.get_name() == "headless":
		return physical
	var label: Key = DisplayServer.keyboard_get_label_from_physical(physical)
	return label if label != KEY_NONE else physical


# Prepends the modifiers the event carries ("Ctrl+S").
static func _with_modifiers(event: InputEventWithModifiers, base: String) -> String:
	var prefix: String = ""
	if event.ctrl_pressed:
		prefix += "Ctrl+"
	if event.alt_pressed:
		prefix += "Alt+"
	if event.shift_pressed:
		prefix += "Mayús+"
	if event.meta_pressed:
		prefix += "Win+"
	return prefix + base


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	add_to_group(GROUP)
	refresh()


## Text the key shows right now.
func get_label() -> String:
	return _label


## Re-reads the [InputMap] (or the fixed text) and redraws.
func refresh() -> void:
	if not text_override.is_empty():
		_label = text_override
	elif action != &"":
		_label = label_for_action(action)
	else:
		_label = UNASSIGNED_TEXT
	_mouse_icon = MOUSE_BUTTON_NONE
	if compact and text_override.is_empty():
		if _label == mouse_button_name(MOUSE_BUTTON_LEFT):
			_mouse_icon = MOUSE_BUTTON_LEFT
		elif _label == mouse_button_name(MOUSE_BUTTON_RIGHT):
			_mouse_icon = MOUSE_BUTTON_RIGHT
	update_minimum_size()
	queue_redraw()


## Mouse button drawn as an icon (MOUSE_BUTTON_NONE if the glyph carries text).
func get_mouse_icon() -> MouseButton:
	return _mouse_icon


func _get_minimum_size() -> Vector2:
	if _mouse_icon != MOUSE_BUTTON_NONE:
		return Vector2(COMPACT_MIN_WIDTH + 2.0, COMPACT_MIN_HEIGHT)
	var font: Font = get_theme_default_font()
	var font_size: int = COMPACT_FONT_SIZE if compact else FONT_SIZE
	var text_width: float = font.get_string_size(_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			font_size).x
	var min_width: float = COMPACT_MIN_WIDTH if compact else MIN_WIDTH
	var min_height: float = COMPACT_MIN_HEIGHT if compact else MIN_HEIGHT
	return Vector2(maxf(text_width + PADDING_X * 2.0, min_width), min_height)


func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	var cap: StyleBoxFlat = StyleBoxFlat.new()
	cap.bg_color = UIPalette.INSET_BG
	cap.border_color = UIPalette.BORDER_LIGHT
	cap.set_border_width_all(1)
	# The thicker bottom border gives a key its relief.
	cap.border_width_bottom = 2
	cap.set_corner_radius_all(3)
	cap.anti_aliasing = true
	draw_style_box(cap, rect)
	if _mouse_icon != MOUSE_BUTTON_NONE:
		_draw_mouse(rect)
		return
	var font: Font = get_theme_default_font()
	var font_size: int = COMPACT_FONT_SIZE if compact else FONT_SIZE
	var text_size: Vector2 = font.get_string_size(_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var baseline: float = (rect.size.y - 1.0 - text_size.y) * 0.5 + font.get_ascent(font_size)
	draw_string(font, Vector2((rect.size.x - text_size.x) * 0.5, baseline), _label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, UIPalette.TEXT)


# A mouse seen from above with the [member _mouse_icon] button filled in: inside the key, a click
# fits where a nine-letter text overflowed the slot.
func _draw_mouse(rect: Rect2) -> void:
	var body := Rect2(rect.position + (rect.size - MOUSE_ICON_SIZE) * 0.5 - Vector2(0.0, 0.5),
			MOUSE_ICON_SIZE)
	var shell := StyleBoxFlat.new()
	shell.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	shell.border_color = UIPalette.TEXT
	shell.set_border_width_all(1)
	shell.set_corner_radius_all(5)
	shell.anti_aliasing = true
	draw_style_box(shell, body)
	var half: float = body.size.x * 0.5
	var button_left: float = body.position.x + 1.0
	if _mouse_icon == MOUSE_BUTTON_RIGHT:
		button_left = body.position.x + half
	draw_rect(Rect2(button_left, body.position.y + 1.0, half - 1.0, body.size.y * 0.4), UIPalette.ACCENT)
	draw_line(Vector2(body.position.x + half, body.position.y + 1.0),
			Vector2(body.position.x + half, body.position.y + body.size.y * 0.42), UIPalette.TEXT, 1.0)
