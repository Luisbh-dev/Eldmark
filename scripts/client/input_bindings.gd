class_name InputBindings
extends RefCounted
## Default input actions of the client (keyboard and mouse).
##
## They are registered at run time instead of in [code]project.godot[/code]
## so that the client owns its controls configuration and the headless
## server does not depend on it. Keys use physical codes (the position of
## the key on the keyboard), so WASD lands in the same place on QWERTY, AZERTY, etc.
## [br][br]These bindings are only the defaults: later the
## player will be able to remap them from the options and they will be saved in their profile.
## That is why [method ensure_defaults] never overwrites an action that already exists.
## [br][br][b]Space does not confirm in the UI.[/b] Godot ships Space in [code]ui_accept[/code], but in the game it is
## jump and the windows do not suspend game input (UI-47): with the social menu open (its first button has
## focus), jumping pressed "Invitar al grupo" (Invite to party). [method ensure_defaults] removes it from [code]ui_accept[/code]; Enter still
## confirms (phase 4 review, client).

## Value of [member InputEvent.device] that accepts any device.
const ALL_DEVICES: int = -1


## Registers in the [InputMap] the actions that are missing with their default keys.
## It is idempotent: it can be called as many times as desired.
static func ensure_defaults() -> void:
	# Movement.
	_ensure_key(&"move_forward", KEY_W)
	_ensure_key(&"move_back", KEY_S)
	_ensure_key(&"move_left", KEY_A)
	_ensure_key(&"move_right", KEY_D)
	_ensure_key(&"jump", KEY_SPACE)
	_ensure_key(&"sprint", KEY_SHIFT)
	_ensure_key(&"dodge", KEY_CTRL)

	# Combat.
	_ensure_mouse_button(&"primary_attack", MOUSE_BUTTON_LEFT)
	_ensure_mouse_button(&"block", MOUSE_BUTTON_RIGHT)
	_ensure_key(&"ability_1", KEY_1)
	_ensure_key(&"ability_2", KEY_2)
	_ensure_key(&"ability_3", KEY_3)
	_ensure_key(&"interact", KEY_E)
	# Phase 4 (docs/habilidades.md, section 0, "Teclas nuevas", new keys): swap weapon and the two potions.
	_ensure_key(&"swap_weapon", KEY_Q)
	_ensure_key(&"consumable_1", KEY_R)
	_ensure_key(&"consumable_2", KEY_T)

	# Camera and cursor.
	_ensure_key(&"free_cursor", KEY_ALT)
	_ensure_key(&"toggle_cursor", KEY_ESCAPE)
	_ensure_key(&"shoulder_swap", KEY_V)
	_ensure_mouse_button(&"zoom_in", MOUSE_BUTTON_WHEEL_UP)
	_ensure_mouse_button(&"zoom_out", MOUSE_BUTTON_WHEEL_DOWN)

	# Debug.
	_ensure_key(&"toggle_debug", KEY_F3)
	_ensure_key(&"toggle_net_ghost", KEY_F4)

	# UI.
	_ensure_key(&"open_settings", KEY_F10)
	# Shows or hides the HUD's controls help line (UI-49).
	_ensure_key(&"toggle_help", KEY_F1)
	_ensure_key(&"open_map", KEY_M)
	_ensure_key(&"map_zoom_in", KEY_EQUAL)
	_ensure_key(&"map_zoom_out", KEY_MINUS)
	_ensure_key(&"scoreboard", KEY_TAB)
	_ensure_keys(&"chat_open", [KEY_ENTER, KEY_KP_ENTER])
	_ensure_key(&"party_accept", KEY_Y)
	_ensure_key(&"party_decline", KEY_N)
	# Player menu (SOC-07). It used to be T, provisional: T is the stamina potion since phase 4
	# (docs/habilidades.md, section 0, and section 11.7).
	_ensure_key(&"social_menu", KEY_G)
	# Inventory and character window (docs/progresion.md §11.1, UI-26).
	_ensure_key(&"open_inventory", KEY_I)
	_ensure_key(&"open_character", KEY_C)
	# Space is jump: it does not press the button that has focus.
	_erase_key(&"ui_accept", KEY_SPACE)


## Removes from [param action] (if it exists) the events of key [param keycode] (by code or by physical code).
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


## Like [method _ensure_key], with several physical keys for the same action.
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
