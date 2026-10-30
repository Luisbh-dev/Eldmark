class_name PredictionPair
extends RefCounted
## Cliente y servidor de un mismo personaje sin red (como test_prediction.gd): dos mundos de física
## separados ([SubViewport] con [code]own_world_3d[/code]), cada uno con un [PlayerCharacter] sobre
## un suelo plano. El cliente predice con la [ClientPrediction] de verdad (entradas de un cerebro
## guionizado, por [LocalPlayerController]); el servidor aplica la regla de sustitución de
## docs/red.md, sección 8.2 (repite la última entrada aplicada con todos sus botones y la marca
## [constant PlayerInput.SUBSTITUTED]) y, tras simular cada tick, llama a [member server_hook] para lo
## que imponga el servidor. Sus estados llegan al cliente cada 2 ticks con 6 de retraso.
## [br][br]
## Uso: [code]await pair.build(tree, route, combat)[/code] y, dentro de cada tick de física,
## [method frame]. Al acabar, [method free_worlds].

## Tick del servidor en el que aparece el jugador, y primer tick con entrada real.
const SPAWN_TICK: int = 10
const FIRST_REAL_TICK: int = 14
## Retraso (fotogramas) e intervalo (ticks) de los estados propios.
const STATE_DELAY_FRAMES: int = 6
const STATE_INTERVAL_TICKS: int = 2
const SPAWN_POSITION: Vector3 = Vector3(0.0, 0.0, 40.0)

const _CHARACTER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")


## Cerebro cuyas entradas salen de una función del tick.
class ScriptedBrain extends BotBrain:
	var route: Callable


	func _init() -> void:
		super(1, BotBrain.Pattern.IDLE)


	func next_input(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return route.call(tick) as PlayerInput


var server: PlayerCharacter
var client: PlayerCharacter
var prediction: ClientPrediction
## Lo que impone el servidor tras simular un tick: [code]func(character, tick) -> void[/code]. Si
## cambia el estado, quien lo pone llama a [method commit] (redondeo por encode/decode, como
## [code]CombatDirector.commit_state[/code]).
var server_hook: Callable = Callable()
## Ticks cuya entrada se pierde camino del servidor.
var lost: Array[int] = []
## Fotogramas que tardan en llegar los estados propios del servidor.
var state_delay_frames: int = STATE_DELAY_FRAMES
## Resultados de [method ClientPrediction.on_server_state]: (tick, resultado).
var results: Array[Vector2i] = []
## Estado del servidor tras cada tick (tick -> PlayerState).
var server_states: Dictionary = {}
## Último tick que ha simulado el servidor.
var server_tick: int = 0
## Entradas sustituidas por el servidor.
var substitutions: int = 0

var _server_viewport: SubViewport
var _client_viewport: SubViewport
var _controller: LocalPlayerController
var _brain: ScriptedBrain
var _dt: float = 1.0 / 60.0
var _inbox: Dictionary = {}
var _last_applied: PlayerInput = null
var _last_real_tick: int = 0
var _pending: Array[Dictionary] = []
var _frame: int = 0


## Monta los dos mundos y arranca la predicción con la ruta [param route]
## ([code]func(tick) -> PlayerInput[/code]) y el estado de combate [param combat] al aparecer. Hay
## que llamarla con [code]await[/code]; al volver se está dentro del tick de física.
func build(tree: SceneTree, route: Callable, combat: CombatState) -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_server_viewport = _make_world(tree, "ServidorPar")
	_client_viewport = _make_world(tree, "ClientePar")
	server = _CHARACTER_SCENE.instantiate() as PlayerCharacter
	_server_viewport.add_child(server)
	client = _CHARACTER_SCENE.instantiate() as PlayerCharacter
	_client_viewport.add_child(client)
	_brain = ScriptedBrain.new()
	_brain.route = route
	_controller = LocalPlayerController.new()
	_controller.name = "LocalPlayerController"
	_controller.auto_step = false
	_client_viewport.add_child(_controller)
	_controller.setup(client, null)
	_controller.set_bot(_brain)
	prediction = ClientPrediction.new()
	prediction.setup(client, _controller, null, _dt)
	for _i: int in 3:
		await tree.physics_frame

	var spawn := PlayerState.new()
	spawn.position = SPAWN_POSITION
	spawn.grounded = true
	spawn.combat = combat.duplicate_state()
	spawn = PlayerState.decode(spawn.encode())
	server_tick = SPAWN_TICK
	_last_applied = NetProtocol.neutral_input(SPAWN_TICK, spawn.yaw)
	_last_real_tick = SPAWN_TICK
	server.set_state(spawn)
	server.reset_physics_interpolation()
	server_states[SPAWN_TICK] = server.get_state()
	prediction.start(SPAWN_TICK, spawn, FIRST_REAL_TICK)


## Un tick de cliente (llegan los estados que tocan, un paso de predicción y el envío de la entrada,
## que se pierde si su tick está en [member lost]) y uno de servidor. Devuelve el estado del
## servidor.
func frame() -> PlayerState:
	while not _pending.is_empty() and _pending[0]["due"] <= _frame:
		var item: Dictionary = _pending.pop_front()
		var tick: int = item["tick"]
		results.append(Vector2i(tick, prediction.on_server_state(tick, item["state"], false)))
	var input: PlayerInput = prediction.step()
	if not lost.has(input.tick) and input.tick > server_tick and not _inbox.has(input.tick):
		_inbox[input.tick] = PlayerInput.decode(input.encode())
	_frame += 1

	server_tick += 1
	server.simulate(_take(server_tick), _dt)
	if server_hook.is_valid():
		server_hook.call(server, server_tick)
	var state: PlayerState = server.get_state()
	server_states[server_tick] = state
	if server_tick % STATE_INTERVAL_TICKS == 0:
		_pending.append({
			"tick": server_tick,
			"state": PlayerState.decode(state.encode()),
			"due": _frame + state_delay_frames,
		})
	return state


## Pasa el estado de [param character] por encode/decode (como [code]CombatDirector.commit_state[/code]).
static func commit(character: PlayerCharacter) -> void:
	character.set_state(PlayerState.decode(character.get_state().encode()))


## El estado predicho del tick [param tick] (null si ya no está en el anillo).
func predicted(tick: int) -> PlayerState:
	return prediction.get_predicted_state(tick)


## Ticks con un resultado distinto de [param expected].
func results_not(expected: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for entry: Vector2i in results:
		if entry.y != expected:
			found.append(entry)
	return found


## Primer tick, desde [param from_tick], a partir del cual cliente y servidor coinciden byte a byte
## hasta el último que ha simulado el servidor; -1 si el último no coincide.
func converged_since(from_tick: int) -> int:
	var first: int = -1
	for tick: int in range(from_tick, server_tick + 1):
		var mine: PlayerState = predicted(tick)
		var theirs: PlayerState = server_states.get(tick)
		var same: bool = mine != null and theirs != null and mine.encode() == theirs.encode()
		if same and first < 0:
			first = tick
		elif not same:
			first = -1
	return first


func free_worlds() -> void:
	for viewport: SubViewport in [_server_viewport, _client_viewport]:
		if is_instance_valid(viewport):
			if viewport.is_inside_tree():
				viewport.get_parent().remove_child(viewport)
			viewport.free()


func _take(tick: int) -> PlayerInput:
	var input: PlayerInput
	if _inbox.has(tick):
		input = _inbox[tick]
		_inbox.erase(tick)
		_last_real_tick = tick
	else:
		input = _last_applied.duplicate_input()
		input.tick = tick
		input.buttons |= PlayerInput.SUBSTITUTED
		if tick - _last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
			input.move = Vector2.ZERO
		substitutions += 1
	_last_applied = input
	return input


static func _make_world(tree: SceneTree, world_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = world_name
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0.0, -0.5, 0.0)
	viewport.add_child(body)
	return viewport
