extends TestCase
## Pruebas de [RemoteInterpolator] (docs/red.md, secciones 7 y 16): anillo ordenado sin duplicados,
## interpolación lineal de posición y velocidad, [code]lerp_angle[/code] del yaw al cruzar ±PI,
## grounded de la muestra más cercana, extrapolación de 6 ticks y parada, y el contador de
## teletransporte.
## [br][br]
## La visibilidad según [code]spawn_tick[/code] y [code]despawn_tick[/code] (también de la sección
## 16) la gobierna [RemotePlayerView], no el interpolador.

const NET_ID: int = 7
const GROUNDED: int = EntityRecord.FLAG_GROUNDED


func test_empty_interpolator_has_nothing_to_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	assert_null(interpolator.sample(10.0), "sin muestras, sample() devuelve null")
	assert_eq(interpolator.get_newest_tick(), 0, "sin muestras, el tick más nuevo es 0")
	assert_eq(interpolator.get_sample_count(), 0, "ninguna muestra")


func test_single_sample_is_held_before_and_after() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(1.0, 2.0, 3.0), 0.5))
	for render_time: float in [0.0, 9.5, 10.0]:
		var sample: EntityRecord = interpolator.sample(render_time)
		assert_vec_near(sample.position, Vector3(1.0, 2.0, 3.0), 1e-6,
				"antes de la primera muestra (y en ella) se queda en la primera: t=%s" % render_time)
		assert_near(sample.yaw, 0.5, 1e-6, "yaw de la primera muestra: t=%s" % render_time)
	assert_eq(interpolator.get_newest_tick(), 10, "tick más nuevo")


func test_lerp_between_two_samples() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(0.0, 1.0, 0.0), 0.0, Vector3(2.0, 0.0, 0.0)))
	interpolator.push(12, _record(Vector3(4.0, 3.0, -8.0), 1.0, Vector3(6.0, 4.0, 0.0)))

	var at_start: EntityRecord = interpolator.sample(10.0)
	assert_vec_near(at_start.position, Vector3(0.0, 1.0, 0.0), 1e-6, "en la primera muestra")
	var quarter: EntityRecord = interpolator.sample(10.5)
	assert_vec_near(quarter.position, Vector3(1.0, 1.5, -2.0), 1e-6, "un cuarto del camino")
	assert_vec_near(quarter.velocity, Vector3(3.0, 1.0, 0.0), 1e-6, "la velocidad también se interpola")
	assert_near(quarter.yaw, 0.25, 1e-6, "yaw a un cuarto")
	var middle: EntityRecord = interpolator.sample(11.0)
	assert_vec_near(middle.position, Vector3(2.0, 2.0, -4.0), 1e-6, "mitad del camino")
	var three_quarters: EntityRecord = interpolator.sample(11.5)
	assert_vec_near(three_quarters.position, Vector3(3.0, 2.5, -6.0), 1e-6, "tres cuartos")
	assert_eq(middle.net_id, NET_ID, "conserva el identificador de red")


func test_sample_positions_are_the_raw_stored_samples_oldest_first() -> void:
	var interpolator := RemoteInterpolator.new()
	assert_eq(interpolator.get_sample_positions().size(), 0, "sin muestras, ninguna posición")
	# Llegan desordenadas: se guardan por tick y las posiciones salen de la más antigua a la más nueva.
	interpolator.push(14, _record(Vector3(14.0, 0.0, 0.0)))
	interpolator.push(10, _record(Vector3(10.0, 1.0, 0.0)))
	interpolator.push(12, _record(Vector3(12.0, 2.0, 0.0)))
	assert_eq(interpolator.get_sample_positions(), PackedVector3Array([
		Vector3(10.0, 1.0, 0.0), Vector3(12.0, 2.0, 0.0), Vector3(14.0, 0.0, 0.0),
	]), "sin interpolar, tal como llegaron")
	for tick: int in range(20, 20 + RemoteInterpolator.BUFFER_SIZE):
		interpolator.push(tick, _record(Vector3(float(tick), 0.0, 0.0)))
	var positions: PackedVector3Array = interpolator.get_sample_positions()
	assert_eq(positions.size(), RemoteInterpolator.BUFFER_SIZE, "como mucho BUFFER_SIZE")
	assert_eq(positions[positions.size() - 1].x, float(20 + RemoteInterpolator.BUFFER_SIZE - 1))


func test_interpolates_between_the_right_pair_of_samples() -> void:
	var interpolator := RemoteInterpolator.new()
	for tick: int in [10, 12, 14, 16]:
		interpolator.push(tick, _record(Vector3(float(tick), 0.0, 0.0)))
	assert_vec_near(interpolator.sample(11.0).position, Vector3(11.0, 0.0, 0.0), 1e-6, "entre 10 y 12")
	assert_vec_near(interpolator.sample(13.0).position, Vector3(13.0, 0.0, 0.0), 1e-6, "entre 12 y 14")
	assert_vec_near(interpolator.sample(15.5).position, Vector3(15.5, 0.0, 0.0), 1e-6, "entre 14 y 16")
	assert_vec_near(interpolator.sample(14.0).position, Vector3(14.0, 0.0, 0.0), 1e-6,
			"justo en una muestra intermedia")
	# Con huecos (snapshots perdidos) se interpola igual por el tiempo, no por el índice.
	var gaps := RemoteInterpolator.new()
	gaps.push(10, _record(Vector3(0.0, 0.0, 0.0)))
	gaps.push(16, _record(Vector3(6.0, 0.0, 0.0)))
	assert_vec_near(gaps.sample(13.0).position, Vector3(3.0, 0.0, 0.0), 1e-6, "salto de 6 ticks")


func test_yaw_uses_lerp_angle_across_pi() -> void:
	var interpolator := RemoteInterpolator.new()
	var near_positive_pi: float = PI - 0.1
	var near_negative_pi: float = -PI + 0.1
	interpolator.push(10, _record(Vector3.ZERO, near_positive_pi))
	interpolator.push(12, _record(Vector3.ZERO, near_negative_pi))
	var middle: EntityRecord = interpolator.sample(11.0)
	assert_near(absf(middle.yaw), PI, 1e-5, "por el camino corto pasa por ±PI, no por 0 (%s)" % middle.yaw)
	var quarter: EntityRecord = interpolator.sample(10.5)
	assert_near(angle_difference(near_positive_pi, quarter.yaw), 0.05, 1e-5,
			"un cuarto del giro corto (0,2 rad) son 0,05 rad")

	var backwards := RemoteInterpolator.new()
	backwards.push(10, _record(Vector3.ZERO, near_negative_pi))
	backwards.push(12, _record(Vector3.ZERO, near_positive_pi))
	assert_near(absf(backwards.sample(11.0).yaw), PI, 1e-5, "también en sentido contrario")
	assert_near(angle_difference(near_negative_pi, backwards.sample(10.5).yaw), -0.05, 1e-5,
			"y en el sentido correcto")


func test_grounded_comes_from_the_nearest_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO, 0.0, Vector3.ZERO, GROUNDED))
	interpolator.push(12, _record(Vector3(0.0, 1.0, 0.0), 0.0, Vector3.ZERO, 0))
	assert_true(interpolator.sample(10.0).is_grounded(), "en la primera muestra, en el suelo")
	assert_true(interpolator.sample(10.8).is_grounded(), "más cerca de la primera: en el suelo")
	assert_false(interpolator.sample(11.2).is_grounded(), "más cerca de la segunda: en el aire")
	assert_false(interpolator.sample(11.9).is_grounded(), "casi en la segunda: en el aire")


func test_extrapolates_horizontally_up_to_six_ticks_then_stands_still() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(0.0, 1.0, 0.0), 0.3, Vector3(6.0, 9.0, -3.0)))
	var per_tick: float = 1.0 / float(Engine.physics_ticks_per_second)

	var on_time: EntityRecord = interpolator.sample(10.0)
	assert_vec_near(on_time.position, Vector3(0.0, 1.0, 0.0), 1e-6, "en la última muestra, sin moverse")

	var half: EntityRecord = interpolator.sample(13.0)
	assert_vec_near(half.position, Vector3(6.0 * 3.0 * per_tick, 1.0, -3.0 * 3.0 * per_tick), 1e-6,
			"3 ticks por delante: velocidad horizontal x 3 ticks, sin tocar la altura")
	assert_vec_near(half.velocity, Vector3(6.0, 9.0, -3.0), 1e-6, "y conserva la velocidad")
	assert_near(half.yaw, 0.3, 1e-6, "el yaw no cambia")

	var limit: EntityRecord = interpolator.sample(10.0 + RemoteInterpolator.MAX_EXTRAPOLATION_TICKS)
	var limit_position: Vector3 = Vector3(6.0, 0.0, -3.0) * (6.0 * per_tick) + Vector3(0.0, 1.0, 0.0)
	assert_vec_near(limit.position, limit_position, 1e-6, "a los 6 ticks (100 ms) llega al límite")
	assert_vec_near(limit.velocity, Vector3(6.0, 9.0, -3.0), 1e-6, "en el límite aún se mueve")

	for ahead: float in [6.5, 7.0, 10.0, 60.0]:
		var stopped: EntityRecord = interpolator.sample(10.0 + ahead)
		assert_vec_near(stopped.position, limit_position, 1e-6,
				"%s ticks por delante se queda quieto en el límite" % ahead)
		assert_vec_near(stopped.velocity, Vector3.ZERO, 1e-6, "con velocidad 0 (%s ticks)" % ahead)


func test_new_sample_after_extrapolating_takes_over() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO, 0.0, Vector3(6.0, 0.0, 0.0)))
	var extrapolated: EntityRecord = interpolator.sample(12.0)
	assert_true(extrapolated.position.x > 0.0, "extrapola")
	# Llega la muestra siguiente (con un salto respecto a lo extrapolado): ya se interpola entre las dos.
	interpolator.push(14, _record(Vector3(1.0, 0.0, 0.0), 0.0, Vector3(6.0, 0.0, 0.0)))
	assert_vec_near(interpolator.sample(12.0).position, Vector3(0.5, 0.0, 0.0), 1e-6,
			"con la muestra nueva el mismo instante se interpola")
	assert_eq(interpolator.get_newest_tick(), 14, "tick más nuevo")


func test_teleport_counter_change_holds_the_first_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(0.0, 0.0, 0.0), 0.0, Vector3.ZERO, GROUNDED, 0))
	interpolator.push(12, _record(Vector3(100.0, 0.0, 0.0), 1.0, Vector3.ZERO, GROUNDED, 1))
	for render_time: float in [10.0, 10.5, 11.0, 11.99]:
		var held: EntityRecord = interpolator.sample(render_time)
		assert_vec_near(held.position, Vector3.ZERO, 1e-6,
				"cambia el contador: no se interpola, se queda en la primera (t=%s)" % render_time)
		assert_near(held.yaw, 0.0, 1e-6, "ni el yaw (t=%s)" % render_time)
		assert_eq(held.get_teleport_counter(), 0, "con su contador (t=%s)" % render_time)
	var arrived: EntityRecord = interpolator.sample(12.0)
	assert_vec_near(arrived.position, Vector3(100.0, 0.0, 0.0), 1e-6, "al alcanzar la segunda, está en ella")
	assert_eq(arrived.get_teleport_counter(), 1, "con su contador")

	# Después del teletransporte, con el mismo contador, se vuelve a interpolar.
	interpolator.push(14, _record(Vector3(102.0, 0.0, 0.0), 1.0, Vector3.ZERO, GROUNDED, 1))
	assert_vec_near(interpolator.sample(13.0).position, Vector3(101.0, 0.0, 0.0), 1e-6,
			"mismo contador: se interpola")
	assert_vec_near(interpolator.sample(11.5).position, Vector3.ZERO, 1e-6,
			"y lo anterior sigue sin interpolar")


func test_teleport_counter_wraps_modulo_four() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO, 0.0, Vector3.ZERO, 0, 3))
	interpolator.push(12, _record(Vector3(50.0, 0.0, 0.0), 0.0, Vector3.ZERO, 0, 0))
	assert_vec_near(interpolator.sample(11.0).position, Vector3.ZERO, 1e-6,
			"del contador 3 al 0 también es un teletransporte")


func test_samples_are_kept_sorted_and_duplicates_are_dropped() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(10.0, 0.0, 0.0)))
	interpolator.push(14, _record(Vector3(14.0, 0.0, 0.0)))
	interpolator.push(12, _record(Vector3(12.0, 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), 3, "tres muestras")
	assert_eq(interpolator.get_oldest_tick(), 10, "la más antigua")
	assert_eq(interpolator.get_newest_tick(), 14, "la más nueva, aunque no llegó la última")
	assert_vec_near(interpolator.sample(11.0).position, Vector3(11.0, 0.0, 0.0), 1e-6,
			"la desordenada se inserta en su sitio")
	assert_vec_near(interpolator.sample(13.0).position, Vector3(13.0, 0.0, 0.0), 1e-6, "y es la intermedia")

	interpolator.push(12, _record(Vector3(999.0, 0.0, 0.0)))
	interpolator.push(14, _record(Vector3(999.0, 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), 3, "los duplicados se descartan")
	assert_vec_near(interpolator.sample(12.0).position, Vector3(12.0, 0.0, 0.0), 1e-6,
			"gana la primera copia")
	interpolator.push(11, null)
	assert_eq(interpolator.get_sample_count(), 3, "un registro null se ignora")


func test_ring_keeps_the_newest_thirty_two_samples() -> void:
	var interpolator := RemoteInterpolator.new()
	for tick: int in range(1, 41):
		interpolator.push(tick * 2, _record(Vector3(float(tick), 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), RemoteInterpolator.BUFFER_SIZE, "32 muestras como mucho")
	assert_eq(interpolator.get_newest_tick(), 80, "la más nueva")
	assert_eq(interpolator.get_oldest_tick(), 18, "las 8 más antiguas salieron de la ventana")
	interpolator.push(4, _record(Vector3(999.0, 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), RemoteInterpolator.BUFFER_SIZE,
			"una muestra más antigua que la ventana se descarta")
	assert_eq(interpolator.get_oldest_tick(), 18, "sin cambiar la ventana")
	# Una desordenada que sí cabe en la ventana desplaza a la más antigua.
	interpolator.push(19, _record(Vector3(19.0, 0.0, 0.0)))
	assert_eq(interpolator.get_oldest_tick(), 19,
			"una desordenada dentro de la ventana entra y desplaza a la más antigua")
	assert_vec_near(interpolator.sample(19.0).position, Vector3(19.0, 0.0, 0.0), 1e-6, "y se usa")


func test_sample_returns_a_new_record_each_time() -> void:
	var interpolator := RemoteInterpolator.new()
	var original: EntityRecord = _record(Vector3(1.0, 0.0, 0.0))
	interpolator.push(10, original)
	interpolator.push(12, _record(Vector3(3.0, 0.0, 0.0)))
	for render_time: float in [5.0, 10.0, 11.0, 12.0, 20.0]:
		var sample: EntityRecord = interpolator.sample(render_time)
		sample.position = Vector3(-99.0, -99.0, -99.0)
		sample.flags = 0xFF
	assert_vec_near(original.position, Vector3(1.0, 0.0, 0.0), 1e-9,
			"modificar lo devuelto no toca las muestras guardadas")
	assert_vec_near(interpolator.sample(10.0).position, Vector3(1.0, 0.0, 0.0), 1e-9, "ni las siguientes")
	assert_eq(interpolator.sample(10.0).flags, 0, "ni sus flags")


func test_clear_forgets_every_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO))
	interpolator.clear()
	assert_null(interpolator.sample(10.0), "sin muestras")
	assert_eq(interpolator.get_newest_tick(), 0, "sin tick más nuevo")


# --- Con el reloj de interpolación -----------------------------------------------------------------

func test_clock_and_interpolator_draw_a_stream_without_loss_always_between_two_samples() -> void:
	var result: Dictionary = _draw_stream(3, 3, 0.0)
	assert_true(result["frames"] > 1000, "hay fotogramas que medir (%d)" % result["frames"])
	assert_eq(result["extrapolated"], 0, "sin pérdidas siempre se dibuja entre dos muestras")
	assert_eq(result["held"], 0, "y nunca por detrás de la más antigua")
	assert_true(result["worst_error"] < 1e-4, "la posición dibujada sigue a la real (%s m)"
			% result["worst_error"])
	assert_near(result["average_delay"], InterpolationClock.MIN_DELAY_TICKS, 1e-6,
			"sin jitter, el retardo es el mínimo (4 ticks)")


func test_clock_and_interpolator_draw_a_lossy_jittery_stream_mostly_between_samples() -> void:
	# Snapshots a 30 Hz que tardan entre 3 y 6 ticks y se pierden el 10 %.
	var result: Dictionary = _draw_stream(3, 6, 0.1)
	assert_true(result["worst_error"] < 1e-3, "y el movimiento dibujado sigue siendo el real (%s m)"
			% result["worst_error"])
	assert_true(result["average_delay"] > InterpolationClock.MIN_DELAY_TICKS + 1.0,
			"el jitter sube el retardo (%s ticks)" % result["average_delay"])
	var extrapolated_share: float = float(result["extrapolated"]) / float(result["frames"])
	assert_true(extrapolated_share < 0.08,
			"se extrapola en menos del 8 %% de los fotogramas (%s)" % extrapolated_share)
	assert_eq(result["held"], 0, "y nunca se queda por detrás de la más antigua")


## Un remoto que corre a 5 m/s en X. Sus snapshots (uno cada 2 ticks del servidor) llegan al cliente
## con un retardo de entre [param min_delay] y [param max_delay] ticks y se pierde la fracción
## [param loss]. Cada tick local el reloj avanza y se muestrea el interpolador en
## [code]render_tick + 0.5[/code]. Devuelve cuántos fotogramas (a partir del 300) cayeron por
## delante de la última muestra (extrapolación) o por detrás de la primera, el peor error de
## posición y el retardo medio del reloj.
func _draw_stream(min_delay: int, max_delay: int, loss: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var clock := InterpolationClock.new()
	var interpolator := RemoteInterpolator.new()
	var arrivals: Dictionary = {}
	var speed: float = 5.0
	var per_tick: float = speed / float(Engine.physics_ticks_per_second)
	var frames: int = 0
	var extrapolated: int = 0
	var held: int = 0
	var worst_error: float = 0.0
	var delay_sum: float = 0.0
	for frame: int in range(1, 1500):
		var server_tick: int = frame + 100
		if server_tick % 2 == 0 and rng.randf() >= loss:
			var arrival: int = frame + rng.randi_range(min_delay, max_delay)
			if not arrivals.has(arrival):
				arrivals[arrival] = []
			(arrivals[arrival] as Array).append(server_tick)
		for tick: int in arrivals.get(frame, []):
			var sample := EntityRecord.new()
			sample.position = Vector3(float(tick) * per_tick, 0.0, 0.0)
			sample.velocity = Vector3(speed, 0.0, 0.0)
			interpolator.push(tick, sample)
			clock.on_snapshot(tick, frame)
		var render_time: float = clock.advance(frame) + 0.5
		if frame < 300 or interpolator.get_sample_count() == 0:
			continue
		frames += 1
		delay_sum += clock.get_delay_ticks()
		if render_time > float(interpolator.get_newest_tick()):
			extrapolated += 1
		if render_time < float(interpolator.get_oldest_tick()):
			held += 1
		var drawn: EntityRecord = interpolator.sample(render_time)
		worst_error = maxf(worst_error, absf(drawn.position.x - render_time * per_tick))
	return {
		"frames": frames, "extrapolated": extrapolated, "held": held, "worst_error": worst_error,
		"average_delay": delay_sum / float(maxi(frames, 1)),
	}


func _record(position: Vector3, yaw: float = 0.0, velocity: Vector3 = Vector3.ZERO,
		flags: int = 0, teleport_counter: int = 0) -> EntityRecord:
	var record := EntityRecord.new()
	record.net_id = NET_ID
	record.position = position
	record.yaw = yaw
	record.velocity = velocity
	record.flags = flags | (teleport_counter << EntityRecord.TELEPORT_SHIFT)
	return record
