extends TestCase
## Pruebas de [BotCheatBrain], el cerebro de los modos [code]reach[/code] y [code]rate[/code] del bot
## tramposo (docs/combate.md, sección 4.5), sin red ni mundo: con un buscador de enemigos a mano se
## comprueba qué entradas genera según la distancia.


## Un cerebro que ve un enemigo fijo en [param enemy].
func _brain(style: BotCheatBrain.Style, enemy: Variant) -> BotCheatBrain:
	var brain := BotCheatBrain.new(5, style, Vector3.ZERO, 20.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy)
	return brain


## Entradas de [param ticks] ticks seguidos desde [param first] con el bot siempre en [param position].
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
	assert_eq(input.move, Vector2(0.0, 1.0), "a 8 m avanza")
	assert_near(input.look_yaw, 0.0, 1e-6, "mirando al enemigo (yaw 0 es hacia -Z)")
	assert_eq(input.buttons & PlayerInput.SPRINT, 0, "sin esprintar a 8 m")
	var far: PlayerInput = _brain(BotCheatBrain.Style.REACH, Vector3(0.0, 0.0, -20.0)).next_input(
			1, Vector3.ZERO, 0.0)
	assert_true((far.buttons & PlayerInput.SPRINT) != 0, "a 20 m esprinta")
	assert_eq(_pressed([input, far]), 0, "y no ataca mientras se acerca")


func test_reach_backs_off_when_the_enemy_is_closer_than_five_meters() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.REACH, Vector3(0.0, 0.0, -3.0))
	var input: PlayerInput = brain.next_input(1, Vector3.ZERO, 0.0)
	assert_eq(input.move, Vector2(0.0, -1.0), "a 3 m retrocede")
	assert_near(input.look_yaw, 0.0, 1e-6, "sin dejar de mirarlo")


func test_reach_swings_from_five_meters_one_tap_every_forty_ticks() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.REACH, Vector3(0.0, 0.0, -BotCheatBrain.REACH_DISTANCE))
	var inputs: Array[PlayerInput] = _inputs(brain, 100, 200)
	for input: PlayerInput in inputs:
		assert_eq(input.move, Vector2.ZERO, "a la distancia justa se queda quieto")
	assert_eq(_pressed(inputs), 5 * BotCheatBrain.TAP_TICKS, "cinco toques de dos ticks en 200 ticks")
	# Los toques empiezan cada 40 ticks.
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
	assert_eq(approach.move, Vector2(0.0, 1.0), "se acerca")
	assert_eq(approach.buttons & PlayerInput.PRIMARY, 0, "sin pulsar mientras no llega")
	var close: BotCheatBrain = _brain(BotCheatBrain.Style.RATE, Vector3(0.0, 0.0, -1.5))
	var inputs: Array[PlayerInput] = _inputs(close, 10, 20)
	assert_eq(_pressed(inputs), 10, "pulsa un tick de cada dos")
	for input: PlayerInput in inputs:
		var expected: bool = input.tick % 2 == 0
		assert_eq((input.buttons & PlayerInput.PRIMARY) != 0, expected, "en los ticks pares (%d)" % input.tick)
		assert_eq(input.move, Vector2.ZERO, "y quieto")


func test_without_an_enemy_both_styles_wander_like_the_plain_brain() -> void:
	for style: BotCheatBrain.Style in [BotCheatBrain.Style.REACH, BotCheatBrain.Style.RATE]:
		var cheat: BotCheatBrain = _brain(style, null)
		var plain := BotBrain.new(5, BotBrain.Pattern.WANDER, Vector3.ZERO, 20.0)
		for tick: int in range(1, 200):
			var a: PlayerInput = cheat.next_input(tick, Vector3(1.0, 0.0, 1.0), 0.5)
			var b: PlayerInput = plain.next_input(tick, Vector3(1.0, 0.0, 1.0), 0.5)
			assert_eq(a.quantized().move, b.quantized().move, "mismo paseo (tick %d)" % tick)
			assert_eq(a.buttons & PlayerInput.PRIMARY, 0, "y no ataca")


func test_the_same_seed_gives_the_same_inputs() -> void:
	var first: BotCheatBrain = _brain(BotCheatBrain.Style.RATE, null)
	var second: BotCheatBrain = _brain(BotCheatBrain.Style.RATE, null)
	for tick: int in range(1, 300):
		var a: PlayerInput = first.next_input(tick, Vector3.ZERO, 0.0)
		var b: PlayerInput = second.next_input(tick, Vector3.ZERO, 0.0)
		assert_eq(a.move, b.move)
		assert_eq(a.buttons, b.buttons)
