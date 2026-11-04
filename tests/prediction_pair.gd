class_name PredictionPair
extends RefCounted
## Client and server of one and the same character without a network (like test_prediction.gd):
## two separate physics worlds ([SubViewport] with [code]own_world_3d[/code]), each with a
## [PlayerCharacter] on flat ground. The client predicts with the real [ClientPrediction] (inputs
## from a scripted brain, via [LocalPlayerController]); the server applies the substitution rule of
## docs/networking.md, section 8.2 (it repeats the last applied input with all its buttons and the
## [constant PlayerInput.SUBSTITUTED] marker) and, after simulating each tick, calls
## [member server_hook] for whatever the server imposes. Its states reach the client every 2 ticks
## with 6 delay.
## [br][br]
## Usage: [code]await pair.build(tree, route, combat)[/code] and, inside each physics tick,
## [method frame]. When finished, [method free_worlds].

## Server tick at which the player spawns, and first tick with real input.
const SPAWN_TICK: int = 10
const FIRST_REAL_TICK: int = 14
## Delay (frames) and interval (ticks) of the own states.
const STATE_DELAY_FRAMES: int = 6
const STATE_INTERVAL_TICKS: int = 2
const SPAWN_POSITION: Vector3 = Vector3(0.0, 0.0, 40.0)

const _CHARACTER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")


## Brain whose inputs come from a function of the tick.
class ScriptedBrain extends BotBrain:
	var route: Callable


	func _init() -> void:
		super(1, BotBrain.Pattern.IDLE)


	func next_input(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return route.call(tick) as PlayerInput


var server: PlayerCharacter
var client: PlayerCharacter
var prediction: ClientPrediction
## What the server imposes after simulating a tick: [code]func(character, tick) -> void[/code]. If
## it changes the state, whoever sets it calls [method commit] (rounding through encode/decode,
## like [code]CombatDirector.commit_state[/code]).
var server_hook: Callable = Callable()
## Ticks whose input is lost on the way to the server.
var lost: Array[int] = []
## Frames it takes for the server's own states to arrive.
var state_delay_frames: int = STATE_DELAY_FRAMES
## Results of [method ClientPrediction.on_server_state]: (tick, result).
var results: Array[Vector2i] = []
## Server state after each tick (tick -> PlayerState).
var server_states: Dictionary = {}
## Last tick the server has simulated.
var server_tick: int = 0
## Inputs substituted by the server.
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


## Sets up the two worlds and starts prediction with route [param route]
## ([code]func(tick) -> PlayerInput[/code]) and combat state [param combat] on spawning. It must be
## called with [code]await[/code]; on return one is inside the physics tick.
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


## One client tick (the due states arrive, one prediction step and the input send, which is lost if
## its tick is in [member lost]) and one server tick. Returns the server state.
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


## Passes [param character]'s state through encode/decode (like
## [code]CombatDirector.commit_state[/code]).
static func commit(character: PlayerCharacter) -> void:
	character.set_state(PlayerState.decode(character.get_state().encode()))


## The predicted state of tick [param tick] (null if it is no longer in the ring).
func predicted(tick: int) -> PlayerState:
	return prediction.get_predicted_state(tick)


## Ticks with a result other than [param expected].
func results_not(expected: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for entry: Vector2i in results:
		if entry.y != expected:
			found.append(entry)
	return found


## First tick, from [param from_tick], from which client and server match byte for byte up to the
## last one the server has simulated; -1 if the last one does not match.
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
