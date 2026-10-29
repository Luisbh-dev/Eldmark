extends TestCase
## Pruebas de la cola de entradas del servidor ([InputQueue], docs/red.md secciones 4.1, 8.2 y
## 12): ventana de aceptación, primera copia, tardías, ack, antelación, sustitución y, sobre todo,
## que la sustituta no inventa flancos (con un [PlayerCharacter] real).
## [br][br]
## Convención de [code]next_tick[/code] en [method InputQueue.push]: el tick que el servidor
## simulará a continuación. Con la cola al día es [code]get_last_consumed() + 1[/code].

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const JUMP: int = PlayerInput.JUMP
const SPRINT: int = PlayerInput.SPRINT
const DODGE: int = PlayerInput.DODGE
const PRIMARY: int = PlayerInput.PRIMARY
const SUBSTITUTED: int = PlayerInput.SUBSTITUTED
## Ticks que se espera a que el personaje se asiente en el suelo antes de saltar.
const SETTLE_TICKS: int = 5
## Tick en el que empieza a mantenerse el salto.
const JUMP_HELD_FROM: int = 6

var _viewport: SubViewport
var _character: PlayerCharacter
var _jumped_count: int = 0
var _landed_ticks: Array[int] = []
var _current_tick: int = 0


func after_each() -> void:
	if is_instance_valid(_viewport):
		if _viewport.is_inside_tree():
			_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_character = null
	await wait_process_frames()


## Cola lista para un jugador que apareció tras el tick [param spawn_tick].
func _make_queue(spawn_tick: int = 0) -> InputQueue:
	var queue := InputQueue.new()
	queue.reset(spawn_tick, NetProtocol.neutral_input(spawn_tick, 0.0))
	return queue


func _input(tick: int, move: Vector2 = Vector2.ZERO, buttons: int = 0, yaw: float = 0.0,
		pitch: float = 0.0) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.buttons = buttons
	input.look_yaw = yaw
	input.look_pitch = pitch
	return input.quantized()


## Pone [param packet] en la bandeja de entrada del tick [param tick].
static func _deliver(inbox: Dictionary, tick: int, packet: Array) -> void:
	if not inbox.has(tick):
		inbox[tick] = []
	(inbox[tick] as Array).append(packet)


# --- Ventana de aceptación --------------------------------------------------------------------

func test_accepts_inputs_inside_the_window() -> void:
	var queue: InputQueue = _make_queue()
	# El servidor va a simular el tick 1: acepta del 1 al 1 + 30.
	assert_eq(queue.push(_input(1), 10, 1), InputQueue.PushResult.ACCEPTED, "justo a tiempo")
	assert_eq(queue.push(_input(2), 10, 1), InputQueue.PushResult.ACCEPTED, "por delante")
	assert_eq(queue.push(_input(31), 10, 1), InputQueue.PushResult.ACCEPTED,
			"el límite: next_tick + 30")
	assert_eq(queue.too_early_count, 0, "ninguna demasiado temprana")


func test_rejects_inputs_too_far_ahead() -> void:
	var queue: InputQueue = _make_queue()
	assert_eq(queue.push(_input(32), 0, 1), InputQueue.PushResult.TOO_EARLY, "31 por delante")
	assert_eq(queue.push(_input(1000), 0, 1), InputQueue.PushResult.TOO_EARLY, "muy por delante")
	assert_eq(queue.too_early_count, 2, "se cuentan")
	assert_eq(queue.get_ack_tick(), 0, "y no entran en la cola")
	# Con el servidor más adelantado, el mismo tick ya cabe.
	assert_eq(queue.push(_input(32), 0, 2), InputQueue.PushResult.ACCEPTED, "al avanzar next_tick")
	assert_eq(queue.too_early_count, 2, "y no se vuelve a contar")


func test_window_never_wraps_the_ring_onto_unconsumed_inputs() -> void:
	# Aunque quien llama pase un next_tick absurdo, un tick que comparte hueco con otro todavía
	# sin consumir nunca se acepta.
	var queue: InputQueue = _make_queue()
	assert_eq(queue.push(_input(1), 0, 1), InputQueue.PushResult.ACCEPTED, "tick 1")
	assert_eq(queue.push(_input(65), 0, 1000), InputQueue.PushResult.TOO_EARLY,
			"el tick 65 comparte hueco con el 1")
	assert_eq(queue.push(_input(64), 0, 1000), InputQueue.PushResult.ACCEPTED,
			"el 64 aún cabe")
	assert_eq(queue.take(1).tick, 1, "el tick 1 sigue intacto")


func test_first_copy_wins_even_if_the_second_differs() -> void:
	var queue: InputQueue = _make_queue()
	var first: PlayerInput = _input(3, Vector2(1, 0), JUMP)
	var second: PlayerInput = _input(3, Vector2(0, 1), PRIMARY)
	assert_eq(queue.push(first, 5, 1), InputQueue.PushResult.ACCEPTED, "primera copia")
	assert_eq(queue.push(second, 99, 1), InputQueue.PushResult.DUPLICATE, "segunda copia")
	queue.take(1)
	queue.take(2)
	var taken: PlayerInput = queue.take(3)
	assert_vec_near(taken.move, first.move, 1e-6, "se aplica el movimiento de la primera")
	assert_eq(taken.buttons, JUMP, "y sus botones")
	assert_eq(queue.get_view_offset_q(3), 5, "y su view_offset_q")


func test_copies_of_consumed_inputs_are_duplicates() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1, Vector2(0, 1)), 0, 1)
	queue.take(1)
	assert_eq(queue.push(_input(1, Vector2(1, 0)), 0, 2), InputQueue.PushResult.DUPLICATE,
			"copia redundante de un tick ya consumido")
	assert_eq(queue.push(_input(0), 0, 2), InputQueue.PushResult.DUPLICATE, "tick del alta")
	assert_eq(queue.late_count, 0, "no son tardías: sí se habían recibido")


func test_late_input_is_counted_once_and_not_applied() -> void:
	var queue: InputQueue = _make_queue()
	var substitute: PlayerInput = queue.take(1)
	assert_eq(queue.substitutions_total, 1, "el tick 1 se sustituyó")
	assert_eq(queue.push(_input(1, Vector2(1, 0), JUMP), 8, 2), InputQueue.PushResult.LATE,
			"llega cuando ya se ha consumido")
	assert_eq(queue.late_count, 1, "se cuenta")
	assert_eq(queue.push(_input(1, Vector2(1, 0), JUMP), 8, 2), InputQueue.PushResult.DUPLICATE,
			"la segunda copia de la tardía ya es un duplicado")
	assert_eq(queue.late_count, 1, "y no se vuelve a contar")
	assert_eq(substitute.buttons, SUBSTITUTED, "lo aplicado no cambia (sin botones y sustituida)")
	assert_eq(queue.get_view_offset_q(1), -1, "una tardía no aporta view_offset_q")
	assert_eq(queue.substitutions_total, 1, "la sustitución sigue contada")


func test_late_input_far_in_the_past_is_a_duplicate() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 101):
		queue.take(t)
	assert_eq(queue.push(_input(5), 0, 101), InputQueue.PushResult.DUPLICATE,
			"el hueco de ese tick ya lo ocupa otro: no es una tardía")
	assert_eq(queue.late_count, 0, "no se cuenta")
	assert_eq(queue.push(_input(99), 0, 101), InputQueue.PushResult.LATE,
			"en cambio una reciente sí es tardía")


func test_buttons_are_masked_to_valid_bits() -> void:
	var queue: InputQueue = _make_queue()
	var input: PlayerInput = _input(1)
	input.buttons = 0xFFFF
	queue.push(input, 0, 1)
	assert_eq(queue.take(1).buttons, NetProtocol.VALID_BUTTONS, "solo los bits 0-8")


# --- Ack --------------------------------------------------------------------------------------

func test_ack_without_inputs_is_the_last_consumed() -> void:
	var queue: InputQueue = _make_queue(40)
	assert_eq(queue.get_ack_tick(), 40, "recién creada: el tick del alta")
	assert_eq(queue.get_last_consumed(), 40, "get_last_consumed")
	queue.take(41)
	queue.take(42)
	assert_eq(queue.get_ack_tick(), 42, "tras consumir con sustituciones")
	assert_eq(queue.get_last_consumed(), 42, "get_last_consumed avanza")


func test_ack_is_the_highest_contiguous_received_tick() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in [1, 2, 3, 5]:
		queue.push(_input(t), 0, 1)
	assert_eq(queue.get_ack_tick(), 3, "se corta en el hueco del 4")
	queue.push(_input(4), 0, 1)
	assert_eq(queue.get_ack_tick(), 5, "al llegar el 4 se unen")


func test_ack_with_a_gap_at_the_start_waits_for_it() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(2), 0, 1)
	queue.push(_input(3), 0, 1)
	assert_eq(queue.get_ack_tick(), 0, "falta el 1: nada contiguo")
	queue.push(_input(1), 0, 1)
	assert_eq(queue.get_ack_tick(), 3, "llega el 1")


func test_ack_does_not_stay_stuck_after_a_substitution() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(2), 0, 1)
	queue.push(_input(3), 0, 1)
	assert_eq(queue.get_ack_tick(), 0, "antes de consumir el 1")
	queue.take(1)
	assert_eq(queue.get_ack_tick(), 3, "el 1 se sustituyó y el ack salta al 3")
	queue.take(2)
	queue.take(3)
	assert_eq(queue.get_ack_tick(), 3, "tras consumir todo")
	queue.take(4)
	assert_eq(queue.get_ack_tick(), 4, "y sigue el último consumido")


func test_ack_contiguity_is_capped_by_the_window() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 32):
		queue.push(_input(t), 0, 1)
	assert_eq(queue.get_ack_tick(), 30, "como mucho 30 ticks por delante del último consumido")


# --- Antelación -------------------------------------------------------------------------------

func test_min_lead_without_data_is_no_margin() -> void:
	var queue: InputQueue = _make_queue()
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN, "sin entradas")
	queue.push(_input(1), 0, 1)
	assert_eq(queue.pop_min_lead(), 0, "una entrada justo a tiempo: antelación 0")
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN, "y se reinicia al leerla")


func test_min_lead_is_the_smallest_since_the_last_pop() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(5), 0, 1)
	queue.push(_input(3), 0, 1)
	queue.push(_input(9), 0, 1)
	assert_eq(queue.pop_min_lead(), 2, "la mínima de 4, 2 y 8")
	queue.push(_input(12), 0, 2)
	assert_eq(queue.pop_min_lead(), 10, "solo cuentan las posteriores a la lectura")


func test_min_lead_ignores_redundant_copies() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(10), 0, 1)
	assert_eq(queue.pop_min_lead(), 9, "primera copia: antelación 9")
	# La copia redundante llega cuando el servidor ya va por el tick 6: su antelación sería 4.
	assert_eq(queue.push(_input(10), 0, 6), InputQueue.PushResult.DUPLICATE, "copia redundante")
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN,
			"no cuenta: sesgaría la medida a la baja")
	# Ni dentro del mismo intervalo.
	queue.push(_input(20), 0, 11)
	queue.push(_input(20), 0, 18)
	assert_eq(queue.pop_min_lead(), 9, "solo la primera copia de cada tick")


func test_min_lead_counts_late_inputs_as_negative() -> void:
	var queue: InputQueue = _make_queue()
	queue.take(1)
	queue.take(2)
	assert_eq(queue.push(_input(1), 0, 3), InputQueue.PushResult.LATE, "tardía por dos ticks")
	assert_eq(queue.pop_min_lead(), -2, "antelación negativa: lo que se retrasó")
	queue.push(_input(5), 0, 3)
	assert_eq(queue.push(_input(2), 0, 4), InputQueue.PushResult.LATE, "otra tardía")
	assert_eq(queue.pop_min_lead(), -2, "se queda con la mínima: la de 5 es 2 y la tardía -2")


func test_a_lost_input_does_not_lower_the_margin() -> void:
	# Pérdida y retraso no se mezclan: lo que nunca llega no baja el margen.
	var queue: InputQueue = _make_queue()
	queue.push(_input(4), 0, 1)
	queue.take(1)
	queue.take(2)
	queue.take(3)
	assert_eq(queue.pop_min_lead(), 3,
			"tres sustituciones y el margen sigue siendo el de la medida")


func test_min_lead_is_saturated_so_it_never_equals_no_margin() -> void:
	var queue: InputQueue = _make_queue()
	queue.take(1)
	assert_eq(queue.push(_input(1), 0, 500), InputQueue.PushResult.LATE, "muy tardía")
	var lead: int = queue.pop_min_lead()
	assert_eq(lead, -127, "se satura a -127")
	assert_true(lead != NetProtocol.NO_MARGIN, "-128 queda reservado para «sin datos»")


# --- Sustitución ------------------------------------------------------------------------------

func test_take_returns_the_real_input_when_it_arrived() -> void:
	var queue: InputQueue = _make_queue()
	var pushed: PlayerInput = _input(1, Vector2(0.5, 1.0), SPRINT, 1.0, 0.2)
	queue.push(pushed, 0, 1)
	var taken: PlayerInput = queue.take(1)
	assert_eq(taken.tick, 1, "tick")
	assert_vec_near(taken.move, pushed.move, 1e-6, "move")
	assert_near(taken.look_yaw, pushed.look_yaw, 1e-6, "look_yaw")
	assert_near(taken.look_pitch, pushed.look_pitch, 1e-6, "look_pitch")
	assert_eq(taken.buttons, SPRINT, "buttons")
	assert_eq(queue.substitutions_total, 0, "no hubo sustitución")
	assert_eq(queue.get_last_consumed(), 1, "consumida")


func test_substitute_repeats_the_whole_last_input() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1, Vector2(0.0, 1.0), JUMP | SPRINT | PRIMARY | DODGE, 2.0, 0.3), 0, 1)
	queue.take(1)
	var substitute: PlayerInput = queue.take(2)
	assert_eq(substitute.tick, 2, "lleva el tick que se simula")
	assert_vec_near(substitute.move, Vector2(0, 1), 1e-6, "repite el movimiento")
	assert_near(substitute.look_yaw, _input(1, Vector2.ZERO, 0, 2.0).look_yaw, 1e-6, "y el yaw")
	assert_near(substitute.look_pitch, _input(1, Vector2.ZERO, 0, 0.0, 0.3).look_pitch, 1e-6,
			"y el pitch")
	assert_eq(substitute.buttons, JUMP | SPRINT | PRIMARY | DODGE | SUBSTITUTED,
			"repite TODOS los botones (ni se quitan ni se inventan flancos) y lleva la marca de sustituida")
	assert_eq(queue.substitutions_total, 1, "una sustitución")


func test_only_substitutes_carry_the_substituted_bit() -> void:
	var queue: InputQueue = _make_queue()
	# Un cliente que intente poner el bit 15 no lo consigue: push() lo descarta.
	var forged: PlayerInput = _input(1, Vector2(0, 1), PRIMARY | SUBSTITUTED)
	assert_eq(forged.buttons & SUBSTITUTED, SUBSTITUTED, "la entrada de prueba lleva el bit")
	queue.push(forged, 0, 1)
	var real: PlayerInput = queue.take(1)
	assert_eq(real.buttons, PRIMARY, "una entrada real nunca lleva la marca (se aplica VALID_BUTTONS)")
	var substitute: PlayerInput = queue.take(2)
	assert_eq(substitute.buttons, PRIMARY | SUBSTITUTED, "la sustituta repite PRIMARY y lleva la marca")
	assert_eq(queue.take(3).buttons, PRIMARY | SUBSTITUTED, "y la siguiente también")
	queue.push(_input(4, Vector2(0, 1), PRIMARY), 0, 4)
	assert_eq(queue.take(4).buttons, PRIMARY, "la siguiente real vuelve a no llevarla")
	assert_eq(SUBSTITUTED & NetProtocol.VALID_BUTTONS, 0, "fuera de los botones válidos")


func test_substitute_stops_moving_after_six_ticks_without_real_inputs() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1, Vector2(0.0, 1.0), JUMP | SPRINT, 2.0, 0.3), 0, 1)
	queue.take(1)
	for t: int in range(2, 8):
		var repeated: PlayerInput = queue.take(t)
		assert_vec_near(repeated.move, Vector2(0, 1), 1e-6,
				"tick %d: aún repite el movimiento (%d ticks tras la última real)" % [t, t - 1])
	var stopped: PlayerInput = queue.take(8)
	assert_vec_near(stopped.move, Vector2.ZERO, 1e-6, "al séptimo tick sin entradas, move = 0")
	assert_eq(stopped.buttons, JUMP | SPRINT | SUBSTITUTED, "pero los botones se conservan")
	assert_near(stopped.look_yaw, _input(1, Vector2.ZERO, 0, 2.0).look_yaw, 1e-6, "y el yaw")
	var still: PlayerInput = queue.take(9)
	assert_vec_near(still.move, Vector2.ZERO, 1e-6, "y sigue quieto")
	assert_eq(still.buttons, JUMP | SPRINT | SUBSTITUTED, "con los mismos botones")
	assert_eq(queue.substitutions_total, 8, "ocho ticks sustituidos (2 al 9)")


func test_real_input_after_a_long_silence_moves_again_and_restarts_the_count() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 21):
		queue.take(t)
	queue.push(_input(21, Vector2(1, 0)), 0, 21)
	assert_vec_near(queue.take(21).move, Vector2(1, 0), 1e-6, "la real vuelve a mover")
	for t: int in range(22, 28):
		assert_vec_near(queue.take(t).move, Vector2(1, 0), 1e-6, "tick %d: la repite" % t)
	assert_vec_near(queue.take(28).move, Vector2.ZERO, 1e-6, "y a los 6 ticks vuelve a pararse")


func test_a_press_that_starts_during_a_loss_enters_as_an_edge_in_the_next_real_input() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(14, Vector2.ZERO, 0), 0, 14)
	for t: int in range(1, 14):
		queue.take(t)
	assert_eq(queue.take(14).buttons, 0, "tick 14 real, sin botones")
	for t: int in range(15, 18):
		assert_eq(queue.take(t).buttons, SUBSTITUTED, "15-17 perdidas: se repite «sin botones»")
	queue.push(_input(18, Vector2.ZERO, JUMP), 0, 18)
	assert_eq(queue.take(18).buttons, JUMP,
			"la pulsación llega en la primera entrada real que la lleva")


func test_substitute_of_the_spawn_is_the_neutral_input() -> void:
	var queue := InputQueue.new()
	var neutral: PlayerInput = NetProtocol.neutral_input(100, 1.5)
	queue.reset(100, neutral)
	assert_eq(queue.get_last_consumed(), 100, "el alta cuenta como consumido")
	var first: PlayerInput = queue.take(101)
	assert_eq(first.tick, 101, "tick 101")
	assert_vec_near(first.move, Vector2.ZERO, 1e-6, "sin movimiento")
	assert_eq(first.buttons, SUBSTITUTED, "sin botones, y sustituida")
	assert_near(first.look_yaw, neutral.look_yaw, 1e-6, "el yaw del alta")
	assert_near(first.look_pitch, 0.0, 1e-6, "sin pitch")
	assert_eq(queue.substitutions_total, 1, "cuenta como sustitución")


func test_reset_clears_counters_and_slots() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1), 0, 1)
	queue.push(_input(50), 0, 1)
	queue.take(1)
	queue.take(2)
	queue.push(_input(1), 0, 3)
	queue.reset(200, NetProtocol.neutral_input(200, 0.0))
	assert_eq(queue.late_count, 0, "late_count")
	assert_eq(queue.too_early_count, 0, "too_early_count")
	assert_eq(queue.substitutions_total, 0, "substitutions_total")
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN, "sin antelación")
	assert_eq(queue.get_ack_tick(), 200, "ack = tick del alta")
	assert_eq(queue.get_view_offset_q(1), -1, "huecos vacíos")
	assert_eq(queue.push(_input(201), 0, 201), InputQueue.PushResult.ACCEPTED, "vuelve a aceptar")


func test_view_offset_q() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1), 37, 1)
	queue.push(_input(3), 1234, 1)
	assert_eq(queue.get_view_offset_q(1), 37, "recibida y sin consumir")
	assert_eq(queue.get_view_offset_q(2), -1, "no recibida")
	queue.take(1)
	queue.take(2)
	queue.take(3)
	assert_eq(queue.get_view_offset_q(1), 37, "real y consumida")
	assert_eq(queue.get_view_offset_q(2), -1, "sustituida")
	assert_eq(queue.get_view_offset_q(3), 1234, "otra real")
	assert_eq(queue.get_view_offset_q(500), -1, "un tick que no está en el anillo")
	for t: int in range(4, 80):
		queue.take(t)
	assert_eq(queue.get_view_offset_q(1), -1, "ya sobrescrito")


func test_take_always_returns_the_requested_tick() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 200):
		var input: PlayerInput = queue.take(t)
		if input == null or input.tick != t:
			fail("take(%d) no devolvió una entrada de ese tick" % t)
			return
	assert_eq(queue.substitutions_total, 199, "todas sustituidas")


func test_random_network_conditions_keep_the_invariants() -> void:
	# Propiedad: con pérdida, retraso, desorden y duplicados, cada tick se aplica la primera copia
	# que llegó a tiempo y, si no, una sustituta; ningún tick se aplica dos veces ni se salta.
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var queue: InputQueue = _make_queue()
	var inbox: Dictionary = {}
	var sent: Dictionary = {}
	var first_arrival: Dictionary = {}
	var real_expected: int = 0
	var previous_ack: int = 0
	for server_tick: int in range(1, 1201):
		# El cliente va 3 ticks por delante y envía las últimas 4 entradas, cada paquete con su
		# retardo (0 a 5 ticks), con un 20 % de pérdida y a veces duplicado.
		var client_tick: int = server_tick + 3
		sent[client_tick] = _input(client_tick, Vector2(rng.randf(), rng.randf()).limit_length(1.0),
				rng.randi() & 0x1FF)
		if not rng.randf() < 0.2:
			var packet: Array = []
			for t: int in range(client_tick - 3, client_tick + 1):
				if sent.has(t):
					packet.append(sent[t])
			_deliver(inbox, server_tick + rng.randi_range(0, 5), packet)
			if rng.randf() < 0.1:
				_deliver(inbox, server_tick + rng.randi_range(0, 7), packet)
		# Llegan los paquetes de este tick, antes de simular.
		for packet: Array in inbox.get(server_tick, []):
			for pushed: PlayerInput in packet:
				var result: int = queue.push(pushed.duplicate_input(), pushed.tick, server_tick)
				if result == InputQueue.PushResult.ACCEPTED and not first_arrival.has(pushed.tick):
					first_arrival[pushed.tick] = pushed
		inbox.erase(server_tick)
		var ack: int = queue.get_ack_tick()
		if ack < previous_ack:
			fail("el ack retrocedió: %d -> %d en el tick %d" % [previous_ack, ack, server_tick])
			return
		previous_ack = ack
		if ack < queue.get_last_consumed() or ack > queue.get_last_consumed() + 30:
			fail("ack %d fuera de [consumido, consumido + 30] en el tick %d" % [ack, server_tick])
			return
		var taken: PlayerInput = queue.take(server_tick)
		if taken == null or taken.tick != server_tick:
			fail("take(%d) devolvió un tick equivocado" % server_tick)
			return
		if first_arrival.has(server_tick):
			real_expected += 1
			var expected: PlayerInput = first_arrival[server_tick]
			if taken.buttons != expected.buttons or not taken.move.is_equal_approx(expected.move):
				fail("el tick %d no aplicó la primera copia recibida" % server_tick)
				return
	assert_eq(queue.substitutions_total, 1200 - real_expected,
			"las sustituciones son exactamente los ticks sin entrada a tiempo")
	assert_true(real_expected > 800, "con un 20 %% de pérdida y redundancia llegan casi todas (%d)"
			% real_expected)
	assert_true(queue.late_count > 0, "con retardos de hasta 5 ticks hay tardías")
	assert_eq(queue.get_last_consumed(), 1200, "se consumieron los 1200 ticks")


# --- Sin flancos inventados, con un PlayerCharacter real --------------------------------------

## Mundo mínimo en un SubViewport con su propio espacio de física: un suelo y un personaje.
func _build_physics_world() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	_viewport.add_child(floor_body)
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	_character = scene.instantiate() as PlayerCharacter
	_character.jumped.connect(func() -> void: _jumped_count += 1)
	_character.landed.connect(func() -> void: _landed_ticks.append(_current_tick))
	_viewport.add_child(_character)
	_jumped_count = 0
	_landed_ticks.clear()
	_current_tick = 0


## Qué hace el servidor con un tick cuya entrada se perdió.
enum Substitute {
	## La cola real: repite la máscara completa de la última entrada aplicada.
	QUEUE,
	## Control: una entrada «sin botones», que es lo que hacía el diseño descartado. Sirve para
	## comprobar que la prueba sí detecta un flanco inventado.
	NAIVE_NEUTRAL,
}


## Entrada de la escena: neutral mientras el personaje se asienta y JUMP mantenido después.
func _scripted_input(tick: int) -> PlayerInput:
	return _input(tick, Vector2.ZERO, JUMP if tick >= JUMP_HELD_FROM else 0)


## Simula [param total_ticks] ticks de [method _scripted_input] con los ticks de [param lost]
## perdidos, uno por paso de física. Devuelve los estados (tick -> [PlayerState.encode]) y deja en
## [member _jumped_count] y [member _landed_ticks] lo que ocurrió.
func _run_scene(total_ticks: int, lost: Array[int], substitute: Substitute) -> Dictionary:
	await _build_physics_world_ready()
	var queue: InputQueue = _make_queue()
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var states: Dictionary = {}
	var last_applied: PlayerInput = NetProtocol.neutral_input(0, 0.0)
	for t: int in range(1, total_ticks + 1):
		await tree.physics_frame
		_current_tick = t
		var input: PlayerInput
		if substitute == Substitute.QUEUE:
			if not lost.has(t):
				queue.push(_scripted_input(t), 0, t)
			input = queue.take(t)
		else:
			if lost.has(t):
				input = last_applied.duplicate_input()
				input.tick = t
				input.buttons = 0
			else:
				input = _scripted_input(t)
		last_applied = input
		_character.simulate(input, dt)
		states[t] = _character.get_state().encode()
	return states


func _build_physics_world_ready() -> void:
	_build_physics_world()
	# Dos pasos de física para que el espacio registre los cuerpos recién añadidos.
	await wait_physics_frames(2)


func _free_physics_world() -> void:
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_character = null
	await wait_process_frames()


func test_substitute_never_invents_edges_with_a_real_character() -> void:
	# Referencia: ninguna pérdida. Salta una vez y aterriza en el tick L.
	var no_loss: Array[int] = []
	var reference: Dictionary = await _run_scene(70, no_loss, Substitute.QUEUE)
	if not assert_eq(_jumped_count, 1, "referencia: un solo salto (JUMP mantenido no repite)"):
		return
	if not assert_eq(_landed_ticks.size(), 2, "referencia: aterriza al asentarse y tras el salto"):
		return
	var landing: int = _landed_ticks[1]
	assert_true(landing > JUMP_HELD_FROM + 30 and landing < 65,
			"el salto dura ~44 ticks (aterriza en %d)" % landing)
	await _free_physics_world()

	# Caso del diseño: JUMP mantenido, entradas 15-17 perdidas y la 18 con JUMP. No salta otra vez
	# y toda la trayectoria coincide con la de la referencia.
	var lost_mid: Array[int] = [15, 16, 17]
	var run_mid: Dictionary = await _run_scene(70, lost_mid, Substitute.QUEUE)
	assert_eq(_jumped_count, 1, "con 15-17 perdidas: sigue habiendo un solo salto")
	assert_eq(_character.jump_buffer_ticks, 0, "y no queda ninguna pulsación guardada")
	for t: int in range(1, 71):
		if run_mid[t] != reference[t]:
			fail("el estado del tick %d difiere de la referencia tras perder 15-17" % t)
			break
	await _free_physics_world()

	# Pérdida justo antes de aterrizar: un flanco inventado en la entrada 18 de este caso (la
	# primera real tras la pérdida) quedaría dentro del búfer de salto y saltaría otra vez.
	var lost_landing: Array[int] = [landing - 5, landing - 4, landing - 3]
	var run_landing: Dictionary = await _run_scene(landing + 15, lost_landing, Substitute.QUEUE)
	assert_eq(_jumped_count, 1, "perdidas %s: ningún salto inventado al aterrizar" % [lost_landing])
	for t: int in range(1, landing + 16):
		if run_landing[t] != reference[t]:
			fail("el estado del tick %d difiere de la referencia (pérdida antes de aterrizar)" % t)
			break
	await _free_physics_world()

	# Control: con la sustituta «sin botones» la misma pérdida sí inventa el flanco y salta dos
	# veces, así que la prueba anterior habría detectado el defecto.
	await _run_scene(landing + 15, lost_landing, Substitute.NAIVE_NEUTRAL)
	assert_eq(_jumped_count, 2, "control: una sustituta sin botones inventa un segundo salto")
	await _free_physics_world()
