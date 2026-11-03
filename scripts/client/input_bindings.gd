class_name InputBindings
extends RefCounted
## Acciones de entrada por defecto del cliente (teclado y ratón).
##
## Se registran en tiempo de ejecución en lugar de en [code]project.godot[/code]
## para que el cliente sea dueño de su configuración de controles y el servidor
## headless no dependa de ella. Las teclas usan códigos físicos (la posición de
## la tecla en el teclado), así WASD cae en el mismo sitio en QWERTY, AZERTY, etc.
## [br][br]Estas asignaciones son solo los valores por defecto: más adelante el
## jugador podrá reasignarlas desde las opciones y se guardarán en su perfil.
## Por eso [method ensure_defaults] nunca pisa una acción que ya exista.
## [br][br][b]Espacio no confirma en la interfaz.[/b] Godot trae Espacio en [code]ui_accept[/code], pero en el juego es
## saltar y las ventanas no suspenden la entrada de juego (UI-47): con el menú social abierto (su primer botón tiene el
## foco), saltar pulsaba «Invitar al grupo». [method ensure_defaults] lo quita de [code]ui_accept[/code]; Intro sigue
## confirmando (revisión de la fase 4, cliente).

## Valor de [member InputEvent.device] que acepta cualquier dispositivo.
const ALL_DEVICES: int = -1


## Registra en el [InputMap] las acciones que falten con sus teclas por defecto.
## Es idempotente: se puede llamar tantas veces como se quiera.
static func ensure_defaults() -> void:
	# Movimiento.
	_ensure_key(&"move_forward", KEY_W)
	_ensure_key(&"move_back", KEY_S)
	_ensure_key(&"move_left", KEY_A)
	_ensure_key(&"move_right", KEY_D)
	_ensure_key(&"jump", KEY_SPACE)
	_ensure_key(&"sprint", KEY_SHIFT)
	_ensure_key(&"dodge", KEY_CTRL)

	# Combate.
	_ensure_mouse_button(&"primary_attack", MOUSE_BUTTON_LEFT)
	_ensure_mouse_button(&"block", MOUSE_BUTTON_RIGHT)
	_ensure_key(&"ability_1", KEY_1)
	_ensure_key(&"ability_2", KEY_2)
	_ensure_key(&"ability_3", KEY_3)
	_ensure_key(&"interact", KEY_E)
	# Fase 4 (docs/habilidades.md, sección 0, «Teclas nuevas»): cambiar de arma y las dos pociones.
	_ensure_key(&"swap_weapon", KEY_Q)
	_ensure_key(&"consumable_1", KEY_R)
	_ensure_key(&"consumable_2", KEY_T)

	# Cámara y cursor.
	_ensure_key(&"free_cursor", KEY_ALT)
	_ensure_key(&"toggle_cursor", KEY_ESCAPE)
	_ensure_key(&"shoulder_swap", KEY_V)
	_ensure_mouse_button(&"zoom_in", MOUSE_BUTTON_WHEEL_UP)
	_ensure_mouse_button(&"zoom_out", MOUSE_BUTTON_WHEEL_DOWN)

	# Depuración.
	_ensure_key(&"toggle_debug", KEY_F3)
	_ensure_key(&"toggle_net_ghost", KEY_F4)

	# Interfaz.
	_ensure_key(&"open_settings", KEY_F10)
	# Muestra u oculta la línea de ayuda de controles del HUD (UI-49).
	_ensure_key(&"toggle_help", KEY_F1)
	_ensure_key(&"open_map", KEY_M)
	_ensure_key(&"map_zoom_in", KEY_EQUAL)
	_ensure_key(&"map_zoom_out", KEY_MINUS)
	_ensure_key(&"scoreboard", KEY_TAB)
	_ensure_keys(&"chat_open", [KEY_ENTER, KEY_KP_ENTER])
	_ensure_key(&"party_accept", KEY_Y)
	_ensure_key(&"party_decline", KEY_N)
	# Menú de jugador (SOC-07). Era T, provisional: T es la poción de resistencia desde la fase 4
	# (docs/habilidades.md, sección 0, y sección 11.7).
	_ensure_key(&"social_menu", KEY_G)
	# Inventario y ventana de personaje (docs/progresion.md §11.1, UI-26).
	_ensure_key(&"open_inventory", KEY_I)
	_ensure_key(&"open_character", KEY_C)
	# Espacio es saltar: no pulsa el botón que tenga el foco.
	_erase_key(&"ui_accept", KEY_SPACE)


## Quita de [param action] (si existe) los eventos de la tecla [param keycode] (por código o por código físico).
static func _erase_key(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		return
	for event: InputEvent in InputMap.action_get_events(action):
		var key: InputEventKey = event as InputEventKey
		if key != null and (key.keycode == keycode or key.physical_keycode == keycode):
			InputMap.action_erase_event(action, event)


static func _ensure_key(action: StringName, physical_keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	var event: InputEventKey = InputEventKey.new()
	event.device = ALL_DEVICES
	event.physical_keycode = physical_keycode
	InputMap.add_action(action)
	InputMap.action_add_event(action, event)


## Como [method _ensure_key], con varias teclas físicas para la misma acción.
static func _ensure_keys(action: StringName, physical_keycodes: Array[Key]) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for physical_keycode: Key in physical_keycodes:
		var event: InputEventKey = InputEventKey.new()
		event.device = ALL_DEVICES
		event.physical_keycode = physical_keycode
		InputMap.action_add_event(action, event)


static func _ensure_mouse_button(action: StringName, button: MouseButton) -> void:
	if InputMap.has_action(action):
		return
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.device = ALL_DEVICES
	event.button_index = button
	InputMap.add_action(action)
	InputMap.action_add_event(action, event)
