extends TestCase
## Tests for [RemoteInterpolator] (docs/networking.md, sections 7 and 16): ordered ring without duplicates,
## linear interpolation of position and velocity, [code]lerp_angle[/code] of the yaw when crossing ±PI,
## grounded from the nearest sample, 6-tick extrapolation and stopping, and the
## teleport counter.
## [br][br]
## Visibility according to [code]spawn_tick[/code] and [code]despawn_tick[/code] (also from section
## 16) is governed by [RemotePlayerView], not the interpolator.

const NET_ID: int = 7
const GROUNDED: int = EntityRecord.FLAG_GROUNDED


func test_empty_interpolator_has_nothing_to_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	assert_null(interpolator.sample(10.0), "with no samples, sample() returns null")
	assert_eq(interpolator.get_newest_tick(), 0, "with no samples, the newest tick is 0")
	assert_eq(interpolator.get_sample_count(), 0, "no samples")


func test_single_sample_is_held_before_and_after() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(1.0, 2.0, 3.0), 0.5))
	for render_time: float in [0.0, 9.5, 10.0]:
		var sample: EntityRecord = interpolator.sample(render_time)
		assert_vec_near(sample.position, Vector3(1.0, 2.0, 3.0), 1e-6,
				"before the first sample (and at it) it stays at the first: t=%s" % render_time)
		assert_near(sample.yaw, 0.5, 1e-6, "yaw of the first sample: t=%s" % render_time)
	assert_eq(interpolator.get_newest_tick(), 10, "newest tick")


func test_lerp_between_two_samples() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(0.0, 1.0, 0.0), 0.0, Vector3(2.0, 0.0, 0.0)))
	interpolator.push(12, _record(Vector3(4.0, 3.0, -8.0), 1.0, Vector3(6.0, 4.0, 0.0)))

	var at_start: EntityRecord = interpolator.sample(10.0)
	assert_vec_near(at_start.position, Vector3(0.0, 1.0, 0.0), 1e-6, "at the first sample")
	var quarter: EntityRecord = interpolator.sample(10.5)
	assert_vec_near(quarter.position, Vector3(1.0, 1.5, -2.0), 1e-6, "a quarter of the way")
	assert_vec_near(quarter.velocity, Vector3(3.0, 1.0, 0.0), 1e-6, "velocity is interpolated too")
	assert_near(quarter.yaw, 0.25, 1e-6, "yaw at a quarter")
	var middle: EntityRecord = interpolator.sample(11.0)
	assert_vec_near(middle.position, Vector3(2.0, 2.0, -4.0), 1e-6, "halfway")
	var three_quarters: EntityRecord = interpolator.sample(11.5)
	assert_vec_near(three_quarters.position, Vector3(3.0, 2.5, -6.0), 1e-6, "three quarters")
	assert_eq(middle.net_id, NET_ID, "keeps the network identifier")


func test_sample_positions_are_the_raw_stored_samples_oldest_first() -> void:
	var interpolator := RemoteInterpolator.new()
	assert_eq(interpolator.get_sample_positions().size(), 0, "with no samples, no positions")
	# They arrive out of order: they are stored by tick and positions come out from the oldest to the newest.
	interpolator.push(14, _record(Vector3(14.0, 0.0, 0.0)))
	interpolator.push(10, _record(Vector3(10.0, 1.0, 0.0)))
	interpolator.push(12, _record(Vector3(12.0, 2.0, 0.0)))
	assert_eq(interpolator.get_sample_positions(), PackedVector3Array([
		Vector3(10.0, 1.0, 0.0), Vector3(12.0, 2.0, 0.0), Vector3(14.0, 0.0, 0.0),
	]), "without interpolating, as they arrived")
	for tick: int in range(20, 20 + RemoteInterpolator.BUFFER_SIZE):
		interpolator.push(tick, _record(Vector3(float(tick), 0.0, 0.0)))
	var positions: PackedVector3Array = interpolator.get_sample_positions()
	assert_eq(positions.size(), RemoteInterpolator.BUFFER_SIZE, "at most BUFFER_SIZE")
	assert_eq(positions[positions.size() - 1].x, float(20 + RemoteInterpolator.BUFFER_SIZE - 1))


func test_interpolates_between_the_right_pair_of_samples() -> void:
	var interpolator := RemoteInterpolator.new()
	for tick: int in [10, 12, 14, 16]:
		interpolator.push(tick, _record(Vector3(float(tick), 0.0, 0.0)))
	assert_vec_near(interpolator.sample(11.0).position, Vector3(11.0, 0.0, 0.0), 1e-6, "between 10 and 12")
	assert_vec_near(interpolator.sample(13.0).position, Vector3(13.0, 0.0, 0.0), 1e-6, "between 12 and 14")
	assert_vec_near(interpolator.sample(15.5).position, Vector3(15.5, 0.0, 0.0), 1e-6, "between 14 and 16")
	assert_vec_near(interpolator.sample(14.0).position, Vector3(14.0, 0.0, 0.0), 1e-6,
			"exactly on an intermediate sample")
	# With gaps (lost snapshots) it interpolates the same by time, not by index.
	var gaps := RemoteInterpolator.new()
	gaps.push(10, _record(Vector3(0.0, 0.0, 0.0)))
	gaps.push(16, _record(Vector3(6.0, 0.0, 0.0)))
	assert_vec_near(gaps.sample(13.0).position, Vector3(3.0, 0.0, 0.0), 1e-6, "jump of 6 ticks")


func test_yaw_uses_lerp_angle_across_pi() -> void:
	var interpolator := RemoteInterpolator.new()
	var near_positive_pi: float = PI - 0.1
	var near_negative_pi: float = -PI + 0.1
	interpolator.push(10, _record(Vector3.ZERO, near_positive_pi))
	interpolator.push(12, _record(Vector3.ZERO, near_negative_pi))
	var middle: EntityRecord = interpolator.sample(11.0)
	assert_near(absf(middle.yaw), PI, 1e-5, "by the short path it goes through ±PI, not through 0 (%s)" % middle.yaw)
	var quarter: EntityRecord = interpolator.sample(10.5)
	assert_near(angle_difference(near_positive_pi, quarter.yaw), 0.05, 1e-5,
			"a quarter of the short turn (0.2 rad) is 0.05 rad")

	var backwards := RemoteInterpolator.new()
	backwards.push(10, _record(Vector3.ZERO, near_negative_pi))
	backwards.push(12, _record(Vector3.ZERO, near_positive_pi))
	assert_near(absf(backwards.sample(11.0).yaw), PI, 1e-5, "also in the opposite direction")
	assert_near(angle_difference(near_negative_pi, backwards.sample(10.5).yaw), -0.05, 1e-5,
			"and in the right direction")


func test_grounded_comes_from_the_nearest_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO, 0.0, Vector3.ZERO, GROUNDED))
	interpolator.push(12, _record(Vector3(0.0, 1.0, 0.0), 0.0, Vector3.ZERO, 0))
	assert_true(interpolator.sample(10.0).is_grounded(), "at the first sample, on the ground")
	assert_true(interpolator.sample(10.8).is_grounded(), "closer to the first: on the ground")
	assert_false(interpolator.sample(11.2).is_grounded(), "closer to the second: in the air")
	assert_false(interpolator.sample(11.9).is_grounded(), "almost at the second: in the air")


func test_extrapolates_horizontally_up_to_six_ticks_then_stands_still() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(0.0, 1.0, 0.0), 0.3, Vector3(6.0, 9.0, -3.0)))
	var per_tick: float = 1.0 / float(Engine.physics_ticks_per_second)

	var on_time: EntityRecord = interpolator.sample(10.0)
	assert_vec_near(on_time.position, Vector3(0.0, 1.0, 0.0), 1e-6, "at the last sample, not moving")

	var half: EntityRecord = interpolator.sample(13.0)
	assert_vec_near(half.position, Vector3(6.0 * 3.0 * per_tick, 1.0, -3.0 * 3.0 * per_tick), 1e-6,
			"3 ticks ahead: horizontal velocity x 3 ticks, without touching the height")
	assert_vec_near(half.velocity, Vector3(6.0, 9.0, -3.0), 1e-6, "and keeps the velocity")
	assert_near(half.yaw, 0.3, 1e-6, "the yaw does not change")

	var limit: EntityRecord = interpolator.sample(10.0 + RemoteInterpolator.MAX_EXTRAPOLATION_TICKS)
	var limit_position: Vector3 = Vector3(6.0, 0.0, -3.0) * (6.0 * per_tick) + Vector3(0.0, 1.0, 0.0)
	assert_vec_near(limit.position, limit_position, 1e-6, "at 6 ticks (100 ms) it reaches the limit")
	assert_vec_near(limit.velocity, Vector3(6.0, 9.0, -3.0), 1e-6, "at the limit it still moves")

	for ahead: float in [6.5, 7.0, 10.0, 60.0]:
		var stopped: EntityRecord = interpolator.sample(10.0 + ahead)
		assert_vec_near(stopped.position, limit_position, 1e-6,
				"%s ticks ahead it stops at the limit" % ahead)
		assert_vec_near(stopped.velocity, Vector3.ZERO, 1e-6, "with velocity 0 (%s ticks)" % ahead)


func test_extrapolation_and_copies_keep_the_health_byte() -> void:
	var interpolator := RemoteInterpolator.new()
	var record: EntityRecord = _record(Vector3.ZERO, 0.0, Vector3(6.0, 0.0, 0.0))
	record.health_q = 77
	record.action = 5
	interpolator.push(10, record)
	assert_eq(interpolator.sample(10.0).health_q, 77, "at the sample")
	assert_eq(interpolator.sample(12.0).health_q, 77, "extrapolating")
	assert_eq(interpolator.sample(12.0).action, 5, "and the action too")
	assert_eq(interpolator.sample(60.0).health_q, 77, "past the extrapolation limit")


func test_new_sample_after_extrapolating_takes_over() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO, 0.0, Vector3(6.0, 0.0, 0.0)))
	var extrapolated: EntityRecord = interpolator.sample(12.0)
	assert_true(extrapolated.position.x > 0.0, "extrapolates")
	# The next sample arrives (with a jump relative to what was extrapolated): it now interpolates between the two.
	interpolator.push(14, _record(Vector3(1.0, 0.0, 0.0), 0.0, Vector3(6.0, 0.0, 0.0)))
	assert_vec_near(interpolator.sample(12.0).position, Vector3(0.5, 0.0, 0.0), 1e-6,
			"with the new sample the same instant is interpolated")
	assert_eq(interpolator.get_newest_tick(), 14, "newest tick")


func test_teleport_counter_change_holds_the_first_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(0.0, 0.0, 0.0), 0.0, Vector3.ZERO, GROUNDED, 0))
	interpolator.push(12, _record(Vector3(100.0, 0.0, 0.0), 1.0, Vector3.ZERO, GROUNDED, 1))
	for render_time: float in [10.0, 10.5, 11.0, 11.99]:
		var held: EntityRecord = interpolator.sample(render_time)
		assert_vec_near(held.position, Vector3.ZERO, 1e-6,
				"the counter changes: it is not interpolated, it stays at the first (t=%s)" % render_time)
		assert_near(held.yaw, 0.0, 1e-6, "nor the yaw (t=%s)" % render_time)
		assert_eq(held.get_teleport_counter(), 0, "with its counter (t=%s)" % render_time)
	var arrived: EntityRecord = interpolator.sample(12.0)
	assert_vec_near(arrived.position, Vector3(100.0, 0.0, 0.0), 1e-6, "on reaching the second, it is on it")
	assert_eq(arrived.get_teleport_counter(), 1, "with its counter")

	# After the teleport, with the same counter, it interpolates again.
	interpolator.push(14, _record(Vector3(102.0, 0.0, 0.0), 1.0, Vector3.ZERO, GROUNDED, 1))
	assert_vec_near(interpolator.sample(13.0).position, Vector3(101.0, 0.0, 0.0), 1e-6,
			"same counter: it is interpolated")
	assert_vec_near(interpolator.sample(11.5).position, Vector3.ZERO, 1e-6,
			"and what came before is still not interpolated")


func test_teleport_counter_wraps_modulo_four() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO, 0.0, Vector3.ZERO, 0, 3))
	interpolator.push(12, _record(Vector3(50.0, 0.0, 0.0), 0.0, Vector3.ZERO, 0, 0))
	assert_vec_near(interpolator.sample(11.0).position, Vector3.ZERO, 1e-6,
			"from counter 3 to 0 is also a teleport")


func test_samples_are_kept_sorted_and_duplicates_are_dropped() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3(10.0, 0.0, 0.0)))
	interpolator.push(14, _record(Vector3(14.0, 0.0, 0.0)))
	interpolator.push(12, _record(Vector3(12.0, 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), 3, "three samples")
	assert_eq(interpolator.get_oldest_tick(), 10, "the oldest")
	assert_eq(interpolator.get_newest_tick(), 14, "the newest, even though the last one did not arrive")
	assert_vec_near(interpolator.sample(11.0).position, Vector3(11.0, 0.0, 0.0), 1e-6,
			"the out-of-order one is inserted in its place")
	assert_vec_near(interpolator.sample(13.0).position, Vector3(13.0, 0.0, 0.0), 1e-6, "and it is the intermediate one")

	interpolator.push(12, _record(Vector3(999.0, 0.0, 0.0)))
	interpolator.push(14, _record(Vector3(999.0, 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), 3, "duplicates are discarded")
	assert_vec_near(interpolator.sample(12.0).position, Vector3(12.0, 0.0, 0.0), 1e-6,
			"the first copy wins")
	interpolator.push(11, null)
	assert_eq(interpolator.get_sample_count(), 3, "a null record is ignored")


func test_ring_keeps_the_newest_thirty_two_samples() -> void:
	var interpolator := RemoteInterpolator.new()
	for tick: int in range(1, 41):
		interpolator.push(tick * 2, _record(Vector3(float(tick), 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), RemoteInterpolator.BUFFER_SIZE, "32 samples at most")
	assert_eq(interpolator.get_newest_tick(), 80, "the newest")
	assert_eq(interpolator.get_oldest_tick(), 18, "the 8 oldest left the window")
	interpolator.push(4, _record(Vector3(999.0, 0.0, 0.0)))
	assert_eq(interpolator.get_sample_count(), RemoteInterpolator.BUFFER_SIZE,
			"a sample older than the window is discarded")
	assert_eq(interpolator.get_oldest_tick(), 18, "without changing the window")
	# An out-of-order one that does fit in the window displaces the oldest.
	interpolator.push(19, _record(Vector3(19.0, 0.0, 0.0)))
	assert_eq(interpolator.get_oldest_tick(), 19,
			"an out-of-order one within the window enters and displaces the oldest")
	assert_vec_near(interpolator.sample(19.0).position, Vector3(19.0, 0.0, 0.0), 1e-6, "and is used")


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
			"modifying what is returned does not touch the stored samples")
	assert_vec_near(interpolator.sample(10.0).position, Vector3(1.0, 0.0, 0.0), 1e-9, "nor the following ones")
	assert_eq(interpolator.sample(10.0).flags, 0, "nor their flags")


func test_clear_forgets_every_sample() -> void:
	var interpolator := RemoteInterpolator.new()
	interpolator.push(10, _record(Vector3.ZERO))
	interpolator.clear()
	assert_null(interpolator.sample(10.0), "no samples")
	assert_eq(interpolator.get_newest_tick(), 0, "no newest tick")


# --- With the interpolation clock ------------------------------------------------------------------

func test_clock_and_interpolator_draw_a_stream_without_loss_always_between_two_samples() -> void:
	var result: Dictionary = _draw_stream(3, 3, 0.0)
	assert_true(result["frames"] > 1000, "there are frames to measure (%d)" % result["frames"])
	assert_eq(result["extrapolated"], 0, "without losses it is always drawn between two samples")
	assert_eq(result["held"], 0, "and never behind the oldest")
	assert_true(result["worst_error"] < 1e-4, "the drawn position follows the real one (%s m)"
			% result["worst_error"])
	assert_near(result["average_delay"], InterpolationClock.MIN_DELAY_TICKS, 1e-6,
			"without jitter, the delay is the minimum (4 ticks)")


func test_clock_and_interpolator_draw_a_lossy_jittery_stream_mostly_between_samples() -> void:
	# Snapshots at 30 Hz that take between 3 and 6 ticks and 10 % are lost.
	var result: Dictionary = _draw_stream(3, 6, 0.1)
	assert_true(result["worst_error"] < 1e-3, "and the drawn movement is still the real one (%s m)"
			% result["worst_error"])
	assert_true(result["average_delay"] > InterpolationClock.MIN_DELAY_TICKS + 1.0,
			"jitter raises the delay (%s ticks)" % result["average_delay"])
	var extrapolated_share: float = float(result["extrapolated"]) / float(result["frames"])
	assert_true(extrapolated_share < 0.08,
			"it extrapolates in less than 8 %% of the frames (%s)" % extrapolated_share)
	assert_eq(result["held"], 0, "and it never falls behind the oldest")


## A remote that runs at 5 m/s along X. Its snapshots (one every 2 server ticks) reach the client
## with a delay between [param min_delay] and [param max_delay] ticks and the fraction
## [param loss] is lost. Each local tick the clock advances and the interpolator is sampled at
## [code]render_tick + 0.5[/code]. Returns how many frames (from 300 on) fell
## ahead of the last sample (extrapolation) or behind the first, the worst position
## error and the clock's average delay.
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
