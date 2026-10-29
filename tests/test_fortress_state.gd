extends TestCase
## Pruebas de [FortressState] (docs/fuerte.md, secciones 1.3 a 1.5): cada fila de la tabla de
## decisión, la fórmula del progreso frente a simular tick a tick, los decaimientos, la disputa, el
## reinicio, la reaparición del capitán y de los guardias, la puerta y los campos que cambian.
## Todo es puro (sin nodos), así que se recorren miles de ticks al instante.

const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const VARDHEIM: int = 1
const SOLMARCH: int = 2
const ASKARRA: int = 3
## Ticks por segundo de la simulación.
const TPS: int = 60

var _def: FortressDefinition = null
var _state: FortressState = null
var _tick: int = 0


func before_each() -> void:
	_def = load(DEFINITION_PATH) as FortressDefinition
	assert_not_null(_def, "se carga la definición del Vado Gris")
	_tick = 100
	_state = FortressState.initial(_def, _tick)


# --- Estado inicial y velocidades -------------------------------------------------------------

func test_initial_state_is_a_neutral_garrisoned_fort() -> void:
	assert_eq(_state.owner, 0, "neutral")
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_eq(_state.phase_tick, 100)
	assert_true(_state.captain_alive, "el Capitán del Vado vive")
	assert_eq(_state.gate_health, 9000)
	assert_eq(_state.gate_max, 9000)
	assert_eq(_state.progress_max, 21600, "30 s -> 1800 ticks -> 21 600")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.capture_rate, 0)
	assert_eq(_state.progress_at(100.0), 0)
	assert_false(_state.contested)
	assert_eq(_state.presence, PackedInt32Array([0, 0, 0, 0]))
	assert_eq(_state.under_attack_until_tick, 0, "no atacado: se puede reaparecer")
	assert_false(_state.is_circle_active())
	assert_false(_state.is_gate_broken())


func test_capture_rates_by_number_of_attackers() -> void:
	assert_eq(FortressState.rate_for_count(0), 0)
	assert_eq(FortressState.rate_for_count(1), 12)
	assert_eq(FortressState.rate_for_count(2), 16)
	assert_eq(FortressState.rate_for_count(3), 20)
	assert_eq(FortressState.rate_for_count(4), 24)
	assert_eq(FortressState.rate_for_count(9), 24, "tope: 4 o más")
	assert_eq(FortressState.rate_for_count(-1), 0)
	assert_eq(FortressState.EMPTY_DECAY_RATE, -4, "un tercio de la velocidad base")
	assert_eq(FortressState.FOREIGN_DECAY_RATE, -24)


# --- GARRISONED -------------------------------------------------------------------------------

func test_a_garrisoned_fort_ignores_the_circle() -> void:
	for _i: int in 1000:
		_tick += 1
		var events: PackedInt32Array = _state.advance(_def, _tick, _p(2, 0, 0))
		assert_true(events.is_empty())
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "con el capitán vivo no se captura")
	assert_eq(_state.progress_at(float(_tick)), 0)
	assert_eq(_state.presence[VARDHEIM], 2, "pero la presencia se guarda para la interfaz")


func test_captain_death_makes_the_fort_vulnerable() -> void:
	var events: PackedInt32Array = _state.on_captain_died(_tick, SOLMARCH)
	assert_eq(events, PackedInt32Array([WarEvents.CAPTAIN_DOWN]))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_eq(_state.phase_tick, _tick)
	assert_false(_state.captain_alive)
	assert_eq(_state.captain_respawn_tick, _tick + 300 * TPS, "reaparece a los 300 s")
	assert_true(_state.is_circle_active())
	# Una segunda muerte no hace nada.
	assert_true(_state.on_captain_died(_tick + 5, SOLMARCH).is_empty())
	assert_eq(_state.captain_respawn_tick, _tick + 300 * TPS)


func test_captain_death_outside_garrisoned_is_ignored() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_true(_state.on_captain_died(_tick, VARDHEIM).is_empty(), "capturando no hay capitán que matar")
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)


# --- VULNERABLE -------------------------------------------------------------------------------

func test_vulnerable_with_a_single_realm_starts_capturing() -> void:
	for count: int in [1, 2, 3, 4, 7]:
		before_each()
		_kill_captain()
		_tick += 10
		var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, count, 0))
		assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_STARTED]), "%d atacantes" % count)
		assert_eq(_state.phase, FortressState.Phase.CAPTURING)
		assert_eq(_state.capture_realm, SOLMARCH)
		assert_eq(_state.capture_rate, FortressState.rate_for_count(count), "velocidad con %d" % count)
		assert_eq(_state.capture_start_tick, _tick, "la fórmula se ancla en este tick")
		assert_eq(_state.capture_progress_at_start, 0)
		assert_false(_state.contested)
		assert_eq(_state.event_realm(WarEvents.CAPTURE_STARTED), SOLMARCH, "el aviso lleva al captor")


func test_vulnerable_without_attackers_stays_vulnerable() -> void:
	_kill_captain()
	for _i: int in 200:
		_tick += 1
		assert_true(_state.advance(_def, _tick, _p(0, 0, 0)).is_empty())
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_false(_state.contested)


func test_two_realms_in_the_circle_keep_it_vulnerable_and_contested() -> void:
	_kill_captain()
	_tick += 1
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(1, 1, 0))
	assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_CONTESTED]), "avisa al entrar en disputa")
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_true(_state.contested)
	assert_eq(_state.capture_rate, 0)
	# Mientras sigue disputado no se repite el aviso.
	for _i: int in 100:
		_tick += 1
		assert_true(_state.advance(_def, _tick, _p(1, 1, 0)).is_empty())
	# Con una sola bandera, la captura empieza.
	_tick += 1
	var start: PackedInt32Array = _state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(start, PackedInt32Array([WarEvents.CAPTURE_STARTED]))
	assert_false(_state.contested)
	assert_eq(_state.capture_realm, SOLMARCH)


func test_attackers_and_the_owner_together_are_contested() -> void:
	_set_owner(VARDHEIM)
	_kill_captain()
	_tick += 1
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(1, 1, 0))
	assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_CONTESTED]))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "A y D: sigue vulnerable")
	assert_true(_state.contested)
	# El dueño solo no es atacante: ni captura ni disputa.
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_false(_state.contested)
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_eq(_state.capture_realm, 0)
	# Solmarch solo captura el fuerte de Vardheim.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 2, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.capture_realm, SOLMARCH)


func test_with_a_neutral_fort_every_realm_is_an_attacker() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.capture_realm, VARDHEIM, "Vardheim captura el fuerte neutral")
	before_each()
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 1))
	assert_eq(_state.capture_realm, ASKARRA)


func test_the_disputed_notice_is_limited_to_one_every_ten_seconds() -> void:
	_kill_captain()
	# Entra y sale de la disputa cada 2 s durante 40 s (10 entradas): los avisos, separados al menos 10 s.
	var notices: Array[int] = []
	var entries: int = 0
	var was_contested: bool = false
	for i: int in range(0, 40 * TPS):
		_tick += 1
		var contested_now: bool = (i / (2 * TPS)) % 2 == 0
		var events: PackedInt32Array = _state.advance(_def, _tick, _p(1, 1, 0) if contested_now else _p(0, 0, 0))
		if contested_now and not was_contested:
			entries += 1
		was_contested = contested_now
		if events.has(WarEvents.CAPTURE_CONTESTED):
			notices.append(_tick)
	assert_eq(entries, 10, "diez entradas en disputa")
	assert_true(notices.size() >= 3 and notices.size() < entries, "avisos en 40 s: %d (menos que las entradas)" % notices.size())
	for i: int in range(1, notices.size()):
		assert_true(notices[i] - notices[i - 1] >= 10 * TPS, "aviso %d: %d ticks desde el anterior" % [i, notices[i] - notices[i - 1]])
	# Con la misma regla, dos entradas separadas menos de 10 s dan un solo aviso.
	before_each()
	_kill_captain()
	var count: int = 0
	for i: int in 9 * TPS:
		_tick += 1
		var on: bool = (i % 60) < 30
		if _state.advance(_def, _tick, _p(1, 1, 0) if on else _p(0, 0, 0)).has(WarEvents.CAPTURE_CONTESTED):
			count += 1
	assert_eq(count, 1, "en 9 s, un solo aviso")


func test_the_captain_respawns_when_nobody_captures_in_time() -> void:
	_kill_captain()
	var respawn: int = _state.captain_respawn_tick
	_tick = respawn - 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "un tick antes sigue vulnerable")
	assert_false(_state.captain_alive)
	_tick = respawn
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, 0, 0))
	assert_true(events.is_empty())
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "al cumplirse el plazo reaparece el capitán")
	assert_true(_state.captain_alive)
	assert_eq(_state.captain_respawn_tick, FortressState.NO_TICK)
	assert_eq(_state.phase_tick, respawn)
	assert_false(_state.is_circle_active())


func test_the_captain_can_be_brought_back_early_only_while_vulnerable() -> void:
	assert_false(_state.respawn_captain(_tick), "con el capitán vivo no hay nada que hacer")
	_kill_captain()
	_tick += 10
	assert_true(_state.respawn_captain(_tick), "reaparición completa de los Huecos")
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_true(_state.captain_alive)
	assert_eq(_state.captain_respawn_tick, FortressState.NO_TICK)
	assert_eq(_state.phase_tick, _tick)
	# Capturando no vuelve.
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_false(_state.respawn_captain(_tick + 1))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_false(_state.captain_alive)


func test_a_contested_circle_does_not_stop_the_captain_respawning() -> void:
	_kill_captain()
	var respawn: int = _state.captain_respawn_tick
	_tick = respawn - 5
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_true(_state.contested)
	_tick = respawn
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_false(_state.contested, "y la disputa se acaba con el círculo")


# --- CAPTURING: avance y captura --------------------------------------------------------------

func test_a_capture_completes_at_the_exact_tick() -> void:
	# Ticks hasta capturar = 21 600 / velocidad: 1800, 1350, 1080 y 900 con 1, 2, 3 y 4 o más.
	var expected_ticks: Dictionary = {1: 1800, 2: 1350, 3: 1080, 4: 900, 6: 900}
	for count: int in expected_ticks:
		before_each()
		_kill_captain()
		_tick += 1
		_state.advance(_def, _tick, _p(count, 0, 0))
		var start: int = _tick
		var captured_at: int = -1
		for _i: int in 3000:
			_tick += 1
			var events: PackedInt32Array = _state.advance(_def, _tick, _p(count, 0, 0))
			if events.has(WarEvents.FORT_CAPTURED):
				captured_at = _tick
				break
		assert_eq(captured_at - start, int(expected_ticks[count]), "%d atacantes capturan en %d ticks" % [count, expected_ticks[count]])


func test_capture_completion_makes_the_attacker_the_owner() -> void:
	# Un golpe a la puerta y a los guardias antes, para ver que la captura lo restablece.
	_state.set_guards_alive(4)
	_kill_captain()
	_state.on_gate_damaged(_tick, 4000, VARDHEIM)
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	var events: PackedInt32Array = PackedInt32Array()
	while not events.has(WarEvents.FORT_CAPTURED):
		_tick += 1
		events = _state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(events, PackedInt32Array([WarEvents.FORT_CAPTURED]))
	assert_eq(_state.owner, VARDHEIM, "dueño: el captor")
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_state.phase_tick, _tick)
	assert_eq(_state.gate_health, 9000, "puerta reparada")
	assert_eq(_state.gate_last_damage_tick, FortressState.NO_TICK)
	assert_false(_state.captain_alive, "sin capitán hasta que llegue la guarnición")
	assert_eq(_state.guards_alive, 0, "los PNJ del dueño anterior se retiran")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.capture_rate, 0)
	assert_false(_state.is_circle_active())
	assert_eq(_state.event_realm(WarEvents.FORT_CAPTURED), VARDHEIM, "el aviso lleva al nuevo dueño")


func test_the_captor_alone_keeps_the_formula_running() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	var start: int = _tick
	# Un compañero más a mitad: se vuelve a anclar con el progreso del momento y la velocidad nueva.
	_tick = start + 600
	_state.advance(_def, _tick, _p(0, 2, 0))
	assert_eq(_state.capture_rate, 16)
	assert_eq(_state.capture_progress_at_start, 600 * 12, "progreso hasta ahí: 7200")
	assert_eq(_state.capture_start_tick, _tick)
	assert_eq(_state.progress_at(float(_tick + 100)), 600 * 12 + 100 * 16)


func test_contested_capture_freezes() -> void:
	_set_owner(SOLMARCH)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	var frozen_at: int = _tick + 300
	_tick = frozen_at
	_state.advance(_def, _tick, _p(2, 0, 0))
	var progress: int = _state.progress_at(float(_tick))
	assert_eq(progress, 300 * 16)
	# Llega el dueño: disputado, velocidad 0.
	_tick += 10
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(2, 1, 0))
	assert_eq(events, PackedInt32Array([WarEvents.CAPTURE_CONTESTED]))
	assert_true(_state.contested)
	assert_eq(_state.capture_rate, 0)
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	for _i: int in 500:
		_tick += 1
		_state.advance(_def, _tick, _p(2, 1, 0))
	assert_eq(_state.progress_at(float(_tick)), progress + 10 * 16, "congelado desde que llegó el dueño")
	# Otro reino también disputa.
	before_each()
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 100
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_true(_state.contested, "captor y otro reino")
	assert_eq(_state.capture_rate, 0)
	# Se va el intruso: se reanuda.
	_tick += 50
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_false(_state.contested)
	assert_eq(_state.capture_rate, 12)


func test_foreign_players_without_the_captor_roll_the_capture_back_fast() -> void:
	_set_owner(SOLMARCH)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(3, 0, 0))
	_tick += 400
	_state.advance(_def, _tick, _p(3, 0, 0))
	var progress: int = _state.progress_at(float(_tick))
	assert_eq(progress, 400 * 20, "tres captores: 20 por tick")
	# Se van los captores y solo queda el dueño: -24 por tick.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.capture_rate, -24)
	assert_eq(_state.capture_progress_at_start, 400 * 20 + 20)
	_tick += 100
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.progress_at(float(_tick)), 400 * 20 + 20 - 100 * 24)
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)


func test_progress_zero_with_a_single_foreign_realm_hands_it_the_capture() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 200
	_state.advance(_def, _tick, _p(1, 0, 0))
	# Solmarch (2 jugadores) sustituye a Vardheim: la captura de Vardheim retrocede a 24 por tick.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 2, 0))
	assert_eq(_state.capture_rate, -24)
	var progress: int = _state.progress_at(float(_tick))
	var swapped: PackedInt32Array = PackedInt32Array()
	var ticks_to_zero: int = 0
	while swapped.is_empty():
		_tick += 1
		ticks_to_zero += 1
		swapped = _state.advance(_def, _tick, _p(0, 2, 0))
		assert_true(ticks_to_zero < 1000)
	assert_eq(swapped, PackedInt32Array([WarEvents.CAPTURE_STARTED]), "el nuevo captor lo anuncia")
	assert_eq(ticks_to_zero, ceili(float(progress) / 24.0), "cuando llega a cero")
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.capture_realm, SOLMARCH)
	assert_eq(_state.capture_rate, 16, "con su número de jugadores")
	assert_eq(_state.capture_progress_at_start, 0)
	assert_eq(_state.capture_start_tick, _tick)


func test_progress_zero_without_an_attacker_goes_back_to_vulnerable() -> void:
	# Solo queda el dueño dentro y el progreso llega a cero.
	_set_owner(SOLMARCH)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 50
	_state.advance(_def, _tick, _p(1, 0, 0))
	var progress: int = _state.progress_at(float(_tick))
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	var guard: int = 0
	while _state.phase == FortressState.Phase.CAPTURING and guard < 100:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 1, 0))
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "sin atacantes y a cero: VULNERABLE")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.capture_rate, 0)
	assert_eq(_state.capture_progress_at_start, 0)
	assert_eq(_state.progress_at(float(_tick)), 0)
	assert_true(progress > 0)
	assert_eq(_state.captain_respawn_tick, _tick + 300 * TPS, "el capitán tiene un plazo nuevo")


func test_progress_zero_with_two_attackers_goes_back_to_vulnerable_contested() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 20
	_state.advance(_def, _tick, _p(0, 1, 1))
	var guard: int = 0
	while _state.phase == FortressState.Phase.CAPTURING and guard < 100:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 1, 1))
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "dos atacantes a cero: nadie captura")
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 1))
	assert_true(_state.contested, "y siguen disputando")
	assert_eq(_state.capture_realm, 0)


# --- CAPTURING: el círculo vacío --------------------------------------------------------------

func test_an_empty_circle_freezes_for_five_seconds_then_decays_slowly() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	_tick += 600
	_state.advance(_def, _tick, _p(0, 1, 0))
	var progress: int = _state.progress_at(float(_tick))
	assert_eq(progress, 600 * 12)
	# Todos se van: 5 s congelado.
	var empty_from: int = _tick + 1
	_tick = empty_from
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.empty_since_tick, empty_from)
	assert_eq(_state.capture_rate, 0, "congelado")
	assert_eq(_state.progress_at(float(_tick)), progress + 12, "el último tick con el captor se suma")
	var frozen: int = _state.progress_at(float(_tick))
	_tick = empty_from + 299
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.capture_rate, 0, "a los 299 ticks sigue congelado")
	assert_eq(_state.progress_at(float(_tick)), frozen)
	_tick = empty_from + 300
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.capture_rate, -4, "a los 5 s empieza a decaer a -4 por tick")
	assert_eq(_state.progress_at(float(_tick + 100)), frozen - 400)
	# Si vuelve alguien, se reanuda y se borra la cuenta del vacío.
	_tick += 10
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.empty_since_tick, FortressState.NO_TICK)
	assert_eq(_state.capture_rate, 12)


func test_an_empty_circle_decays_to_zero_and_the_fort_is_vulnerable_again() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 60
	_state.advance(_def, _tick, _p(1, 0, 0))
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	var guard: int = 0
	while _state.phase == FortressState.Phase.CAPTURING and guard < 5000:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 0, 0))
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE)
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.empty_since_tick, FortressState.NO_TICK)


func test_everybody_leaving_right_after_the_start_keeps_the_little_progress_and_decays() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	# Se van en el tick siguiente: ya hay 12 de progreso, así que sigue capturando congelado 5 s y luego decae
	# (12 / 4 = 3 ticks) hasta volver a VULNERABLE.
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.progress_at(float(_tick)), 12)
	_tick += 5 * TPS
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.capture_rate, -4)
	_tick += 3
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "a cero y sin atacantes")


func test_a_capture_frozen_at_zero_with_nobody_inside_goes_back_to_vulnerable_at_once() -> void:
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(1, 0, 0))
	# Como si la captura no hubiera avanzado nada (p. ej. el captor y el dueño llegaron juntos y se fueron).
	_state.capture_rate = 0
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.VULNERABLE, "progreso 0 y ningún atacante")
	assert_eq(_state.capture_realm, 0)


# --- La fórmula frente a simular tick a tick --------------------------------------------------

func test_the_formula_matches_a_tick_by_tick_simulation() -> void:
	# Escenario: el capitán muere, entran captores de Vardheim en distinto número, llega Solmarch (disputa y
	# luego relevo), se vacía el círculo y al final Vardheim captura.
	var script: Array[Array] = [
		[300, _p(0, 0, 0)], [900, _p(1, 0, 0)], [400, _p(3, 0, 0)], [200, _p(3, 1, 0)],
		[300, _p(0, 2, 0)], [100, _p(0, 0, 0)], [500, _p(0, 0, 0)], [2000, _p(2, 0, 0)],
		[300, _p(2, 0, 1)], [3000, _p(4, 0, 0)],
	]
	_kill_captain()
	var reference: int = 0
	var captured: bool = false
	var checks: int = 0
	var previous_captor: int = 0
	var last_rate: int = 0
	for step: Array in script:
		for _i: int in int(step[0]):
			_tick += 1
			# Integración entera de la velocidad en vigor durante el tick anterior.
			reference = clampi(reference + last_rate, 0, _state.progress_max)
			var events: PackedInt32Array = _state.advance(_def, _tick, step[1])
			if _state.phase != FortressState.Phase.CAPTURING or _state.capture_realm != previous_captor:
				# La captura se ha anclado de nuevo desde cero (captor nuevo, vuelta a VULNERABLE, captura hecha).
				if events.has(WarEvents.FORT_CAPTURED):
					assert_eq(reference, _state.progress_max, "la captura se completa al llegar al máximo")
				reference = _state.capture_progress_at_start
			previous_captor = _state.capture_realm if _state.phase == FortressState.Phase.CAPTURING else 0
			if _state.phase == FortressState.Phase.CAPTURING:
				assert_eq(_state.progress_at(float(_tick)), reference, "tick %d" % _tick)
				assert_eq(_state.progress_at(float(_tick) + 0.5), clampi(reference + floori(_state.capture_rate * 0.5), 0, _state.progress_max))
				checks += 1
			last_rate = _state.capture_rate if _state.phase == FortressState.Phase.CAPTURING else 0
			if _state.phase == FortressState.Phase.CONSOLIDATING:
				captured = true
				break
		if captured:
			break
	assert_true(captured, "la captura acaba completándose")
	assert_true(checks > 3000, "se comprobaron %d ticks" % checks)
	assert_eq(_state.owner, VARDHEIM)


func test_progress_formula_clamps_and_accepts_fractional_ticks() -> void:
	_state.capture_start_tick = 1000
	_state.capture_progress_at_start = 5000
	_state.capture_rate = 12
	assert_eq(_state.progress_at(1000.0), 5000)
	assert_eq(_state.progress_at(1010.0), 5120)
	assert_eq(_state.progress_at(1010.5), 5126, "tick fraccionario del cliente, hacia abajo")
	assert_eq(_state.progress_at(999.0), 4988, "también hacia atrás")
	assert_eq(_state.progress_at(100000.0), _state.progress_max, "tope en el máximo")
	_state.capture_rate = -24
	assert_eq(_state.progress_at(1100.0), 2600)
	assert_eq(_state.progress_at(5000.0), 0, "y en cero")
	_state.capture_rate = -4
	assert_eq(_state.progress_at(1000.9), 4996, "redondeo hacia abajo en bajada: 5000 - 3,6 = 4996,4")


# --- CONSOLIDATING ----------------------------------------------------------------------------

func test_consolidation_ends_with_the_new_garrison() -> void:
	_capture_by(VARDHEIM)
	var start: int = _state.phase_tick
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING)
	# Durante la consolidación el círculo no cuenta.
	for _i: int in 600:
		_tick += 1
		assert_true(_state.advance(_def, _tick, _p(0, 5, 0)).is_empty())
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING)
	assert_false(_state.contested)
	assert_eq(_state.capture_realm, 0)
	_tick = start + 120 * TPS - 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING, "un tick antes")
	_tick = start + 120 * TPS
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, 0, 0))
	assert_true(events.is_empty())
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "a los 2 min llega la guarnición")
	assert_true(_state.captain_alive, "con el capitán del nuevo dueño")
	assert_eq(_state.owner, VARDHEIM)
	assert_eq(_state.phase_tick, _tick)


func test_the_new_owner_can_be_recaptured_after_the_garrison_is_beaten() -> void:
	_capture_by(VARDHEIM)
	_tick += 120 * TPS
	_state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	_tick += 5
	assert_true(_state.on_captain_died(_tick, SOLMARCH).has(WarEvents.CAPTAIN_DOWN))
	_tick += 5
	_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_eq(_state.capture_realm, SOLMARCH)
	_tick += 5
	_state.advance(_def, _tick, _p(1, 1, 0))
	assert_true(_state.contested, "el nuevo dueño disputa")


# --- Reinicio ---------------------------------------------------------------------------------

func test_reset_to_neutral_from_any_phase() -> void:
	_capture_by(VARDHEIM)
	_state.on_gate_damaged(_tick, 5000, SOLMARCH)
	_state.set_guards_alive(4)
	_tick += 7
	var events: PackedInt32Array = _state.reset_to_neutral(_def, _tick)
	assert_eq(events, PackedInt32Array([WarEvents.FORT_RESET]))
	assert_eq(_state.owner, 0)
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_eq(_state.phase_tick, _tick)
	assert_true(_state.captain_alive, "el Capitán del Vado")
	assert_eq(_state.gate_health, 9000, "puerta llena")
	assert_eq(_state.capture_realm, 0)
	assert_eq(_state.progress_at(float(_tick)), 0)
	assert_eq(_state.guards_alive, 0)
	assert_eq(_state.under_attack_until_tick, _tick, "ya no está atacado")
	assert_eq(_state.last_attack_notice_tick, FortressState.NO_TICK)
	assert_eq(_state.event_realm(WarEvents.FORT_RESET, VARDHEIM), 0, "el aviso de reinicio lleva el reino 0")
	# Desde la captura en curso, con jugadores dentro (no se mueven: el estado solo cambia).
	before_each()
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	_tick += 100
	_state.advance(_def, _tick, _p(2, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	_state.reset_to_neutral(_def, _tick)
	assert_eq(_state.phase, FortressState.Phase.GARRISONED)
	assert_eq(_state.presence[VARDHEIM], 2, "la presencia se conserva")
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	assert_eq(_state.phase, FortressState.Phase.GARRISONED, "con el capitán vivo no se vuelve a capturar")


func test_the_periodic_reset_returns_the_fort_to_neutral_after_30_minutes() -> void:
	_capture_by(VARDHEIM)
	var created: int = 100
	var reset_at: int = created + 1800 * TPS
	_tick = reset_at - 1
	assert_true(_state.advance(_def, _tick, _p(0, 0, 0)).is_empty())
	assert_eq(_state.owner, VARDHEIM, "un tick antes sigue siendo suyo")
	_tick = reset_at
	var events: PackedInt32Array = _state.advance(_def, _tick, _p(0, 0, 0))
	assert_eq(events, PackedInt32Array([WarEvents.FORT_RESET]))
	assert_eq(_state.owner, 0)
	assert_eq(_state.last_reset_tick, reset_at)
	# El siguiente reinicio, otros 30 minutos después.
	_tick = reset_at + 1800 * TPS - 1
	assert_true(_state.advance(_def, _tick, _p(0, 0, 0)).is_empty())
	_tick += 1
	assert_eq(_state.advance(_def, _tick, _p(0, 0, 0)), PackedInt32Array([WarEvents.FORT_RESET]))


func test_without_a_reset_period_the_fort_never_resets_itself() -> void:
	var def: FortressDefinition = _def.duplicate() as FortressDefinition
	def.reset_to_neutral_s = 0.0
	var state: FortressState = FortressState.initial(def, 0)
	state.owner = VARDHEIM
	assert_true(state.advance(def, 10000000, _p(0, 0, 0)).is_empty())
	assert_eq(state.owner, VARDHEIM)


# --- La puerta --------------------------------------------------------------------------------

func test_gate_damage_notices_and_breaking() -> void:
	var events: PackedInt32Array = _state.on_gate_damaged(1000, 2000, SOLMARCH)
	assert_eq(events, PackedInt32Array([WarEvents.UNDER_ATTACK]), "primer golpe: aviso de ataque")
	assert_eq(_state.gate_health, 7000)
	assert_eq(_state.gate_last_damage_tick, 1000)
	assert_eq(_state.under_attack_until_tick, 1000 + 30 * TPS, "atacado 30 s")
	assert_eq(_state.event_realm(WarEvents.UNDER_ATTACK, SOLMARCH), SOLMARCH, "el aviso lleva al atacante")
	# Otro golpe 10 s después: sin aviso (como mucho uno por minuto) pero sí se alarga el «atacado».
	assert_true(_state.on_gate_damaged(1600, 1000, SOLMARCH).is_empty())
	assert_eq(_state.under_attack_until_tick, 1600 + 1800)
	# Pasado el minuto, otro aviso.
	assert_eq(_state.on_gate_damaged(1000 + 3600, 1000, VARDHEIM), PackedInt32Array([WarEvents.UNDER_ATTACK]))
	# El golpe que la rompe da el aviso de puerta rota (y el de ataque si toca).
	_state.gate_health = 800
	var broken: PackedInt32Array = _state.on_gate_damaged(9000, 5000, SOLMARCH)
	assert_true(broken.has(WarEvents.GATE_BROKEN))
	assert_eq(_state.gate_health, 0)
	assert_true(_state.is_gate_broken())
	# Rota, ya no recibe daño ni avisos.
	assert_true(_state.on_gate_damaged(9001, 100, SOLMARCH).is_empty())
	assert_eq(_state.gate_last_damage_tick, 9000)
	# Daño no positivo: nada.
	var healthy: FortressState = FortressState.initial(_def, 0)
	assert_true(healthy.on_gate_damaged(5, 0, VARDHEIM).is_empty())
	assert_true(healthy.on_gate_damaged(5, -30, VARDHEIM).is_empty())
	assert_eq(healthy.gate_health, 9000)


func test_gate_break_notice_only_when_it_breaks_in_that_hit() -> void:
	var events: PackedInt32Array = _state.on_gate_damaged(500, 20000, VARDHEIM)
	assert_eq(events, PackedInt32Array([WarEvents.UNDER_ATTACK, WarEvents.GATE_BROKEN]), "ataque y rotura a la vez")
	assert_eq(_state.gate_health, 0, "la vida no baja de 0")


func test_gate_repair_after_five_minutes_without_damage() -> void:
	assert_false(_state.gate_repair_due(100000), "una puerta entera no se repara")
	_state.on_gate_damaged(1000, 3000, SOLMARCH)
	assert_false(_state.gate_repair_due(1000 + 300 * TPS - 1))
	assert_true(_state.gate_repair_due(1000 + 300 * TPS), "a los 5 min sin daño")
	# Un golpe más lo aplaza otros 5 min.
	_state.on_gate_damaged(5000, 100, SOLMARCH)
	assert_false(_state.gate_repair_due(1000 + 300 * TPS))
	assert_true(_state.gate_repair_due(5000 + 300 * TPS))
	_state.repair_gate()
	assert_eq(_state.gate_health, 9000)
	assert_false(_state.gate_repair_due(900000))


func test_defender_damage_marks_the_fort_as_attacked() -> void:
	_state.on_defender_damaged(2000, SOLMARCH)
	assert_eq(_state.under_attack_until_tick, 2000 + 1800)
	_state.on_defender_damaged(2100, SOLMARCH)
	assert_eq(_state.under_attack_until_tick, 2100 + 1800)
	# Un golpe antiguo (otro hilo de eventos) no acorta el plazo.
	_state.on_defender_damaged(2050, SOLMARCH)
	assert_eq(_state.under_attack_until_tick, 2100 + 1800)
	# El aviso de «atacado» por defensores se concede una vez por minuto.
	assert_true(_state.claim_attack_notice(2100))
	assert_false(_state.claim_attack_notice(2100 + 3599))
	assert_true(_state.claim_attack_notice(2100 + 3600))


# --- Guardias ---------------------------------------------------------------------------------

func test_dead_guards_respawn_after_180_seconds() -> void:
	_set_owner(VARDHEIM)
	_state.set_guards_alive(4)
	assert_false(_state.guards_respawn_due(_tick + 100000), "con la guarnición completa no hay nada que reponer")
	_tick += 50
	_state.set_guards_alive(3)
	_state.advance(_def, _tick + 1, _p(0, 0, 0))
	var due_at: int = _tick + 1 + 180 * TPS
	assert_eq(_state.guards_respawn_tick, due_at, "se arma al notar que falta uno")
	assert_false(_state.guards_respawn_due(due_at - 1))
	assert_true(_state.guards_respawn_due(due_at))
	# Se repone: la cuenta se borra.
	_state.set_guards_alive(4)
	assert_eq(_state.guards_respawn_tick, FortressState.NO_TICK)
	assert_false(_state.guards_respawn_due(due_at + 10))
	# Otro muerto después arma una cuenta nueva sin tocar la anterior mientras haya faltas.
	_state.set_guards_alive(2)
	_state.advance(_def, due_at + 100, _p(0, 0, 0))
	_state.set_guards_alive(1)
	_state.advance(_def, due_at + 200, _p(0, 0, 0))
	assert_eq(_state.guards_respawn_tick, due_at + 100 + 180 * TPS, "la cuenta sigue desde el primero que cayó")


func test_guards_only_respawn_in_garrisoned_and_vulnerable() -> void:
	_set_owner(VARDHEIM)
	_state.set_guards_alive(4)
	_state.set_guards_alive(2)
	_tick += 1
	_state.advance(_def, _tick, _p(0, 0, 0))
	var due_at: int = _state.guards_respawn_tick
	assert_true(_state.guards_respawn_due(due_at), "GARRISONED")
	_kill_captain()
	assert_true(_state.guards_respawn_due(due_at), "VULNERABLE")
	_tick = due_at - 10
	_state.advance(_def, _tick, _p(0, 0, 3))
	assert_eq(_state.phase, FortressState.Phase.CAPTURING)
	assert_false(_state.guards_respawn_due(due_at + 10), "CAPTURING: no")


func test_capture_removes_the_previous_garrison() -> void:
	_set_owner(VARDHEIM)
	_state.set_guards_alive(4)
	_kill_captain()
	_tick += 1
	_state.advance(_def, _tick, _p(0, 1, 0))
	while _state.phase != FortressState.Phase.CONSOLIDATING:
		_tick += 1
		_state.advance(_def, _tick, _p(0, 1, 0))
	assert_eq(_state.owner, SOLMARCH)
	assert_eq(_state.guards_alive, 0)
	assert_eq(_state.guards_respawn_tick, FortressState.NO_TICK)
	assert_false(_state.guards_respawn_due(_tick + 100000), "no hay guarnición esperada")
	_state.set_guards_alive(4)
	assert_eq(_state.guards_alive, 4)


# --- Presencia, campos y copias ---------------------------------------------------------------

func test_presence_is_stored_for_the_interface_and_short_arrays_are_padded() -> void:
	_state.advance(_def, 101, PackedInt32Array([0, 3, 5, 1]))
	assert_eq(_state.presence, PackedInt32Array([0, 3, 5, 1]))
	_state.advance(_def, 102, PackedInt32Array([0, 2]))
	assert_eq(_state.presence, PackedInt32Array([0, 2, 0, 0]), "los reinos que faltan, a cero")
	_state.advance(_def, 103, PackedInt32Array())
	assert_eq(_state.presence, PackedInt32Array([0, 0, 0, 0]))
	# No guarda el mismo array que le pasan.
	var counts: PackedInt32Array = PackedInt32Array([0, 1, 0, 0])
	_state.advance(_def, 104, counts)
	counts[1] = 9
	assert_eq(_state.presence[VARDHEIM], 1)


func test_changed_fields_since_lists_exactly_what_changed() -> void:
	var before: FortressState = _state.duplicate_state()
	assert_true(_state.changed_fields_since(before).is_empty(), "sin cambios, nada")
	_tick += 10
	_kill_captain()
	var changed: PackedInt32Array = _state.changed_fields_since(before)
	assert_eq(changed, PackedInt32Array([FortressFields.PHASE, FortressFields.PHASE_TICK, FortressFields.CAPTAIN_ALIVE]))
	before = _state.duplicate_state()
	_tick += 5
	_state.advance(_def, _tick, _p(0, 3, 0))
	changed = _state.changed_fields_since(before)
	assert_true(changed.has(FortressFields.PHASE), "pasa a CAPTURING")
	assert_true(changed.has(FortressFields.CAPTURE_REALM))
	assert_true(changed.has(FortressFields.CAPTURE_RATE))
	assert_true(changed.has(FortressFields.CAPTURE_START_TICK))
	assert_true(changed.has(FortressFields.PRESENCE_BASE + SOLMARCH), "y la presencia de Solmarch")
	assert_false(changed.has(FortressFields.OWNER))
	assert_false(changed.has(FortressFields.GATE_HEALTH))
	# Aplicar los campos cambiados a la copia antigua reproduce el estado nuevo: es lo que hace el cliente.
	for field_id: int in changed:
		assert_true(FortressFields.set_value(before, field_id, FortressFields.get_value(_state, field_id)))
	assert_eq(before.changed_fields_since(_state), PackedInt32Array(), "el cliente queda igual que el servidor")


func test_duplicate_state_is_independent() -> void:
	_kill_captain()
	_state.set_guards_alive(4)
	var copy: FortressState = _state.duplicate_state()
	_tick += 1
	_state.advance(_def, _tick, _p(2, 0, 0))
	_state.on_gate_damaged(_tick, 1000, VARDHEIM)
	assert_eq(copy.phase, FortressState.Phase.VULNERABLE)
	assert_eq(copy.gate_health, 9000)
	assert_eq(copy.presence, PackedInt32Array([0, 0, 0, 0]))
	assert_eq(copy.progress_max, _state.progress_max)
	# La copia sigue funcionando como el original (guarda los tiempos de la definición).
	assert_eq(copy.on_gate_damaged(10, 100, VARDHEIM), PackedInt32Array([WarEvents.UNDER_ATTACK]))
	assert_eq(copy.under_attack_until_tick, 10 + 1800)


func test_every_decision_is_a_pure_function_of_state_and_presence() -> void:
	# Dos estados que reciben lo mismo acaban idénticos, tick a tick.
	var a: FortressState = FortressState.initial(_def, 0)
	var b: FortressState = FortressState.initial(_def, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	a.on_captain_died(10, VARDHEIM)
	b.on_captain_died(10, VARDHEIM)
	for tick: int in range(11, 6000):
		if tick % 6 == 0 or tick % 6 == 1:
			var counts: PackedInt32Array = _p(rng.randi_range(0, 2), rng.randi_range(0, 2), rng.randi_range(0, 1))
			a.advance(_def, tick, counts)
			b.advance(_def, tick, counts)
		else:
			a.advance(_def, tick, a.presence)
			b.advance(_def, tick, b.presence)
		assert_true(a.changed_fields_since(b).is_empty(), "tick %d" % tick)
		if not a.changed_fields_since(b).is_empty():
			break


# --- Ayudantes --------------------------------------------------------------------------------

## Recuento de presencia [Vardheim, Solmarch, Askarra].
func _p(vardheim: int, solmarch: int, askarra: int) -> PackedInt32Array:
	return PackedInt32Array([0, vardheim, solmarch, askarra])


## El fuerte pasa a ser de [param realm] sin captura (para probar al dueño).
func _set_owner(realm: int) -> void:
	_state.owner = realm


func _kill_captain() -> void:
	_state.on_captain_died(_tick, SOLMARCH)


## Mata al capitán y captura el fuerte con 4 jugadores de [param realm]; deja el estado en CONSOLIDATING.
func _capture_by(realm: int) -> void:
	_kill_captain()
	var presence: PackedInt32Array = _p(4 if realm == VARDHEIM else 0, 4 if realm == SOLMARCH else 0, 4 if realm == ASKARRA else 0)
	var guard: int = 0
	while _state.phase != FortressState.Phase.CONSOLIDATING and guard < 5000:
		_tick += 1
		_state.advance(_def, _tick, presence)
		guard += 1
	assert_eq(_state.phase, FortressState.Phase.CONSOLIDATING, "el fuerte se captura")
