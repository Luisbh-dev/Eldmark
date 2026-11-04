class_name UIKeyGlyph
extends Control
## Glifo de tecla (UI-09): una «tecla» dibujada con el nombre real de lo que el jugador tiene
## asignado a una acción, para que la ayuda del HUD y las pistas no digan «E» cuando la tecla es otra.
## [br][br]
## Lee la asignación del [InputMap] ([method label_for_action]): la primera tecla, botón del ratón o
## botón de mando de la acción, con los modificadores si los lleva. Para las teclas físicas
## ([member InputEventKey.physical_keycode], las que usa [InputBindings]) pregunta al sistema qué
## letra hay en esa posición con [method DisplayServer.keyboard_get_label_from_physical]: en un
## teclado AZERTY la tecla de «W» muestra «Z». Sin pantalla (modo headless, que no lo admite y
## registraría un error) o si el sistema no lo sabe, usa el nombre de la tecla física tal cual.
## [br][br]
## Los nombres se dan en español ([constant KEY_NAMES], [method mouse_button_name]). Si se reasignan
## las teclas, [method refresh_all] (o [method refresh] en uno) vuelve a leer el [InputMap].
## [br][br]
## Solo cliente.

## Grupo en el que están todos los glifos vivos (para [method refresh_all]).
const GROUP: StringName = &"ui_key_glyphs"
## Texto cuando la acción no existe o no tiene nada asignado.
const UNASSIGNED_TEXT: String = "?"
## Nombre en español de las teclas cuyo nombre en inglés no vale tal cual.
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
## Márgenes de la tecla y altura mínima (px).
const PADDING_X: float = 7.0
const MIN_HEIGHT: float = 22.0
const COMPACT_MIN_HEIGHT: float = 16.0
const MIN_WIDTH: float = 22.0
const COMPACT_MIN_WIDTH: float = 16.0
## Medidas (px) del ratón dibujado de los glifos compactos de clic.
const MOUSE_ICON_SIZE: Vector2 = Vector2(11.0, 15.0)

## Acción cuya asignación se muestra. Vacía: se muestra [member text_override].
var action: StringName = &"":
	set(value):
		action = value
		refresh()
## Texto fijo para cuando no hay acción (o para forzar uno: «Rueda» en la ayuda de zoom).
var text_override: String = "":
	set(value):
		text_override = value
		refresh()
## Tamaño reducido (casillas de la barra de acciones).
var compact: bool = false:
	set(value):
		compact = value
		refresh()

var _label: String = UNASSIGNED_TEXT
## En el modo compacto, el botón del ratón que se dibuja como icono en vez de escribir «Clic izq.»
## (MOUSE_BUTTON_NONE: se escribe el texto).
var _mouse_icon: MouseButton = MOUSE_BUTTON_NONE


## Crea un glifo ya configurado para [param action_name].
static func for_action(action_name: StringName, is_compact: bool = false) -> UIKeyGlyph:
	var glyph: UIKeyGlyph = UIKeyGlyph.new()
	glyph.compact = is_compact
	glyph.action = action_name
	return glyph


## Texto de la tecla que tiene asignada [param action_name] en el [InputMap]; [constant
## UNASSIGNED_TEXT] si la acción no existe o no tiene eventos de teclado, ratón o mando.
static func label_for_action(action_name: StringName) -> String:
	if not InputMap.has_action(action_name):
		return UNASSIGNED_TEXT
	var events: Array[InputEvent] = InputMap.action_get_events(action_name)
	# Teclado antes que ratón y mando: es lo que se enseña como «la tecla de la acción».
	for kind: int in 3:
		for event: InputEvent in events:
			if _kind_of(event) == kind:
				var text: String = label_for_event(event)
				if not text.is_empty():
					return text
	return UNASSIGNED_TEXT


## Texto de un evento de entrada: tecla (con modificadores), botón del ratón o botón de mando.
## Cadena vacía si es de otro tipo.
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


## Nombre en español de un botón del ratón.
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


## Nombre en español de la tecla [param key] (un código de [enum Key]).
static func key_name(key: Key) -> String:
	if KEY_NAMES.has(key):
		return KEY_NAMES[key]
	return OS.get_keycode_string(key)


## Vuelve a leer la asignación de todos los glifos vivos de [param tree] (tras reasignar teclas).
static func refresh_all(tree: SceneTree) -> void:
	for node: Node in tree.get_nodes_in_group(GROUP):
		(node as UIKeyGlyph).refresh()


# Orden de preferencia al elegir qué evento enseñar: 0 teclado, 1 ratón, 2 mando, 3 otro.
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


# La tecla que hay en la posición física [param physical] con la distribución de teclado actual.
# Sin pantalla, o si el sistema no devuelve nada, la propia tecla física.
static func _layout_key(physical: Key) -> Key:
	if DisplayServer.get_name() == "headless":
		return physical
	var label: Key = DisplayServer.keyboard_get_label_from_physical(physical)
	return label if label != KEY_NONE else physical


# Antepone los modificadores que lleva el evento («Ctrl+S»).
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


## Texto que muestra ahora la tecla.
func get_label() -> String:
	return _label


## Vuelve a leer el [InputMap] (o el texto fijo) y se redibuja.
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


## Botón del ratón que se dibuja como icono (MOUSE_BUTTON_NONE si el glifo lleva texto).
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
	# El borde inferior más grueso da el relieve de una tecla.
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


# Un ratón visto desde arriba con el botón de [member _mouse_icon] relleno: dentro de la tecla, un clic
# cabe donde un texto de nueve letras se salía de la casilla.
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
