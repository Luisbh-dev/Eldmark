extends TestCase
## Tests of [Ballistics] (docs/habilidades.md, section 4.4): the position of a projectile after n
## ticks (integer or fractional) and the quantization with which it travels in the ENTITY_SPAWN.

const GRAVITY: float = 6.0


func test_position_follows_the_formula() -> void:
	var p0 := Vector3(1.0, 2.0, -3.0)
	var v0 := Vector3(10.0, 5.0, -20.0)
	assert_eq(Ballistics.position(p0, v0, GRAVITY, 0.0), p0, "at n = 0 it is at the origin")
	# After 60 ticks (1 s): p0 + v0 - (0, g/2, 0).
	assert_vec_near(Ballistics.position(p0, v0, GRAVITY, 60.0), Vector3(11.0, 4.0, -23.0), 1e-5,
			"after one second")
	# After 30 ticks (0.5 s): p0 + v0/2 - (0, g/8, 0).
	assert_vec_near(Ballistics.position(p0, v0, GRAVITY, 30.0), Vector3(6.0, 3.75, -13.0), 1e-5,
			"after half a second")
	# A fractional n (the drawing) falls between the integers and on the same parabola.
	var halfway: Vector3 = Ballistics.position(p0, v0, GRAVITY, 30.5)
	var t: float = 30.5 / 60.0
	assert_vec_near(halfway, p0 + v0 * t + Vector3(0.0, -0.5 * GRAVITY * t * t, 0.0), 1e-5,
			"fractional n")
	assert_eq(Ballistics.position(p0, v0, GRAVITY, 45), Ballistics.position(p0, v0, GRAVITY, 45.0),
			"integer n and n as a float give the same (server and drawing)")


func test_apex_and_symmetry() -> void:
	# Launched upward at g m/s, it rises for 1 s and returns to its height at 2 s.
	var p0 := Vector3(0.0, 1.5, 0.0)
	var v0 := Vector3(0.0, GRAVITY, 0.0)
	var apex: Vector3 = Ballistics.position(p0, v0, GRAVITY, 60.0)
	assert_near(apex.y, 1.5 + GRAVITY * 0.5, 1e-5, "peak at g/2 m above the origin")
	for n: int in [10, 30, 59]:
		var before: Vector3 = Ballistics.position(p0, v0, GRAVITY, 60.0 - n)
		var after: Vector3 = Ballistics.position(p0, v0, GRAVITY, 60.0 + n)
		assert_near(before.y, after.y, 1e-5, "symmetric at %d ticks from the peak" % n)
	assert_near(Ballistics.position(p0, v0, GRAVITY, 120.0).y, 1.5, 1e-5, "returns to its height")


func test_flight_numbers_of_the_design() -> void:
	# docs/habilidades.md, section 2.4: the maximum draw (70 m/s) takes 0.71 s over 50 m and drops 1.5 m;
	# the quick one (45 m/s), 1.11 s and 3.7 m.
	var drawn_ticks: float = 50.0 / 70.0 * 60.0
	var drawn: Vector3 = Ballistics.position(Vector3.ZERO, Vector3(0.0, 0.0, -70.0), GRAVITY, drawn_ticks)
	assert_near(drawn.z, -50.0, 1e-4, "50 m")
	assert_near(drawn.y, -1.53, 0.01, "drops 1.5 m")
	var quick_ticks: float = 50.0 / 45.0 * 60.0
	var quick: Vector3 = Ballistics.position(Vector3.ZERO, Vector3(0.0, 0.0, -45.0), GRAVITY, quick_ticks)
	assert_near(quick_ticks / 60.0, 1.11, 0.005, "1,11 s")
	assert_near(quick.y, -3.70, 0.01, "drops 3.7 m")


func test_quantize_rounds_like_the_spawn() -> void:
	var result: Array = Ballistics.quantize(Vector3(1.234, -5.678, 100.006), Vector3(44.999, -0.004, 12.3456))
	if not assert_eq(result.size(), 2, "[p0, v0]"):
		return
	var p0: Vector3 = result[0]
	var v0: Vector3 = result[1]
	assert_vec_near(p0, Vector3(1.23, -5.68, 100.01), 1e-4, "position to 1 cm")
	assert_vec_near(v0, Vector3(45.0, 0.0, 12.35), 1e-4, "velocity to 1 cm/s")
	# It is what the entity record gives (20 bits per axis) and the s16 of cm/s of the velocity.
	assert_eq(p0, NetMath.unpack_position(NetMath.pack_position(Vector3(1.234, -5.678, 100.006))),
			"like NetMath.pack_position")
	assert_eq(v0.x, NetMath.dequantize_velocity(NetMath.quantize_velocity(44.999)),
			"like NetMath.quantize_velocity")
	# Idempotent: quantizing what is already quantized changes nothing (the client repeats the server's).
	var again: Array = Ballistics.quantize(p0, v0)
	assert_eq(again[0], p0, "idempotent position")
	assert_eq(again[1], v0, "idempotent velocity")


func test_quantize_saturates_and_handles_nan() -> void:
	var result: Array = Ballistics.quantize(Vector3(NAN, 0.0, 0.0), Vector3(400.0, -400.0, NAN))
	var p0: Vector3 = result[0]
	var v0: Vector3 = result[1]
	assert_eq(p0.x, 0.0, "a NaN position is 0")
	assert_eq(v0, Vector3(327.67, -327.68, 0.0), "the velocity saturates at s16 of cm/s and NaN is 0")


func test_server_and_client_get_the_same_trajectory_from_the_spawn() -> void:
	# The server flies with the quantized values; the client receives them through the SPAWN (which quantizes the same way) and
	# calls the same function: the positions of each tick match bit for bit.
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
			fail("tick %d: server %s, client %s" % [n, server, client])
			return


func test_solve_lead_hits_a_moving_target() -> void:
	var origin := Vector3(0.0, 1.4, 0.0)
	var cases: Array = [
		[Vector3(0.0, 0.9, -30.0), Vector3(5.0, 0.0, 0.0), 45.0],
		[Vector3(10.0, 0.9, -50.0), Vector3(-6.0, 0.0, 2.0), 70.0],
		[Vector3(-20.0, 3.0, 10.0), Vector3(0.0, 0.0, -4.0), 40.0],
		[Vector3(0.0, 0.9, -15.0), Vector3.ZERO, 55.0],
	]
	for case: Array in cases:
		var target: Vector3 = case[0]
		var velocity: Vector3 = case[1]
		var speed: float = case[2]
		var direction: Vector3 = Ballistics.solve_lead(origin, target, velocity, speed, GRAVITY)
		assert_near(direction.length(), 1.0, 1e-5, "unit direction")
		# Walks the parabola and looks for the step closest to the moving target.
		var best: float = INF
		var steps: int = 0
		for n: int in 6000:
			var ticks: float = n * 0.05
			var arrow: Vector3 = Ballistics.position(origin, direction * speed, GRAVITY, ticks)
			var moved: Vector3 = target + velocity * (ticks / 60.0)
			var gap: float = arrow.distance_to(moved)
			if gap < best:
				best = gap
				steps = n
		assert_true(best < 0.02, "%s at %s m/s: the arrow passes %s m from the target (n = %s)"
				% [target, speed, best, steps * 0.05])
	# Without gravity or movement, the straight line.
	var straight: Vector3 = Ballistics.solve_lead(Vector3.ZERO, Vector3(0.0, 0.0, -10.0), Vector3.ZERO, 30.0, 0.0)
	assert_vec_near(straight, Vector3(0.0, 0.0, -1.0), 1e-6, "straight")
	assert_eq(Ballistics.solve_lead(Vector3.ONE, Vector3.ONE, Vector3.ZERO, 30.0, 6.0), Vector3.FORWARD,
			"with no distance, forward")
