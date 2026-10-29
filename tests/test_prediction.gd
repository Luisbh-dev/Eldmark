extends TestCase
## Pruebas de la predicción del cliente ([ClientPrediction]), del suavizado de las correcciones
## ([CorrectionSmoother]) y de los cambios de [LocalPlayerController] de la fase 2 (docs/red.md,
## secciones 6, 16 y 17.7). No hay red: el «servidor» y el cliente son dos mundos de física
## separados (dos [SubViewport] con [code]own_world_3d = true[/code]), cada uno con un
## [PlayerCharacter] sobre un suelo con una rampa.
## [br][br]
## El servidor se modela a mano con la regla de la sección 8.2 (sin depender de
## [code]scripts/server/[/code]): aplica la entrada del tick si le ha llegado y, si no, repite la
## última aplicada con todos sus botones y pone el movimiento a 0 pasados 6 ticks sin entradas
## reales. Las entradas del servidor son las mismas (cuantizadas, tras pasar por
## encode/decode) que genera el cliente.
## [br][br]
## Todo se simula dentro del tick de física con [code]delta = 1 / physics_ticks_per_second[/code],
## como pide [method PlayerCharacter.simulate]. Varios ticks dentro de un mismo paso de física son
## válidos (es lo que hace la reconciliación) y se usan donde no importa el reloj.

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const WORLD_LAYER: int = PlayerCharacter.WORLD_COLLISION_LAYER
## Tick del servidor en el que «aparece» el jugador, y primer tick con entrada real.
const SPAWN_TICK: int = 10
const FIRST_REAL_TICK: int = 14
## Seis metros delante de la rampa de 25°, que sube hacia -Z.
const SPAWN_POSITION: Vector3 = Vector3(20.0, 0.0, 6.0)
const RAMP_FOOT: Vector3 = Vector3(20.0, -0.02, 0.0)
const RAMP_ANGLE_DEG: float = 25.0
const RAMP_LENGTH: float = 12.0
const RAMP_WIDTH: float = 10.0
const RAMP_THICKNESS: float = 0.5
## Ticks de retraso con los que llegan los estados del servidor (6 ticks = 100 ms).
const STATE_DELAY_FRAMES: int = 6
## Un estado propio cada 2 ticks, como los snapshots a 30 Hz.
const STATE_INTERVAL_TICKS: int = 2
## Ticks de la ruta guionizada.
const ROUTE_TICKS: int = 250
## Ticks que salta el hard reset hacia delante de la prueba de la regla de sustitución: más de
## [constant NetProtocol.REPEAT_MOVE_TICKS], para ver cómo se repite el movimiento y cómo se anula.
const GAP_TICKS: int = 12
## Altura (m) del suelo que la ruta tiene que pisar para dar por subida la rampa: un salto en llano
## llega a ~1,5 m, así que 2 m solo se alcanzan subiendo por ella.
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
## Estados propios del servidor en camino hacia el cliente: {tick, state, due} (due = fotograma
## de cliente en el que llegan).
var _pending_states: Array[Dictionary] = []
var _frame_counter: int = 0


## Cerebro cuyas entradas salen de una función del tick, y que recuerda lo último que vio.
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


## El servidor de la prueba: la regla de sustitución de la sección 8.2 sobre un personaje real.
class ServerModel:
	var character: PlayerCharacter
	var dt: float = 1.0 / 60.0
	var tick: int = 0
	## Entradas recibidas todavía sin aplicar (tick -> entrada). Gana la primera copia.
	var inbox: Dictionary = {}
	var last_applied: PlayerInput = null
	var last_real_tick: int = 0
	var substitutions: int = 0
	## Estado tras cada tick simulado (tick -> PlayerState).
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
			if for_tick - last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
				input.move = Vector2.ZERO
			substitutions += 1
		last_applied = input
		return input


	## Simula el tick siguiente y devuelve el estado resultante.
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


# --- Predicción: mismas entradas, mismo estado --------------------------------------------------

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
		if not assert_not_null(predicted, "el anillo guarda el tick %d" % _model.tick):
			return
		if predicted.encode() != state.encode():
			fail("el estado predicho del tick %d difiere del del servidor.\n  predicho: %s\n  servidor: %s"
					% [_model.tick, predicted, state])
			return
	# Un salto en llano ya llega a ~1,5 m (8² / (2 · 22)): solo se está en la rampa si los pies, en el
	# suelo, pasan de los 2 m (la ruta llega a unos 3,5 m).
	assert_true(grounded_peak_height > MIN_RAMP_HEIGHT,
			"la ruta sube por la rampa: pisa el suelo a más de %s m (máximo %.2f m)"
			% [MIN_RAMP_HEIGHT, grounded_peak_height])
	assert_true(peak_height > 1.0, "y salta (altura máxima %s)" % peak_height)
	assert_true(yaw_wraps >= 1, "la ruta gira cruzando ±PI (%d cruces)" % yaw_wraps)
	assert_true(_jumped_count >= 2, "la ruta salta (%d saltos)" % _jumped_count)
	assert_true(_prediction.get_predicted_tick() > ClientPrediction.HISTORY_SIZE,
			"la ruta da la vuelta a los anillos de 256 huecos")
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1,
			"el servidor solo sustituyó los ticks anteriores a la primera entrada real")


func test_states_arriving_late_all_match_without_loss() -> void:
	if not await _begin_session(_route_input):
		return
	var results: Array[Vector2i] = []
	for _frame: int in ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, [] as Array[int])
		_server_tick()
	assert_true(results.size() > 100, "llegaron estados (%d)" % results.size())
	for entry: Vector2i in results:
		if entry.y != ClientPrediction.Result.MATCH:
			fail("el estado del tick %d no coincidió (resultado %d)" % [entry.x, entry.y])
			return
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["matches"], results.size(), "todos coinciden")
	assert_eq(stats["corrections"], 0, "ninguna corrección")
	assert_eq(stats["replays"], 0, "ninguna repetición")
	assert_eq(stats["hard_resets"], 0, "ningún hard reset")
	assert_eq(stats["resimulated_ticks"], 0, "ningún tick vuelto a simular")
	assert_eq(stats["max_correction"], 0.0, "corrección máxima 0")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "el suavizador no se usó")


func test_a_substituted_tick_is_reconciled_and_converges_exactly() -> void:
	if not await _begin_session(_route_input):
		return
	# El tick 31 es el primero con movimiento: si se pierde, el servidor repite la entrada
	# neutra y arranca un tick tarde.
	var lost: Array[int] = [31]
	var results: Array[Vector2i] = []
	for _frame: int in ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1 + 1,
			"el servidor sustituyó el tick perdido")
	var corrected: Array[Vector2i] = _results_with(results, ClientPrediction.Result.CORRECTED)
	assert_eq(corrected.size(), 1, "una sola reconciliación")
	if corrected.size() != 1:
		return
	var first_bad: int = corrected[0].x
	assert_true(first_bad >= 31 and first_bad <= 32, "el primer estado distinto es el 31 o el 32 (%d)"
			% first_bad)
	for entry: Vector2i in results:
		if entry.x > first_bad and entry.y != ClientPrediction.Result.MATCH:
			fail("tras reconciliar, el estado del tick %d debería coincidir (resultado %d)"
					% [entry.x, entry.y])
			return
		if entry.x < first_bad and entry.y != ClientPrediction.Result.MATCH:
			fail("antes de la pérdida, el estado del tick %d debería coincidir" % entry.x)
			return
	# Desde el primer estado reconciliado, el cliente queda bit a bit igual al servidor.
	for tick: int in range(first_bad, _model.tick + 1):
		var predicted: PlayerState = _prediction.get_predicted_state(tick)
		if predicted == null or predicted.encode() != (_model.states[tick] as PlayerState).encode():
			fail("el tick %d no quedó igual al servidor tras la reconciliación" % tick)
			return
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["replays"], 1, "una repetición")
	assert_eq(stats["corrections"], 1, "una corrección de más de 1 mm")
	assert_eq(stats["hard_resets"], 0, "sin hard reset")
	assert_true(stats["max_correction"] > 0.005 and stats["max_correction"] < 0.2,
			"el error fue de pocos centímetros (%s m)" % stats["max_correction"])
	assert_eq(stats["last_correction"], stats["max_correction"], "última corrección")
	assert_true(stats["resimulated_ticks"] > 5 and stats["resimulated_ticks"] < 30,
			"se repitieron unos 10 ticks (%s)" % stats["resimulated_ticks"])
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "y el desfase ya decayó")


func test_a_lost_jump_is_reconciled_without_repeating_the_sound() -> void:
	if not await _begin_session(_route_input):
		return
	# El salto se pulsa en los ticks 100-102: perdidos los tres, el servidor nunca salta.
	var lost: Array[int] = [100, 101, 102]
	var results: Array[Vector2i] = []
	var jumps_before_replays: int = -1
	for _frame: int in ROUTE_TICKS:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
		if _prediction.get_predicted_tick() == 102:
			jumps_before_replays = _jumped_count
	assert_eq(jumps_before_replays, 1, "el cliente salta una vez al predecir el tick 100")
	assert_true(_results_with(results, ClientPrediction.Result.CORRECTED).size() >= 1,
			"el error de un salto se reconcilia")
	var last_bad: int = 0
	for entry: Vector2i in results:
		if entry.y != ClientPrediction.Result.MATCH:
			last_bad = maxi(last_bad, entry.x)
	for entry: Vector2i in results:
		if entry.x > last_bad and entry.y != ClientPrediction.Result.MATCH:
			fail("tras la última corrección el estado del tick %d debería coincidir" % entry.x)
			return
	for tick: int in range(last_bad, _model.tick + 1):
		var predicted: PlayerState = _prediction.get_predicted_state(tick)
		if predicted == null or predicted.encode() != (_model.states[tick] as PlayerState).encode():
			fail("el tick %d no quedó igual al servidor" % tick)
			return
	assert_true(_prediction.get_stats()["max_correction"] > 0.3,
			"la corrección del salto perdido es grande (%s m)" % _prediction.get_stats()["max_correction"])
	assert_eq(_prediction.get_stats()["hard_resets"], 0, "sin hard reset")
	# Las repeticiones vuelven a simular un salto (la entrada real llega un tick tarde) pero no
	# emiten jumped ni landed: solo cuenta lo que se simuló en tiempo real.
	assert_true(_jumped_count <= 2, "las repeticiones no emiten jumped (%d saltos)" % _jumped_count)
	assert_true(_character.events_enabled, "los eventos vuelven a estar activados")
	assert_false(_prediction.is_replaying(), "no se queda en modo repetición")


func test_a_late_first_real_input_is_reconciled() -> void:
	if not await _begin_session(_walk_route):
		return
	# Las entradas de los ticks 14 y 15 (las dos primeras reales) llegan tarde: el servidor las
	# sustituye con la entrada neutra del alta y el cliente lo corrige.
	var lost: Array[int] = [FIRST_REAL_TICK, FIRST_REAL_TICK + 1]
	var results: Array[Vector2i] = []
	for _frame: int in 120:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1 + 2,
			"el servidor sustituyó el avance neutro y los dos ticks perdidos")
	var last_bad: int = _last_result_tick_not(results, ClientPrediction.Result.MATCH)
	assert_true(last_bad > 0, "hubo reconciliaciones")
	assert_true(_results_with(results, ClientPrediction.Result.HARD_RESET).is_empty(),
			"sin hard reset")
	assert_true(last_bad <= FIRST_REAL_TICK + 3, "y solo en los primeros ticks (%d)" % last_bad)
	_assert_converged_since(last_bad)


func test_a_long_loss_burst_is_reconciled_repeatedly_and_converges() -> void:
	if not await _begin_session(_walk_route):
		return
	# Doce ticks seguidos perdidos: el servidor repite el movimiento 6 ticks y después se queda
	# quieto (8.2); con cada estado que llega, el cliente vuelve a reconciliar.
	var lost: Array[int] = []
	for tick: int in range(40, 52):
		lost.append(tick)
	var results: Array[Vector2i] = []
	for _frame: int in 150:
		await tree.physics_frame
		_client_tick(results, lost)
		_server_tick()
	assert_eq(_model.substitutions, FIRST_REAL_TICK - SPAWN_TICK - 1 + 12, "doce sustituciones")
	var corrected: Array[Vector2i] = _results_with(results, ClientPrediction.Result.CORRECTED)
	assert_true(corrected.size() >= 4, "varias reconciliaciones seguidas (%d)" % corrected.size())
	assert_true(_results_with(results, ClientPrediction.Result.HARD_RESET).is_empty(),
			"sin hard reset")
	var last_bad: int = _last_result_tick_not(results, ClientPrediction.Result.MATCH)
	assert_true(last_bad >= 50 and last_bad <= 53, "la última diferencia es de cuando acaba la "
			+ "pérdida (%d)" % last_bad)
	_assert_converged_since(last_bad)
	var stats: Dictionary = _prediction.get_stats()
	assert_true(stats["max_correction"] > 0.2, "el servidor se paró y el error fue grande (%s m)"
			% stats["max_correction"])
	assert_true(stats["max_correction"] < ClientPrediction.SNAP_DISTANCE,
			"pero se suavizó, sin saltar")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "y el desfase acabó anulándose")


func test_replays_do_not_emit_jump_or_landing_events() -> void:
	if not await _begin_session(_route_input):
		return
	# Sin estados del servidor por el camino: se predice hasta justo después del salto del tick 100
	# (que el cliente emite una vez, en tiempo real) y llega un estado anterior al salto que
	# difiere un poco. La repetición vuelve a saltar en el tick 100, pero sin emitir nada.
	while _prediction.get_predicted_tick() < 108:
		_prediction.step()
	var jumps: int = _jumped_count
	var landings: int = _landed_count
	assert_eq(jumps, 1, "se saltó una vez en tiempo real")
	var wrong: PlayerState = _prediction.get_predicted_state(99).duplicate_state()
	wrong.position += Vector3(0.0, 0.0, 0.05)
	var result: int = _prediction.on_server_state(99, wrong, false)
	assert_eq(result, ClientPrediction.Result.CORRECTED, "se reconcilia")
	assert_eq(_jumped_count, jumps, "la repetición del salto no emite jumped")
	assert_eq(_landed_count, landings, "ni landed")
	assert_true(_character.events_enabled, "events_enabled vuelve a true")
	assert_true(_character.velocity.y > 0.0, "y el salto sí se repitió: sigue subiendo")
	assert_false(_character.grounded, "en el aire")


# --- Arranque, anillos y estados que no encajan -------------------------------------------------

func test_start_advances_with_neutral_input_and_without_events() -> void:
	if not await _build_session():
		return
	await tree.physics_frame
	assert_null(_prediction.step(), "step() antes de start() no hace nada")
	assert_false(_prediction.is_started(), "sin arrancar")
	# En el aire, a 1 cm del suelo: durante el avance neutro aterriza y emitiría landed.
	var spawn := PlayerState.new()
	spawn.position = SPAWN_POSITION + Vector3(0.0, 0.01, 0.0)
	spawn.grounded = false
	spawn.yaw = 1.25
	spawn = PlayerState.decode(spawn.encode())
	_prediction.start(SPAWN_TICK, spawn, FIRST_REAL_TICK)
	assert_true(_prediction.is_started(), "arrancada")
	assert_eq(_prediction.get_predicted_tick(), FIRST_REAL_TICK - 1, "predicho hasta justo antes de P0")
	assert_eq(_prediction.get_first_real_tick(), FIRST_REAL_TICK, "primer tick con entrada real")
	assert_true(_character.grounded, "el personaje aterrizó durante el avance neutro")
	assert_eq(_landed_count, 0, "pero el avance neutro no emite landed")
	assert_true(_character.events_enabled, "y deja events_enabled como estaba")
	assert_null(_prediction.get_input(SPAWN_TICK), "el tick de aparición no tiene entrada")
	assert_not_null(_prediction.get_predicted_state(SPAWN_TICK), "pero sí estado")
	assert_true(_prediction.get_predicted_state(SPAWN_TICK).equals_exact(spawn), "el de aparición")
	var neutral: PlayerInput = NetProtocol.neutral_input(0, spawn.yaw)
	for tick: int in range(SPAWN_TICK + 1, FIRST_REAL_TICK):
		var input: PlayerInput = _prediction.get_input(tick)
		if not assert_not_null(input, "entrada neutra del tick %d" % tick):
			return
		assert_eq(input.tick, tick, "con su tick")
		assert_eq(input.move, Vector2.ZERO, "sin movimiento")
		assert_eq(input.buttons, 0, "sin botones")
		assert_near(input.look_yaw, neutral.look_yaw, 1e-9, "mirando al yaw cuantizado del alta")
	assert_null(_prediction.get_input(FIRST_REAL_TICK), "todavía no hay entrada real")
	var stepped: PlayerInput = _prediction.step()
	assert_eq(stepped.tick, FIRST_REAL_TICK, "el primer paso es el tick P0")
	assert_eq(_prediction.get_predicted_tick(), FIRST_REAL_TICK, "y avanza el predicho")
	assert_eq(_prediction.get_input(FIRST_REAL_TICK), stepped, "queda guardada")
	assert_true(_prediction.get_predicted_state(FIRST_REAL_TICK).equals_exact(_character.get_state()),
			"con el estado resultante")
	assert_eq(_controller.get_tick(), FIRST_REAL_TICK, "el controlador generó el tick pedido")


func test_rings_keep_the_last_256_ticks_with_their_tags() -> void:
	if not await _begin_session(_route_input):
		return
	for _i: int in 300:
		_prediction.step()
	var last: int = _prediction.get_predicted_tick()
	assert_eq(last, FIRST_REAL_TICK - 1 + 300, "300 pasos")
	for tick: int in range(last - ClientPrediction.HISTORY_SIZE + 1, last + 1):
		var input: PlayerInput = _prediction.get_input(tick)
		var state: PlayerState = _prediction.get_predicted_state(tick)
		if input == null or state == null or input.tick != tick:
			fail("el tick %d debería estar en los anillos" % tick)
			return
	for tick: int in [last - ClientPrediction.HISTORY_SIZE, SPAWN_TICK, 0, -5, last + 1, last + 300]:
		assert_null(_prediction.get_input(tick), "la entrada del tick %d no está" % tick)
		assert_null(_prediction.get_predicted_state(tick), "ni su estado")


func test_stale_and_repeated_server_states_are_ignored() -> void:
	if not await _begin_session(_route_input):
		return
	for _i: int in 40:
		_prediction.step()
	var tick: int = _prediction.get_predicted_tick() - 10
	var state: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
	assert_eq(_prediction.on_server_state(tick, state, false), ClientPrediction.Result.MATCH, "primero")
	assert_eq(_prediction.on_server_state(tick, state, false), ClientPrediction.Result.IGNORED,
			"repetido")
	var older: PlayerState = _prediction.get_predicted_state(tick - 4).duplicate_state()
	older.position += Vector3(1.0, 0.0, 0.0)
	assert_eq(_prediction.on_server_state(tick - 4, older, false), ClientPrediction.Result.IGNORED,
			"más antiguo que el último reconciliado: nunca reconcilia")
	assert_eq(_prediction.on_server_state(tick + 2, null, false), ClientPrediction.Result.IGNORED,
			"un estado null se ignora")
	var stats: Dictionary = _prediction.get_stats()
	assert_eq(stats["matches"], 1, "una coincidencia")
	assert_eq(stats["ignored"], 3, "tres ignorados")
	assert_eq(stats["replays"], 0, "sin repeticiones")


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
	assert_eq(result, ClientPrediction.Result.HARD_RESET, "llega por delante de lo predicho")
	assert_eq(_prediction.get_predicted_tick(), predicted_tick + 5,
			"el tick predicho pasa a ser el del servidor (TickSync recupera la antelación)")
	assert_true(_character.get_state().equals_exact(ahead), "el personaje queda en el estado del servidor")
	assert_true(_prediction.get_predicted_state(predicted_tick + 5).equals_exact(ahead),
			"y se guarda en el anillo")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "sin suavizado")
	assert_eq(_prediction.get_stats()["hard_resets"], 1, "un hard reset")
	var stepped: PlayerInput = _prediction.step()
	assert_eq(stepped.tick, predicted_tick + 6, "el siguiente paso continúa desde ahí")
	assert_eq(_prediction.on_server_state(predicted_tick + 5, ahead, false),
			ClientPrediction.Result.IGNORED, "y ese estado ya está reconciliado")


## Un estado de un tick que ya salió del anillo: el cliente ya no conoce la última entrada que el
## servidor aplicó en él, así que sustituye con una neutra (con los botones del estado y sin
## movimiento) hasta el primer tick que sigue en el anillo. Es una aproximación inevitable del cliente,
## no la regla de [InputQueue] (que repetiría el movimiento de esa entrada 6 ticks): el oráculo
## reimplementa la aproximación. La regla de verdad se comprueba contra [InputQueue] en
## [method test_client_substitution_matches_the_real_input_queue_across_a_gap].
func test_hard_reset_to_an_old_tick_replays_with_the_neutral_approximation_of_the_client() -> void:
	if not await _begin_session(_route_input):
		return
	for _i: int in 300:
		_prediction.step()
	var last: int = _prediction.get_predicted_tick()
	var old_tick: int = 40
	assert_null(_prediction.get_predicted_state(old_tick), "el tick %d ya salió del anillo" % old_tick)
	var old_state := PlayerState.new()
	old_state.position = SPAWN_POSITION
	old_state.grounded = true
	old_state.yaw = 1.0
	old_state.prev_buttons = PlayerInput.SPRINT
	old_state.last_input_tick = old_tick
	old_state = PlayerState.decode(old_state.encode())

	# Oráculo: se repite desde ese estado con la aproximación del cliente (la última entrada aplicada
	# es neutra con los botones del estado y, sin entradas reales, sin movimiento) hasta el primer
	# tick que sigue en el anillo, y después con las entradas guardadas.
	var first_stored: int = last - ClientPrediction.HISTORY_SIZE + 1
	_server.set_state(old_state)
	var substituted: PlayerInput = NetProtocol.neutral_input(old_tick, old_state.yaw)
	substituted.buttons = old_state.prev_buttons
	for tick: int in range(old_tick + 1, last + 1):
		var input: PlayerInput = _prediction.get_input(tick)
		if input == null:
			assert_true(tick < first_stored, "solo faltan entradas anteriores al anillo")
			input = substituted.duplicate_input()
			input.tick = tick
		_server.simulate(input, _dt)
	var expected: PlayerState = _server.get_state()

	var result: int = _prediction.on_server_state(old_tick, old_state, false)
	assert_eq(result, ClientPrediction.Result.HARD_RESET, "un estado fuera del anillo es un hard reset")
	assert_eq(_prediction.get_predicted_tick(), last, "el tick predicho no cambia")
	assert_true(_character.get_state().equals_exact(expected),
			"tras repetir con sustitución queda como el oráculo.\n  cliente: %s\n  oráculo: %s"
			% [_character.get_state(), expected])
	assert_true(_prediction.get_predicted_state(last).equals_exact(expected),
			"y el anillo guarda el estado nuevo")
	assert_eq(_prediction.get_stats()["resimulated_ticks"], last - old_tick, "ticks vueltos a simular")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "un hard reset no suaviza")


## La regla de sustitución está en [InputQueue.take] (el servidor), en
## [code]ClientPrediction._input_or_substitute[/code] (el cliente, al repetir con huecos en el anillo)
## y, a mano, en [ServerModel]. Aquí el cliente se compara con la [InputQueue] [b]real[/b]: un hueco en
## el anillo (un [method ClientPrediction.hard_reset] hacia delante, que salta [constant GAP_TICKS]
## ticks) seguido de una repetición desde el último tick con entrada conocida. El servidor recibe las
## mismas entradas, sin las del hueco; sus estados y los que deja la repetición del cliente tienen que
## ser idénticos bit a bit en cada tick. El hueco dura más de 6 ticks: el movimiento se repite los
## primeros 6 y después se anula, con SPRINT y JUMP mantenidos en la última entrada conocida.
func test_client_substitution_matches_the_real_input_queue_across_a_gap() -> void:
	if not await _begin_session(_route_input):
		return
	var last_known: int = 100
	while _prediction.get_predicted_tick() < last_known:
		_prediction.step()
	var known_input: PlayerInput = _prediction.get_input(last_known)
	assert_true(known_input.move != Vector2.ZERO and (known_input.buttons & PlayerInput.SPRINT) != 0
			and (known_input.buttons & PlayerInput.JUMP) != 0,
			"la última entrada conocida se mueve, esprinta y tiene el salto pulsado")
	var last_state: PlayerState = _prediction.get_predicted_state(last_known).duplicate_state()

	# El hueco: el cliente salta GAP_TICKS ticks sin predecirlos y sigue con entradas reales.
	var after_gap: int = last_known + GAP_TICKS
	_prediction.hard_reset(after_gap, last_state)
	var end_tick: int = after_gap + 20
	while _prediction.get_predicted_tick() < end_tick:
		_prediction.step()
	assert_null(_prediction.get_input(last_known + 1), "el anillo tiene un hueco justo después")
	assert_null(_prediction.get_input(after_gap), "hasta el tick del salto")
	assert_not_null(_prediction.get_input(after_gap + 1), "y vuelve a tener entradas")

	# El servidor de verdad: la misma cola, con las mismas entradas salvo las del hueco.
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
			"el servidor sustituyó el avance neutro y el hueco")

	# El cliente repite desde el último tick conocido: sustituye los del hueco con su copia de la regla.
	_prediction.hard_reset(last_known, last_state)
	for tick: int in range(last_known, end_tick + 1):
		var client_state: PlayerState = _prediction.get_predicted_state(tick)
		if not assert_not_null(client_state, "el cliente guarda el tick %d" % tick):
			return
		if not client_state.equals_exact(server_states[tick]):
			fail("el tick %d (%s del hueco) difiere de la InputQueue real.\n  cliente:  %s\n  servidor: %s"
					% [tick, "dentro" if tick <= after_gap else "después", client_state, server_states[tick]])
			return
	assert_eq(_prediction.get_stats()["resimulated_ticks"], end_tick - last_known, "se repitió todo el hueco")


# --- Suavizado -------------------------------------------------------------------------------

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
	assert_eq(result, ClientPrediction.Result.CORRECTED, "el estado desplazado se reconcilia")
	assert_vec_near(_character.global_position, body_before + Vector3(0.02, 0.0, 0.0), 1e-5,
			"el cuerpo se corrige de golpe")
	assert_vec_near(_visual.global_position, visual_before, 0.001,
			"la posición global de Visual no salta más de 1 mm en la transición")
	assert_vec_near(_camera_target.global_position, camera_before, 0.001,
			"ni la de CameraTarget")
	assert_vec_near(_smoother.get_offset(), Vector3(-0.02, 0.0, 0.0), 1e-5, "el desfase es el error")
	assert_eq(_prediction.get_stats()["corrections"], 1, "cuenta como corrección (más de 1 mm)")

	var offset: float = _smoother.get_offset().length()
	var half_life_checked: bool = false
	var below_one_mm_at: int = -1
	for i: int in range(1, 41):
		_prediction.step()
		_smoother.physics_step()
		var current: float = _smoother.get_offset().length()
		assert_true(current <= offset + 1e-9, "el desfase solo decrece (tick %d)" % i)
		offset = current
		if i == 6:
			half_life_checked = true
			assert_near(current, 0.01, 0.0006, "semivida de 6 ticks")
		if current == 0.0 and below_one_mm_at < 0:
			below_one_mm_at = i
		assert_vec_near(_visual.global_position - _character.global_position,
				_smoother.get_offset(), 1e-5, "Visual lleva el desfase (tick %d)" % i)
	assert_true(half_life_checked, "se comprobó la semivida")
	assert_true(below_one_mm_at > 0 and below_one_mm_at <= 30,
			"el desfase baja de 1 mm antes de 30 ticks (a los %d)" % below_one_mm_at)
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "y se anula")
	assert_eq(_visual.position, Vector3.ZERO, "Visual vuelve exactamente a su sitio")
	assert_eq(_camera_target.position, Vector3(0.0, 1.6, 0.0), "y CameraTarget también")


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
				"corrección %d" % i)
		accumulated += Vector3(0.0, 0.0, -0.004)
		_smoother.physics_step()
		_prediction.step()
	assert_true(_smoother.get_offset().length() > 0.004, "los desfases se acumulan")
	assert_true(_smoother.get_offset().length() < accumulated.length(), "y decaen mientras tanto")


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
	assert_eq(result, ClientPrediction.Result.CORRECTED, "se reconcilia")
	assert_vec_near(_character.global_position, before + Vector3(5.0, 0.0, 0.0), 1e-4,
			"el cuerpo salta al estado del servidor")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "con más de 3 m no hay suavizado")
	assert_eq(_visual.position, Vector3.ZERO, "Visual está en su sitio: salto directo")
	assert_eq(_camera_target.position, Vector3(0.0, 1.6, 0.0), "CameraTarget también")
	assert_vec_near(_visual.global_position, _character.global_position, 1e-5,
			"Visual sigue al cuerpo")
	assert_near(_prediction.get_stats()["max_correction"], 5.0, 1e-3, "la corrección fue de 5 m")


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
	assert_eq(result, ClientPrediction.Result.CORRECTED, "se reconcilia")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "un teletransporte nunca se suaviza")
	assert_eq(_visual.position, Vector3.ZERO, "Visual en su sitio")

	# Con el contador de teletransporte cambiado se repite aunque el estado coincida exactamente.
	var same_tick: int = _prediction.get_predicted_tick() - 2
	var same: PlayerState = _prediction.get_predicted_state(same_tick).duplicate_state()
	var matches_before: int = _prediction.get_stats()["matches"]
	assert_eq(_prediction.on_server_state(same_tick, same, true), ClientPrediction.Result.CORRECTED,
			"con teleported no se da por bueno un estado igual")
	assert_eq(_prediction.get_stats()["matches"], matches_before, "no cuenta como coincidencia")
	assert_eq(_smoother.get_offset(), Vector3.ZERO, "y tampoco se suaviza")


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
	assert_near(_character.yaw, PI / 2.0, 1e-6, "el personaje está girado 90 grados")
	var tick: int = _prediction.get_predicted_tick() - 4
	var wrong: PlayerState = _prediction.get_predicted_state(tick).duplicate_state()
	wrong.position += Vector3(0.03, 0.0, 0.0)
	var visual_before: Vector3 = _visual.global_position
	var result: int = _prediction.on_server_state(tick, wrong, false)
	_smoother.physics_step()
	assert_eq(result, ClientPrediction.Result.CORRECTED, "se reconcilia")

	var world_offset := Vector3(-0.03, 0.0, 0.0)
	assert_vec_near(_smoother.get_offset(), world_offset, 1e-5, "el desfase está en el mundo")
	# Con el yaw a +90° el personaje mira hacia -X del mundo (su -Z local), así que un desfase de
	# -0,03 en X del mundo es -0,03 en Z local.
	var local_offset: Vector3 = _character.basis.inverse() * world_offset
	assert_vec_near(local_offset, Vector3(0.0, 0.0, -0.03), 1e-5, "el desfase local esperado")
	assert_vec_near(_visual.position, local_offset, 1e-5, "Visual: base + basis⁻¹ · desfase")
	assert_vec_near(_camera_target.position, Vector3(0.0, 1.6, 0.0) + local_offset, 1e-5,
			"CameraTarget: base + basis⁻¹ · desfase")
	assert_vec_near(_visual.global_position, visual_before, 0.001,
			"y en el mundo Visual no se movió más de 1 mm")
	assert_vec_near(_visual.global_position - _character.global_position, world_offset, 1e-5,
			"el desfase en el mundo es el mismo")


func test_smoother_lets_the_camera_target_follow_the_same_offset() -> void:
	if not await _build_session():
		return
	await tree.physics_frame
	var targets: Array[Node3D] = [_visual, _camera_target]
	var smoother := CorrectionSmoother.new()
	smoother.setup(_character, targets)
	smoother.physics_step()
	assert_eq(_visual.position, Vector3.ZERO, "sin desfase, todo en su sitio")
	smoother.add_offset(Vector3(0.0, 0.1, 0.0))
	assert_vec_near(smoother.get_offset(), Vector3(0.0, 0.1, 0.0), 1e-9, "el desfase incluye lo pendiente")
	assert_eq(_visual.position, Vector3.ZERO, "pero hasta physics_step() no se aplica")
	smoother.physics_step()
	assert_vec_near(_visual.position, Vector3(0.0, 0.1, 0.0), 1e-6, "ya aplicado, sin decaer aún")
	assert_vec_near(_camera_target.position, Vector3(0.0, 1.7, 0.0), 1e-6, "en CameraTarget también")
	smoother.physics_step()
	assert_near(_visual.position.y, 0.1 * pow(0.5, 1.0 / CorrectionSmoother.HALF_LIFE_TICKS), 1e-6,
			"el siguiente tick decae con la semivida")
	smoother.clear()
	assert_eq(smoother.get_offset(), Vector3.ZERO, "clear() anula el desfase")
	assert_eq(_visual.position, Vector3.ZERO, "y devuelve Visual a su sitio")
	assert_eq(_camera_target.position, Vector3(0.0, 1.6, 0.0), "y CameraTarget")
	smoother.add_offset(Vector3(0.0005, 0.0, 0.0))
	smoother.physics_step()
	assert_eq(smoother.get_offset(), Vector3.ZERO, "por debajo de 1 mm se anula")
	assert_eq(_visual.position, Vector3.ZERO, "sin tocar nada")


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
	assert_eq(_controller.get_tick(), emitted.size(), "get_tick() cuenta las entradas")
	assert_true(emitted.size() >= 4, "una entrada por paso de física (%d)" % emitted.size())
	var history: Array[PlayerInput] = _controller.get_input_history()
	assert_eq(history.size(), emitted.size(), "el historial las guarda")
	for i: int in emitted.size():
		assert_eq(history[i].tick, i + 1, "el historial va de la más antigua a la más nueva")
		assert_eq(emitted[i].tick, i + 1, "input_generated emite la entrada del tick")
		assert_eq(simulated_at_emission[i], i, "se emite antes de simularla")
	assert_eq(_character.last_input_tick, emitted.size(), "y se simula la entrada del tick")


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
	assert_eq(emitted.size(), 0, "con auto_step = false no genera entradas solo")
	assert_eq(_controller.get_tick(), 0, "ni avanza el tick")
	assert_eq(_character.last_input_tick, 0, "ni simula")
	assert_vec_near(_character.global_position, SPAWN_POSITION, 1e-6, "el personaje no se movió")

	var position_before: Vector3 = _character.global_position
	var input: PlayerInput = _controller.build_input(77)
	assert_eq(input.tick, 77, "build_input(tick) construye la entrada del tick pedido")
	assert_eq(_controller.get_tick(), 77, "get_tick() es el último pedido")
	assert_true(input.buttons == PlayerInput.JUMP, "con los botones del bot")
	var quantized: PlayerInput = input.quantized()
	assert_eq(input.encode(), quantized.encode(), "ya está cuantizada")
	assert_ne_float(input.move.x, 0.123456, "el movimiento está cuantizado")
	assert_true(input.look_yaw >= 0.0 and input.look_yaw < TAU, "y el yaw envuelto a [0, TAU)")
	assert_eq(emitted.size(), 1, "emite input_generated")
	assert_eq(emitted[0], input, "con la misma entrada")
	assert_eq(_controller.get_input_history().size(), 1, "y la guarda en el historial")
	assert_eq(_controller.get_input_history()[0], input, "la misma")
	assert_eq(_character.last_input_tick, 0, "pero no simula")
	assert_vec_near(_character.global_position, position_before, 1e-9, "ni mueve al personaje")
	await tree.physics_frame
	assert_eq(emitted.size(), 1, "un paso de física después sigue sin generar nada")


func test_controller_history_is_a_ring_of_256_inputs_in_order() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	_brain.route = _idle_route
	_controller.set_bot(_brain)
	for tick: int in range(1, 301):
		_controller.build_input(tick)
	var history: Array[PlayerInput] = _controller.get_input_history()
	assert_eq(history.size(), LocalPlayerController.HISTORY_SIZE, "256 entradas como mucho")
	assert_eq(history[0].tick, 300 - 256 + 1, "la más antigua")
	assert_eq(history[history.size() - 1].tick, 300, "la más nueva")
	for i: int in range(1, history.size()):
		if history[i].tick != history[i - 1].tick + 1:
			fail("el historial no está ordenado en la posición %d" % i)
			return
	history.clear()
	assert_eq(_controller.get_input_history().size(), 256, "get_input_history() devuelve una copia")


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
	assert_eq(_brain.calls, 1, "el bot genera la entrada")
	assert_eq(_brain.last_tick, 40, "para el tick pedido")
	assert_vec_near(_brain.last_position, _character.global_position, 1e-6,
			"con la posición del personaje")
	assert_near(_brain.last_yaw, _character.yaw, 1e-9, "y su yaw")
	assert_eq(input.encode(), _route_input(40).quantized().encode(), "la entrada es la del bot, cuantizada")
	assert_eq(input.tick, 40, "con el tick pedido")
	_controller.set_bot(null)
	var device: PlayerInput = _controller.build_input(41)
	assert_eq(_brain.calls, 1, "con set_bot(null) vuelve al dispositivo")
	assert_eq(device.move, Vector2.ZERO, "que sin teclas no se mueve")


func test_accumulated_presses_are_added_to_the_next_input_once() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	_controller.set_bot(null)
	await tree.physics_frame
	# Una acción pulsada por la API de Input solo cuenta como «recién pulsada» a partir del
	# siguiente tick de física.
	_press(&"jump")
	_press(&"dodge")
	await tree.physics_frame
	# Tick de física sin paso: la pulsación se guarda aunque se suelte antes del siguiente.
	assert_true(Input.is_action_just_pressed(&"jump"), "la acción se acaba de pulsar en este tick")
	_controller.accumulate_presses()
	Input.action_release(&"jump")
	Input.action_release(&"dodge")
	_pressed_actions.clear()
	await tree.physics_frame
	assert_false(Input.is_action_pressed(&"jump"), "ya no está pulsada")
	var first: PlayerInput = _controller.build_input(1)
	assert_true(first.has(PlayerInput.JUMP) and first.has(PlayerInput.DODGE),
			"el siguiente build_input() suma las pulsaciones guardadas (botones %d)" % first.buttons)
	var second: PlayerInput = _controller.build_input(2)
	assert_eq(second.buttons, 0, "y solo una vez")

	# Una tecla mantenida sigue en la entrada y no se duplica al acumular.
	_press(&"sprint")
	await tree.physics_frame
	_controller.accumulate_presses()
	var third: PlayerInput = _controller.build_input(3)
	assert_eq(third.buttons, PlayerInput.SPRINT, "una tecla mantenida: ni de menos ni de más")
	await tree.physics_frame
	var fourth: PlayerInput = _controller.build_input(4)
	assert_eq(fourth.buttons, PlayerInput.SPRINT, "y sigue mientras se mantiene")


func test_accumulate_presses_does_nothing_for_bots() -> void:
	if not await _build_session():
		return
	_controller.auto_step = false
	_brain.route = _idle_route
	_controller.set_bot(_brain)
	await tree.physics_frame
	_press(&"jump")
	await tree.physics_frame
	assert_true(Input.is_action_just_pressed(&"jump"), "la acción se acaba de pulsar en este tick")
	_controller.accumulate_presses()
	Input.action_release(&"jump")
	_pressed_actions.clear()
	await tree.physics_frame
	assert_eq(_controller.build_input(1).buttons, 0, "la entrada de un bot no depende del teclado")


# --- Construcción de la escena de prueba -------------------------------------------------------

## Prepara los dos mundos y arranca la predicción con la ruta indicada. Hay que llamarla con
## [code]await[/code]; al volver se está dentro del tick de física.
func _begin_session(route: Callable) -> bool:
	if not await _build_session():
		return false
	await tree.physics_frame
	_brain.route = route
	var spawn: PlayerState = _spawn_state()
	_model = ServerModel.new()
	_model.start(_server, SPAWN_TICK, spawn, _dt)
	_prediction.start(SPAWN_TICK, spawn, FIRST_REAL_TICK)
	# El cliente avanza en neutro hasta justo antes de P0; el servidor irá por detrás
	# (FIRST_REAL_TICK - 1 - SPAWN_TICK ticks) y sustituirá esos ticks con la regla de la 8.2.
	return true


func _build_session() -> bool:
	_server_viewport = _make_world("ServerWorld")
	_client_viewport = _make_world("ClientWorld")
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "no se pudo cargar %s" % CHARACTER_SCENE_PATH):
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
	# Dos pasos de física para que los espacios registren los cuerpos recién añadidos.
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


## Estado de aparición exacto (pasado por encode/decode, como lo impone el servidor).
func _spawn_state() -> PlayerState:
	var state := PlayerState.new()
	state.position = SPAWN_POSITION
	state.grounded = true
	return PlayerState.decode(state.encode())


# --- Rutas guionizadas -------------------------------------------------------------------------

## Entrada neutra mirando al frente.
func _idle_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	return input


## Ruta de [constant ROUTE_TICKS] ticks: espera, esprinta hacia la rampa, sube saltando, gira sin
## parar cruzando ±PI, retrocede saltando y se para.
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


# --- Un tick de cliente y de servidor ----------------------------------------------------------

## Un tick del cliente, en el orden de NetClient: llegan los estados propios que ya tocan, un paso
## de predicción, el envío de la entrada (que se pierde si su tick está en [param lost]) y el
## suavizador. Los resultados de [method ClientPrediction.on_server_state] se añaden a
## [param results] como (tick, resultado).
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


## Un tick del servidor: aplica la entrada (o la sustituta) y encola el estado propio con retraso.
func _server_tick() -> PlayerState:
	var state: PlayerState = _model.step()
	if _model.tick % STATE_INTERVAL_TICKS == 0:
		_pending_states.append({
			"tick": _model.tick,
			"state": PlayerState.decode(state.encode()),
			"due": _frame_counter + STATE_DELAY_FRAMES,
		})
	return state


## Marcha recta hacia delante desde la primera entrada real.
func _walk_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick >= FIRST_REAL_TICK:
		input.move = Vector2(0.0, 1.0)
	return input


## Tick más alto cuyo resultado no fue [param expected], o 0 si todos lo fueron.
func _last_result_tick_not(results: Array[Vector2i], expected: int) -> int:
	var last: int = 0
	for entry: Vector2i in results:
		if entry.y != expected:
			last = maxi(last, entry.x)
	return last


## Desde [param tick], el cliente quedó bit a bit igual al servidor, y todos los estados que
## llegaron después coincidieron.
func _assert_converged_since(tick: int) -> void:
	for t: int in range(tick, _model.tick + 1):
		var predicted: PlayerState = _prediction.get_predicted_state(t)
		var server_state: PlayerState = _model.states[t]
		if predicted == null or predicted.encode() != server_state.encode():
			fail("el tick %d no quedó igual al servidor tras la última reconciliación" % t)
			return
	assert_true(_model.tick > tick + 10, "quedaron ticks por comprobar (hasta el %d)" % _model.tick)


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
