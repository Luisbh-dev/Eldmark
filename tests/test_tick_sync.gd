extends TestCase
## Pruebas de [TickSync] (docs/red.md, secciones 4.2 y 16): margen objetivo según el jitter,
## secuencias de márgenes y los pasos que se deben dar, deuda proporcional, espera hasta el ack
## posterior al ajuste, retraso con pasos nulos, resincronización dura hacia delante y que nunca
## se salta hacia atrás.
## [br][br]
## Los números esperados salen a mano del pseudocódigo de la sección 4.2.

const RANDOM_SEED: int = 20261029
const NO_MARGIN: int = NetProtocol.NO_MARGIN


func test_target_margin_follows_jitter() -> void:
	var sync := TickSync.new()
	assert_eq(sync.get_target_margin(), 1, "sin jitter medido, margen 1")
	var cases: Array[Array] = [
		[0.0, 1], [0.1, 2], [0.5, 2], [0.51, 3], [1.0, 3], [1.01, 4], [1.5, 4], [5.0, 4],
		[-3.0, 1],
	]
	for case: Array in cases:
		sync.set_jitter(case[0])
		assert_eq(sync.get_target_margin(), case[1],
				"jitter %s -> margen 1 + ceil(2 * jitter) acotado a [1, 4]" % case[0])


func test_start_returns_first_real_tick() -> void:
	var sync := TickSync.new()
	assert_eq(sync.start(100, 5), 107, "P0 = spawn_tick + rtt + margen (1) + 1")
	sync.set_jitter(1.0)
	assert_eq(sync.start(100, 5), 109, "con margen 3: P0 = 100 + 5 + 3 + 1")
	assert_eq(sync.start(100, 0), 104, "RTT 0")
	assert_eq(sync.start(100, -4), 104, "un RTT negativo cuenta como 0")


func test_start_resets_previous_session() -> void:
	var sync := TickSync.new()
	_feed(sync, 10, 0, 1)
	assert_eq(sync.next_steps(50), 2, "se adelanta")
	assert_eq(sync.adjustments, 1, "un ajuste")
	_feed(sync, 100, 5, 3)
	sync.start(1, 1)
	assert_eq(sync.adjustments, 0, "start() reinicia los ajustes")
	assert_eq(sync.get_window_min(), NO_MARGIN, "start() vacía la ventana")
	_feed(sync, 0, 1, 1)
	assert_eq(sync.next_steps(10), 1, "sin deuda ni espera tras start()")


func test_steady_margin_keeps_one_step() -> void:
	var sync := TickSync.new()
	# Entre el objetivo (1) y el objetivo + 2 (3) no se toca nada, ni siquiera con la ventana llena.
	for i: int in 60:
		sync.on_snapshot(i, 1 + (i % 3))
		assert_eq(sync.next_steps(100 + i), 1, "paso %d" % i)
	assert_eq(sync.adjustments, 0, "ningún ajuste")


func test_no_data_margin_is_ignored() -> void:
	var sync := TickSync.new()
	sync.on_snapshot(5, NO_MARGIN)
	assert_eq(sync.get_window_min(), NO_MARGIN, "un snapshot sin datos no entra en la ventana")
	assert_eq(sync.next_steps(10), 1, "y no cambia el ritmo")


func test_window_keeps_the_last_samples_and_uses_the_minimum() -> void:
	var sync := TickSync.new()
	_feed(sync, 1, 3, 1)
	_feed(sync, 2, 1, 1)
	_feed(sync, 3, 2, 1)
	assert_eq(sync.get_window_min(), 1, "mínimo de todas las muestras")
	# Una muestra baja antigua sale de la ventana tras WINDOW_SAMPLES muestras más.
	var other := TickSync.new()
	_feed(other, 1, -5, 1)
	_feed(other, 2, 4, TickSync.WINDOW_SAMPLES)
	assert_eq(other.get_window_min(), 4, "la ventana solo recuerda las últimas %d muestras" %
			TickSync.WINDOW_SAMPLES)


func test_behind_pays_a_debt_proportional_to_the_shortfall_with_double_steps() -> void:
	var sync := TickSync.new()
	sync.set_jitter(1.0)
	assert_eq(sync.get_target_margin(), 3, "margen objetivo 3")
	_feed(sync, 10, 0, 1)
	assert_eq(sync.get_window_min(), 0, "mínimo 0")
	# Deuda 3 - 0: tres pasos dobles seguidos y luego el ritmo normal.
	var steps: Array[int] = []
	var predicted: int = 100
	for _i: int in 6:
		var count: int = sync.next_steps(predicted)
		steps.append(count)
		predicted += count
	assert_eq(steps, [2, 2, 2, 1, 1, 1] as Array[int], "pasos tras un margen 0 con objetivo 3")
	assert_eq(sync.adjustments, 1, "un ajuste")
	assert_eq(sync.get_window_min(), NO_MARGIN, "el ajuste vacía la ventana")


func test_small_shortfall_pays_a_single_double_step() -> void:
	var sync := TickSync.new()
	_feed(sync, 10, 0, 1)
	assert_eq(sync.next_steps(100), 2, "margen 0 con objetivo 1: un paso doble")
	assert_eq(sync.next_steps(102), 1, "y vuelta al ritmo normal")
	assert_eq(sync.adjustments, 1, "un ajuste")


func test_waits_for_an_ack_after_the_adjustment() -> void:
	var sync := TickSync.new()
	sync.set_jitter(1.0)
	_feed(sync, 10, 0, 1)
	var predicted: int = 100
	for _i: int in 3:
		predicted += sync.next_steps(predicted)
	# El último paso doble se dio con predicted_tick = 104: el primer tick nuevo es 106 y se espera
	# un ack de 108 (primer tick posterior al ajuste + 2).
	assert_eq(sync.adjustments, 1, "ajuste hecho")
	sync.on_snapshot(107, 0)
	assert_eq(sync.get_window_min(), NO_MARGIN, "ack 107: aún refleja entradas anteriores al ajuste")
	sync.on_snapshot(108, 0)
	assert_eq(sync.get_window_min(), 0, "ack 108: el servidor ya ha visto entradas posteriores")
	sync.on_snapshot(200, 7)
	assert_eq(sync.get_window_min(), 0, "las siguientes entran sin más espera")


func test_ahead_slows_down_with_a_null_step_every_other_tick() -> void:
	var sync := TickSync.new()
	# Con la ventana a medias no se retrasa nunca.
	_feed(sync, 1, 6, TickSync.WINDOW_SAMPLES - 1)
	for i: int in 10:
		assert_eq(sync.next_steps(100 + i), 1, "ventana incompleta: ritmo normal")
	assert_eq(sync.adjustments, 0, "sin ajustes")

	_feed(sync, 2, 6, 1)
	# Margen 6 con objetivo 1: deuda -(6 - 1) = -5 -> cinco pasos nulos, uno de cada dos ticks.
	var steps: Array[int] = []
	var predicted: int = 100
	for _i: int in 12:
		var count: int = sync.next_steps(predicted)
		steps.append(count)
		predicted += count
	assert_eq(steps, [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1] as Array[int],
			"cinco pasos nulos alternados con pasos normales")
	assert_eq(sync.adjustments, 1, "un ajuste")


func test_margin_just_above_the_target_does_not_slow_down() -> void:
	var sync := TickSync.new()
	_feed(sync, 1, 3, TickSync.WINDOW_SAMPLES + 5)
	for i: int in 20:
		assert_eq(sync.next_steps(100 + i), 1, "objetivo 1 + 2 = 3 todavía vale")
	_feed(sync, 2, 4, TickSync.WINDOW_SAMPLES)
	assert_eq(sync.next_steps(200), 0, "con 4 (> objetivo + 2) y la ventana llena sí se retrasa")


func test_hard_resync_forward_takes_all_the_steps_at_once() -> void:
	var sync := TickSync.new()
	_feed(sync, 1, -10, 1)
	# Mínimo -10 con objetivo 1: 1 + (1 - -10) = 12 pasos en el mismo tick.
	assert_eq(sync.next_steps(100), 12, "resincronización dura")
	assert_eq(sync.adjustments, 1, "un ajuste")
	assert_eq(sync.next_steps(112), 1, "y el ritmo normal después")

	var limit := TickSync.new()
	_feed(limit, 1, -100, 1)
	assert_eq(limit.next_steps(100), TickSync.MAX_RESYNC_STEPS, "30 pasos como mucho")

	var edge := TickSync.new()
	_feed(edge, 1, TickSync.RESYNC_BEHIND, 1)
	assert_eq(edge.next_steps(100), 10, "-8 ya es resincronización: 1 + (1 + 8)")

	var proportional := TickSync.new()
	_feed(proportional, 1, TickSync.RESYNC_BEHIND + 1, 1)
	var steps: Array[int] = []
	var predicted: int = 100
	for _i: int in 9:
		var count: int = proportional.next_steps(predicted)
		steps.append(count)
		predicted += count
	assert_eq(steps, [2, 2, 2, 2, 2, 2, 2, 2, 1] as Array[int],
			"-7 se paga con ocho pasos dobles en ticks seguidos")


func test_never_steps_backwards() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = RANDOM_SEED
	var sync := TickSync.new()
	var predicted: int = 1000
	var previous: int = 1
	var total_steps: int = 0
	for i: int in 3000:
		if i % 7 == 0:
			sync.set_jitter(rng.randf() * 3.0)
		if i % 2 == 0:
			var margin: int = rng.randi_range(-30, 12) if rng.randf() < 0.9 else NO_MARGIN
			sync.on_snapshot(predicted - rng.randi_range(0, 3), margin)
		var steps: int = sync.next_steps(predicted)
		assert_true(steps >= 0 and steps <= TickSync.MAX_RESYNC_STEPS,
				"pasos fuera de [0, 30]: %d" % steps)
		assert_false(steps == 0 and previous == 0, "nunca dos ticks seguidos sin paso")
		previous = steps
		predicted += steps
		total_steps += steps
	assert_true(predicted >= 1000, "el tick predicho nunca retrocede")
	assert_true(total_steps > 1500, "avanza de forma sostenida (%d pasos en 3000 ticks)" %
			total_steps)


func _feed(sync: TickSync, ack_tick: int, margin: int, count: int) -> void:
	for _i: int in count:
		sync.on_snapshot(ack_tick, margin)
