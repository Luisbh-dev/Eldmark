class_name LocalPlayerController
extends Node
## Controla el personaje del jugador local en el cliente.
##
## En cada tick de física lee teclado, ratón y cámara (o un [DemoInput]
## guionizado), construye un [PlayerInput], lo cuantiza exactamente igual que
## viajará por la red, lo guarda en el historial, emite
## [signal input_generated] y llama a [method PlayerCharacter.simulate].
## [br][br]Fase 2: [signal input_generated] enviará cada entrada al servidor y
## el historial permitirá la reconciliación (restaurar el estado confirmado y
## volver a simular las entradas aún no confirmadas). Como el cliente simula la
## entrada ya cuantizada, su predicción usa los mismos datos que el servidor.

## Se emite con cada entrada generada, ya cuantizada, justo antes de simularla.
signal input_generated(input: PlayerInput)

## Entradas que guarda el historial (algo más de 4 s a 60 ticks/s).
const HISTORY_SIZE: int = 256

## Botones del ratón que se ignoran mientras el cursor está libre.
const CURSOR_BLOCKED_BUTTONS: int = PlayerInput.PRIMARY | PlayerInput.BLOCK

## Acción del InputMap -> bit de [member PlayerInput.buttons].
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
}

var _character: PlayerCharacter = null
var _camera_rig: CameraRig = null
var _demo: DemoInput = null
var _tick: int = 0
var _history: Array[PlayerInput] = []
## Botones del ratón pulsados con el cursor libre: se ignoran hasta soltarlos,
## para que el clic que recaptura el ratón (o un clic en la interfaz) no ataque.
var _suppressed_buttons: int = 0
var _cursor_was_free: bool = false


func _ready() -> void:
	InputBindings.ensure_defaults()


## Conecta el controlador con el personaje que simula y la cámara de la que
## toma la dirección de la vista.
func setup(character: PlayerCharacter, camera_rig: CameraRig) -> void:
	_character = character
	_camera_rig = camera_rig
	if _demo != null and is_instance_valid(_camera_rig):
		_camera_rig.set_scripted_look(true)


## Modo demo: tanto la entrada como la vista de la cámara salen de [param demo]
## en lugar del teclado y el ratón.
func enable_demo(demo: DemoInput) -> void:
	_demo = demo
	if _demo != null and is_instance_valid(_camera_rig):
		_camera_rig.set_scripted_look(true)


## Últimas entradas generadas (como mucho [constant HISTORY_SIZE]), de la más
## antigua a la más reciente. Es una copia: modificar el array no afecta al
## historial.
func get_input_history() -> Array[PlayerInput]:
	var copy: Array[PlayerInput] = []
	copy.assign(_history)
	return copy


## Tick de la última entrada generada (0 si todavía no se ha generado ninguna).
func get_tick() -> int:
	return _tick


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_character):
		return
	_tick += 1
	var input: PlayerInput = _demo_input() if _demo != null else _device_input()
	input = input.quantized()
	_history.append(input)
	if _history.size() > HISTORY_SIZE:
		_history.pop_front()
	input_generated.emit(input)
	# delta es el paso fijo de física (1 / Engine.physics_ticks_per_second), el
	# mismo que usa move_and_slide() por dentro.
	_character.simulate(input, delta)


func _device_input() -> PlayerInput:
	var input: PlayerInput = PlayerInput.new()
	input.tick = _tick
	input.move = Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")

	var cursor_free: bool = false
	if is_instance_valid(_camera_rig):
		input.look_yaw = _camera_rig.get_yaw()
		input.look_pitch = _camera_rig.get_pitch()
		cursor_free = _camera_rig.is_cursor_free()
	else:
		input.look_yaw = _character.yaw

	var buttons: int = 0
	for action: StringName in BUTTON_ACTIONS:
		# just_pressed recoge pulsaciones más cortas que un tick, para que un
		# toque rápido de salto o esquiva no se pierda entre dos ticks.
		if Input.is_action_pressed(action) or Input.is_action_just_pressed(action):
			buttons |= BUTTON_ACTIONS[action]

	var held_mouse: int = buttons & CURSOR_BLOCKED_BUTTONS
	if cursor_free or _cursor_was_free:
		_suppressed_buttons |= held_mouse
	_suppressed_buttons &= held_mouse
	_cursor_was_free = cursor_free
	input.buttons = buttons & ~_suppressed_buttons
	return input


func _demo_input() -> PlayerInput:
	var look: Vector2 = _demo.look_for(_tick)
	if is_instance_valid(_camera_rig):
		_camera_rig.set_look(look.x, look.y)
	var input: PlayerInput = _demo.next(_tick)
	input.tick = _tick
	return input
