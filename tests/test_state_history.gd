extends TestCase
## Pruebas del historial de posiciones para la compensación de latencia ([StateHistory], docs/red.md
## sección 10): muestras exactas y fraccionarias, sobrescritura del anillo de 64 ticks,
## teletransporte y [method StateHistory.forget].

const GROUNDED: int = EntityRecord.FLAG_GROUNDED


## Flags de un registro con ese contador de teletransporte.
static func _flags(teleport_counter: int, grounded: bool = true) -> int:
	var value: int = (teleport_counter & EntityRecord.TELEPORT_MASK) << EntityRecord.TELEPORT_SHIFT
	return value | (GROUNDED if grounded else 0)


## Posición de la trayectoria de prueba en el tick t: una recta.
static func _path(tick: int) -> Vector3:
	return Vector3(float(tick), 2.0 * float(tick), -float(tick))


func test_record_and_exact_sample() -> void:
	var history := StateHistory.new()
	history.add_entity(7)
	history.record(10, 7, Vector3(1, 2, 3), 0.5, _flags(0))
	assert_true(history.has_tick(7, 10), "el tick 10 está")
	assert_false(history.has_tick(7, 9), "el 9 no")
	assert_false(history.has_tick(7, 11), "el 11 no")
	var sample: StateHistory.Sample = history.sample(7, 10.0)
	if not assert_not_null(sample, "muestra exacta"):
		return
	assert_vec_near(sample.position, Vector3(1, 2, 3), 1e-6, "posición")
	assert_near(sample.yaw, 0.5, 1e-6, "yaw")
	assert_eq(sample.flags, _flags(0), "flags")


func test_values_are_stored_without_quantization() -> void:
	# A diferencia del registro de red, el historial no redondea a 1 cm.
	var history := StateHistory.new()
	history.add_entity(1)
	var exact := Vector3(123.456789, -0.000123, 99.999)
	history.record(5, 1, exact, 1.2345678, 0)
	var sample: StateHistory.Sample = history.sample(1, 5.0)
	assert_vec_near(sample.position, exact, 1e-9, "posición sin cuantizar")
	assert_near(sample.yaw, PlayerState.to_f32(1.2345678), 1e-9, "yaw guardado en f32")


func test_fractional_sample_interpolates_position() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(10, 1, Vector3(0, 0, 0), 0.0, _flags(0))
	history.record(11, 1, Vector3(10, 4, -2), 0.0, _flags(0))
	var sample: StateHistory.Sample = history.sample(1, 10.25)
	if not assert_not_null(sample, "entre los ticks 10 y 11"):
		return
	assert_vec_near(sample.position, Vector3(2.5, 1, -0.5), 1e-5, "un cuarto del camino")
	assert_vec_near(history.sample(1, 10.5).position, Vector3(5, 2, -1), 1e-5, "la mitad")
	assert_vec_near(history.sample(1, 10.75).position, Vector3(7.5, 3, -1.5), 1e-5, "tres cuartos")
	assert_vec_near(history.sample(1, 11.0).position, Vector3(10, 4, -2), 1e-6, "el tick 11 exacto")


func test_yaw_interpolates_the_short_way_around() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(1, 1, Vector3.ZERO, 3.0, 0)
	history.record(2, 1, Vector3.ZERO, -3.0, 0)
	var sample: StateHistory.Sample = history.sample(1, 1.5)
	assert_near(absf(angle_difference(sample.yaw, PI)), 0.0, 1e-4,
			"de 3,0 a -3,0 pasa por PI, no por 0")
	history.record(3, 1, Vector3.ZERO, 0.2, 0)
	history.record(4, 1, Vector3.ZERO, 0.6, 0)
	assert_near(history.sample(1, 3.5).yaw, 0.4, 1e-5, "interpolación normal")


func test_flags_come_from_the_nearest_sample() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(1, 1, Vector3.ZERO, 0.0, _flags(0, true))
	history.record(2, 1, Vector3.ZERO, 0.0, _flags(0, false))
	assert_eq(history.sample(1, 1.25).flags, _flags(0, true), "más cerca del tick 1")
	assert_eq(history.sample(1, 1.75).flags, _flags(0, false), "más cerca del tick 2")


func test_out_of_range_is_null() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	assert_null(history.sample(1, 5.0), "pista vacía")
	for tick: int in range(10, 21):
		history.record(tick, 1, _path(tick), 0.0, 0)
	assert_null(history.sample(1, 9.0), "antes del primero")
	assert_null(history.sample(1, 9.5), "entre un tick que no existe y el primero")
	assert_not_null(history.sample(1, 10.0), "el primero")
	assert_not_null(history.sample(1, 19.5), "entre los dos últimos")
	assert_not_null(history.sample(1, 20.0), "el último")
	assert_null(history.sample(1, 20.5), "más allá del último: no se extrapola")
	assert_null(history.sample(1, 21.0), "un tick por delante")
	assert_null(history.sample(1, -1.0), "tick negativo")
	assert_null(history.sample(1, NAN), "NaN")
	assert_null(history.sample(1, INF), "infinito")


func test_unknown_entity_is_null() -> void:
	var history := StateHistory.new()
	assert_null(history.sample(99, 1.0), "sin pista")
	assert_false(history.has_tick(99, 1), "has_tick sin pista")


func test_ring_overwrites_ticks_older_than_64() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	for tick: int in range(1, 101):
		history.record(tick, 1, _path(tick), 0.0, 0)
	assert_eq(StateHistory.LENGTH_TICKS, 64, "64 ticks")
	for tick: int in range(1, 37):
		assert_false(history.has_tick(1, tick), "el tick %d ya se sobrescribió" % tick)
		assert_null(history.sample(1, float(tick)), "y no se puede muestrear")
	for tick: int in range(37, 101):
		assert_true(history.has_tick(1, tick), "el tick %d sigue" % tick)
		assert_vec_near(history.sample(1, float(tick)).position, _path(tick), 1e-4,
				"tick %d" % tick)
	assert_null(history.sample(1, 36.5), "entre el último sobrescrito y el más viejo")
	assert_vec_near(history.sample(1, 37.5).position, _path(37) + Vector3(0.5, 1.0, -0.5), 1e-4,
			"fraccionario en el borde del anillo")


func test_ring_survives_a_gap_in_the_records() -> void:
	# Si faltan ticks (la entidad no se grabó), esos huecos quedan fuera de rango.
	var history := StateHistory.new()
	history.add_entity(1)
	for tick: int in [10, 11, 12, 20, 21]:
		history.record(tick, 1, _path(tick), 0.0, 0)
	assert_not_null(history.sample(1, 11.5), "entre 11 y 12")
	assert_null(history.sample(1, 15.0), "tick sin grabar")
	assert_null(history.sample(1, 12.5), "entre 12 y el hueco")
	assert_not_null(history.sample(1, 20.5), "entre 20 y 21")


func test_teleport_counter_change_returns_the_previous_sample() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(10, 1, Vector3(0, 0, 0), 0.1, _flags(0))
	history.record(11, 1, Vector3(1, 0, 0), 0.2, _flags(0))
	history.record(12, 1, Vector3(500, 0, 0), 0.9, _flags(1))
	history.record(13, 1, Vector3(501, 0, 0), 1.0, _flags(1))
	# Entre 11 y 12 hay un teletransporte: no se interpola, se queda en el tick 11.
	var across: StateHistory.Sample = history.sample(1, 11.5)
	assert_vec_near(across.position, Vector3(1, 0, 0), 1e-6, "se queda en la muestra anterior")
	assert_near(across.yaw, 0.2, 1e-6, "con su yaw")
	assert_eq(across.flags, _flags(0), "y sus flags")
	assert_vec_near(history.sample(1, 11.99).position, Vector3(1, 0, 0), 1e-6,
			"hasta justo antes del tick 12")
	assert_vec_near(history.sample(1, 12.0).position, Vector3(500, 0, 0), 1e-6, "el 12 exacto")
	# A un lado y otro del salto sí se interpola.
	assert_vec_near(history.sample(1, 10.5).position, Vector3(0.5, 0, 0), 1e-6, "antes del salto")
	assert_vec_near(history.sample(1, 12.5).position, Vector3(500.5, 0, 0), 1e-4,
			"después del salto")


func test_teleport_counter_wraps_modulo_four() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(1, 1, Vector3(0, 0, 0), 0.0, _flags(3))
	history.record(2, 1, Vector3(9, 0, 0), 0.0, _flags(0))
	assert_vec_near(history.sample(1, 1.5).position, Vector3.ZERO, 1e-6,
			"del contador 3 al 0 también es un teletransporte")
	history.record(3, 1, Vector3(9, 0, 0), 0.0, _flags(0, false))
	assert_vec_near(history.sample(1, 2.5).position, Vector3(9, 0, 0), 1e-6,
			"cambiar solo grounded no lo es")


func test_forget_removes_only_that_entity() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.add_entity(2)
	history.record(5, 1, _path(5), 0.0, 0)
	history.record(5, 2, _path(6), 0.0, 0)
	history.forget(1)
	assert_false(history.has_tick(1, 5), "la pista olvidada no tiene ticks")
	assert_null(history.sample(1, 5.0), "ni se puede muestrear")
	assert_true(history.has_tick(2, 5), "la otra sigue")
	assert_vec_near(history.sample(2, 5.0).position, _path(6), 1e-5, "con sus datos")
	history.forget(1)
	history.forget(404)
	assert_true(history.has_tick(2, 5), "olvidar dos veces o un id desconocido no rompe nada")


func test_add_entity_resets_an_existing_track() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(5, 1, _path(5), 0.0, 0)
	history.add_entity(1)
	assert_false(history.has_tick(1, 5), "una pista nueva empieza vacía")
	history.record(6, 1, _path(6), 0.0, 0)
	assert_true(history.has_tick(1, 6), "y se puede grabar de nuevo")


func test_record_without_add_entity_creates_the_track() -> void:
	var history := StateHistory.new()
	history.record(3, 5, _path(3), 0.0, 0)
	assert_true(history.has_tick(5, 3), "se crea la pista al grabar")
	history.record(-1, 6, _path(1), 0.0, 0)
	assert_false(history.has_tick(6, -1), "un tick negativo se ignora")
	assert_null(history.sample(6, 0.0), "y no crea pista")


func test_entities_do_not_share_slots() -> void:
	var history := StateHistory.new()
	for net_id: int in range(1, 6):
		history.add_entity(net_id)
	for tick: int in range(1, 40):
		for net_id: int in range(1, 6):
			history.record(tick, net_id, _path(tick) + Vector3(0, 0, 1000.0 * net_id), 0.0, 0)
	for net_id: int in range(1, 6):
		var sample: StateHistory.Sample = history.sample(net_id, 20.5)
		assert_vec_near(sample.position, _path(20) + Vector3(0.5, 1.0, -0.5)
				+ Vector3(0, 0, 1000.0 * net_id), 1e-3, "entidad %d" % net_id)


func test_random_fractional_samples_match_the_path() -> void:
	# Propiedad: sobre una recta, la muestra en cualquier instante dentro del anillo es la recta.
	var history := StateHistory.new()
	history.add_entity(1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var checked: int = 0
	for tick: int in range(1, 1001):
		history.record(tick, 1, _path(tick), 0.0, 0)
		if tick < 64:
			continue
		for _i: int in 3:
			var instant: float = float(tick) - rng.randf_range(0.0, 63.0)
			var sample: StateHistory.Sample = history.sample(1, instant)
			if sample == null:
				fail("no hay muestra en %f con el último tick %d" % [instant, tick])
				return
			var expected: Vector3 = Vector3(instant, 2.0 * instant, -instant)
			if not sample.position.is_equal_approx(expected) \
					and sample.position.distance_to(expected) > 1e-2:
				fail("muestra %s en %f, se esperaba %s" % [sample.position, instant, expected])
				return
			checked += 1
	assert_true(checked > 2000, "se comprobaron muchas muestras (%d)" % checked)


## Los ticks del servidor son u32 (414 días a 60 Hz ya pasan de 2^31): las etiquetas de la pista no
## pueden ser enteros de 32 bits con signo (hallazgo N5), o el historial queda inservible.
func test_ticks_beyond_two_to_the_thirty_one_are_kept() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	var big: int = 2147483648 + 5
	history.record(big, 1, Vector3(1.0, 2.0, 3.0), 0.5, 1)
	history.record(big + 1, 1, Vector3(3.0, 2.0, 3.0), 0.5, 1)
	assert_true(history.has_tick(1, big), "el tick 2^31 + 5 está grabado")
	assert_false(history.has_tick(1, big + 2), "y el siguiente aún no")
	var exact: StateHistory.Sample = history.sample(1, float(big))
	if assert_not_null(exact, "se puede muestrear"):
		assert_vec_near(exact.position, Vector3(1.0, 2.0, 3.0), 1e-6)
	var between: StateHistory.Sample = history.sample(1, float(big) + 0.5)
	if assert_not_null(between, "también entre dos ticks"):
		assert_vec_near(between.position, Vector3(2.0, 2.0, 3.0), 1e-6)
	var max_tick: int = 4294967295
	history.record(max_tick, 1, Vector3(9.0, 0.0, 0.0), 0.0, 1)
	assert_true(history.has_tick(1, max_tick), "ni en el último tick del u32")
