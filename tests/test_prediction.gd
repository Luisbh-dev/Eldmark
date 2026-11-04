extends TestCase
## Tests of the client prediction ([ClientPrediction]), the smoothing of corrections
## ([CorrectionSmoother]) and the phase 2 changes to [LocalPlayerController] (docs/red.md,
## sections 6, 16 and 17.7). There is no network: the "server" and the client are two separate
## physics worlds (two [SubViewport]s with [code]own_world_3d = true[/code]), each with a
## [PlayerCharacter] on a ground with a ramp.
## [br][br]
## The server is modeled by hand with the rule of section 8.2 (without depending on
## [code]scripts/server/[/code]): it applies the tick's input if it has arrived and, if not, repeats
## the last applied one with all its buttons and sets the movement to 0 after 6 ticks without real
## inputs. The server's inputs are the same ones (quantized, after going through
## encode/decode) that the client generates.
## [br][br]
## Everything is simulated inside the physics tick with [code]delta = 1 / physics_ticks_per_second[/code],
## as [method PlayerCharacter.simulate] requires. Several ticks within the same physics step are
## valid (that is what reconciliation does) and are used where the clock does not matter.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const WORLD_LAYER: int = PlayerCharacter.WORLD_COLLISION_LAYER
## Server tick at which the player "appears", and first tick with real input.
const SPAWN_TICK: int = 10
const FIRST_REAL_TICK: int = 14
## Six meters in front of the 25° ramp, which rises toward -Z.
const SPAWN_POSITION: Vector3 = Vector3(20.0, 0.0, 6.0)
const RAMP_FOOT: Vector3 = Vector3(20.0, -0.02, 0.0)
const RAMP_ANGLE_DEG: float = 25.0
const RAMP_LENGTH: float = 12.0
const RAMP_WIDTH: float = 10.0
const RAMP_THICKNESS: float = 0.5
## Ticks of delay with which the server states arrive (6 ticks = 100 ms).
const STATE_DELAY_FRAMES: int = 6
## One own state every 2 ticks, like snapshots at 30 Hz.
const STATE_INTERVAL_TICKS: int = 2
## Ticks of the scripted route.
const ROUTE_TICKS: int = 250
## Ticks of the combat route.
const COMBAT_ROUTE_TICKS: int = 300
## Ticks that the hard reset jumps forward in the substitution rule test: more than
## [constant NetProtocol.REPEAT_MOVE_TICKS], to see how the movement is repeated and how it is zeroed.
const GAP_TICKS: int = 12
## Height (m) of the ground that the route has to step on to count the ramp as climbed: a jump on flat ground
## reaches ~1.5 m, so 2 m is only reached by climbing it.
const MIN_RAMP_HEIGHT: float = 2.0

var _server_viewport: SubViewport
var _client_viewport: SubViewport
var _server: PlayerCharacter
var _character: PlayerCharacter
var _controller: LocalPlayerController
var _smoother: CorrectionSmoother
var _prediction: ClientPrediction
var _brain: ScriptedBrain
var _visual: Node3D
var _camera_target: Node3D
var _model: ServerModel
var _dt: float = 1.0 / 60.0
var _jumped_count: int = 0
var _landed_count: int = 0
var _pressed_actions: Array[StringName] = []
## Server own states on their way to the client: {tick, state, due} (due = client frame
## at which they arrive).
var _pending_states: Array[Dictionary] = []
var _frame_counter: int = 0


## Brain whose inputs come from a function of the tick, and which remembers the last thing it saw.
class ScriptedBrain extends BotBrain:
	var route: Callable
	var calls: int = 0
	var last_tick: int = -1
	var last_position: Vector3 = Vector3.ZERO
	var last_yaw: float = 0.0


	func _init() -> void:
		super(1, BotBrain.Pattern.IDLE)


	func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
		calls += 1
		last_tick = tick
		last_position = position
		last_yaw = yaw
		return route.call(tick) as PlayerInput


## The test server: the substitution rule of section 8.2 on a real character.
class ServerModel:
	var character: PlayerCharacter
	var dt: float = 1.0 / 60.0
	var tick: int = 0
	## Inputs received that are not yet applied (tick -> input). The first copy wins.
	var inbox: Dictionary = {}
	var last_applied: PlayerInput = null
	var last_real_tick: int = 0
	var substitutions: int = 0
	## State after each simulated tick (tick -> PlayerState).
	var states: Dictionary = {}


	func start(new_character: PlayerCharacter, spawn_tick: int, spawn_state: PlayerState,
			delta: float) -> void:
		character = new_character
		dt = delta
		tick = spawn_tick
		last_applied = NetProtocol.neutral_input(spawn_tick, spawn_state.yaw)
		last_real_tick = spawn_tick
		inbox.clear()
		states.clear()
		substitutions = 0
		character.set_state(spawn_state)
		character.reset_physics_interpolation()
		states[spawn_tick] = character.get_state()


	func receive(input: PlayerInput) -> void:
		if input.tick > tick and not inbox.has(input.tick):
			inbox[input.tick] = PlayerInput.decode(input.encode())


	func take(for_tick: int) -> PlayerInput:
		var input: PlayerInput
		if inbox.has(for_tick):
			input = inbox[for_tick]
			inbox.erase(for_tick)
			last_real_tick = for_tick
		else:
			input = last_applied.duplicate_input()
			input.tick = for_tick
			input.buttons |= PlayerInput.SUBSTITUTED
			if for_tick - last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
				input.move = Vector2.ZERO
			substitutions += 1
		last_applied = input
		return input


	## Simulates the next tick and returns the resulting state.
	func step() -> PlayerState:
		tick += 1
		character.simulate(take(tick), dt)
		var state: PlayerState = character.get_state()
		states[tick] = state
		return state


func before_each() -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_jumped_count = 0
	_landed_count = 0


func after_each() -> void:
	for action: StringName in _pressed_actions:
		Input.action_release(action)
	_pressed_actions.clear()
	for viewport: SubViewport in [_server_viewport, _client_viewport]:
		if is_instance_valid(viewport):
			if viewport.is_inside_tree():
				viewport.get_parent().remove_child(viewport)
			viewport.free()
	_server_viewport = null
	_client_viewport = null
	_server = null
	_character = null
	_controller = null
	_smoother = null
	_prediction = null
	_brain = null
	_visual = null
	_camera_target = null
	_model = null
	await wait_process_frames()


# --- Prediction: same inputs, same state --------------------------------------------------------

func test_prediction_matches_the_server_tick_by_tick() -> void:
	if not await _begin_session(_route_input):
		return
	var results: Array[Vector2i] = []
	var peak_height: float = 0.0
	var grounded_peak_height: float = 0.0
	var yaw_wraps: int = 0
	var previous_yaw: float = _model.states[SPAWN_TICK].yaw
	for _frame: int in ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, [] as Array[int])
		var state: PlayerState = _server_tick()
		peak_height = maxf(peak_height, state.position.y)
		if state.grounded:
			grounded_peak_height = maxf(grounded_peak_height, state.position.y)
		if absf(state.yaw - previous_yaw) > PI:
			yaw_wraps += 1
		previous_yaw = state.yaw
		var predicted: PlayerState = _prediction.get_predicted_state(_model.tick)
		if not assert_not_null(predicted, "the ring stores tick %d" % _model.tick):
			return
		if predicted.encode() != state.encode():
			fail("the predicted state of tick %d differs from the server's.\n  predicted: %s\n  server: %s"
					% [_model.tick, predicted, state])
			return
	# A jump on flat ground already reaches ~1.5 m (8² / (2 · 22)): you are only on the ramp if the feet, off the
	# ground, exceed 2 m (the route reaches about 3.5 m).
	assert_true(grounded_peak_height > MIN_RAMP_HEIGHT,
			"the route climbs the ramp: it steps on ground above %s m (maximum %.2f m)"
			% [MIN_RAMP_HEIGHT, grounded_peak_height])
	assert_true(peak_height > 1.0, "and it jumps (maximum height %s)" % peak_height)
	assert_true(yaw_wraps >= 1, "the route turns crossing ±PI (%d crossings)" % yaw_wraps)
	assert_true(_jumped_count >= 2, "the route jumps (%d jumps)" % _jumped_count)
	assert_true(_prediction.get_predicted_tick() > ClientPrediction.HISTORY_SIZE,
			"the route wraps around the 256-slot rings")
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1,
			"the server only substituted the ticks before the first real input")


func test_states_arriving_late_all_match_without_loss() -> void:
	if not await _begin_session(_route_input):
		return
	var results: Array[Vector2i] = []
	for _frame: int in ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, [] as Array[int])
		_server_tick()
	assert_true(results.size() > 100, "states arrived (%d)" % results.size())
	for entry: Vector2i in results:
		if entry.y != ClientPrediction.Result.MATCH:
			fail("the state of tick %d did not match (result %d)" % [entry.x, entry.y])
			return
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["matches"], results.size(), "all match")
	assert_eq(stats["corrections"], 0, "no correction")
	assert_eq(stats["replays"], 0, "no replay")
	assert_eq(stats["hard_resets"], 0, "no hard reset")
	assert_eq(stats["resimulated_ticks"], 0, "no tick re-simulated")
	assert_eq(stats["max_correction"], 0.0, "maximum correction 0")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "the smoother was not used")


func test_a_substituted_tick_is_reconciled_and_converges_exactly() -> void:
	if not await _begin_session(_route_input):
		return
	# Tick 31 is the first with movement: if it is lost, the server repeats the neutral input
	# and starts one tick late.
	var lost: Array[int] = [31]
	var results: Array[Vector2i] = []
	for _frame: int in ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1 + 1,
			"the server substituted the lost tick")
	var corrected: Array[Vector2i] = _results_with(results, ClientPrediction.Result.CORRECTED)
	assert_eq(corrected.size(), 1, "a single reconciliation")
	if corrected.size() != 1:
		return
	var first_bad: int = corrected[0].x
	assert_true(first_bad >= 31 and first_bad <= 32, "the first different state is 31 or 32 (%d)"
			% first_bad)
	for entry: Vector2i in results:
		if entry.x > first_bad and entry.y != ClientPrediction.Result.MATCH:
			fail("after reconciling, the state of tick %d should match (result %d)"
					% [entry.x, entry.y])
			return
		if entry.x < first_bad and entry.y != ClientPrediction.Result.MATCH:
			fail("before the loss, the state of tick %d should match" % entry.x)
			return
	# From the first reconciled state, the client ends up bit for bit equal to the server.
	for tick: int in range(first_bad, _model.tick + 1):
		var predicted: PlayerState = _prediction.get_predicted_state(tick)
		if predicted == null or predicted.encode() != (_model.states[tick] as PlayerState).encode():
			fail("tick %d did not end up equal to the server after the reconciliation" % tick)
			return
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["replays"], 1, "one replay")
	assert_eq(stats["corrections"], 1, "a correction of more than 1 mm")
	assert_eq(stats["hard_resets"], 0, "without hard reset")
	assert_true(stats["max_correction"] > 0.005 and stats["max_correction"] < 0.2,
			"the error was a few centimeters (%s m)" % stats["max_correction"])
	assert_eq(stats["last_correction"], stats["max_correction"], "last correction")
	assert_true(stats["resimulated_ticks"] > 5 and stats["resimulated_ticks"] < 30,
			"about 10 ticks were replayed (%s)" % stats["resimulated_ticks"])
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "and the offset has already decayed")


func test_a_lost_jump_is_reconciled_without_repeating_the_sound() -> void:
	if not await _begin_session(_route_input):
		return
	# The jump is pressed on ticks 100-102: with all three lost, the server never jumps.
	var lost: Array[int] = [100, 101, 102]
	var results: Array[Vector2i] = []
	var jumps_before_replays: int = -1
	for _frame: int in ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
		if _prediction.get_predicted_tick() == 102:
			jumps_before_replays = _jumped_count
	assert_eq(jumps_before_replays, 1, "the client jumps once when predicting tick 100")
	assert_true(_results_with(results, ClientPrediction.Result.CORRECTED).size() >= 1,
			"the error of a jump is reconciled")
	var last_bad: int = 0
	for entry: Vector2i in results:
		if entry.y != ClientPrediction.Result.MATCH:
			last_bad = maxi(last_bad, entry.x)
	for entry: Vector2i in results:
		if entry.x > last_bad and entry.y != ClientPrediction.Result.MATCH:
			fail("after the last correction the state of tick %d should match" % entry.x)
			return
	for tick: int in range(last_bad, _model.tick + 1):
		var predicted: PlayerState = _prediction.get_predicted_state(tick)
		if predicted == null or predicted.encode() != (_model.states[tick] as PlayerState).encode():
			fail("tick %d did not end up equal to the server" % tick)
			return
	assert_true(_prediction.get_stats()["max_correction"] > 0.3,
			"the correction for the lost jump is large (%s m)" % _prediction.get_stats()["max_correction"])
	assert_eq(_prediction.get_stats()["hard_resets"], 0, "without hard reset")
	# The replays simulate a jump again (the real input arrives one tick late) but do not
	# emit jumped or landed: only what was simulated in real time counts.
	assert_true(_jumped_count <= 2, "the replays do not emit jumped (%d jumps)" % _jumped_count)
	assert_true(_character.events_enabled, "events are enabled again")
	assert_false(_prediction.is_replaying(), "it does not stay in replay mode")


func test_a_late_first_real_input_is_reconciled() -> void:
	if not await _begin_session(_walk_route):
		return
	# The inputs of ticks 14 and 15 (the first two real ones) arrive late: the server
	# substitutes them with the neutral spawn input and the client corrects it.
	var lost: Array[int] = [FIRST_REAL_TICK, FIRST_REAL_TICK + 1]
	var results: Array[Vector2i] = []
	for _frame: int in 120:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1 + 2,
			"the server substituted the neutral advance and the two lost ticks")
	var last_bad: int = _last_result_tick_not(results, ClientPrediction.Result.MATCH)
	assert_true(last_bad > 0, "there were reconciliations")
	assert_true(_results_with(results, ClientPrediction.Result.HARD_RESET).is_empty(),
			"without hard reset")
	assert_true(last_bad <= FIRST_REAL_TICK + 3, "and only in the first ticks (%d)" % last_bad)
	_assert_converged_since(last_bad)


func test_a_long_loss_burst_is_reconciled_repeatedly_and_converges() -> void:
	if not await _begin_session(_walk_route):
		return
	# Twelve consecutive ticks lost: the server repeats the movement for 6 ticks and then stays
	# still (8.2); with every state that arrives, the client reconciles again.
	var lost: Array[int] = []
	for tick: int in range(40, 52):
		lost.append(tick)
	var results: Array[Vector2i] = []
	for _frame: int in 150:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1 + 12, "twelve substitutions")
	var corrected: Array[Vector2i] = _results_with(results, ClientPrediction.Result.CORRECTED)
	assert_true(corrected.size() >= 4, "several consecutive reconciliations (%d)" % corrected.size())
	assert_true(_results_with(results, ClientPrediction.Result.HARD_RESET).is_empty(),
			"without hard reset")
	var last_bad: int = _last_result_tick_not(results, ClientPrediction.Result.MATCH)
	assert_true(last_bad >= 50 and last_bad <= 53, "the last difference is from when the "
			+ "loss ends (%d)" % last_bad)
	_assert_converged_since(last_bad)
	var stats: Dictionary = _prediction.get_stats()
	assert_true(stats["max_correction"] > 0.2, "the server stopped and the error was large (%s m)"
			% stats["max_correction"])
	assert_true(stats["max_correction"] < ClientPrediction.SNAP_DISTANCE,
			"but it was smoothed, without jumping")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "and the offset ended up zeroing out")


# --- Combat: half-finished actions, losses and substituted inputs --------------------------------

func test_combat_route_matches_the_server_tick_by_tick() -> void:
	if not await _begin_session(_combat_route):
		return
	var results: Array[Vector2i] = []
	var actions_seen: Dictionary[int, bool] = {}
	for _frame: int in COMBAT_ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, [] as Array[int])
		var state: PlayerState = _server_tick()
		actions_seen[state.combat.action] = true
		var predicted: PlayerState = _prediction.get_predicted_state(_model.tick)
		if not assert_not_null(predicted, "the ring stores tick %d" % _model.tick):
			return
		if predicted.encode() != state.encode():
			fail("the predicted state of tick %d differs from the server's.\n  predicted: %s\n  server: %s"
					% [_model.tick, predicted, state])
			return
	for action: int in [CombatState.Action.LIGHT, CombatState.Action.HEAVY,
			CombatState.Action.CHARGE, CombatState.Action.BLOCK, CombatState.Action.DODGE]:
		assert_true(actions_seen.has(action), "the route goes through action %d" % action)
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["replays"], 0, "no replay")
	assert_eq(stats["corrections"], 0, "no correction")
	assert_true(stats["matches"] > 100, "states that matched arrived (%d)" % stats["matches"])


func test_a_lost_attack_press_is_reconciled_and_converges() -> void:
	if not await _begin_session(_combat_route):
		return
	# The press that starts the first light attack (tick 40) is lost: the server does not attack.
	var lost: Array[int] = [40]
	var results: Array[Vector2i] = []
	var diverged_in_combat: bool = false
	for _frame: int in COMBAT_ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, lost)
		var state: PlayerState = _server_tick()
		var predicted: PlayerState = _prediction.get_predicted_state(_model.tick)
		if predicted != null and predicted.combat.action != state.combat.action:
			diverged_in_combat = true
	assert_true(diverged_in_combat, "the client and the server ended up with different actions")
	var corrected: Array[Vector2i] = _results_with(results, ClientPrediction.Result.CORRECTED)
	assert_true(corrected.size() >= 1, "it reconciled with a half-finished action")
	assert_true(_results_with(results, ClientPrediction.Result.HARD_RESET).is_empty(),
			"without hard reset")
	var last_bad: int = _last_result_tick_not(results, ClientPrediction.Result.MATCH)
	assert_true(last_bad > 0 and last_bad < 100, "the disagreement is resolved soon (%d)" % last_bad)
	# The route is longer than the 256-tick ring: the last stretch is checked.
	_assert_converged_since(maxi(last_bad, _model.tick - 150))
	# After reconciling, the rest of the route (dodge, block, charge...) comes out the same on both.
	assert_eq(_prediction.get_predicted_state(_model.tick).combat.stamina,
			(_model.states[_model.tick] as PlayerState).combat.stamina, "same stamina")


func test_lost_inputs_in_the_middle_of_a_charge_are_reconciled_and_converge() -> void:
	if not await _begin_session(_combat_route):
		return
	# 6 ticks of the heavy attack's charge are lost (200-239 held): the server repeats the button with
	# the substituted-input mark, so it adds no press and does not throw on reaching the maximum.
	var lost: Array[int] = [212, 213, 214, 215, 216, 217]
	var results: Array[Vector2i] = []
	var server_held_froze: bool = false
	for _frame: int in COMBAT_ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, lost)
		var state: PlayerState = _server_tick()
		var predicted: PlayerState = _prediction.get_predicted_state(_model.tick)
		if predicted != null and _model.tick == 217 and predicted.combat.primary_held \
				> state.combat.primary_held:
			server_held_froze = true
	assert_true(server_held_froze, "substituted inputs do not add to primary_held on the server")
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1 + 6, "six substitutions")
	assert_true(_results_with(results, ClientPrediction.Result.CORRECTED).size() >= 1,
			"the difference is reconciled")
	var last_bad: int = _last_result_tick_not(results, ClientPrediction.Result.MATCH)
	assert_true(last_bad > 0, "there were differences")
	_assert_converged_since(maxi(last_bad, _model.tick - 150))
	assert_true(_prediction.get_stats()["max_correction"] < ClientPrediction.SNAP_DISTANCE,
			"and it was corrected without jumping")


func test_replays_fill_gaps_with_substituted_inputs() -> void:
	if not await _begin_session(_idle_route):
		return
	# A very late hard reset forces replaying ticks whose input has already left the ring: they are
	# substituted as the server would, with the substituted-input mark. The neutral ones the
	# prediction starts with also carry it, because the server substitutes them.
	var first_input: PlayerInput = _prediction.get_input(SPAWN_TICK + 1)
	if assert_not_null(first_input, "the prediction stored the startup neutral inputs"):
		assert_eq(first_input.buttons & PlayerInput.SUBSTITUTED, PlayerInput.SUBSTITUTED,
				"and they carry the substituted mark")
	for _i: int in 20:
		_prediction.step()
	var real: PlayerInput = _prediction.get_input(_prediction.get_predicted_tick())
	assert_eq(real.buttons & PlayerInput.SUBSTITUTED, 0, "the generated inputs do not carry it")
	_prediction._begin_substitution(_prediction.get_predicted_tick())
	var substitute: PlayerInput = _prediction._input_or_substitute(
			_prediction.get_predicted_tick() + 10)
	assert_eq(substitute.buttons & PlayerInput.SUBSTITUTED, PlayerInput.SUBSTITUTED,
			"the replacement of a replay carries the mark")


func test_replays_do_not_emit_jump_or_landing_events() -> void:
	if not await _begin_session(_route_input):
		return
	# Without server states on the way: it predicts until just after the jump of tick 100
	# (which the client emits once, in real time) and a state from before the jump arrives that
	# differs a little. The replay jumps again on tick 100, but without emitting anything.
	while _prediction.get_predicted_tick() < 108:
		_prediction.step()
	var jumps: int = _jumped_count
	var landings: int = _landed_count
	assert_eq(jumps, 1, "it jumped once in real time")
	var wrong: PlayerState = _prediction.get_predicted_state(99).duplicate_state()
	wrong.position += Vector3(0.0, 0.0, 0.05)
	var result: int = _prediction.on_server_state(99, wrong, false)
	assert_eq(result, ClientPrediction.Result.CORRECTED, "it reconciles")
	assert_eq(_jumped_count, jumps, "the jump replay does not emit jumped")
	assert_eq(_landed_count, landings, "nor landed")
	assert_true(_character.events_enabled, "events_enabled goes back to true")
	assert_true(_character.velocity.y > 0.0, "and the jump was indeed replayed: it keeps rising")
	assert_false(_character.grounded, "in the air")


# --- Startup, rings and states that do not fit --------------------------------------------------

func test_start_advances_with_neutral_input_and_without_events() -> void:
	if not await _build_session():
		return
	await tree.physics_frame
	assert_null(_prediction.step(), "step() before start() does nothing")
	assert_false(_prediction.is_started(), "without starting")
	# In the air, 1 cm from the ground: during the neutral advance it lands and would emit landed.
	var spawn := PlayerState.new()
	spawn.position = SPAWN_POSITION + Vector3(0.0, 0.01, 0.0)
	spawn.grounded = false
	spawn.yaw = 1.25
	spawn = PlayerState.decode(spawn.encode())
	_prediction.start(SPAWN_TICK, spawn, FIRST_REAL_TICK)
	assert_true(_prediction.is_started(), "started")
	assert_eq(_prediction.get_predicted_tick(), FIRST_REAL_TICK - 1, "predicted until just before P0")
	assert_eq(_prediction.get_first_real_tick(), FIRST_REAL_TICK, "first tick with real input")
	assert_true(_character.grounded, "the character landed during the neutral advance")
	assert_eq(_landed_count, 0, "but the neutral advance does not emit landed")
	assert_true(_character.events_enabled, "and leaves events_enabled as it was")
	assert_null(_prediction.get_input(SPAWN_TICK), "the spawn tick has no input")
	assert_not_null(_prediction.get_predicted_state(SPAWN_TICK), "but it does have state")
	assert_true(_prediction.get_predicted_state(SPAWN_TICK).equals_exact(spawn), "the spawn one")
	var neutral: PlayerInput = NetProtocol.neutral_input(0, spawn.yaw)
	for tick: int in range(SPAWN_TICK + 1, FIRST_REAL_TICK):
		var input: PlayerInput = _prediction.get_input(tick)
		if not assert_not_null(input, "neutral input of tick %d" % tick):
			return
		assert_eq(input.tick, tick, "with its tick")
		assert_eq(input.move, Vector2.ZERO, "no movement")
		assert_eq(input.buttons, PlayerInput.SUBSTITUTED,
				"without buttons and with the substituted mark (the server substitutes them)")
		assert_near(input.look_yaw, neutral.look_yaw, 1e-9, "looking at the quantized yaw of the spawn")
	assert_null(_prediction.get_input(FIRST_REAL_TICK), "there is no real input yet")
	var stepped: PlayerInput = _prediction.step()
	assert_eq(stepped.tick, FIRST_REAL_TICK, "the first step is tick P0")
	assert_eq(_prediction.get_predicted_tick(), FIRST_REAL_TICK, "and the predicted one advances")
	assert_eq(_prediction.get_input(FIRST_REAL_TICK), stepped, "it is stored")
	assert_true(_prediction.get_predicted_state(FIRST_REAL_TICK).equals_exact(_character.get_state()),
			"with the resulting state")
	assert_eq(_controller.get_tick(), FIRST_REAL_TICK, "the controller generated the requested tick")


func test_rings_keep_the_last_256_ticks_with_their_tags() -> void:
	if not await _begin_session(_route_input):
		return
	for _i: int in 300:
		_prediction.step()
	var last: int = _prediction.get_predicted_tick()
	assert_eq(last, FIRST_REAL_TICK - 1 + 300, "300 steps")
	for tick: int in range(last - ClientPrediction.HISTORY_SIZE + 1, last + 1):
		var input: PlayerInput = _prediction.get_input(tick)
		var state: PlayerState = _prediction.get_predicted_state(tick)
		if input == null or state == null or input.tick != tick:
			fail("tick %d should be in the rings" % tick)
			return
	for tick: int in [last - ClientPrediction.HISTORY_SIZE, SPAWN_TICK, 0, -5, last + 1, last + 300]:
		assert_null(_prediction.get_input(tick), "the input of tick %d is not there" % tick)
		assert_null(_prediction.get_predicted_state(tick), "nor its state")


func test_stale_and_repeated_server_states_are_ignored() -> void:
	if not await _begin_session(_route_input):
		return
	for _i: int in 40:
		_prediction.step()
	var tick: int = _prediction.get_predicted_tick() - 10
	var state: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
	assert_eq(_prediction.on_server_state(tick, state, false), ClientPrediction.Result.MATCH, "first")
	assert_eq(_prediction.on_server_state(tick, state, false), ClientPrediction.Result.IGNORED,
			"repeated")
	var older: PlayerState = _prediction.get_predicted_state(tick - 4).duplicate_state()
	older.position += Vector3(1.0, 0.0, 0.0)
	assert_eq(_prediction.on_server_state(tick - 4, older, false), ClientPrediction.Result.IGNORED,
			"older than the last reconciled one: it never reconciles")
	assert_eq(_prediction.on_server_state(tick + 2, null, false), ClientPrediction.Result.IGNORED,
			"a null state is ignored")
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["matches"], 1, "a match")
	assert_eq(stats["ignored"], 3, "three ignored")
	assert_eq(stats["replays"], 0, "without replays")


func test_a_state_ahead_of_the_prediction_is_a_hard_reset() -> void:
	if not await _begin_session(_route_input):
		return
	for _i: int in 30:
		_prediction.step()
	var predicted_tick: int = _prediction.get_predicted_tick()
	var ahead := PlayerState.new()
	ahead.position = SPAWN_POSITION + Vector3(0.0, 0.0, -3.0)
	ahead.grounded = true
	ahead.yaw = 0.5
	ahead.last_input_tick = predicted_tick + 5
	ahead = PlayerState.decode(ahead.encode())
	_smoother.add_offset(Vector3(0.2, 0.0, 0.0))
	var result: int = _prediction.on_server_state(predicted_tick + 5, ahead, false)
	assert_eq(result, ClientPrediction.Result.HARD_RESET, "arrives ahead of what was predicted")
	assert_eq(_prediction.get_predicted_tick(), predicted_tick + 5,
			"the predicted tick becomes the server's (TickSync recovers the lead)")
	assert_true(_character.get_state().equals_exact(ahead), "the character ends up in the server's state")
	assert_true(_prediction.get_predicted_state(predicted_tick + 5).equals_exact(ahead),
			"and it is stored in the ring")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "without smoothing")
	assert_eq(_prediction.get_stats()["hard_resets"], 1, "a hard reset")
	var stepped: PlayerInput = _prediction.step()
	assert_eq(stepped.tick, predicted_tick + 6, "the next step continues from there")
	assert_eq(_prediction.on_server_state(predicted_tick + 5, ahead, false),
			ClientPrediction.Result.IGNORED, "and that state is already reconciled")


## A state from a tick that has already left the ring: the client no longer knows the last input the
## server applied in it, so it substitutes a neutral one (with the state's buttons and without
## movement) until the first tick that is still in the ring. It is an unavoidable approximation of the
## client, not the rule of [InputQueue] (which would repeat that input's movement for 6 ticks): the oracle
## reimplements the approximation. The real rule is checked against [InputQueue] in
## [method test_client_substitution_matches_the_real_input_queue_across_a_gap].
func test_hard_reset_to_an_old_tick_replays_with_the_neutral_approximation_of_the_client() -> void:
	if not await _begin_session(_route_input):
		return
	for _i: int in 300:
		_prediction.step()
	var last: int = _prediction.get_predicted_tick()
	var old_tick: int = 40
	assert_null(_prediction.get_predicted_state(old_tick), "tick %d has already left the ring" % old_tick)
	var old_state := PlayerState.new()
	old_state.position = SPAWN_POSITION
	old_state.grounded = true
	old_state.yaw = 1.0
	old_state.prev_buttons = PlayerInput.SPRINT
	old_state.last_input_tick = old_tick
	old_state = PlayerState.decode(old_state.encode())

	# Oracle: it replays from that state with the client's approximation (the last applied input
	# is neutral with the state's buttons and, without real inputs, without movement) until the first
	# tick that is still in the ring, and afterward with the stored inputs.
	var first_stored: int = last - ClientPrediction.HISTORY_SIZE + 1
	_server.set_state(old_state)
	var substituted: PlayerInput = NetProtocol.neutral_input(old_tick, old_state.yaw)
	substituted.buttons = old_state.prev_buttons
	for tick: int in range(old_tick + 1, last + 1):
		var input: PlayerInput = _prediction.get_input(tick)
		if input == null:
			assert_true(tick < first_stored, "only inputs before the ring are missing")
			input = substituted.duplicate_input()
			input.tick = tick
		_server.simulate(input, _dt)
	var expected: PlayerState = _server.get_state()

	var result: int = _prediction.on_server_state(old_tick, old_state, false)
	assert_eq(result, ClientPrediction.Result.HARD_RESET, "a state outside the ring is a hard reset")
	assert_eq(_prediction.get_predicted_tick(), last, "the predicted tick does not change")
	assert_true(_character.get_state().equals_exact(expected),
			"after replaying with substitution it ends up as the oracle.\n  client: %s\n  oracle: %s"
			% [_character.get_state(), expected])
	assert_true(_prediction.get_predicted_state(last).equals_exact(expected),
			"and the ring stores the new state")
	assert_eq(_prediction.get_stats()["resimulated_ticks"], last - old_tick, "ticks re-simulated")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "a hard reset does not smooth")


## The substitution rule lives in [InputQueue.take] (the server), in
## [code]ClientPrediction._input_or_substitute[/code] (the client, when replaying with gaps in the ring)
## and, by hand, in [ServerModel]. Here the client is compared with the [b]real[/b] [InputQueue]: a gap in
## the ring (a forward [method ClientPrediction.hard_reset], which skips [constant GAP_TICKS]
## ticks) followed by a replay from the last tick with a known input. The server receives the
## same inputs, without those of the gap; its states and those left by the client's replay have to be
## bit-for-bit identical at every tick. The gap lasts more than 6 ticks: the movement is repeated for the
## first 6 and then zeroed, with SPRINT and JUMP held from the last known input.
func test_client_substitution_matches_the_real_input_queue_across_a_gap() -> void:
	if not await _begin_session(_route_input):
		return
	var last_known: int = 100
	while _prediction.get_predicted_tick() < last_known:
		_prediction.step()
	var known_input: PlayerInput = _prediction.get_input(last_known)
	assert_true(known_input.move != Vector2.ZERO and (known_input.buttons & PlayerInput.SPRINT) != 0
			and (known_input.buttons & PlayerInput.JUMP) != 0,
			"the last known input moves, sprints and has the jump pressed")
	var last_state: PlayerState = _prediction.get_predicted_state(last_known).duplicate_state()

	# The gap: the client skips GAP_TICKS ticks without predicting them and continues with real inputs.
	var after_gap: int = last_known + GAP_TICKS
	_prediction.hard_reset(after_gap, last_state)
	var end_tick: int = after_gap + 20
	while _prediction.get_predicted_tick() < end_tick:
		_prediction.step()
	assert_null(_prediction.get_input(last_known + 1), "the ring has a gap right after")
	assert_null(_prediction.get_input(after_gap), "up to the jump tick")
	assert_not_null(_prediction.get_input(after_gap + 1), "and has inputs again")

	# The real server: the same queue, with the same inputs except those of the gap.
	var queue := InputQueue.new()
	queue.reset(SPAWN_TICK, NetProtocol.neutral_input(SPAWN_TICK, _spawn_state().yaw))
	_server.set_state(_spawn_state())
	var server_states: Dictionary = {}
	for tick: int in range(SPAWN_TICK + 1, end_tick + 1):
		var stored: PlayerInput = _prediction.get_input(tick)
		if stored != null and tick >= FIRST_REAL_TICK:
			queue.push(stored.duplicate_input(), 0, tick)
		_server.simulate(queue.take(tick), _dt)
		server_states[tick] = _server.get_state()
	assert_eq(queue.substitutions_total, FIRST_REAL_TICK - SPAWN_TICK - 1 + GAP_TICKS,
			"the server substituted the neutral advance and the gap")

	# The client replays from the last known tick: it substitutes those of the gap with its copy of the rule.
	_prediction.hard_reset(last_known, last_state)
	for tick: int in range(last_known, end_tick + 1):
		var client_state: PlayerState = _prediction.get_predicted_state(tick)
		if not assert_not_null(client_state, "the client stores tick %d" % tick):
			return
		if not client_state.equals_exact(server_states[tick]):
			fail("tick %d (%s of the gap) differs from the real InputQueue.\n  client:  %s\n  server: %s"
					% [tick, "dentro" if tick <= after_gap else "después", client_state, server_states[tick]])
			return
	assert_eq(_prediction.get_stats()["resimulated_ticks"], end_tick - last_known, "the whole gap was replayed")


# --- Smoothing -------------------------------------------------------------------------------

func test_smoothing_keeps_visual_still_and_decays_below_one_millimetre_in_30_ticks() -> void:
	if not await _begin_session(_idle_route):
		return
	for _i: int in 20:
		_prediction.step()
		_smoother.physics_step()
	var tick: int = _prediction.get_predicted_tick() - 4
	var wrong: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
	wrong.position += Vector3(0.02, 0.0, 0.0)
	var visual_before: Vector3 = _visual.global_position
	var camera_before: Vector3 = _camera_target.global_position
	var body_before: Vector3 = _character.global_position

	var result: int = _prediction.on_server_state(tick, wrong, false)
	_smoother.physics_step()
	assert_eq(result, ClientPrediction.Result.CORRECTED, "the displaced state is reconciled")
	assert_vec_near(_character.global_position, body_before + Vector3(0.02, 0.0, 0.0), 1e-5,
			"the body is corrected at once")
	assert_vec_near(_visual.global_position, visual_before, 0.001,
			"the global position of Visual does not jump more than 1 mm in the transition")
	assert_vec_near(_camera_target.global_position, camera_before, 0.001,
			"nor that of CameraTarget")
	assert_vec_near(_smoother.get_offset(), Vector3(-0.02, 0.0, 0.0), 1e-5, "the offset is the error")
	assert_eq(_prediction.get_stats()["corrections"], 1, "counts as a correction (more than 1 mm)")

	var offset: float = _smoother.get_offset().length()
	var half_life_checked: bool = false
	var below_one_mm_at: int = -1
	for i: int in range(1, 41):
		_prediction.step()
		_smoother.physics_step()
		var current: float = _smoother.get_offset().length()
		assert_true(current <= offset + 1e-9, "the offset only decreases (tick %d)" % i)
		offset = current
		if i == 6:
			half_life_checked = true
			assert_near(current, 0.01, 0.0006, "half-life of 6 ticks")
		if current == 0.0 and below_one_mm_at < 0:
			below_one_mm_at = i
		assert_vec_near(_visual.global_position - _character.global_position,
				_smoother.get_offset(), 1e-5, "Visual carries the offset (tick %d)" % i)
	assert_true(half_life_checked, "the half-life was checked")
	assert_true(below_one_mm_at > 0 and below_one_mm_at <= 30,
			"the offset drops below 1 mm before 30 ticks (at %d)" % below_one_mm_at)
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "and is zeroed")
	assert_eq(_visual.position, Vector3.ZERO, "Visual returns exactly to its place")
	assert_eq(_camera_target.position, Vector3(0.0, 1.6, 0.0), "and CameraTarget too")


func test_smoothing_survives_many_small_corrections() -> void:
	if not await _begin_session(_idle_route):
		return
	for _i: int in 10:
		_prediction.step()
	var accumulated := Vector3.ZERO
	for i: int in 5:
		var tick: int = _prediction.get_predicted_tick() - 2
		var wrong: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
		wrong.position += Vector3(0.0, 0.0, 0.004)
		assert_eq(_prediction.on_server_state(tick, wrong, false), ClientPrediction.Result.CORRECTED,
				"correction %d" % i)
		accumulated += Vector3(0.0, 0.0, -0.004)
		_smoother.physics_step()
		_prediction.step()
	assert_true(_smoother.get_offset().length() > 0.004, "the offsets accumulate")
	assert_true(_smoother.get_offset().length() < accumulated.length(), "and decay in the meantime")


func test_correction_above_three_metres_jumps_without_smoothing() -> void:
	if not await _begin_session(_idle_route):
		return
	for _i: int in 20:
		_prediction.step()
		_smoother.physics_step()
	var tick: int = _prediction.get_predicted_tick() - 4
	var wrong: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
	wrong.position += Vector3(5.0, 0.0, 0.0)
	var before: Vector3 = _character.global_position
	var result: int = _prediction.on_server_state(tick, wrong, false)
	_smoother.physics_step()
	assert_eq(result, ClientPrediction.Result.CORRECTED, "it reconciles")
	assert_vec_near(_character.global_position, before + Vector3(5.0, 0.0, 0.0), 1e-4,
			"the body jumps to the server's state")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "beyond 3 m there is no smoothing")
	assert_eq(_visual.position, Vector3.ZERO, "Visual is in its place: direct jump")
	assert_eq(_camera_target.position, Vector3(0.0, 1.6, 0.0), "CameraTarget too")
	assert_vec_near(_visual.global_position, _character.global_position, 1e-5,
			"Visual follows the body")
	assert_near(_prediction.get_stats()["max_correction"], 5.0, 1e-3, "the correction was 5 m")


func test_teleport_flag_skips_smoothing_even_for_small_errors() -> void:
	if not await _begin_session(_idle_route):
		return
	for _i: int in 20:
		_prediction.step()
	var tick: int = _prediction.get_predicted_tick() - 4
	var wrong: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
	wrong.position += Vector3(0.05, 0.0, 0.0)
	var result: int = _prediction.on_server_state(tick, wrong, true)
	_smoother.physics_step()
	assert_eq(result, ClientPrediction.Result.CORRECTED, "it reconciles")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "a teleport is never smoothed")
	assert_eq(_visual.position, Vector3.ZERO, "Visual in its place")

	# With the teleport counter changed it is replayed even if the state matches exactly.
	var same_tick: int = _prediction.get_predicted_tick() - 2
	var same: PlayerState = _prediction.get_predicted_state(same_tick).duplicate_state()
	var matches_before: int = _prediction.get_stats()["matches"]
	assert_eq(_prediction.on_server_state(same_tick, same, true), ClientPrediction.Result.CORRECTED,
			"with teleported an identical state is not taken as good")
	assert_eq(_prediction.get_stats()["matches"], matches_before, "it does not count as a match")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "and it is not smoothed either")


func test_offset_is_applied_in_local_space_for_a_character_turned_90_degrees() -> void:
	if not await _build_session():
		return
	await tree.physics_frame
	var spawn := PlayerState.new()
	spawn.position = SPAWN_POSITION
	spawn.grounded = true
	spawn.yaw = PI / 2.0
	spawn = PlayerState.decode(spawn.encode())
	_brain.route = _idle_route
	_prediction.start(SPAWN_TICK, spawn, FIRST_REAL_TICK)
	for _i: int in 20:
		_prediction.step()
	assert_near(_character.yaw, PI / 2.0, 1e-6, "the character is turned 90 degrees")
	var tick: int = _prediction.get_predicted_tick() - 4
	var wrong: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
	wrong.position += Vector3(0.03, 0.0, 0.0)
	var visual_before: Vector3 = _visual.global_position
	var result: int = _prediction.on_server_state(tick, wrong, false)
	_smoother.physics_step()
	assert_eq(result, ClientPrediction.Result.CORRECTED, "it reconciles")

	var world_offset := Vector3(-0.03, 0.0, 0.0)
	assert_vec_near(_smoother.get_offset(), world_offset, 1e-5, "the offset is in the world")
	# With the yaw at +90° the character looks toward the world's -X (its local -Z), so an offset of
	# -0.03 in the world's X is -0.03 in local Z.
	var local_offset: Vector3 = _character.basis.inverse() * world_offset
	assert_vec_near(local_offset, Vector3(0.0, 0.0, -0.03), 1e-5, "the expected local offset")
	assert_vec_near(_visual.position, local_offset, 1e-5, "Visual: base + basis⁻¹ · offset")
	assert_vec_near(_camera_target.position, Vector3(0.0, 1.6, 0.0) + local_offset, 1e-5,
			"CameraTarget: base + basis⁻¹ · offset")
	assert_vec_near(_visual.global_position, visual_before, 0.001,
			"and in the world Visual did not move more than 1 mm")
	assert_vec_near(_visual.global_position - _character.global_position, world_offset, 1e-5,
			"the offset in the world is the same")


func test_smoother_lets_the_camera_target_follow_the_same_offset() -> void:
	if not await _build_session():
		return
	await tree.physics_frame
	var targets: Array[Node3D] = [_visual, _camera_target]
	var smoother := CorrectionSmoother.new()
	smoother.setup(_character, targets)
	smoother.physics_step()
	assert_eq(_visual.position, Vector3.ZERO, "without offset, everything in its place")
	smoother.add_offset(Vector3(0.0, 0.1, 0.0))
	assert_vec_near(smoother.get_offset(), Vector3(0.0, 0.1, 0.0), 1e-9, "the offset includes what is pending")
	assert_eq(_visual.position, Vector3.ZERO, "but it is not applied until physics_step()")
	smoother.physics_step()
	assert_vec_near(_visual.position, Vector3(0.0, 0.1, 0.0), 1e-6, "already applied, without decaying yet")
	assert_vec_near(_camera_target.position, Vector3(0.0, 1.7, 0.0), 1e-6, "in CameraTarget too")
	smoother.physics_step()
	assert_near(_visual.position.y, 0.1 * pow(0.5, 1.0 / CorrectionSmoother.HALF_LIFE_TICKS), 1e-6,
			"the next tick decays with the half-life")
	smoother.clear()
	assert_eq(smoother.get_offset(), Vector3.ZERO, "clear() zeroes the offset")
	assert_eq(_visual.position, Vector3.ZERO, "and returns Visual to its place")
	assert_eq(_camera_target.position, Vector3(0.0, 1.6, 0.0), "and CameraTarget")
	smoother.add_offset(Vector3(0.0005, 0.0, 0.0))
	smoother.physics_step()
	assert_eq(smoother.get_offset(), Vector3.ZERO, "below 1 mm it is zeroed")
	assert_eq(_visual.position, Vector3.ZERO, "without touching anything")


# --- LocalPlayerController ---------------------------------------------------------------------

func test_controller_with_auto_step_keeps_the_sandbox_behaviour() -> void:
	if not await _build_session():
		return
	_controller.auto_step = true
	_controller.set_bot(null)
	var emitted: Array[PlayerInput] = []
	var simulated_at_emission: Array[int] = []
	_controller.input_generated.connect(func(input: PlayerInput) -> void:
		emitted.append(input)
		simulated_at_emission.append(_character.last_input_tick))
	_character.set_state(_spawn_state())
	for _i: int in 5:
		await tree.physics_frame
	assert_eq(_controller.get_tick(), emitted.size(), "get_tick() counts the inputs")
	assert_true(emitted.size() >= 4, "one input per physics step (%d)" % emitted.size())
	var history: Array[PlayerInput] = _controller.get_input_history()
	assert_eq(history.size(), emitted.size(), "the history stores them")
	for i: int in emitted.size():
		assert_eq(history[i].tick, i + 1, "the history goes from the oldest to the newest")
		assert_eq(emitted[i].tick, i + 1, "input_generated emits the tick's input")
		assert_eq(simulated_at_emission[i], i, "it is emitted before simulating it")
	assert_eq(_character.last_input_tick, emitted.size(), "and the tick's input is simulated")


func test_controller_without_auto_step_only_builds_inputs_when_asked() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	var emitted: Array[PlayerInput] = []
	_controller.input_generated.connect(func(input: PlayerInput) -> void: emitted.append(input))
	_character.set_state(_spawn_state())
	_brain.route = func(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.move = Vector2(0.123456, 0.9)
		input.look_yaw = 7.0
		input.look_pitch = 0.3
		input.buttons = PlayerInput.JUMP
		return input
	_controller.set_bot(_brain)
	for _i: int in 4:
		await tree.physics_frame
	assert_eq(emitted.size(), 0, "with auto_step = false it does not generate inputs on its own")
	assert_eq(_controller.get_tick(), 0, "nor advance the tick")
	assert_eq(_character.last_input_tick, 0, "nor simulate")
	assert_vec_near(_character.global_position, SPAWN_POSITION, 1e-6, "the character did not move")

	var position_before: Vector3 = _character.global_position
	var input: PlayerInput = _controller.build_input(77)
	assert_eq(input.tick, 77, "build_input(tick) builds the input of the requested tick")
	assert_eq(_controller.get_tick(), 77, "get_tick() is the last requested")
	assert_true(input.buttons == PlayerInput.JUMP, "with the bot's buttons")
	var quantized: PlayerInput = input.quantized()
	assert_eq(input.encode(), quantized.encode(), "it is already quantized")
	assert_ne_float(input.move.x, 0.123456, "the movement is quantized")
	assert_true(input.look_yaw >= 0.0 and input.look_yaw < TAU, "and the yaw wrapped to [0, TAU)")
	assert_eq(emitted.size(), 1, "emits input_generated")
	assert_eq(emitted[0], input, "with the same input")
	assert_eq(_controller.get_input_history().size(), 1, "and stores it in the history")
	assert_eq(_controller.get_input_history()[0], input, "the same")
	assert_eq(_character.last_input_tick, 0, "but does not simulate")
	assert_vec_near(_character.global_position, position_before, 1e-9, "nor move the character")
	await tree.physics_frame
	assert_eq(emitted.size(), 1, "one physics step later it still generates nothing")


func test_controller_history_is_a_ring_of_256_inputs_in_order() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	_brain.route = _idle_route
	_controller.set_bot(_brain)
	for tick: int in range(1, 301):
		_controller.build_input(tick)
	var history: Array[PlayerInput] = _controller.get_input_history()
	assert_eq(history.size(), LocalPlayerController.HISTORY_SIZE, "256 inputs at most")
	assert_eq(history[0].tick, 300 - 256 + 1, "the oldest")
	assert_eq(history[history.size() - 1].tick, 300, "the newest")
	for i: int in range(1, history.size()):
		if history[i].tick != history[i - 1].tick + 1:
			fail("the history is not ordered at position %d" % i)
			return
	history.clear()
	assert_eq(_controller.get_input_history().size(), 256, "get_input_history() returns a copy")


func test_controller_bot_inputs_come_from_the_brain_with_position_and_yaw() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	var spawn: PlayerState = _spawn_state()
	spawn.yaw = 2.0
	spawn = PlayerState.decode(spawn.encode())
	_character.set_state(spawn)
	_brain.route = _route_input
	_controller.set_bot(_brain)
	var input: PlayerInput = _controller.build_input(40)
	assert_eq(_brain.calls, 1, "the bot generates the input")
	assert_eq(_brain.last_tick, 40, "for the requested tick")
	assert_vec_near(_brain.last_position, _character.global_position, 1e-6,
			"with the character's position")
	assert_near(_brain.last_yaw, _character.yaw, 1e-9, "and its yaw")
	assert_eq(input.encode(), _route_input(40).quantized().encode(), "the input is the bot's, quantized")
	assert_eq(input.tick, 40, "with the requested tick")
	_controller.set_bot(null)
	var device: PlayerInput = _controller.build_input(41)
	assert_eq(_brain.calls, 1, "with set_bot(null) it goes back to the device")
	assert_eq(device.move, Vector2.ZERO, "which without keys does not move")


func test_accumulated_presses_are_added_to_the_next_input_once() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	_controller.set_bot(null)
	await tree.physics_frame
	# An action pressed through the Input API only counts as "just pressed" from the
	# next physics tick.
	_press(&"jump")
	_press(&"dodge")
	await tree.physics_frame
	# Physics tick without a step: the press is stored even if it is released before the next one.
	assert_true(Input.is_action_just_pressed(&"jump"), "the action was just pressed on this tick")
	_controller.accumulate_presses()
	Input.action_release(&"jump")
	Input.action_release(&"dodge")
	_pressed_actions.clear()
	await tree.physics_frame
	assert_false(Input.is_action_pressed(&"jump"), "it is no longer pressed")
	var first: PlayerInput = _controller.build_input(1)
	assert_true(first.has(PlayerInput.JUMP) and first.has(PlayerInput.DODGE),
			"the next build_input() adds the stored presses (buttons %d)" % first.buttons)
	var second: PlayerInput = _controller.build_input(2)
	assert_eq(second.buttons, 0, "and only once")

	# A held key stays in the input and is not duplicated when accumulating.
	_press(&"sprint")
	await tree.physics_frame
	_controller.accumulate_presses()
	var third: PlayerInput = _controller.build_input(3)
	assert_eq(third.buttons, PlayerInput.SPRINT, "a held key: neither too few nor too many")
	await tree.physics_frame
	var fourth: PlayerInput = _controller.build_input(4)
	assert_eq(fourth.buttons, PlayerInput.SPRINT, "and it continues while held")


func test_accumulate_presses_does_nothing_for_bots() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	_brain.route = _idle_route
	_controller.set_bot(_brain)
	await tree.physics_frame
	_press(&"jump")
	await tree.physics_frame
	assert_true(Input.is_action_just_pressed(&"jump"), "the action was just pressed on this tick")
	_controller.accumulate_presses()
	Input.action_release(&"jump")
	_pressed_actions.clear()
	await tree.physics_frame
	assert_eq(_controller.build_input(1).buttons, 0, "a bot's input does not depend on the keyboard")


# --- Building the test scene -------------------------------------------------------------------

## Prepares the two worlds and starts the prediction with the given route. It must be called with
## [code]await[/code]; on return you are inside the physics tick.
func _begin_session(route: Callable) -> bool:
	if not await _build_session():
		return false
	await tree.physics_frame
	_brain.route = route
	var spawn: PlayerState = _spawn_state()
	_model = ServerModel.new()
	_model.start(_server, SPAWN_TICK, spawn, _dt)
	_prediction.start(SPAWN_TICK, spawn, FIRST_REAL_TICK)
	# The client advances neutrally until just before P0; the server will lag behind
	# (FIRST_REAL_TICK - 1 - SPAWN_TICK ticks) and will substitute those ticks with the rule of 8.2.
	return true


func _build_session() -> bool:
	_server_viewport = _make_world("ServerWorld")
	_client_viewport = _make_world("ClientWorld")
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "could not load %s" % CHARACTER_SCENE_PATH):
		return false
	_server = scene.instantiate() as PlayerCharacter
	_server_viewport.add_child(_server)
	_character = scene.instantiate() as PlayerCharacter
	_character.jumped.connect(func() -> void: _jumped_count += 1)
	_character.landed.connect(func() -> void: _landed_count += 1)
	_client_viewport.add_child(_character)

	_brain = ScriptedBrain.new()
	_brain.route = _idle_route
	_controller = LocalPlayerController.new()
	_controller.name = "LocalPlayerController"
	_controller.auto_step = false
	_client_viewport.add_child(_controller)
	_controller.setup(_character, null)
	_controller.set_bot(_brain)

	_visual = _character.get_node(^"Visual") as Node3D
	_camera_target = _character.get_camera_target()
	var targets: Array[Node3D] = [_visual, _camera_target]
	_smoother = CorrectionSmoother.new()
	_smoother.setup(_character, targets)
	_prediction = ClientPrediction.new()
	_prediction.setup(_character, _controller, _smoother, _dt)
	# Two physics steps for the spaces to register the newly added bodies.
	await wait_physics_frames(2)
	return true


func _make_world(world_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = world_name
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	_add_box(viewport, Vector3(200.0, 1.0, 200.0), Vector3(0.0, -0.5, 0.0), 0.0)
	var angle: float = deg_to_rad(RAMP_ANGLE_DEG)
	var surface_normal := Vector3(0.0, cos(angle), sin(angle))
	var uphill := Vector3(0.0, sin(angle), -cos(angle))
	var center: Vector3 = (RAMP_FOOT + uphill * (RAMP_LENGTH * 0.5)
			- surface_normal * (RAMP_THICKNESS * 0.5))
	_add_box(viewport, Vector3(RAMP_WIDTH, RAMP_THICKNESS, RAMP_LENGTH), center, angle)
	return viewport


func _add_box(parent: Node, size: Vector3, center: Vector3, pitch: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	body.rotation = Vector3(pitch, 0.0, 0.0)
	parent.add_child(body)


## Exact spawn state (passed through encode/decode, as the server imposes it).
func _spawn_state() -> PlayerState:
	var state := PlayerState.new()
	state.position = SPAWN_POSITION
	state.grounded = true
	return PlayerState.decode(state.encode())


# --- Scripted routes ---------------------------------------------------------------------------

## Neutral input looking straight ahead.
func _idle_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	return input


## Route of [constant ROUTE_TICKS] ticks: waits, sprints toward the ramp, climbs jumping, turns
## nonstop crossing ±PI, backs up jumping and stops.
func _route_input(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick < 31:
		return input
	if tick <= 120:
		input.move = Vector2(0.0, 1.0)
		if tick >= 45:
			input.buttons |= PlayerInput.SPRINT
		if tick >= 100 and tick <= 102:
			input.buttons |= PlayerInput.JUMP
	elif tick <= 190:
		input.look_yaw = float(tick - 120) * 0.1
		input.move = Vector2(0.3, 1.0).limit_length(1.0)
	elif tick <= 230:
		input.look_yaw = 3.0
		input.move = Vector2(0.0, -1.0)
		if tick >= 200 and tick <= 201:
			input.buttons |= PlayerInput.JUMP
	else:
		input.look_yaw = 3.0
	return input


## Combat route: walks forward and attacks (light attack chained with the next), dodges, blocks and
## charges the heavy attack (200-239 held, released after the minimum charge).
func _combat_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick < 31:
		return input
	input.move = Vector2(0.2, 1.0).limit_length(1.0)
	input.look_yaw = 0.002 * float(tick)
	if tick == 40 or tick == 70:
		input.buttons |= PlayerInput.PRIMARY
	if tick == 110:
		input.buttons |= PlayerInput.DODGE
	if tick >= 140 and tick <= 175:
		input.buttons |= PlayerInput.BLOCK
	if tick >= 200 and tick <= 239:
		input.buttons |= PlayerInput.PRIMARY
	if tick == 275:
		input.buttons |= PlayerInput.PRIMARY
	return input


# --- One client tick and one server tick -------------------------------------------------------

## One client tick, in NetClient's order: the own states that are due arrive, a prediction step,
## the input is sent (and lost if its tick is in [param lost]) and the smoother runs. The results of
## [method ClientPrediction.on_server_state] are appended to [param results] as (tick, result).
func _client_tick(results: Array[Vector2i], lost: Array[int]) -> void:
	while not _pending_states.is_empty() and _pending_states[0]["due"] <= _frame_counter:
		var item: Dictionary = _pending_states.pop_front()
		var tick: int = item["tick"]
		var result: int = _prediction.on_server_state(tick, item["state"], false)
		results.append(Vector2i(tick, result))
	var input: PlayerInput = _prediction.step()
	if not lost.has(input.tick):
		_model.receive(input)
	_smoother.physics_step()
	_frame_counter += 1


## One server tick: it applies the input (or the substitute) and queues the own state with delay.
func _server_tick() -> PlayerState:
	var state: PlayerState = _model.step()
	if _model.tick % STATE_INTERVAL_TICKS == 0:
		_pending_states.append({
			"tick": _model.tick,
			"state": PlayerState.decode(state.encode()),
			"due": _frame_counter + STATE_DELAY_FRAMES,
		})
	return state


## Straight march forward from the first real input.
func _walk_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick >= FIRST_REAL_TICK:
		input.move = Vector2(0.0, 1.0)
	return input


## Highest tick whose result was not [param expected], or 0 if all were.
func _last_result_tick_not(results: Array[Vector2i], expected: int) -> int:
	var last: int = 0
	for entry: Vector2i in results:
		if entry.y != expected:
			last = maxi(last, entry.x)
	return last


## From [param tick] on, the client ended up bit for bit equal to the server, and all the states that
## arrived afterward matched.
func _assert_converged_since(tick: int) -> void:
	for t: int in range(tick, _model.tick + 1):
		var predicted: PlayerState = _prediction.get_predicted_state(t)
		var server_state: PlayerState = _model.states[t]
		if predicted == null or predicted.encode() != server_state.encode():
			fail("tick %d did not end up equal to the server after the last reconciliation" % t)
			return
	assert_true(_model.tick > tick + 10, "ticks were left to check (up to %d)" % _model.tick)


func _results_with(results: Array[Vector2i], wanted: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for entry: Vector2i in results:
		if entry.y == wanted:
			found.append(entry)
	return found


func _press(action: StringName) -> void:
	Input.action_press(action)
	_pressed_actions.append(action)


func assert_ne_float(actual: float, unexpected: float, message: String = "") -> bool:
	return assert_false(is_equal_approx(actual, unexpected), message)
