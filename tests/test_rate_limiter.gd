extends TestCase
## Tests for the rate limiter ([RateLimiter], a token bucket measured in ticks) and for [ServerPeer]'s
## warnings (50 warnings within 600 ticks kick), docs/red.md section 12.


func test_burst_then_empty() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for i: int in 5:
		assert_true(limiter.try_consume(10), "the burst allows spend %d" % i)
	assert_false(limiter.try_consume(10), "no tokens on the same tick")
	assert_false(limiter.try_consume(10), "and there still are none")


func test_refills_one_rate_per_tick() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for _i: int in 5:
		limiter.try_consume(10)
	assert_false(limiter.try_consume(10), "empty")
	assert_true(limiter.try_consume(11), "one tick later there is a token")
	assert_false(limiter.try_consume(11), "and only one")
	assert_true(limiter.try_consume(13), "two ticks later, two more tokens")
	assert_true(limiter.try_consume(13), "the second")
	assert_false(limiter.try_consume(13), "and there is no third")


func test_fractional_rate_accumulates() -> void:
	var limiter := RateLimiter.new(0.25, 2.0)
	assert_true(limiter.try_consume(0), "first of the burst")
	assert_true(limiter.try_consume(0), "second of the burst")
	assert_false(limiter.try_consume(0), "empty")
	assert_false(limiter.try_consume(3), "three ticks give 0.75 tokens: not yet")
	assert_true(limiter.try_consume(4), "four ticks complete a token")
	assert_false(limiter.try_consume(4), "and nothing is left")


func test_never_exceeds_burst() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	limiter.try_consume(0)
	assert_near(limiter.get_tokens(10000), 5.0, 1e-9, "after a long time it goes back to the cap")
	var granted: int = 0
	for _i: int in 20:
		if limiter.try_consume(10000):
			granted += 1
	assert_eq(granted, 5, "never more tokens than the burst")


func test_cost_and_failed_attempts() -> void:
	var limiter := RateLimiter.new(0.0, 10.0)
	assert_true(limiter.try_consume(0, 4.0), "spends 4")
	assert_false(limiter.try_consume(0, 7.0), "7 do not fit in the remaining 6")
	assert_near(limiter.get_tokens(0), 6.0, 1e-9, "a failed attempt spends nothing")
	assert_true(limiter.try_consume(0, 6.0), "spends all 6")
	assert_false(limiter.try_consume(0, 0.5), "nothing is left now")
	assert_false(RateLimiter.new(1.0, 5.0).try_consume(0, 6.0),
			"a cost greater than the capacity is never granted")


func test_going_back_in_time_does_not_refill() -> void:
	var limiter := RateLimiter.new(1.0, 3.0)
	for _i: int in 3:
		limiter.try_consume(100)
	assert_false(limiter.try_consume(50), "an earlier tick does not refill")
	assert_false(limiter.try_consume(100), "nor when going back to the earlier tick")
	assert_true(limiter.try_consume(101), "but the following time does count from the last one")


func test_negative_parameters_are_clamped() -> void:
	var limiter := RateLimiter.new(-1.0, -5.0)
	assert_false(limiter.try_consume(0), "with no capacity it grants nothing")
	assert_false(limiter.try_consume(1000), "not even over time")


func test_same_seed_of_calls_gives_same_result() -> void:
	# Deterministic: with no clock or randomness, two buckets with the same calls give the same result.
	var a := RateLimiter.new(0.4, 6.0)
	var b := RateLimiter.new(0.4, 6.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var tick: int = 0
	for _i: int in 500:
		tick += rng.randi_range(0, 3)
		var cost: float = float(rng.randi_range(1, 3))
		assert_eq(a.try_consume(tick, cost), b.try_consume(tick, cost), "same result")


func test_grant_adds_tokens_above_the_burst_until_the_next_refill() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for _i: int in 5:
		limiter.try_consume(10)
	limiter.grant(10, 20.0)
	assert_near(limiter.get_tokens(10), 20.0, 1e-9, "the credit is added to what was left (0)")
	var granted: int = 0
	for _i: int in 30:
		if limiter.try_consume(10):
			granted += 1
	assert_eq(granted, 20, "and allows spending it all in the same tick, above the burst")
	# What is not spent is lost on the next refill: the cap goes back to being the burst.
	var spare := RateLimiter.new(1.0, 5.0)
	spare.grant(10, 50.0)
	assert_near(spare.get_tokens(10), 55.0, 1e-9, "5 from the burst plus 50 of credit")
	assert_near(spare.get_tokens(11), 5.0, 1e-9, "once a tick passes it is limited to the burst again")


func test_grant_refills_first_so_the_credit_is_not_erased() -> void:
	var limiter := RateLimiter.new(1.0, 5.0)
	for _i: int in 5:
		limiter.try_consume(10)
	# 3 ticks have passed since the last use: 3 tokens are refilled and then the credit is added.
	limiter.grant(13, 10.0)
	assert_near(limiter.get_tokens(13), 13.0, 1e-9, "3 refilled and 10 of credit")
	limiter.grant(13, -4.0)
	assert_near(limiter.get_tokens(13), 13.0, 1e-9, "a negative credit does not remove tokens")


# --- ServerPeer limiters ----------------------------------------------------------------------

func test_peer_unreliable_limiter_allows_two_per_tick() -> void:
	var peer := ServerPeer.new(3)
	assert_eq(peer.peer_id, 3, "the id it is given")
	var denied: int = 0
	for tick: int in range(100, 1100):
		for _i: int in 2:
			if not peer.limiter_unreliable.try_consume(tick):
				denied += 1
	assert_eq(denied, 0, "2 packets per tick (120 per second) always pass")

	var burst := ServerPeer.new(4)
	var granted: int = 0
	for _i: int in 100:
		if burst.limiter_unreliable.try_consume(500):
			granted += 1
	assert_eq(granted, 30, "a burst of 100 in one tick: only 30")


func test_peer_reliable_limiter_is_ten_per_second_with_burst_of_twenty() -> void:
	var peer := ServerPeer.new(1)
	var granted: int = 0
	for _i: int in 50:
		if peer.limiter_reliable.try_consume(0):
			granted += 1
	assert_eq(granted, 20, "burst of 20 reliable messages")
	# 600 ticks (10 s) at one message every 6 ticks (10 per second) must all pass.
	var sustained := ServerPeer.new(2)
	var denied: int = 0
	for tick: int in range(0, 600, 6):
		if not sustained.limiter_reliable.try_consume(tick):
			denied += 1
	assert_eq(denied, 0, "10 reliable messages per second pass")
	# At 20 per second the burst runs out and it starts rejecting.
	var flood := ServerPeer.new(5)
	denied = 0
	for tick: int in range(0, 600, 3):
		if not flood.limiter_reliable.try_consume(tick):
			denied += 1
	assert_true(denied > 0, "20 reliable messages per second cannot be sustained")


func test_peer_bytes_limiter_is_16kb_per_second_with_burst_of_4kb() -> void:
	var peer := ServerPeer.new(1)
	assert_true(peer.limiter_bytes.try_consume(0, 4096.0), "the burst is 4 KB")
	assert_false(peer.limiter_bytes.try_consume(0, 1.0), "and there is no more")
	assert_false(peer.limiter_bytes.try_consume(7, 2000.0), "7 ticks recover ~1.9 KB: not enough")
	assert_true(peer.limiter_bytes.try_consume(7, 1900.0), "but 1900 B does")
	assert_true(peer.limiter_bytes.try_consume(1000, 4096.0), "much later there is 4 KB again")
	assert_false(peer.limiter_bytes.try_consume(1000, 1.0), "but the bucket does not exceed 4 KB")
	# 1200 B per snapshot at 30 Hz is 36,000 B/s: it does not fit in a sustained rate of 16 KB/s.
	var flood := ServerPeer.new(2)
	var denied: int = 0
	for tick: int in range(0, 600, 2):
		if not flood.limiter_bytes.try_consume(tick, 1200.0):
			denied += 1
	assert_true(denied > 0, "a sustained 36 KB/s exceeds the 16 KB/s limit")
	# 8 KB/s always passes.
	var polite := ServerPeer.new(3)
	denied = 0
	for tick: int in range(0, 600, 2):
		if not polite.limiter_bytes.try_consume(tick, 270.0):
			denied += 1
	assert_eq(denied, 0, "~8 KB/s fits")


func test_peer_stall_credit_covers_the_ticks_the_server_missed() -> void:
	# The server lost 90 ticks: the client kept sending one batch per tick and they all arrive together.
	var peer := ServerPeer.new(1)
	peer.limiter_unreliable.try_consume(500)
	peer.grant_stall_credit(500, 89)
	var granted: int = 0
	for _i: int in 90:
		if peer.limiter_unreliable.try_consume(500) and peer.limiter_bytes.try_consume(500, 51.0):
			granted += 1
	assert_eq(granted, 90, "all 90 batches of 51 B pass (30 from the burst + 2 per lost tick)")
	# The credit is not a new cap: one tick later everything goes back to the normal burst.
	assert_near(peer.limiter_unreliable.get_tokens(501), ServerPeer.UNRELIABLE_BURST, 1e-6,
			"the leftover credit disappears")
	var late := ServerPeer.new(2)
	late.grant_stall_credit(10, 0)
	late.grant_stall_credit(10, -5)
	assert_near(late.limiter_unreliable.get_tokens(10), ServerPeer.UNRELIABLE_BURST, 1e-6,
			"without lost ticks there is no credit")


# --- Warnings and kicks -----------------------------------------------------------------------

func test_fifty_strikes_in_the_same_tick_kick() -> void:
	var peer := ServerPeer.new(1)
	for i: int in 49:
		assert_false(peer.add_strike(1000, "paquete malformado"), "warning %d does not kick" % i)
	assert_true(peer.add_strike(1000, "paquete malformado"), "warning 50 kicks")
	assert_eq(peer.strikes_total, 50, "all of them are counted")
	assert_eq(peer.last_strike_reason, "paquete malformado", "the reason is stored")
	assert_true(peer.add_strike(1000, "otro"), "and the following ones also ask for a kick")
	assert_eq(peer.last_strike_reason, "otro", "the last reason")


func test_strikes_must_fall_inside_the_window() -> void:
	# 50 warnings, one every 12 ticks: from the first to the last 588 ticks pass (< 600): it kicks.
	var fast := ServerPeer.new(1)
	var kicked: bool = false
	for i: int in 50:
		kicked = fast.add_strike(i * 12, "exceso de ritmo")
	assert_true(kicked, "50 warnings in 588 ticks kick")

	# One every 13 ticks: from the first to the fiftieth 637 ticks pass: there are never 50 within 600.
	var slow := ServerPeer.new(2)
	for i: int in 300:
		assert_false(slow.add_strike(i * 13, "exceso de ritmo"), "slow warning %d" % i)


func test_window_boundary() -> void:
	var inside := ServerPeer.new(1)
	for _i: int in 49:
		inside.add_strike(0, "x")
	assert_true(inside.add_strike(599, "x"), "a warning from tick 0 still counts at tick 599")

	var outside := ServerPeer.new(2)
	for _i: int in 49:
		outside.add_strike(0, "x")
	assert_false(outside.add_strike(600, "x"), "and stops counting at 600")
	assert_false(outside.add_strike(600, "x"), "there are still not 50 within the window")


func test_old_strikes_do_not_accumulate_forever() -> void:
	# An isolated warning every 100 ticks for a long time never kicks.
	var peer := ServerPeer.new(1)
	for i: int in 500:
		assert_false(peer.add_strike(i * 100, "ruido"), "isolated warning %d" % i)
	assert_eq(peer.strikes_total, 500, "even so they are counted in total")


func test_new_peer_has_clean_state() -> void:
	var peer := ServerPeer.new()
	assert_eq(peer.state, ServerPeer.State.AUTHENTICATING, "starts out authenticating")
	assert_eq(peer.strikes_total, 0, "no warnings")
	assert_true(peer.relevant.is_empty(), "no relevant entities")
	assert_true(peer.priority.is_empty(), "no priorities")
	assert_null(peer.entity, "no entity")
	assert_null(peer.input_queue, "no input queue")
	assert_not_null(peer.limiter_unreliable, "unreliable limiter")
	assert_not_null(peer.limiter_reliable, "reliable limiter")
	assert_not_null(peer.limiter_bytes, "byte limiter")


## Server ticks are u32 (414 days at 60 Hz already exceed 2^31): the warning window cannot
## store them in signed 32-bit integers (finding N5), or the subtraction with the oldest warning
## overflows and no one is ever kicked.
func test_strikes_beyond_two_to_the_thirty_one_ticks_still_kick() -> void:
	var big: int = 2147483648 + 5
	var peer := ServerPeer.new(1)
	var kicked_at: int = -1
	for i: int in 60:
		if peer.add_strike(big + i, "prueba") and kicked_at < 0:
			kicked_at = i
	assert_eq(kicked_at, 49, "warning 50 also kicks with ticks above 2^31")
	var spread := ServerPeer.new(2)
	var kicks: int = 0
	for i: int in 200:
		# One warning every 13 ticks: 46 per 600-tick window, it never reaches 50.
		if spread.add_strike(big + i * 13, "prueba"):
			kicks += 1
	assert_eq(kicks, 0, "and spaced-out warnings never kick")
	var max_tick: int = 4294967295
	var edge := ServerPeer.new(3)
	for i: int in 49:
		edge.add_strike(max_tick - 100 + i, "prueba")
	assert_true(edge.add_strike(max_tick - 50, "prueba"), "not even in the last range of the u32")
