extends TestCase
## Tests for [InterpolationClock] (docs/networking.md, sections 4.3 and 16): it converges to the delay with a synthetic
## jitter, the delay is bounded to [4, 12] ticks, the correction is gradual and it jumps on
## errors of more than 10 ticks.
## [br][br]
## The synthetic snapshots arrive every 2 local ticks with
## [code]server_tick = local_tick + base_offset - lateness[/code]: the window's maximum offset
## is [code]base_offset[/code] and the jitter, the mean of [code]lateness[/code].
## [br][br]
## [b]Steady state.[/b] The draw tick converges exactly to the target (without the one-tick bias
## of the original pseudocode in section 4.3).

## Draw tick minus target once the clock has stabilised.
const STEADY_LEAD: float = 0.0


func test_does_not_start_before_the_first_snapshot() -> void:
	var clock := InterpolationClock.new()
	for tick: int in range(1, 10):
		assert_eq(clock.advance(tick), 0.0, "without snapshots there is nothing to measure with")
	assert_eq(clock.get_render_tick(), 0.0, "draw tick 0")
	assert_eq(clock.get_delay_ticks(), 4.0, "initial delay: 2 snapshot intervals")
	assert_eq(clock.get_jitter_ticks(), 0.0, "no jitter")


func test_converges_to_the_minimum_delay_without_jitter() -> void:
	var clock := InterpolationClock.new()
	var render_tick: float = 0.0
	for local_tick: int in range(1, 301):
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		render_tick = clock.advance(local_tick)
		if local_tick == 2:
			assert_near(render_tick, 2.0 + 30.0 - 4.0, 1e-6, "the first snapshot starts the clock")
	assert_eq(clock.get_jitter_ticks(), 0.0, "no jitter")
	assert_eq(clock.get_delay_ticks(), 4.0, "minimum delay of 4 ticks (67 ms)")
	assert_near(render_tick, 300.0 + 30.0 - 4.0 + STEADY_LEAD, 1e-6,
			"in steady state it draws 4 ticks behind the server, plus the bias tick")
	assert_near(clock.get_render_tick(), render_tick, 1e-9, "get_render_tick() is the latest value")


func test_jitter_raises_the_delay() -> void:
	var clock := InterpolationClock.new()
	var render_tick: float = 0.0
	var snapshots: int = 0
	for local_tick: int in range(1, 601):
		if local_tick % 2 == 0:
			# One on-time snapshot and another two ticks late, alternating: mean jitter of 1 tick.
			var lateness: int = 2 if snapshots % 2 == 1 else 0
			clock.on_snapshot(local_tick + 30 - lateness, local_tick)
			snapshots += 1
		render_tick = clock.advance(local_tick)
	assert_near(clock.get_jitter_ticks(), 1.0, 0.1, "mean jitter")
	assert_near(clock.get_delay_ticks(), 4.0 + 2.0 * 1.0, 0.25, "delay = 4 + 2 · jitter")
	assert_near(render_tick, 600.0 + 30.0 - clock.get_delay_ticks() + STEADY_LEAD, 0.3,
			"the draw tick follows the target")


func test_delay_is_clamped_to_twelve_ticks() -> void:
	var clock := InterpolationClock.new()
	for local_tick: int in range(1, 801):
		if local_tick % 2 == 0:
			var lateness: int = 20 if local_tick % 4 == 2 else 0
			clock.on_snapshot(local_tick + 40 - lateness, local_tick)
		clock.advance(local_tick)
	assert_true(clock.get_jitter_ticks() > 5.0, "high jitter (%s)" % clock.get_jitter_ticks())
	assert_eq(clock.get_delay_ticks(), 12.0, "maximum delay of 12 ticks (200 ms)")


func test_jitter_goes_back_to_zero_after_a_burst() -> void:
	var clock := InterpolationClock.new()
	for local_tick: int in range(1, 41):
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
	# A spike: five consecutive snapshots 4 ticks late.
	for local_tick: int in range(42, 52, 2):
		clock.on_snapshot(local_tick + 30 - 4, local_tick)
	assert_true(clock.get_jitter_ticks() > 0.5, "the spike raises the jitter")
	for local_tick: int in range(52, 652, 2):
		clock.on_snapshot(local_tick + 30, local_tick)
	assert_eq(clock.get_jitter_ticks(), 0.0,
			"the jitter goes back to exactly 0 (otherwise TickSync's target margin would stay "
			+ "one tick too high forever)")
	assert_eq(clock.get_delay_ticks(), 4.0, "and the delay, to the minimum")
	var sync := TickSync.new()
	sync.set_jitter(clock.get_jitter_ticks())
	assert_eq(sync.get_target_margin(), 1, "target margin 1")


func test_small_errors_are_corrected_gradually() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	var base_offset: int = 30
	var previous: float = 0.0
	var max_step_error: float = 0.0
	var render_tick: float = 0.0
	for _i: int in 300:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + base_offset, local_tick)
		render_tick = clock.advance(local_tick)
		previous = render_tick
	# The server "runs ahead" by 5 ticks (for example, the client ran out of ticks for a moment).
	base_offset += 5
	var target: float = 0.0
	for _i: int in 400:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + base_offset, local_tick)
		render_tick = clock.advance(local_tick)
		max_step_error = maxf(max_step_error, absf(render_tick - previous - 1.0))
		previous = render_tick
		target = float(local_tick + base_offset) - 4.0
	assert_true(max_step_error <= 0.05 + 1e-9,
			"the correction never exceeds 0.05 ticks per tick (it was %s)" % max_step_error)
	assert_true(max_step_error > 0.04, "and it does correct at that rate (it was %s)" % max_step_error)
	assert_near(render_tick, target + STEADY_LEAD, 0.05, "it ends up on the target")


func test_jumps_when_the_error_exceeds_ten_ticks() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	for _i: int in 200:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		clock.advance(local_tick)
	# The server runs ahead by 15 ticks: the target moves away by more than 10 ticks and it jumps at once.
	local_tick += 1
	var before: float = clock.get_render_tick()
	clock.on_snapshot(local_tick + 45, local_tick)
	var jumped: float = clock.advance(local_tick)
	assert_near(jumped, float(local_tick + 45) - 4.0, 1e-6, "jumps to the target")
	assert_true(jumped - before > 14.0, "the jump is about 15 ticks")


## A server that loses ticks (or a sustained rise in latency) drops the offsets at once.
## The maximum of the 2 s window would remember the old ones and the draw tick would run ahead of the
## data that exists (it would extrapolate 6 ticks and then the remote would stand still, finding N3).
## A sustained step of more than STEP_DOWN_TICKS is adopted in RECENT_TICKS ticks, not in 120.
func test_a_sustained_step_down_of_the_offsets_is_adopted_in_half_a_second() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	for _i: int in 200:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 45, local_tick)
		clock.advance(local_tick)
	# The server loses 15 ticks: the offsets drop from 45 to 30 and stay there.
	var change_tick: int = local_tick
	var adopted_after: int = -1
	var jitter_after_100: float = -1.0
	for _i: int in 400:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		var render_tick: float = clock.advance(local_tick)
		var target: float = float(local_tick + 30) - clock.get_delay_ticks()
		if adopted_after < 0 and absf(render_tick - target) <= 1.0:
			adopted_after = local_tick - change_tick
		if local_tick - change_tick == 100:
			jitter_after_100 = clock.get_jitter_ticks()
	assert_true(adopted_after > 0 and adopted_after <= 40,
			"the draw tick reaches local + 30 - delay (±1) in 40 ticks or fewer (%d)" % adopted_after)
	assert_true(jitter_after_100 >= 0.0 and jitter_after_100 < 1.0,
			"the step's jitter becomes small again in a short time (%s)" % jitter_after_100)
	# The delay returns to the minimum and the draw tick follows it at 0.05 ticks per tick.
	assert_near(clock.get_delay_ticks(), 4.0, 0.05, "the delay returns to the minimum")
	assert_near(clock.get_render_tick(), float(local_tick + 30) - clock.get_delay_ticks(), 1.0,
			"and the draw tick ends up on the new measurement")


## An overloaded server that continuously loses 1 in 12 ticks lowers the offsets non-stop.
## The draw tick cannot run more than MAX_EXTRAPOLATION_TICKS ahead of the last snapshot (the
## remote would freeze), which with the 2 s maximum did happen permanently.
func test_a_server_that_keeps_losing_ticks_does_not_freeze_the_remotes() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	var newest_server_tick: int = 0
	var frozen: int = 0
	var measured: int = 0
	for _i: int in 1200:
		local_tick += 1
		if local_tick % 2 == 0:
			newest_server_tick = local_tick + 30 - local_tick / 12
			clock.on_snapshot(newest_server_tick, local_tick)
		var render_tick: float = clock.advance(local_tick)
		if local_tick > 240:
			measured += 1
			if render_tick - float(newest_server_tick) > float(RemoteInterpolator.MAX_EXTRAPOLATION_TICKS):
				frozen += 1
	assert_true(measured > 900, "almost the whole run is measured")
	assert_eq(frozen, 0, "no tick with the remote more than 6 ticks ahead of its last data")


## A spike shorter than RECENT_TICKS is not a step: the old offsets keep governing and the
## draw tick does not jump at once, neither during the spike nor when it ends.
func test_a_short_dip_is_not_a_step() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	var previous: float = 0.0
	var max_jump: float = 0.0
	for i: int in 400:
		local_tick += 1
		# Between ticks 201 and 220 (20 ticks, fewer than RECENT_TICKS) the snapshots arrive
		# 15 ticks late.
		var offset: int = 30 if i >= 200 and i < 220 else 45
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + offset, local_tick)
		var render_tick: float = clock.advance(local_tick)
		if i > 2:
			max_jump = maxf(max_jump, absf(render_tick - previous - 1.0))
		previous = render_tick
	assert_true(max_jump <= InterpolationClock.MAX_CORRECTION_PER_TICK + 1e-9,
			"the draw tick never jumps (largest jump %s)" % max_jump)
	assert_near(previous, float(local_tick + 45) - clock.get_delay_ticks(), 1.0,
			"and it follows the usual measurement (45), not the spike's")


## A latency that improves (offsets that rise) is adopted instantly, as always.
func test_offsets_that_go_up_are_adopted_immediately() -> void:
	var clock := InterpolationClock.new()
	var local_tick: int = 0
	for _i: int in 200:
		local_tick += 1
		if local_tick % 2 == 0:
			clock.on_snapshot(local_tick + 30, local_tick)
		clock.advance(local_tick)
	local_tick += 2
	clock.on_snapshot(local_tick + 45, local_tick)
	var render_tick: float = clock.advance(local_tick)
	assert_near(render_tick, float(local_tick + 45) - clock.get_delay_ticks(), 1e-6,
			"jumps to the new measurement in the same snapshot")


## With server ticks above 2^31 (the u32 of networking.md 4.1 reaches 828 days) the clock keeps working
## fine: samples cannot be held in 32-bit integers (finding N5).
func test_server_ticks_beyond_two_to_the_thirty_one_do_not_overflow() -> void:
	var clock := InterpolationClock.new()
	var base: int = 2147483648 + 1000
	var render_tick: float = 0.0
	for local_tick: int in range(1, 301):
		if local_tick % 2 == 0:
			clock.on_snapshot(base + local_tick + 5, local_tick)
		render_tick = clock.advance(local_tick)
	assert_near(render_tick, float(base + 300 + 5) - 4.0, 0.5,
			"the draw tick is the server's minus the delay, without overflowing")
	assert_true(render_tick > 0.0, "and positive")
