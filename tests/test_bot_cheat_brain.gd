extends TestCase
## Tests of [BotCheatBrain], the brain of the [code]reach[/code] and [code]rate[/code] modes of the cheating
## bot (docs/combate.md, section 4.5), without network or world: with a hand-made enemy finder it
## checks which inputs it generates depending on the distance.


## A brain that sees a fixed enemy at [param enemy].
func _brain(style: BotCheatBrain.Style, enemy: Variant) -> BotCheatBrain:
	var brain := BotCheatBrain.new(5, style, Vector3.ZERO, 20.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy)
	return brain


## Inputs for [param ticks] consecutive ticks from [param first] with the bot always at [param position].
func _inputs(brain: BotBrain, first: int, ticks: int, position: Vector3 = Vector3.ZERO) -> Array[PlayerInput]:
	var inputs: Array[PlayerInput] = []
	for tick: int in range(first, first + ticks):
		inputs.append(brain.next_input(tick, position, 0.0))
	return inputs


func _pressed(inputs: Array[PlayerInput]) -> int:
	var count: int = 0
	for input: PlayerInput in inputs:
		if (input.buttons & PlayerInput.PRIMARY) != 0:
			count += 1
	return count


func test_reach_walks_toward_the_enemy_until_it_is_five_meters_away() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.REACH, Vector3(0.0, 0.0, -8.0))
	var input: PlayerInput = brain.next_input(1, Vector3.ZERO, 0.0)
	assert_eq(input.move, Vector2(0.0, 1.0), "at 8 m it advances")
	assert_near(input.look_yaw, 0.0, 1e-6, "facing the enemy (yaw 0 is toward -Z)")
	assert_eq(input.buttons & PlayerInput.SPRINT, 0, "without sprinting at 8 m")
	var far: PlayerInput = _brain(BotCheatBrain.Style.REACH, Vector3(0.0, 0.0, -20.0)).next_input(
			1, Vector3.ZERO, 0.0)
	assert_true((far.buttons & PlayerInput.SPRINT) != 0, "at 20 m it sprints")
	assert_eq(_pressed([input, far]), 0, "and does not attack while approaching")


func test_reach_backs_off_when_the_enemy_is_closer_than_five_meters() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.REACH, Vector3(0.0, 0.0, -3.0))
	var input: PlayerInput = brain.next_input(1, Vector3.ZERO, 0.0)
	assert_eq(input.move, Vector2(0.0, -1.0), "at 3 m it backs off")
	assert_near(input.look_yaw, 0.0, 1e-6, "without ceasing to face it")


func test_reach_swings_from_five_meters_one_tap_every_forty_ticks() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.REACH, Vector3(0.0, 0.0, -BotCheatBrain.REACH_DISTANCE))
	var inputs: Array[PlayerInput] = _inputs(brain, 100, 200)
	for input: PlayerInput in inputs:
		assert_eq(input.move, Vector2.ZERO, "at the exact distance it stays still")
	assert_eq(_pressed(inputs), 5 * BotCheatBrain.TAP_TICKS, "five two-tick taps in 200 ticks")
	# The taps start every 40 ticks.
	var starts: Array[int] = []
	for index: int in inputs.size():
		var pressed: bool = (inputs[index].buttons & PlayerInput.PRIMARY) != 0
		var before: bool = index > 0 and (inputs[index - 1].buttons & PlayerInput.PRIMARY) != 0
		if pressed and not before:
			starts.append(inputs[index].tick)
	assert_eq(starts, [100, 140, 180, 220, 260] as Array[int])


func test_rate_closes_in_and_presses_primary_every_other_tick() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.RATE, Vector3(0.0, 0.0, -6.0))
	var approach: PlayerInput = brain.next_input(2, Vector3.ZERO, 0.0)
	assert_eq(approach.move, Vector2(0.0, 1.0), "approaches")
	assert_eq(approach.buttons & PlayerInput.PRIMARY, 0, "without pressing while it has not arrived")
	var close: BotCheatBrain = _brain(BotCheatBrain.Style.RATE, Vector3(0.0, 0.0, -1.5))
	var inputs: Array[PlayerInput] = _inputs(close, 10, 20)
	assert_eq(_pressed(inputs), 10, "presses one tick out of every two")
	for input: PlayerInput in inputs:
		var expected: bool = input.tick % 2 == 0
		assert_eq((input.buttons & PlayerInput.PRIMARY) != 0, expected, "on the even ticks (%d)" % input.tick)
		assert_eq(input.move, Vector2.ZERO, "and standing still")


func test_without_an_enemy_both_styles_wander_like_the_plain_brain() -> void:
	for style: BotCheatBrain.Style in [BotCheatBrain.Style.REACH, BotCheatBrain.Style.RATE]:
		var cheat: BotCheatBrain = _brain(style, null)
		var plain := BotBrain.new(5, BotBrain.Pattern.WANDER, Vector3.ZERO, 20.0)
		for tick: int in range(1, 200):
			var a: PlayerInput = cheat.next_input(tick, Vector3(1.0, 0.0, 1.0), 0.5)
			var b: PlayerInput = plain.next_input(tick, Vector3(1.0, 0.0, 1.0), 0.5)
			assert_eq(a.quantized().move, b.quantized().move, "same walk (tick %d)" % tick)
			assert_eq(a.buttons & PlayerInput.PRIMARY, 0, "and does not attack")


func test_the_same_seed_gives_the_same_inputs() -> void:
	var first: BotCheatBrain = _brain(BotCheatBrain.Style.RATE, null)
	var second: BotCheatBrain = _brain(BotCheatBrain.Style.RATE, null)
	for tick: int in range(1, 300):
		var a: PlayerInput = first.next_input(tick, Vector3.ZERO, 0.0)
		var b: PlayerInput = second.next_input(tick, Vector3.ZERO, 0.0)
		assert_eq(a.move, b.move)
		assert_eq(a.buttons, b.buttons)


# --- Phase 4 modes: reuse, potion and interact (docs/habilidades.md, section 4.7) ----------------

func _count_button(inputs: Array[PlayerInput], button: int) -> int:
	var count: int = 0
	for input: PlayerInput in inputs:
		if (input.buttons & button) != 0:
			count += 1
	return count


func test_reuse_closes_in_and_mashes_the_first_ability_every_other_tick() -> void:
	var far: BotCheatBrain = _brain(BotCheatBrain.Style.REUSE, Vector3(0.0, 0.0, -6.0))
	var approach: PlayerInput = far.next_input(2, Vector3.ZERO, 0.0)
	assert_eq(approach.move, Vector2(0.0, 1.0), "approaches")
	assert_eq(approach.buttons & PlayerInput.ABILITY_1, 0, "without pressing while it has not arrived")
	var close: BotCheatBrain = _brain(BotCheatBrain.Style.REUSE, Vector3(0.0, 0.0, -1.5))
	var inputs: Array[PlayerInput] = _inputs(close, 10, 40)
	assert_eq(_count_button(inputs, PlayerInput.ABILITY_1), 20, "ability 1 one tick out of every two")
	assert_eq(_count_button(inputs, PlayerInput.PRIMARY), 0, "and nothing else")
	for input: PlayerInput in inputs:
		assert_eq((input.buttons & PlayerInput.ABILITY_1) != 0, input.tick % 2 == 0, "tick %d" % input.tick)


func test_potion_mashes_both_potions_in_place_without_an_enemy() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.POTION, null)
	var inputs: Array[PlayerInput] = _inputs(brain, 100, 40, Vector3(3.0, 0.0, 3.0))
	assert_eq(_count_button(inputs, PlayerInput.CONSUMABLE_1), 10, "R on multiples of 4")
	assert_eq(_count_button(inputs, PlayerInput.CONSUMABLE_2), 10, "T on the other even ticks")
	for input: PlayerInput in inputs:
		assert_eq(input.move, Vector2.ZERO, "standing still")
		if input.tick % 2 != 0:
			assert_eq(input.buttons, 0, "an edge every two ticks: the odd ones, released")


func test_interact_mashes_interact_in_place() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.INTERACT, Vector3(0.0, 0.0, -1.0))
	var inputs: Array[PlayerInput] = _inputs(brain, 100, 30)
	assert_eq(_count_button(inputs, PlayerInput.INTERACT), 15, "INTERACT one tick out of every two")
	for input: PlayerInput in inputs:
		assert_eq(input.move, Vector2.ZERO, "without going toward anyone")
		assert_eq(input.buttons & ~PlayerInput.INTERACT, 0, "and without other buttons")
