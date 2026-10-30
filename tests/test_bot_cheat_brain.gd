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


# --- Modos de la fase 4: reuse, potion e interact (docs/habilidades.md, sección 4.7) ----------------

func _count_button(inputs: Array[PlayerInput], button: int) -> int:
	var count: int = 0
	for input: PlayerInput in inputs:
		if (input.buttons & button) != 0:
			count += 1
	return count


func test_reuse_closes_in_and_mashes_the_first_ability_every_other_tick() -> void:
	var far: BotCheatBrain = _brain(BotCheatBrain.Style.REUSE, Vector3(0.0, 0.0, -6.0))
	var approach: PlayerInput = far.next_input(2, Vector3.ZERO, 0.0)
	assert_eq(approach.move, Vector2(0.0, 1.0), "se acerca")
	assert_eq(approach.buttons & PlayerInput.ABILITY_1, 0, "sin pulsar mientras no llega")
	var close: BotCheatBrain = _brain(BotCheatBrain.Style.REUSE, Vector3(0.0, 0.0, -1.5))
	var inputs: Array[PlayerInput] = _inputs(close, 10, 40)
	assert_eq(_count_button(inputs, PlayerInput.ABILITY_1), 20, "la habilidad 1 un tick de cada dos")
	assert_eq(_count_button(inputs, PlayerInput.PRIMARY), 0, "y nada más")
	for input: PlayerInput in inputs:
		assert_eq((input.buttons & PlayerInput.ABILITY_1) != 0, input.tick % 2 == 0, "tick %d" % input.tick)


func test_potion_mashes_both_potions_in_place_without_an_enemy() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.POTION, null)
	var inputs: Array[PlayerInput] = _inputs(brain, 100, 40, Vector3(3.0, 0.0, 3.0))
	assert_eq(_count_button(inputs, PlayerInput.CONSUMABLE_1), 10, "R en los múltiplos de 4")
	assert_eq(_count_button(inputs, PlayerInput.CONSUMABLE_2), 10, "T en los demás pares")
	for input: PlayerInput in inputs:
		assert_eq(input.move, Vector2.ZERO, "quieto")
		if input.tick % 2 != 0:
			assert_eq(input.buttons, 0, "un flanco cada dos ticks: los impares, sueltos")


func test_interact_mashes_interact_in_place() -> void:
	var brain: BotCheatBrain = _brain(BotCheatBrain.Style.INTERACT, Vector3(0.0, 0.0, -1.0))
	var inputs: Array[PlayerInput] = _inputs(brain, 100, 30)
	assert_eq(_count_button(inputs, PlayerInput.INTERACT), 15, "INTERACT un tick de cada dos")
	for input: PlayerInput in inputs:
		assert_eq(input.move, Vector2.ZERO, "sin ir hacia nadie")
		assert_eq(input.buttons & ~PlayerInput.INTERACT, 0, "y sin otros botones")
