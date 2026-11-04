extends TestCase
## Tests for [TickSync] (docs/networking.md, sections 4.2 and 16): target margin according to jitter,
## margin sequences and the steps to take, proportional debt, waiting for the ack
## after the adjustment, delay with null steps, hard forward resync and that it never
## jumps backward.
## [br][br]
## The expected numbers come by hand from the pseudocode in section 4.2.

const RANDOM_SEED: int = 20261029
const NO_MARGIN: int = NetProtocol.NO_MARGIN


func test_target_margin_follows_jitter() -> void:
	var sync := TickSync.new()
	assert_eq(sync.get_target_margin(), 1, "without measured jitter, margin 1")
	var cases: Array[Array] = [
		[0.0, 1], [0.1, 2], [0.5, 2], [0.51, 3], [1.0, 3], [1.01, 4], [1.5, 4], [5.0, 4],
		[-3.0, 1],
	]
	for case: Array in cases:
		sync.set_jitter(case[0])
		assert_eq(sync.get_target_margin(), case[1],
				"jitter %s -> margin 1 + ceil(2 * jitter) clamped to [1, 4]" % case[0])


func test_start_returns_first_real_tick() -> void:
	var sync := TickSync.new()
	assert_eq(sync.start(100, 5), 107, "P0 = spawn_tick + rtt + margin (1) + 1")
	sync.set_jitter(1.0)
	assert_eq(sync.start(100, 5), 109, "with margin 3: P0 = 100 + 5 + 3 + 1")
	assert_eq(sync.start(100, 0), 104, "RTT 0")
	assert_eq(sync.start(100, -4), 104, "a negative RTT counts as 0")


func test_start_resets_previous_session() -> void:
	var sync := TickSync.new()
	_feed(sync, 10, 0, 1)
	assert_eq(sync.next_steps(50), 2, "moves ahead")
	assert_eq(sync.adjustments, 1, "one adjustment")
	_feed(sync, 100, 5, 3)
	sync.start(1, 1)
	assert_eq(sync.adjustments, 0, "start() resets the adjustments")
	assert_eq(sync.get_window_min(), NO_MARGIN, "start() empties the window")
	_feed(sync, 0, 1, 1)
	assert_eq(sync.next_steps(10), 1, "no debt or wait after start()")


func test_steady_margin_keeps_one_step() -> void:
	var sync := TickSync.new()
	# Between the target (1) and target + 2 (3) nothing is touched, not even with the window full.
	for i: int in 60:
		sync.on_snapshot(i, 1 + (i % 3))
		assert_eq(sync.next_steps(100 + i), 1, "step %d" % i)
	assert_eq(sync.adjustments, 0, "no adjustment")


func test_no_data_margin_is_ignored() -> void:
	var sync := TickSync.new()
	sync.on_snapshot(5, NO_MARGIN)
	assert_eq(sync.get_window_min(), NO_MARGIN, "a snapshot with no data does not enter the window")
	assert_eq(sync.next_steps(10), 1, "and does not change the pace")


func test_window_keeps_the_last_samples_and_uses_the_minimum() -> void:
	var sync := TickSync.new()
	_feed(sync, 1, 3, 1)
	_feed(sync, 2, 1, 1)
	_feed(sync, 3, 2, 1)
	assert_eq(sync.get_window_min(), 1, "minimum of all samples")
	# An old low sample leaves the window after WINDOW_SAMPLES more samples.
	var other := TickSync.new()
	_feed(other, 1, -5, 1)
	_feed(other, 2, 4, TickSync.WINDOW_SAMPLES)
	assert_eq(other.get_window_min(), 4, "the window only remembers the last %d samples" %
			TickSync.WINDOW_SAMPLES)


func test_behind_pays_a_debt_proportional_to_the_shortfall_with_double_steps() -> void:
	var sync := TickSync.new()
	sync.set_jitter(1.0)
	assert_eq(sync.get_target_margin(), 3, "target margin 3")
	_feed(sync, 10, 0, 1)
	assert_eq(sync.get_window_min(), 0, "minimum 0")
	# Debt 3 - 0: three consecutive double steps and then the normal pace.
	var steps: Array[int] = []
	var predicted: int = 100
	for _i: int in 6:
		var count: int = sync.next_steps(predicted)
		steps.append(count)
		predicted += count
	assert_eq(steps, [2, 2, 2, 1, 1, 1] as Array[int], "steps after a margin 0 with target 3")
	assert_eq(sync.adjustments, 1, "one adjustment")
	assert_eq(sync.get_window_min(), NO_MARGIN, "the adjustment empties the window")


func test_small_shortfall_pays_a_single_double_step() -> void:
	var sync := TickSync.new()
	_feed(sync, 10, 0, 1)
	assert_eq(sync.next_steps(100), 2, "margin 0 with target 1: one double step")
	assert_eq(sync.next_steps(102), 1, "and back to the normal pace")
	assert_eq(sync.adjustments, 1, "one adjustment")


func test_waits_for_an_ack_after_the_adjustment() -> void:
	var sync := TickSync.new()
	sync.set_jitter(1.0)
	_feed(sync, 10, 0, 1)
	var predicted: int = 100
	for _i: int in 3:
		predicted += sync.next_steps(predicted)
	# The last double step was taken with predicted_tick = 104: the first new tick is 106 and an ack
	# of 108 is awaited (first tick after the adjustment + 2).
	assert_eq(sync.adjustments, 1, "adjustment done")
	sync.on_snapshot(107, 0)
	assert_eq(sync.get_window_min(), NO_MARGIN, "ack 107: still reflects inputs from before the adjustment")
	sync.on_snapshot(108, 0)
	assert_eq(sync.get_window_min(), 0, "ack 108: the server has already seen later inputs")
	sync.on_snapshot(200, 7)
	assert_eq(sync.get_window_min(), 0, "the following ones enter with no further wait")


func test_ahead_slows_down_with_a_null_step_every_other_tick() -> void:
	var sync := TickSync.new()
	# With the window half full it never delays.
	_feed(sync, 1, 6, TickSync.WINDOW_SAMPLES - 1)
	for i: int in 10:
		assert_eq(sync.next_steps(100 + i), 1, "incomplete window: normal pace")
	assert_eq(sync.adjustments, 0, "no adjustments")

	_feed(sync, 2, 6, 1)
	# Margin 6 with target 1: debt -(6 - 1) = -5 -> five null steps, one every two ticks.
	var steps: Array[int] = []
	var predicted: int = 100
	for _i: int in 12:
		var count: int = sync.next_steps(predicted)
		steps.append(count)
		predicted += count
	assert_eq(steps, [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1] as Array[int],
			"five null steps alternating with normal steps")
	assert_eq(sync.adjustments, 1, "one adjustment")


func test_margin_just_above_the_target_does_not_slow_down() -> void:
	var sync := TickSync.new()
	_feed(sync, 1, 3, TickSync.WINDOW_SAMPLES + 5)
	for i: int in 20:
		assert_eq(sync.next_steps(100 + i), 1, "target 1 + 2 = 3 is still fine")
	_feed(sync, 2, 4, TickSync.WINDOW_SAMPLES)
	assert_eq(sync.next_steps(200), 0, "with 4 (> target + 2) and the window full it does delay")


func test_hard_resync_forward_takes_all_the_steps_at_once() -> void:
	var sync := TickSync.new()
	_feed(sync, 1, -10, 1)
	# Minimum -10 with target 1: 1 + (1 - -10) = 12 steps on the same tick.
	assert_eq(sync.next_steps(100), 12, "hard resync")
	assert_eq(sync.adjustments, 1, "one adjustment")
	assert_eq(sync.next_steps(112), 1, "and the normal pace afterward")

	var limit := TickSync.new()
	_feed(limit, 1, -100, 1)
	assert_eq(limit.next_steps(100), TickSync.MAX_RESYNC_STEPS, "30 steps at most")

	var edge := TickSync.new()
	_feed(edge, 1, TickSync.RESYNC_BEHIND, 1)
	assert_eq(edge.next_steps(100), 10, "-8 is already a resync: 1 + (1 + 8)")

	var proportional := TickSync.new()
	_feed(proportional, 1, TickSync.RESYNC_BEHIND + 1, 1)
	var steps: Array[int] = []
	var predicted: int = 100
	for _i: int in 9:
		var count: int = proportional.next_steps(predicted)
		steps.append(count)
		predicted += count
	assert_eq(steps, [2, 2, 2, 2, 2, 2, 2, 2, 1] as Array[int],
			"-7 is paid with eight double steps on consecutive ticks")


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
				"steps outside [0, 30]: %d" % steps)
		assert_false(steps == 0 and previous == 0, "never two consecutive ticks without a step")
		previous = steps
		predicted += steps
		total_steps += steps
	assert_true(predicted >= 1000, "the predicted tick never goes backward")
	assert_true(total_steps > 1500, "advances steadily (%d steps in 3000 ticks)" %
			total_steps)


# --- Closed loop with a minimal server ------------------------------------------------------------

func test_closed_loop_recovers_when_the_start_estimate_is_too_late() -> void:
	# Assumed RTT 0 with 3 + 3 real ticks: the first inputs arrive 4 ticks late.
	var loop: Dictionary = _run_loop(3, 3, 0, 0, 0.0, 400)
	var leads: Array[Vector2i] = loop["leads"]
	assert_true(_min_lead_after(leads, 0) < 0, "at the start the inputs arrive late")
	assert_true(_min_lead_after(leads, 100) >= 0,
			"after 100 ticks none arrives late any more (minimum lead %d)"
			% _min_lead_after(leads, 100))
	assert_true(_max_lead_after(leads, 100) <= TickSync.MIN_TARGET + 2,
			"and the lead stays under target + 2 (%d)" % _max_lead_after(leads, 100))
	assert_true(loop["adjustments"] >= 1 and loop["adjustments"] <= 3,
			"with few adjustments (%d)" % loop["adjustments"])


func test_closed_loop_hard_resync_when_the_estimate_is_very_wrong() -> void:
	# Six ticks out and another six back, and an RTT of 0 is assumed: margin of -9.
	var loop: Dictionary = _run_loop(6, 6, 0, 0, 0.0, 400)
	var leads: Array[Vector2i] = loop["leads"]
	assert_true(_min_lead_after(leads, 0) <= TickSync.RESYNC_BEHIND,
			"the first inputs arrive very late (%d)" % _min_lead_after(leads, 0))
	assert_true(_min_lead_after(leads, 100) >= 0, "and after 100 ticks there are no late ones")
	assert_true(_max_lead_after(leads, 100) <= TickSync.MIN_TARGET + 2, "with the lead bounded")
	assert_true(loop["adjustments"] <= 4, "without oscillating (%d adjustments)" % loop["adjustments"])


func test_closed_loop_slows_down_when_the_estimate_is_too_early() -> void:
	# Assumed RTT 20 with 3 + 3 real: the inputs arrive 15 ticks earlier than needed.
	var loop: Dictionary = _run_loop(3, 3, 0, 20, 0.0, 900)
	var leads: Array[Vector2i] = loop["leads"]
	assert_true(_max_lead_after(leads, 0) >= 10, "at the start there is surplus lead (%d)"
			% _max_lead_after(leads, 0))
	assert_true(_min_lead_after(leads, 500) >= 0, "never late, not even when delaying")
	assert_true(_max_lead_after(leads, 500) <= TickSync.MIN_TARGET + 2,
			"and it ends with the lead at the target (%d)" % _max_lead_after(leads, 500))
	assert_true(loop["adjustments"] <= 4, "without oscillating (%d adjustments)" % loop["adjustments"])


func test_closed_loop_with_jitter_keeps_inputs_on_time() -> void:
	# Upstream with between 3 and 6 ticks of delay (jitter 3 upstream) and measured snapshot jitter of 1.5.
	var loop: Dictionary = _run_loop(3, 3, 3, 6, 1.5, 1800)
	var leads: Array[Vector2i] = loop["leads"]
	var late: int = 0
	var total: int = 0
	for entry: Vector2i in leads:
		if entry.x < 300:
			continue
		total += 1
		if entry.y < 0:
			late += 1
	assert_true(total > 1000, "there are inputs to measure (%d)" % total)
	assert_true(float(late) / float(total) < 0.02,
			"fewer than 2 %% of inputs late in steady state (%d of %d)" % [late, total])
	assert_true(loop["adjustments"] <= 12, "few adjustments (%d)" % loop["adjustments"])


## Closed loop without physics: a client with [TickSync] and a minimal server that measures the lead
## of the first copy of each input (section 4.1) and returns the minimum and the ack in snapshots
## every 2 ticks. Inputs take [param up] ticks to arrive (plus between 0 and [param up_jitter]
## of jitter) and snapshots [param down]. [param assumed_rtt] is the RTT with which P0 is computed.
## Returns {"leads": Array[Vector2i] (frame, lead), "adjustments": int}.
func _run_loop(up: int, down: int, up_jitter: int, assumed_rtt: int, jitter_ticks: float,
		frames: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = RANDOM_SEED
	var sync := TickSync.new()
	sync.set_jitter(jitter_ticks)
	var spawn_tick: int = 100
	var predicted: int = sync.start(spawn_tick, assumed_rtt) - 1
	# When the client receives the join, the server is already at spawn_tick + down.
	var server_tick: int = spawn_tick + down - 1
	var uplink: Dictionary = {}
	var downlink: Dictionary = {}
	var received: Dictionary = {}
	var leads: Array[Vector2i] = []
	var min_lead: int = 0
	var has_lead: bool = false
	for frame: int in frames:
		# Server: receive, simulate the next tick and, every 2 ticks, send the snapshot.
		for tick: int in uplink.get(frame, []):
			var lead: int = tick - (server_tick + 1)
			if tick <= server_tick or received.has(tick):
				if tick <= server_tick:
					leads.append(Vector2i(frame, lead))
					min_lead = lead if not has_lead else mini(min_lead, lead)
					has_lead = true
				continue
			received[tick] = true
			leads.append(Vector2i(frame, lead))
			min_lead = lead if not has_lead else mini(min_lead, lead)
			has_lead = true
		server_tick += 1
		received.erase(server_tick)
		if frame % NetProtocol.SNAPSHOT_INTERVAL_TICKS == 0:
			var ack: int = server_tick
			while received.has(ack + 1) and ack < server_tick + NetProtocol.MAX_INPUT_LEAD_TICKS:
				ack += 1
			var margin: int = clampi(min_lead, -127, 127) if has_lead else NO_MARGIN
			has_lead = false
			var arrival: int = frame + down
			if not downlink.has(arrival):
				downlink[arrival] = []
			(downlink[arrival] as Array).append(Vector2i(ack, margin))
		# Client: snapshots arrive, it decides how many steps to take and the inputs are sent.
		for snapshot: Vector2i in downlink.get(frame, []):
			sync.on_snapshot(snapshot.x, snapshot.y)
		var steps: int = sync.next_steps(predicted)
		for _step: int in steps:
			predicted += 1
			var arrival: int = frame + up + rng.randi_range(0, up_jitter)
			if not uplink.has(arrival):
				uplink[arrival] = []
			(uplink[arrival] as Array).append(predicted)
	return {"leads": leads, "adjustments": sync.adjustments}


func _min_lead_after(leads: Array[Vector2i], from_frame: int) -> int:
	var low: int = 1000000
	for entry: Vector2i in leads:
		if entry.x >= from_frame:
			low = mini(low, entry.y)
	return low


func _max_lead_after(leads: Array[Vector2i], from_frame: int) -> int:
	var high: int = -1000000
	for entry: Vector2i in leads:
		if entry.x >= from_frame:
			high = maxi(high, entry.y)
	return high


func _feed(sync: TickSync, ack_tick: int, margin: int, count: int) -> void:
	for _i: int in count:
		sync.on_snapshot(ack_tick, margin)
