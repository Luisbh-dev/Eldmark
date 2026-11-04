class_name LocalPlayerController
extends Node
## Controls the local player's character on the client.
##
## On every physics tick it reads keyboard, mouse and camera (or a scripted [DemoInput],
## or a [BotBrain]), builds a [PlayerInput], quantizes it
## exactly as it will travel over the network, stores it in the history, emits
## [signal input_generated] and calls [method PlayerCharacter.simulate].
## [br][br]Phase 4 (docs/abilities.md, sections 0 and 3.2): Q swaps weapons, R and T drink the
## potions, and the [constant PlayerInput.AIM_LEFT] bit (left shoulder of the aim) comes from the camera's
## effective shoulder on every device input.
## [br][br]Phase 2: with [member auto_step] set to false the controller does not advance on its own.
## [method ClientPrediction.step] calls [method build_input] (which builds the
## input of the requested tick without simulating) and simulates the character itself, and the
## replays of reconciliation simulate the stored inputs again.
## Since the client simulates the already quantized input, its prediction uses the same
## data as the server.

## Emitted with every generated input, already quantized. In the sandbox ([member auto_step] true) it is
## emitted just before simulating it.
signal input_generated(input: PlayerInput)

## Inputs the history keeps (a bit over 4 s at 60 ticks/s).
const HISTORY_SIZE: int = 256

## Mouse buttons that are ignored while the cursor is free.
const CURSOR_BLOCKED_BUTTONS: int = PlayerInput.PRIMARY | PlayerInput.BLOCK

## InputMap action -> bit of [member PlayerInput.buttons].
const BUTTON_ACTIONS: Dictionary[StringName, int] = {
	&"jump": PlayerInput.JUMP,
	&"sprint": PlayerInput.SPRINT,
	&"dodge": PlayerInput.DODGE,
	&"primary_attack": PlayerInput.PRIMARY,
	&"block": PlayerInput.BLOCK,
	&"ability_1": PlayerInput.ABILITY_1,
	&"ability_2": PlayerInput.ABILITY_2,
	&"ability_3": PlayerInput.ABILITY_3,
	&"interact": PlayerInput.INTERACT,
	&"swap_weapon": PlayerInput.SWAP_WEAPON,
	&"consumable_1": PlayerInput.CONSUMABLE_1,
	&"consumable_2": PlayerInput.CONSUMABLE_2,
}

## true (sandbox): the controller advances one tick per physics step, as in phase 1. false:
## [ClientPrediction] advances it by calling [method build_input], and [method _physics_process] does
## nothing.
var auto_step: bool = true

var _character: PlayerCharacter = null
var _camera_rig: CameraRig = null
var _demo: DemoInput = null
var _bot: BotBrain = null
var _tick: int = 0
## Ring of the last generated inputs: the oldest is at _history_start.
var _history: Array[PlayerInput] = []
var _history_start: int = 0
## Buttons pressed on ticks with no step (see [method accumulate_presses]): they are added to the input
## of the next [method build_input].
var _pending_presses: int = 0
## Mouse buttons pressed with the cursor free: they are ignored until released,
## so that the click that recaptures the mouse (or a click on the UI) does not attack.
var _suppressed_buttons: int = 0
var _cursor_was_free: bool = false
## Who has game input suspended (the chat box while typing): instance id ->
## true. While there is any, device input is neutral (no movement or buttons).
var _input_blockers: Dictionary = {}


func _ready() -> void:
	InputBindings.ensure_defaults()


## Connects the controller to the character it simulates and the camera from which it
## takes the view direction.
func setup(character: PlayerCharacter, camera_rig: CameraRig) -> void:
	_character = character
	_camera_rig = camera_rig
	if _demo != null and is_instance_valid(_camera_rig):
		_camera_rig.set_scripted_look(true)


## Demo mode: both the input and the camera view come from [param demo]
## instead of the keyboard and mouse.
func enable_demo(demo: DemoInput) -> void:
	_demo = demo
	if _demo != null and is_instance_valid(_camera_rig):
		_camera_rig.set_scripted_look(true)


## Bot mode: inputs come from [code]brain.next_input(tick, position, yaw)[/code] instead of
## the keyboard or the demo. With null it returns to the device (or to the demo, if enabled).
func set_bot(brain: BotBrain) -> void:
	_bot = brain


## Suspends (or restores) the device's game input on behalf of [param holder]: while any
## holder has it suspended, the character does not move or use buttons even if keys are pressed, and the view
## follows the camera's (which the requester usually has with the cursor free). Each requester counts only
## once. Used by the chat box while the player types (SOC-05). The input of a bot or a demo
## is not affected.
func set_input_blocked(blocked: bool, holder: Object) -> void:
	var key: int = holder.get_instance_id()
	if blocked:
		_input_blockers[key] = true
	else:
		_input_blockers.erase(key)


## true if any live requester has game input suspended ([method set_input_blocked]).
func is_input_blocked() -> bool:
	for key: int in _input_blockers.keys():
		if not is_instance_id_valid(key):
			_input_blockers.erase(key)
	return not _input_blockers.is_empty()


## Last generated inputs (at most [constant HISTORY_SIZE]), from the oldest to the
## most recent. It is a copy: modifying the array does not affect the
## history.
func get_input_history() -> Array[PlayerInput]:
	var copy: Array[PlayerInput] = []
	copy.resize(_history.size())
	for i: int in _history.size():
		copy[i] = _history[(_history_start + i) % _history.size()]
	return copy


## Tick of the last generated input (0 if none has been generated yet).
func get_tick() -> int:
	return _tick


func _physics_process(delta: float) -> void:
	if not auto_step or not is_instance_valid(_character):
		return
	var input: PlayerInput = build_input(_tick + 1)
	# delta is the fixed physics step (1 / Engine.physics_ticks_per_second), the
	# same one move_and_slide() uses internally.
	_character.simulate(input, delta)


## Builds the input of tick [param tick] from the bot, the demo or the device (in that
## priority order), adds the presses stored by [method accumulate_presses], quantizes it
## as it will travel over the network, stores it in the history, emits [signal input_generated] and
## returns it. It does not simulate: the caller does ([ClientPrediction] or, in the sandbox,
## [method _physics_process]).
func build_input(tick: int) -> PlayerInput:
	_tick = tick
	var input: PlayerInput
	if _bot != null:
		input = _bot_input()
	elif _demo != null:
		input = _demo_input()
	else:
		input = _device_input()
	input.buttons |= _pending_presses
	_pending_presses = 0
	input = input.quantized()
	_store_in_history(input)
	input_generated.emit(input)
	return input


## On ticks with no prediction step (0 steps): stores the actions pressed in this physics tick
## so that the next [method build_input] adds them and no short tap is lost.
## With a bot or a demo it does nothing, because their input does not depend on the device.
func accumulate_presses() -> void:
	if _bot != null or _demo != null or is_input_blocked():
		return
	var cursor_free: bool = _cursor_was_free
	if is_instance_valid(_camera_rig):
		cursor_free = cursor_free or _camera_rig.is_cursor_free()
	for action: StringName in BUTTON_ACTIONS:
		if Input.is_action_just_pressed(action):
			var button: int = BUTTON_ACTIONS[action]
			# A click with the cursor free does not attack (see _device_input).
			if cursor_free and (button & CURSOR_BLOCKED_BUTTONS) != 0:
				continue
			_pending_presses |= button


func _store_in_history(input: PlayerInput) -> void:
	if _history.size() < HISTORY_SIZE:
		_history.append(input)
		return
	_history[_history_start] = input
	_history_start = (_history_start + 1) % HISTORY_SIZE


func _device_input() -> PlayerInput:
	var input: PlayerInput = PlayerInput.new()
	input.tick = _tick
	input.move = Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")

	var cursor_free: bool = false
	if is_instance_valid(_camera_rig):
		input.look_yaw = _camera_rig.get_yaw()
		input.look_pitch = _camera_rig.get_pitch()
		cursor_free = _camera_rig.is_cursor_free()
	elif is_instance_valid(_character):
		input.look_yaw = _character.yaw

	var buttons: int = 0
	for action: StringName in BUTTON_ACTIONS:
		# just_pressed catches presses shorter than a tick, so that a quick
		# jump or dodge tap is not lost between two ticks.
		if Input.is_action_pressed(action) or Input.is_action_just_pressed(action):
			buttons |= BUTTON_ACTIONS[action]

	var held_mouse: int = buttons & CURSOR_BLOCKED_BUTTONS
	if cursor_free or _cursor_was_free:
		_suppressed_buttons |= held_mouse
	_suppressed_buttons &= held_mouse
	_cursor_was_free = cursor_free
	input.buttons = buttons & ~_suppressed_buttons
	# With input suspended (typing in chat) the character stays still with no buttons; mouse
	# buttons that are held stay suppressed until released (above).
	if is_input_blocked():
		input.move = Vector2.ZERO
		input.buttons = 0
	# Aim shoulder (docs/abilities.md, section 3.2): a level that describes the view, not a
	# press. It comes from the camera's effective shoulder (after the automatic switch because of a wall), which is
	# the one that gives the canonical ray of the arrows ([method AimRay.canonical]).
	if is_instance_valid(_camera_rig) and _camera_rig.get_effective_shoulder() < 0:
		input.buttons |= PlayerInput.AIM_LEFT
	return input


func _demo_input() -> PlayerInput:
	var look: Vector2 = _demo.look_for(_tick)
	if is_instance_valid(_camera_rig):
		_camera_rig.set_look(look.x, look.y)
	var input: PlayerInput = _demo.next(_tick)
	input.tick = _tick
	return input


func _bot_input() -> PlayerInput:
	var position: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	if is_instance_valid(_character):
		position = _character.global_position if _character.is_inside_tree() \
				else _character.position
		yaw = _character.yaw
	var input: PlayerInput = _bot.next_input(_tick, position, yaw)
	input.tick = _tick
	return input
