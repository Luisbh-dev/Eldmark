extends TestCase
## Pruebas de [Ballistics] (docs/habilidades.md, sección 4.4): la posición de un proyectil tras n
## ticks (entero o fraccionario) y la cuantización con la que viaja en el ENTITY_SPAWN.

const GRAVITY: float = 6.0


func test_position_follows_the_formula() -> void:
	var p0 := Vector3(1.0, 2.0, -3.0)
	var v0 := Vector3(10.0, 5.0, -20.0)
	assert_eq(Ballistics.position(p0, v0, GRAVITY, 0.0), p0, "en n = 0 está en el origen")
	# Tras 60 ticks (1 s): p0 + v0 - (0, g/2, 0).
	assert_vec_near(Ballistics.position(p0, v0, GRAVITY, 60.0), Vector3(11.0, 4.0, -23.0), 1e-5,
			"tras un segundo")
	# Tras 30 ticks (0,5 s): p0 + v0/2 - (0, g/8, 0).
	assert_vec_near(Ballistics.position(p0, v0, GRAVITY, 30.0), Vector3(6.0, 3.75, -13.0), 1e-5,
			"tras medio segundo")
	# Un n fraccionario (el dibujo) cae entre los enteros y en la misma parábola.
	var halfway: Vector3 = Ballistics.position(p0, v0, GRAVITY, 30.5)
	var t: float = 30.5 / 60.0
	assert_vec_near(halfway, p0 + v0 * t + Vector3(0.0, -0.5 * GRAVITY * t * t, 0.0), 1e-5,
			"n fraccionario")
	assert_eq(Ballistics.position(p0, v0, GRAVITY, 45), Ballistics.position(p0, v0, GRAVITY, 45.0),
			"n entero y n como float dan lo mismo (servidor y dibujo)")


func test_apex_and_symmetry() -> void:
	# Lanzada hacia arriba a g m/s, sube durante 1 s y vuelve a su altura a los 2 s.
	var p0 := Vector3(0.0, 1.5, 0.0)
	var v0 := Vector3(0.0, GRAVITY, 0.0)
	var apex: Vector3 = Ballistics.position(p0, v0, GRAVITY, 60.0)
	assert_near(apex.y, 1.5 + GRAVITY * 0.5, 1e-5, "cumbre a g/2 m sobre el origen")
	for n: int in [10, 30, 59]:
		var before: Vector3 = Ballistics.position(p0, v0, GRAVITY, 60.0 - n)
		var after: Vector3 = Ballistics.position(p0, v0, GRAVITY, 60.0 + n)
		assert_near(before.y, after.y, 1e-5, "simétrica a %d ticks de la cumbre" % n)
	assert_near(Ballistics.position(p0, v0, GRAVITY, 120.0).y, 1.5, 1e-5, "vuelve a su altura")


func test_flight_numbers_of_the_design() -> void:
	# docs/habilidades.md, sección 2.4: el tensado máximo (70 m/s) tarda 0,71 s en 50 m y cae 1,5 m;
	# el rápido (45 m/s), 1,11 s y 3,7 m.
	var drawn_ticks: float = 50.0 / 70.0 * 60.0
	var drawn: Vector3 = Ballistics.position(Vector3.ZERO, Vector3(0.0, 0.0, -70.0), GRAVITY, drawn_ticks)
	assert_near(drawn.z, -50.0, 1e-4, "50 m")
	assert_near(drawn.y, -1.53, 0.01, "cae 1,5 m")
	var quick_ticks: float = 50.0 / 45.0 * 60.0
	var quick: Vector3 = Ballistics.position(Vector3.ZERO, Vector3(0.0, 0.0, -45.0), GRAVITY, quick_ticks)
	assert_near(quick_ticks / 60.0, 1.11, 0.005, "1,11 s")
	assert_near(quick.y, -3.70, 0.01, "cae 3,7 m")


func test_quantize_rounds_like_the_spawn() -> void:
	var result: Array = Ballistics.quantize(Vector3(1.234, -5.678, 100.006), Vector3(44.999, -0.004, 12.3456))
	if not assert_eq(result.size(), 2, "[p0, v0]"):
		return
	var p0: Vector3 = result[0]
	var v0: Vector3 = result[1]
	assert_vec_near(p0, Vector3(1.23, -5.68, 100.01), 1e-4, "posición a 1 cm")
	assert_vec_near(v0, Vector3(45.0, 0.0, 12.35), 1e-4, "velocidad a 1 cm/s")
	# Es lo que da el registro de entidad (20 bits por eje) y el s16 de cm/s de la velocidad.
	assert_eq(p0, NetMath.unpack_position(NetMath.pack_position(Vector3(1.234, -5.678, 100.006))),
			"como NetMath.pack_position")
	assert_eq(v0.x, NetMath.dequantize_velocity(NetMath.quantize_velocity(44.999)),
			"como NetMath.quantize_velocity")
	# Idempotente: cuantizar lo cuantizado no cambia nada (el cliente repite la del servidor).
	var again: Array = Ballistics.quantize(p0, v0)
	assert_eq(again[0], p0, "posición idempotente")
	assert_eq(again[1], v0, "velocidad idempotente")


func test_quantize_saturates_and_handles_nan() -> void:
	var result: Array = Ballistics.quantize(Vector3(NAN, 0.0, 0.0), Vector3(400.0, -400.0, NAN))
	var p0: Vector3 = result[0]
	var v0: Vector3 = result[1]
	assert_eq(p0.x, 0.0, "un NaN de posición es 0")
	assert_eq(v0, Vector3(327.67, -327.68, 0.0), "la velocidad satura a s16 de cm/s y el NaN es 0")


func test_server_and_client_get_the_same_trajectory_from_the_spawn() -> void:
	# El servidor vuela con lo cuantizado; el cliente lo recibe por el SPAWN (que cuantiza igual) y
	# llama a la misma función: las posiciones de cada tick coinciden bit a bit.
	var quantized: Array = Ballistics.quantize(Vector3(10.123, 1.4, -7.777), Vector3(31.2, 4.05, -30.01))
	var spawn_p0: Vector3 = NetMath.unpack_position(NetMath.pack_position(quantized[0]))
	var spawn_v0: Vector3 = Vector3(
		NetMath.dequantize_velocity(NetMath.quantize_velocity(quantized[1].x)),
		NetMath.dequantize_velocity(NetMath.quantize_velocity(quantized[1].y)),
		NetMath.dequantize_velocity(NetMath.quantize_velocity(quantized[1].z)),
	)
	for n: int in 121:
		var server: Vector3 = Ballistics.position(quantized[0], quantized[1], GRAVITY, n)
		var client: Vector3 = Ballistics.position(spawn_p0, spawn_v0, GRAVITY, float(n))
		if server != client:
			fail("tick %d: servidor %s, cliente %s" % [n, server, client])
			return
