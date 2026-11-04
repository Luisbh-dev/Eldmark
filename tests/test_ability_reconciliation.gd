extends TestCase
## The cooldown of an ability survives reconciliation (docs/abilities.md, section 7.3):
## client and server with the same inputs, a position difference imposed by the server
## after the commit and, after replaying, the same [member CombatState.ability_ready] and the same
## state byte for byte. And a rejection (the server never got to start the ability) restores it to its
## value. No network: [PredictionPair].

const Action = CombatState.Action
## Tick of the shield bash press (commit 18 ticks later).
const PRESS_TICK: int = 40
## Tick (the server's, after the commit) at which the server displaces the character.
const SHOVE_TICK: int = 70
const FRAMES: int = 160

var _pair: PredictionPair


func after_each() -> void:
	if _pair != null:
		_pair.free_worlds()
		_pair = null
	await wait_process_frames()


func test_the_cooldown_survives_a_reconciliation() -> void:
	_pair = PredictionPair.new()
	_pair.server_hook = func(character: PlayerCharacter, tick: int) -> void:
		if tick == SHOVE_TICK:
			# A server push (what a hit or a collision the client did not see would do).
			character.global_position += Vector3(0.35, 0.0, 0.0)
			PredictionPair.commit(character)
	await _pair.build(tree, _route, _initial_combat())
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var commit_tick: int = PRESS_TICK + bash.cast_ticks
	for _frame: int in FRAMES:
		await tree.physics_frame
		_pair.frame()
	var server_state: PlayerState = _pair.server_states[commit_tick]
	assert_eq(server_state.combat.action, Action.ABILITY, "the server uses the ability")
	assert_eq(server_state.combat.ability_ready[0], commit_tick + bash.cooldown_ticks,
			"and sets the cooldown at the commit")
	var corrected: Array[Vector2i] = _pair.results_not(ClientPrediction.Result.MATCH)
	assert_true(corrected.size() >= 1, "the push forces a reconciliation (%s)" % [corrected])
	for entry: Vector2i in corrected:
		assert_true(entry.x >= SHOVE_TICK, "the first difference is the push's (%d)" % entry.x)
	var since: int = _pair.converged_since(SHOVE_TICK)
	assert_true(since >= SHOVE_TICK and since <= SHOVE_TICK + 2,
			"after replaying, client and server match byte for byte (from %d)" % since)
	var last: int = _pair.server_tick
	var predicted: PlayerState = _pair.predicted(last)
	assert_eq(predicted.combat.ability_ready[0], commit_tick + bash.cooldown_ticks,
			"the predicted cooldown is still the one from the commit")
	var correction: float = _pair.prediction.get_stats()["max_correction"]
	assert_true(correction > 0.3 and correction < 0.4, "the client adopted the push (%s m)" % correction)
	assert_eq(_pair.prediction.get_stats()["hard_resets"], 0, "no hard reset")


func test_a_rejected_ability_returns_the_cooldown_on_replay() -> void:
	# A single-tick press is lost: the server repeats the previous input (without the button) and
	# never starts the ability; the client predicted it and, on reconciling, removes it.
	_pair = PredictionPair.new()
	_pair.lost.assign([PRESS_TICK])
	# With 30 frames of delay the client gets to predict the commit before knowing anything.
	_pair.state_delay_frames = 30
	await _pair.build(tree, _tap_route, _initial_combat())
	var predicted_ready: int = -1
	for _frame: int in FRAMES:
		await tree.physics_frame
		_pair.frame()
		if _pair.prediction.get_predicted_tick() == PRESS_TICK + 25:
			var early: PlayerState = _pair.predicted(PRESS_TICK + 25)
			predicted_ready = early.combat.ability_ready[0] if early != null else -1
	assert_true(predicted_ready > 0, "the client predicted the ability and its cooldown (%d)" % predicted_ready)
	for tick: int in range(PRESS_TICK, _pair.server_tick + 1):
		var state: PlayerState = _pair.server_states[tick]
		if state.combat.action == Action.ABILITY:
			fail("the server must not start the ability (tick %d)" % tick)
			return
	var last: PlayerState = _pair.predicted(_pair.server_tick)
	assert_eq(last.combat.ability_ready[0], 0, "on replay, the cooldown returns to 0")
	assert_true(_pair.converged_since(PRESS_TICK) > 0, "and both end up the same")
	assert_eq(_pair.substitutions, PredictionPair.FIRST_REAL_TICK - PredictionPair.SPAWN_TICK - 1 + 1,
			"the server replaced the lost press")


func _initial_combat() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"), 0,
			CombatState.pack_charges(3, 2))


## Walks diagonally and presses the shield bash at [constant PRESS_TICK], held for 3 ticks.
func _route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick < 20:
		return input
	input.move = Vector2(0.3, 1.0).limit_length(1.0)
	input.look_yaw = 0.003 * float(tick)
	if tick >= PRESS_TICK and tick < PRESS_TICK + 3:
		input.buttons |= PlayerInput.ABILITY_1
	return input


## Like [method _route], but the press lasts a single tick.
func _tap_route(tick: int) -> PlayerInput:
	var input: PlayerInput = _route(tick)
	if tick != PRESS_TICK:
		input.buttons &= ~PlayerInput.ABILITY_1
	return input
