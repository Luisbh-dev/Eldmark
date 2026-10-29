class_name LocalPlayerController
extends Node
## Controla el personaje del jugador local en el cliente.
##
## En cada tick de física lee teclado, ratón y cámara (o un [DemoInput]
## guionizado, o un [BotBrain]), construye un [PlayerInput], lo cuantiza
## exactamente igual que viajará por la red, lo guarda en el historial, emite
## [signal input_generated] y llama a [method PlayerCharacter.simulate].
## [br][br]Fase 2: con [member auto_step] en false el controlador no avanza solo.
## [method ClientPrediction.step] llama a [method build_input] (que construye la
## entrada del tick pedido sin simular) y simula el personaje él mismo, y las
## repeticiones de la reconciliación vuelven a simular las entradas guardadas.
## Como el cliente simula la entrada ya cuantizada, su predicción usa los mismos
## datos que el servidor.

## Se emite con cada entrada generada, ya cuantizada. En el sandbox ([member auto_step] en true) se
## emite justo antes de simularla.
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

## true (sandbox): el controlador avanza un tick por paso de física, como en la fase 1. false:
## lo avanza [ClientPrediction] llamando a [method build_input], y [method _physics_process] no
## hace nada.
var auto_step: bool = true

var _character: PlayerCharacter = null
var _camera_rig: CameraRig = null
var _demo: DemoInput = null
var _bot: BotBrain = null
var _tick: int = 0
## Anillo de las últimas entradas generadas: la más antigua está en _history_start.
var _history: Array[PlayerInput] = []
var _history_start: int = 0
## Botones pulsados en ticks sin paso (ver [method accumulate_presses]): se suman a la entrada
## del siguiente [method build_input].
var _pending_presses: int = 0
## Botones del ratón pulsados con el cursor libre: se ignoran hasta soltarlos,
## para que el clic que recaptura el ratón (o un clic en la interfaz) no ataque.
var _suppressed_buttons: int = 0
var _cursor_was_free: bool = false
## Quién tiene la entrada de juego suspendida (la caja de chat mientras se escribe): id de instancia ->
## true. Mientras haya alguno, la entrada del dispositivo es neutra (sin movimiento ni botones).
var _input_blockers: Dictionary = {}


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


## Modo bot: las entradas salen de [code]brain.next_input(tick, posición, yaw)[/code] en lugar del
## teclado o de la demo. Con null vuelve al dispositivo (o a la demo, si está activada).
func set_bot(brain: BotBrain) -> void:
	_bot = brain


## Suspende (o devuelve) la entrada de juego del dispositivo en nombre de [param holder]: mientras alguno
## la tenga suspendida, el personaje no se mueve ni usa botones aunque se pulsen las teclas, y la vista
## sigue la de la cámara (que el solicitante suele tener con el cursor libre). Cada solicitante cuenta una
## sola vez. Lo usa la caja de chat mientras el jugador escribe (SOC-05). La entrada de un bot o de una demo
## no se ve afectada.
func set_input_blocked(blocked: bool, holder: Object) -> void:
	var key: int = holder.get_instance_id()
	if blocked:
		_input_blockers[key] = true
	else:
		_input_blockers.erase(key)


## true si algún solicitante vivo tiene suspendida la entrada de juego ([method set_input_blocked]).
func is_input_blocked() -> bool:
	for key: int in _input_blockers.keys():
		if not is_instance_id_valid(key):
			_input_blockers.erase(key)
	return not _input_blockers.is_empty()


## Últimas entradas generadas (como mucho [constant HISTORY_SIZE]), de la más
## antigua a la más reciente. Es una copia: modificar el array no afecta al
## historial.
func get_input_history() -> Array[PlayerInput]:
	var copy: Array[PlayerInput] = []
	copy.resize(_history.size())
	for i: int in _history.size():
		copy[i] = _history[(_history_start + i) % _history.size()]
	return copy


## Tick de la última entrada generada (0 si todavía no se ha generado ninguna).
func get_tick() -> int:
	return _tick


func _physics_process(delta: float) -> void:
	if not auto_step or not is_instance_valid(_character):
		return
	var input: PlayerInput = build_input(_tick + 1)
	# delta es el paso fijo de física (1 / Engine.physics_ticks_per_second), el
	# mismo que usa move_and_slide() por dentro.
	_character.simulate(input, delta)


## Construye la entrada del tick [param tick] a partir del bot, la demo o el dispositivo (en ese
## orden de prioridad), le suma las pulsaciones que guardó [method accumulate_presses], la
## cuantiza como viajará por la red, la guarda en el historial, emite [signal input_generated] y
## la devuelve. No simula: lo hace quien llama ([ClientPrediction] o, en el sandbox,
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


## En los ticks sin paso de predicción (0 pasos): guarda las acciones pulsadas en este tick de
## física para que el siguiente [method build_input] las sume y no se pierda ningún toque corto.
## Con un bot o una demo no hace nada, porque su entrada no depende del dispositivo.
func accumulate_presses() -> void:
	if _bot != null or _demo != null or is_input_blocked():
		return
	var cursor_free: bool = _cursor_was_free
	if is_instance_valid(_camera_rig):
		cursor_free = cursor_free or _camera_rig.is_cursor_free()
	for action: StringName in BUTTON_ACTIONS:
		if Input.is_action_just_pressed(action):
			var button: int = BUTTON_ACTIONS[action]
			# Un clic con el cursor libre no ataca (ver _device_input).
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
	# Con la entrada suspendida (escribiendo en el chat) el personaje se queda quieto y sin botones; los
	# botones del ratón que se mantienen siguen suprimidos hasta soltarlos (arriba).
	if is_input_blocked():
		input.move = Vector2.ZERO
		input.buttons = 0
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
