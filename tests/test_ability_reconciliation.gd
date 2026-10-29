extends TestCase
## La reutilización de una habilidad sobrevive a la reconciliación (docs/habilidades.md, sección 7.3):
## cliente y servidor con las mismas entradas, una diferencia de posición que impone el servidor
## después del compromiso y, tras repetir, la misma [member CombatState.ability_ready] y el mismo
## estado byte a byte. Y un rechazo (el servidor no llegó a empezar la habilidad) la devuelve a su
## valor. Sin red: [PredictionPair].

const Action = CombatState.Action
## Tick de la pulsación del golpe de escudo (compromiso 18 ticks después).
const PRESS_TICK: int = 40
## Tick (del servidor, tras el compromiso) en que el servidor desplaza al personaje.
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
			# Un empujón del servidor (lo que haría un golpe o una colisión que el cliente no vio).
			character.global_position += Vector3(0.35, 0.0, 0.0)
			PredictionPair.commit(character)
	await _pair.build(tree, _route, _initial_combat())
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var commit_tick: int = PRESS_TICK + bash.cast_ticks
	for _frame: int in FRAMES:
		await tree.physics_frame
		_pair.frame()
	var server_state: PlayerState = _pair.server_states[commit_tick]
	assert_eq(server_state.combat.action, Action.ABILITY, "el servidor usa la habilidad")
	assert_eq(server_state.combat.ability_ready[0], commit_tick + bash.cooldown_ticks,
			"y fija la reutilización en el compromiso")
	var corrected: Array[Vector2i] = _pair.results_not(ClientPrediction.Result.MATCH)
	assert_true(corrected.size() >= 1, "el empujón obliga a reconciliar (%s)" % [corrected])
	for entry: Vector2i in corrected:
		assert_true(entry.x >= SHOVE_TICK, "la primera diferencia es la del empujón (%d)" % entry.x)
	var since: int = _pair.converged_since(SHOVE_TICK)
	assert_true(since >= SHOVE_TICK and since <= SHOVE_TICK + 2,
			"tras repetir, cliente y servidor coinciden byte a byte (desde %d)" % since)
	var last: int = _pair.server_tick
	var predicted: PlayerState = _pair.predicted(last)
	assert_eq(predicted.combat.ability_ready[0], commit_tick + bash.cooldown_ticks,
			"la reutilización predicha sigue siendo la del compromiso")
	var correction: float = _pair.prediction.get_stats()["max_correction"]
	assert_true(correction > 0.3 and correction < 0.4, "el cliente adoptó el empujón (%s m)" % correction)
	assert_eq(_pair.prediction.get_stats()["hard_resets"], 0, "sin hard reset")


func test_a_rejected_ability_returns_the_cooldown_on_replay() -> void:
	# La pulsación de un solo tick se pierde: el servidor repite la entrada anterior (sin el botón) y
	# nunca empieza la habilidad; el cliente la predijo y, al reconciliar, la quita.
	_pair = PredictionPair.new()
	_pair.lost.assign([PRESS_TICK])
	# Con 30 fotogramas de retraso el cliente llega a predecir el compromiso antes de saber nada.
	_pair.state_delay_frames = 30
	await _pair.build(tree, _tap_route, _initial_combat())
	var predicted_ready: int = -1
	for _frame: int in FRAMES:
		await tree.physics_frame
		_pair.frame()
		if _pair.prediction.get_predicted_tick() == PRESS_TICK + 25:
			var early: PlayerState = _pair.predicted(PRESS_TICK + 25)
			predicted_ready = early.combat.ability_ready[0] if early != null else -1
	assert_true(predicted_ready > 0, "el cliente predijo la habilidad y su reutilización (%d)" % predicted_ready)
	for tick: int in range(PRESS_TICK, _pair.server_tick + 1):
		var state: PlayerState = _pair.server_states[tick]
		if state.combat.action == Action.ABILITY:
			fail("el servidor no debía empezar la habilidad (tick %d)" % tick)
			return
	var last: PlayerState = _pair.predicted(_pair.server_tick)
	assert_eq(last.combat.ability_ready[0], 0, "al repetir, la reutilización vuelve a 0")
	assert_true(_pair.converged_since(PRESS_TICK) > 0, "y los dos acaban iguales")
	assert_eq(_pair.substitutions, PredictionPair.FIRST_REAL_TICK - PredictionPair.SPAWN_TICK - 1 + 1,
			"el servidor sustituyó la pulsación perdida")


func _initial_combat() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"), 0,
			CombatState.pack_charges(3, 2))


## Camina en diagonal y pulsa el golpe de escudo en [constant PRESS_TICK], mantenido 3 ticks.
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


## Como [method _route], pero la pulsación dura un solo tick.
func _tap_route(tick: int) -> PlayerInput:
	var input: PlayerInput = _route(tick)
	if tick != PRESS_TICK:
		input.buttons &= ~PlayerInput.ABILITY_1
	return input
