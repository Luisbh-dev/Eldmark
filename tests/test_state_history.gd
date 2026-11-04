extends TestCase
## Tests for the position history used for lag compensation ([StateHistory], docs/networking.md
## section 10): exact and fractional samples, overwriting of the 64-tick ring,
## teleport and [method StateHistory.forget]; and, for projectiles (docs/abilities.md, section 4.4),
## [method StateHistory.position_at] and the swept boxes by blocks.

const GROUNDED: int = EntityRecord.FLAG_GROUNDED


## Flags of a record with that teleport counter.
static func _flags(teleport_counter: int, grounded: bool = true) -> int:
	var value: int = (teleport_counter & EntityRecord.TELEPORT_MASK) << EntityRecord.TELEPORT_SHIFT
	return value | (GROUNDED if grounded else 0)


## Position of the test trajectory at tick t: a straight line.
static func _path(tick: int) -> Vector3:
	return Vector3(float(tick), 2.0 * float(tick), -float(tick))


func test_record_and_exact_sample() -> void:
	var history := StateHistory.new()
	history.add_entity(7)
	history.record(10, 7, Vector3(1, 2, 3), 0.5, _flags(0))
	assert_true(history.has_tick(7, 10), "tick 10 is there")
	assert_false(history.has_tick(7, 9), "el 9 no")
	assert_false(history.has_tick(7, 11), "el 11 no")
	var sample: StateHistory.Sample = history.sample(7, 10.0)
	if not assert_not_null(sample, "exact sample"):
		return
	assert_vec_near(sample.position, Vector3(1, 2, 3), 1e-6, "position")
	assert_near(sample.yaw, 0.5, 1e-6, "yaw")
	assert_eq(sample.flags, _flags(0), "flags")


func test_values_are_stored_without_quantization() -> void:
	# Unlike the network record, the history does not round to 1 cm.
	var history := StateHistory.new()
	history.add_entity(1)
	var exact := Vector3(123.456789, -0.000123, 99.999)
	history.record(5, 1, exact, 1.2345678, 0)
	var sample: StateHistory.Sample = history.sample(1, 5.0)
	assert_vec_near(sample.position, exact, 1e-9, "unquantized position")
	assert_near(sample.yaw, PlayerState.to_f32(1.2345678), 1e-9, "yaw stored as f32")


func test_fractional_sample_interpolates_position() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(10, 1, Vector3(0, 0, 0), 0.0, _flags(0))
	history.record(11, 1, Vector3(10, 4, -2), 0.0, _flags(0))
	var sample: StateHistory.Sample = history.sample(1, 10.25)
	if not assert_not_null(sample, "between ticks 10 and 11"):
		return
	assert_vec_near(sample.position, Vector3(2.5, 1, -0.5), 1e-5, "a quarter of the way")
	assert_vec_near(history.sample(1, 10.5).position, Vector3(5, 2, -1), 1e-5, "halfway")
	assert_vec_near(history.sample(1, 10.75).position, Vector3(7.5, 3, -1.5), 1e-5, "three quarters")
	assert_vec_near(history.sample(1, 11.0).position, Vector3(10, 4, -2), 1e-6, "exactly tick 11")


func test_yaw_interpolates_the_short_way_around() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(1, 1, Vector3.ZERO, 3.0, 0)
	history.record(2, 1, Vector3.ZERO, -3.0, 0)
	var sample: StateHistory.Sample = history.sample(1, 1.5)
	assert_near(absf(angle_difference(sample.yaw, PI)), 0.0, 1e-4,
			"from 3.0 to -3.0 it goes through PI, not through 0")
	history.record(3, 1, Vector3.ZERO, 0.2, 0)
	history.record(4, 1, Vector3.ZERO, 0.6, 0)
	assert_near(history.sample(1, 3.5).yaw, 0.4, 1e-5, "normal interpolation")


func test_flags_come_from_the_nearest_sample() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(1, 1, Vector3.ZERO, 0.0, _flags(0, true))
	history.record(2, 1, Vector3.ZERO, 0.0, _flags(0, false))
	assert_eq(history.sample(1, 1.25).flags, _flags(0, true), "closer to tick 1")
	assert_eq(history.sample(1, 1.75).flags, _flags(0, false), "closer to tick 2")


func test_out_of_range_is_null() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	assert_null(history.sample(1, 5.0), "empty track")
	for tick: int in range(10, 21):
		history.record(tick, 1, _path(tick), 0.0, 0)
	assert_null(history.sample(1, 9.0), "before the first")
	assert_null(history.sample(1, 9.5), "between a tick that does not exist and the first")
	assert_not_null(history.sample(1, 10.0), "the first")
	assert_not_null(history.sample(1, 19.5), "between the last two")
	assert_not_null(history.sample(1, 20.0), "the last")
	assert_null(history.sample(1, 20.5), "beyond the last: it does not extrapolate")
	assert_null(history.sample(1, 21.0), "one tick ahead")
	assert_null(history.sample(1, -1.0), "negative tick")
	assert_null(history.sample(1, NAN), "NaN")
	assert_null(history.sample(1, INF), "infinity")


func test_unknown_entity_is_null() -> void:
	var history := StateHistory.new()
	assert_null(history.sample(99, 1.0), "without a track")
	assert_false(history.has_tick(99, 1), "has_tick without a track")


func test_ring_overwrites_ticks_older_than_64() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	for tick: int in range(1, 101):
		history.record(tick, 1, _path(tick), 0.0, 0)
	assert_eq(StateHistory.LENGTH_TICKS, 64, "64 ticks")
	for tick: int in range(1, 37):
		assert_false(history.has_tick(1, tick), "tick %d has already been overwritten" % tick)
		assert_null(history.sample(1, float(tick)), "and cannot be sampled")
	for tick: int in range(37, 101):
		assert_true(history.has_tick(1, tick), "tick %d is still there" % tick)
		assert_vec_near(history.sample(1, float(tick)).position, _path(tick), 1e-4,
				"tick %d" % tick)
	assert_null(history.sample(1, 36.5), "between the last overwritten and the oldest")
	assert_vec_near(history.sample(1, 37.5).position, _path(37) + Vector3(0.5, 1.0, -0.5), 1e-4,
			"fractional at the ring's edge")


func test_ring_survives_a_gap_in_the_records() -> void:
	# If ticks are missing (the entity was not recorded), those gaps fall out of range.
	var history := StateHistory.new()
	history.add_entity(1)
	for tick: int in [10, 11, 12, 20, 21]:
		history.record(tick, 1, _path(tick), 0.0, 0)
	assert_not_null(history.sample(1, 11.5), "between 11 and 12")
	assert_null(history.sample(1, 15.0), "unrecorded tick")
	assert_null(history.sample(1, 12.5), "between 12 and the gap")
	assert_not_null(history.sample(1, 20.5), "between 20 and 21")


func test_teleport_counter_change_returns_the_previous_sample() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(10, 1, Vector3(0, 0, 0), 0.1, _flags(0))
	history.record(11, 1, Vector3(1, 0, 0), 0.2, _flags(0))
	history.record(12, 1, Vector3(500, 0, 0), 0.9, _flags(1))
	history.record(13, 1, Vector3(501, 0, 0), 1.0, _flags(1))
	# There is a teleport between 11 and 12: it is not interpolated, it stays at tick 11.
	var across: StateHistory.Sample = history.sample(1, 11.5)
	assert_vec_near(across.position, Vector3(1, 0, 0), 1e-6, "it stays at the previous sample")
	assert_near(across.yaw, 0.2, 1e-6, "with its yaw")
	assert_eq(across.flags, _flags(0), "and its flags")
	assert_vec_near(history.sample(1, 11.99).position, Vector3(1, 0, 0), 1e-6,
			"until just before tick 12")
	assert_vec_near(history.sample(1, 12.0).position, Vector3(500, 0, 0), 1e-6, "exactly 12")
	# On either side of the jump it is interpolated.
	assert_vec_near(history.sample(1, 10.5).position, Vector3(0.5, 0, 0), 1e-6, "before the jump")
	assert_vec_near(history.sample(1, 12.5).position, Vector3(500.5, 0, 0), 1e-4,
			"after the jump")


func test_teleport_counter_wraps_modulo_four() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(1, 1, Vector3(0, 0, 0), 0.0, _flags(3))
	history.record(2, 1, Vector3(9, 0, 0), 0.0, _flags(0))
	assert_vec_near(history.sample(1, 1.5).position, Vector3.ZERO, 1e-6,
			"from counter 3 to 0 is also a teleport")
	history.record(3, 1, Vector3(9, 0, 0), 0.0, _flags(0, false))
	assert_vec_near(history.sample(1, 2.5).position, Vector3(9, 0, 0), 1e-6,
			"changing only grounded is not")


func test_forget_removes_only_that_entity() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.add_entity(2)
	history.record(5, 1, _path(5), 0.0, 0)
	history.record(5, 2, _path(6), 0.0, 0)
	history.forget(1)
	assert_false(history.has_tick(1, 5), "the forgotten track has no ticks")
	assert_null(history.sample(1, 5.0), "nor can it be sampled")
	assert_true(history.has_tick(2, 5), "the other one remains")
	assert_vec_near(history.sample(2, 5.0).position, _path(6), 1e-5, "with its data")
	history.forget(1)
	history.forget(404)
	assert_true(history.has_tick(2, 5), "forgetting twice or an unknown id breaks nothing")


func test_add_entity_resets_an_existing_track() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(5, 1, _path(5), 0.0, 0)
	history.add_entity(1)
	assert_false(history.has_tick(1, 5), "a new track starts empty")
	history.record(6, 1, _path(6), 0.0, 0)
	assert_true(history.has_tick(1, 6), "and can be recorded again")


func test_record_without_add_entity_creates_the_track() -> void:
	var history := StateHistory.new()
	history.record(3, 5, _path(3), 0.0, 0)
	assert_true(history.has_tick(5, 3), "the track is created on recording")
	history.record(-1, 6, _path(1), 0.0, 0)
	assert_false(history.has_tick(6, -1), "a negative tick is ignored")
	assert_null(history.sample(6, 0.0), "and creates no track")


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
				+ Vector3(0, 0, 1000.0 * net_id), 1e-3, "entity %d" % net_id)


func test_random_fractional_samples_match_the_path() -> void:
	# Property: on a straight line, the sample at any instant within the ring is the line.
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
				fail("there is no sample at %f with the last tick %d" % [instant, tick])
				return
			var expected: Vector3 = Vector3(instant, 2.0 * instant, -instant)
			if not sample.position.is_equal_approx(expected) \
					and sample.position.distance_to(expected) > 1e-2:
				fail("sample %s at %f, %s was expected" % [sample.position, instant, expected])
				return
			checked += 1
	assert_true(checked > 2000, "many samples were checked (%d)" % checked)


## Server ticks are u32 (414 days at 60 Hz already exceed 2^31): the track's labels cannot
## be signed 32-bit integers (finding N5), or the history becomes useless.
func test_ticks_beyond_two_to_the_thirty_one_are_kept() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	var big: int = 2147483648 + 5
	history.record(big, 1, Vector3(1.0, 2.0, 3.0), 0.5, 1)
	history.record(big + 1, 1, Vector3(3.0, 2.0, 3.0), 0.5, 1)
	assert_true(history.has_tick(1, big), "tick 2^31 + 5 is recorded")
	assert_false(history.has_tick(1, big + 2), "and the next one is not yet")
	var exact: StateHistory.Sample = history.sample(1, float(big))
	if assert_not_null(exact, "it can be sampled"):
		assert_vec_near(exact.position, Vector3(1.0, 2.0, 3.0), 1e-6)
	var between: StateHistory.Sample = history.sample(1, float(big) + 0.5)
	if assert_not_null(between, "also between two ticks"):
		assert_vec_near(between.position, Vector3(2.0, 2.0, 3.0), 1e-6)
	var max_tick: int = 4294967295
	history.record(max_tick, 1, Vector3(9.0, 0.0, 0.0), 0.0, 1)
	assert_true(history.has_tick(1, max_tick), "nor at the last tick of the u32")


func test_get_flags_returns_exact_flags_or_minus_one() -> void:
	var history := StateHistory.new()
	history.add_entity(3)
	var blocking: int = _flags(1) | ActionMachine.DEFENSE_BLOCKING
	var invulnerable: int = _flags(0) | ActionMachine.DEFENSE_INVULNERABLE
	history.record(10, 3, Vector3.ZERO, 0.0, blocking)
	history.record(11, 3, Vector3.ZERO, 0.0, invulnerable)
	assert_eq(history.get_flags(3, 10), blocking, "the defensive flags are stored with the rest")
	assert_eq(history.get_flags(3, 11), invulnerable)
	assert_eq(history.get_flags(3, 12), -1, "an unrecorded tick")
	assert_eq(history.get_flags(3, -4), -1, "a negative tick")
	assert_eq(history.get_flags(99, 10), -1, "an entity without a track")
	history.record(10 + StateHistory.LENGTH_TICKS, 3, Vector3.ZERO, 0.0, 0)
	assert_eq(history.get_flags(3, 10), -1, "overwritten by the ring")
	var sample: StateHistory.Sample = history.sample(3, 11.0)
	assert_true((sample.flags & ActionMachine.DEFENSE_INVULNERABLE) != 0, "sample returns them too")


# --- Projectiles: position at a tick and swept boxes ------------------------------------------

func test_position_at_reads_an_exact_tick_or_infinity() -> void:
	var history := StateHistory.new()
	history.add_entity(4)
	for tick: int in range(100, 110):
		history.record(tick, 4, _path(tick), 0.0, _flags(0))
	assert_eq(history.position_at(4, 105), _path(105), "the exact tick")
	assert_eq(history.position_at(4, 110), Vector3.INF, "an unrecorded tick")
	assert_eq(history.position_at(4, 99), Vector3.INF, "an earlier one")
	assert_eq(history.position_at(4, -1), Vector3.INF, "a negative one")
	assert_eq(history.position_at(5, 105), Vector3.INF, "an entity without a track")
	history.record(105 + StateHistory.LENGTH_TICKS, 4, Vector3.ONE, 0.0, _flags(0))
	assert_eq(history.position_at(4, 105), Vector3.INF, "overwritten by the ring")
	var sample: StateHistory.Sample = history.sample(4, 106.0)
	assert_eq(history.position_at(4, 106), sample.position, "the same as sample on a whole tick")


func test_the_swept_box_covers_the_last_25_recorded_ticks() -> void:
	var history := StateHistory.new()
	history.add_entity(2)
	assert_true(history.swept_box(2).size.x < 0.0, "with nothing recorded, an empty box")
	assert_true(history.swept_box(9).size.x < 0.0, "nor a track")
	# A trajectory that goes back and forth in x and rises in z: each tick in a different place.
	var position_of: Callable = func(tick: int) -> Vector3:
		return Vector3(sin(float(tick) * 0.7) * 5.0, float(tick % 3), float(tick) * 0.25)
	for last: int in range(200, 260):
		history.record(last, 2, position_of.call(last), 0.0, _flags(0))
		var box: AABB = history.swept_box(2)
		# What the projectile rewind may ask for on the next tick (s = last + 1): from s − 24 to
		# s − 1, plus a tick of margin.
		for tick: int in range(last - 24, last + 1):
			if tick < 200:
				continue
			var point: Vector3 = position_of.call(tick)
			assert_true(box.grow(1e-4).has_point(point), "the box after %d covers tick %d" % [last, tick])
	# And it does not keep anything from more than 4 blocks ago: a very distant forgotten point.
	history.record(300, 2, Vector3(1000.0, 0.0, 0.0), 0.0, _flags(0))
	for tick: int in range(301, 301 + 4 * StateHistory.SWEPT_BLOCK_TICKS):
		history.record(tick, 2, Vector3.ZERO, 0.0, _flags(0))
	assert_eq(history.swept_box(2), AABB(Vector3.ZERO, Vector3.ZERO), "what is more than 4 blocks old does not count")


func test_the_swept_box_is_cheap_to_keep_and_survives_a_gap() -> void:
	var history := StateHistory.new()
	history.add_entity(1)
	history.record(16, 1, Vector3(1.0, 0.0, 0.0), 0.0, _flags(0))
	history.record(17, 1, Vector3(2.0, 0.0, 0.0), 0.0, _flags(0))
	assert_eq(history.swept_box(1), AABB(Vector3(1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0)), "two points")
	# A gap of more than 4 blocks: the old blocks no longer count even though they remain in their slots.
	history.record(17 + 5 * StateHistory.SWEPT_BLOCK_TICKS, 1, Vector3(-3.0, 1.0, 0.0), 0.0, _flags(0))
	assert_eq(history.swept_box(1), AABB(Vector3(-3.0, 1.0, 0.0), Vector3.ZERO), "only the new block")
	history.add_entity(1)
	assert_true(history.swept_box(1).size.x < 0.0, "add_entity empties it")
