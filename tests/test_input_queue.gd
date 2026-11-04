extends TestCase
## Tests for the server's input queue ([InputQueue], docs/red.md sections 4.1, 8.2 and
## 12): acceptance window, first copy, late ones, ack, lead time, substitution and, above all,
## that the substitute does not invent edges (with a real [PlayerCharacter]).
## [br][br]
## Convention of [code]next_tick[/code] in [method InputQueue.push]: the tick the server
## will simulate next. With the queue up to date it is [code]get_last_consumed() + 1[/code].

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const JUMP: int = PlayerInput.JUMP
const SPRINT: int = PlayerInput.SPRINT
const DODGE: int = PlayerInput.DODGE
const PRIMARY: int = PlayerInput.PRIMARY
const SUBSTITUTED: int = PlayerInput.SUBSTITUTED
## Ticks to wait for the character to settle on the ground before jumping.
const SETTLE_TICKS: int = 5
## Tick at which the jump starts being held.
const JUMP_HELD_FROM: int = 6

var _viewport: SubViewport
var _character: PlayerCharacter
var _jumped_count: int = 0
var _landed_ticks: Array[int] = []
var _current_tick: int = 0


func after_each() -> void:
	if is_instance_valid(_viewport):
		if _viewport.is_inside_tree():
			_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_character = null
	await wait_process_frames()


## Queue ready for a player that appeared after tick [param spawn_tick].
func _make_queue(spawn_tick: int = 0) -> InputQueue:
	var queue := InputQueue.new()
	queue.reset(spawn_tick, NetProtocol.neutral_input(spawn_tick, 0.0))
	return queue


func _input(tick: int, move: Vector2 = Vector2.ZERO, buttons: int = 0, yaw: float = 0.0,
		pitch: float = 0.0) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.buttons = buttons
	input.look_yaw = yaw
	input.look_pitch = pitch
	return input.quantized()


## Puts [param packet] in the input tray of tick [param tick].
static func _deliver(inbox: Dictionary, tick: int, packet: Array) -> void:
	if not inbox.has(tick):
		inbox[tick] = []
	(inbox[tick] as Array).append(packet)


# --- Acceptance window ------------------------------------------------------------------------

func test_accepts_inputs_inside_the_window() -> void:
	var queue: InputQueue = _make_queue()
	# The server is about to simulate tick 1: it accepts from 1 to 1 + 30.
	assert_eq(queue.push(_input(1), 10, 1), InputQueue.PushResult.ACCEPTED, "just in time")
	assert_eq(queue.push(_input(2), 10, 1), InputQueue.PushResult.ACCEPTED, "ahead")
	assert_eq(queue.push(_input(31), 10, 1), InputQueue.PushResult.ACCEPTED,
			"the limit: next_tick + 30")
	assert_eq(queue.too_early_count, 0, "none too early")


func test_rejects_inputs_too_far_ahead() -> void:
	var queue: InputQueue = _make_queue()
	assert_eq(queue.push(_input(32), 0, 1), InputQueue.PushResult.TOO_EARLY, "31 ahead")
	assert_eq(queue.push(_input(1000), 0, 1), InputQueue.PushResult.TOO_EARLY, "far ahead")
	assert_eq(queue.too_early_count, 2, "they are counted")
	assert_eq(queue.get_ack_tick(), 0, "and do not enter the queue")
	# With the server further ahead, the same tick now fits.
	assert_eq(queue.push(_input(32), 0, 2), InputQueue.PushResult.ACCEPTED, "when next_tick advances")
	assert_eq(queue.too_early_count, 2, "and it is not counted again")


func test_too_early_inputs_still_report_their_lead() -> void:
	# If the server loses ticks, the client is far ahead and all its inputs are too
	# early: the lead time is still recorded (saturated), so that TickSync finds out and
	# falls back. Without this the margin window stays empty forever.
	var queue: InputQueue = _make_queue()
	assert_eq(queue.push(_input(32), 0, 1), InputQueue.PushResult.TOO_EARLY, "31 ahead")
	assert_eq(queue.pop_min_lead(), 31, "the lead time of one that is too early counts")
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN, "and is reset when read")
	assert_eq(queue.push(_input(1000), 0, 1), InputQueue.PushResult.TOO_EARLY, "far ahead")
	assert_eq(queue.pop_min_lead(), 127, "saturates at 127")
	queue.push(_input(40), 0, 1)
	queue.push(_input(2), 0, 1)
	assert_eq(queue.pop_min_lead(), 1, "and is mixed with the accepted ones: the minimum wins")


func test_window_never_wraps_the_ring_onto_unconsumed_inputs() -> void:
	# Even if the caller passes an absurd next_tick, a tick that shares a slot with another not yet
	# consumed is never accepted.
	var queue: InputQueue = _make_queue()
	assert_eq(queue.push(_input(1), 0, 1), InputQueue.PushResult.ACCEPTED, "tick 1")
	assert_eq(queue.push(_input(65), 0, 1000), InputQueue.PushResult.TOO_EARLY,
			"tick 65 shares a slot with 1")
	assert_eq(queue.push(_input(64), 0, 1000), InputQueue.PushResult.ACCEPTED,
			"64 still fits")
	assert_eq(queue.take(1).tick, 1, "tick 1 stays intact")


func test_first_copy_wins_even_if_the_second_differs() -> void:
	var queue: InputQueue = _make_queue()
	var first: PlayerInput = _input(3, Vector2(1, 0), JUMP)
	var second: PlayerInput = _input(3, Vector2(0, 1), PRIMARY)
	assert_eq(queue.push(first, 5, 1), InputQueue.PushResult.ACCEPTED, "first copy")
	assert_eq(queue.push(second, 99, 1), InputQueue.PushResult.DUPLICATE, "second copy")
	queue.take(1)
	queue.take(2)
	var taken: PlayerInput = queue.take(3)
	assert_vec_near(taken.move, first.move, 1e-6, "the movement of the first is applied")
	assert_eq(taken.buttons, JUMP, "and its buttons")
	assert_eq(queue.get_view_offset_q(3), 5, "and its view_offset_q")


func test_copies_of_consumed_inputs_are_duplicates() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1, Vector2(0, 1)), 0, 1)
	queue.take(1)
	assert_eq(queue.push(_input(1, Vector2(1, 0)), 0, 2), InputQueue.PushResult.DUPLICATE,
			"redundant copy of an already consumed tick")
	assert_eq(queue.push(_input(0), 0, 2), InputQueue.PushResult.DUPLICATE, "spawn tick")
	assert_eq(queue.late_count, 0, "they are not late: they had been received")


func test_late_input_is_counted_once_and_not_applied() -> void:
	var queue: InputQueue = _make_queue()
	var substitute: PlayerInput = queue.take(1)
	assert_eq(queue.substitutions_total, 1, "tick 1 was substituted")
	assert_eq(queue.push(_input(1, Vector2(1, 0), JUMP), 8, 2), InputQueue.PushResult.LATE,
			"arrives when it has already been consumed")
	assert_eq(queue.late_count, 1, "it is counted")
	assert_eq(queue.push(_input(1, Vector2(1, 0), JUMP), 8, 2), InputQueue.PushResult.DUPLICATE,
			"the second copy of the late one is already a duplicate")
	assert_eq(queue.late_count, 1, "and it is not counted again")
	assert_eq(substitute.buttons, SUBSTITUTED, "what was applied does not change (no buttons and substituted)")
	assert_eq(queue.get_view_offset_q(1), -1, "a late one contributes no view_offset_q")
	assert_eq(queue.substitutions_total, 1, "the substitution is still counted")


func test_late_input_far_in_the_past_is_a_duplicate() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 101):
		queue.take(t)
	assert_eq(queue.push(_input(5), 0, 101), InputQueue.PushResult.DUPLICATE,
			"that tick's slot is already occupied by another: it is not a late one")
	assert_eq(queue.late_count, 0, "it is not counted")
	assert_eq(queue.push(_input(99), 0, 101), InputQueue.PushResult.LATE,
			"in contrast, a recent one is a late one")


func test_buttons_are_masked_to_valid_bits() -> void:
	var queue: InputQueue = _make_queue()
	var input: PlayerInput = _input(1)
	input.buttons = 0xFFFF
	queue.push(input, 0, 1)
	assert_eq(queue.take(1).buttons, NetProtocol.VALID_BUTTONS, "only bits 0-12")


# --- Ack --------------------------------------------------------------------------------------

func test_ack_without_inputs_is_the_last_consumed() -> void:
	var queue: InputQueue = _make_queue(40)
	assert_eq(queue.get_ack_tick(), 40, "just created: the spawn tick")
	assert_eq(queue.get_last_consumed(), 40, "get_last_consumed")
	queue.take(41)
	queue.take(42)
	assert_eq(queue.get_ack_tick(), 42, "after consuming with substitutions")
	assert_eq(queue.get_last_consumed(), 42, "get_last_consumed advances")


func test_ack_is_the_highest_contiguous_received_tick() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in [1, 2, 3, 5]:
		queue.push(_input(t), 0, 1)
	assert_eq(queue.get_ack_tick(), 3, "it cuts off at the gap at 4")
	queue.push(_input(4), 0, 1)
	assert_eq(queue.get_ack_tick(), 5, "when 4 arrives they join up")


func test_ack_with_a_gap_at_the_start_waits_for_it() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(2), 0, 1)
	queue.push(_input(3), 0, 1)
	assert_eq(queue.get_ack_tick(), 0, "1 is missing: nothing contiguous")
	queue.push(_input(1), 0, 1)
	assert_eq(queue.get_ack_tick(), 3, "1 arrives")


func test_ack_does_not_stay_stuck_after_a_substitution() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(2), 0, 1)
	queue.push(_input(3), 0, 1)
	assert_eq(queue.get_ack_tick(), 0, "before consuming 1")
	queue.take(1)
	assert_eq(queue.get_ack_tick(), 3, "1 was substituted and the ack jumps to 3")
	queue.take(2)
	queue.take(3)
	assert_eq(queue.get_ack_tick(), 3, "after consuming everything")
	queue.take(4)
	assert_eq(queue.get_ack_tick(), 4, "and the last consumed one holds")


func test_ack_contiguity_is_capped_by_the_window() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 32):
		queue.push(_input(t), 0, 1)
	assert_eq(queue.get_ack_tick(), 30, "at most 30 ticks ahead of the last consumed")


# --- Lead time --------------------------------------------------------------------------------

func test_min_lead_without_data_is_no_margin() -> void:
	var queue: InputQueue = _make_queue()
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN, "without inputs")
	queue.push(_input(1), 0, 1)
	assert_eq(queue.pop_min_lead(), 0, "an input just in time: lead time 0")
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN, "and it is reset when read")


func test_min_lead_is_the_smallest_since_the_last_pop() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(5), 0, 1)
	queue.push(_input(3), 0, 1)
	queue.push(_input(9), 0, 1)
	assert_eq(queue.pop_min_lead(), 2, "the minimum of 4, 2 and 8")
	queue.push(_input(12), 0, 2)
	assert_eq(queue.pop_min_lead(), 10, "only those after the reading count")


func test_min_lead_ignores_redundant_copies() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(10), 0, 1)
	assert_eq(queue.pop_min_lead(), 9, "first copy: lead time 9")
	# The redundant copy arrives when the server is already at tick 6: its lead time would be 4.
	assert_eq(queue.push(_input(10), 0, 6), InputQueue.PushResult.DUPLICATE, "redundant copy")
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN,
			"does not count: it would bias the measurement downwards")
	# Not within the same interval either.
	queue.push(_input(20), 0, 11)
	queue.push(_input(20), 0, 18)
	assert_eq(queue.pop_min_lead(), 9, "only the first copy of each tick")


func test_min_lead_counts_late_inputs_as_negative() -> void:
	var queue: InputQueue = _make_queue()
	queue.take(1)
	queue.take(2)
	assert_eq(queue.push(_input(1), 0, 3), InputQueue.PushResult.LATE, "late by two ticks")
	assert_eq(queue.pop_min_lead(), -2, "negative lead time: how much it was delayed")
	queue.push(_input(5), 0, 3)
	assert_eq(queue.push(_input(2), 0, 4), InputQueue.PushResult.LATE, "another late one")
	assert_eq(queue.pop_min_lead(), -2, "it keeps the minimum: that of 5 is 2 and the late one -2")


func test_a_lost_input_does_not_lower_the_margin() -> void:
	# Loss and delay are not mixed: what never arrives does not lower the margin.
	var queue: InputQueue = _make_queue()
	queue.push(_input(4), 0, 1)
	queue.take(1)
	queue.take(2)
	queue.take(3)
	assert_eq(queue.pop_min_lead(), 3,
			"three substitutions and the margin is still the measured one")


func test_min_lead_is_saturated_so_it_never_equals_no_margin() -> void:
	var queue: InputQueue = _make_queue()
	queue.take(1)
	assert_eq(queue.push(_input(1), 0, 500), InputQueue.PushResult.LATE, "very late")
	var lead: int = queue.pop_min_lead()
	assert_eq(lead, -127, "saturates at -127")
	assert_true(lead != NetProtocol.NO_MARGIN, "-128 is reserved for \"no data\"")


# --- Substitution -----------------------------------------------------------------------------

func test_take_returns_the_real_input_when_it_arrived() -> void:
	var queue: InputQueue = _make_queue()
	var pushed: PlayerInput = _input(1, Vector2(0.5, 1.0), SPRINT, 1.0, 0.2)
	queue.push(pushed, 0, 1)
	var taken: PlayerInput = queue.take(1)
	assert_eq(taken.tick, 1, "tick")
	assert_vec_near(taken.move, pushed.move, 1e-6, "move")
	assert_near(taken.look_yaw, pushed.look_yaw, 1e-6, "look_yaw")
	assert_near(taken.look_pitch, pushed.look_pitch, 1e-6, "look_pitch")
	assert_eq(taken.buttons, SPRINT, "buttons")
	assert_eq(queue.substitutions_total, 0, "there was no substitution")
	assert_eq(queue.get_last_consumed(), 1, "consumed")


func test_substitute_repeats_the_whole_last_input() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1, Vector2(0.0, 1.0), JUMP | SPRINT | PRIMARY | DODGE, 2.0, 0.3), 0, 1)
	queue.take(1)
	var substitute: PlayerInput = queue.take(2)
	assert_eq(substitute.tick, 2, "carries the tick being simulated")
	assert_vec_near(substitute.move, Vector2(0, 1), 1e-6, "repeats the movement")
	assert_near(substitute.look_yaw, _input(1, Vector2.ZERO, 0, 2.0).look_yaw, 1e-6, "and the yaw")
	assert_near(substitute.look_pitch, _input(1, Vector2.ZERO, 0, 0.0, 0.3).look_pitch, 1e-6,
			"and the pitch")
	assert_eq(substitute.buttons, JUMP | SPRINT | PRIMARY | DODGE | SUBSTITUTED,
			"repeats ALL the buttons (edges are neither removed nor invented) and carries the substituted mark")
	assert_eq(queue.substitutions_total, 1, "one substitution")


func test_only_substitutes_carry_the_substituted_bit() -> void:
	var queue: InputQueue = _make_queue()
	# A client that tries to set bit 15 does not succeed: push() discards it.
	var forged: PlayerInput = _input(1, Vector2(0, 1), PRIMARY | SUBSTITUTED)
	assert_eq(forged.buttons & SUBSTITUTED, SUBSTITUTED, "the test input carries the bit")
	queue.push(forged, 0, 1)
	var real: PlayerInput = queue.take(1)
	assert_eq(real.buttons, PRIMARY, "a real input never carries the mark (VALID_BUTTONS is applied)")
	var substitute: PlayerInput = queue.take(2)
	assert_eq(substitute.buttons, PRIMARY | SUBSTITUTED, "the substitute repeats PRIMARY and carries the mark")
	assert_eq(queue.take(3).buttons, PRIMARY | SUBSTITUTED, "and the next one too")
	queue.push(_input(4, Vector2(0, 1), PRIMARY), 0, 4)
	assert_eq(queue.take(4).buttons, PRIMARY, "the next real one again does not carry it")
	assert_eq(SUBSTITUTED & NetProtocol.VALID_BUTTONS, 0, "outside the valid buttons")


func test_substitute_stops_moving_after_six_ticks_without_real_inputs() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1, Vector2(0.0, 1.0), JUMP | SPRINT, 2.0, 0.3), 0, 1)
	queue.take(1)
	for t: int in range(2, 8):
		var repeated: PlayerInput = queue.take(t)
		assert_vec_near(repeated.move, Vector2(0, 1), 1e-6,
				"tick %d: it still repeats the movement (%d ticks after the last real one)" % [t, t - 1])
	var stopped: PlayerInput = queue.take(8)
	assert_vec_near(stopped.move, Vector2.ZERO, 1e-6, "at the seventh tick without inputs, move = 0")
	assert_eq(stopped.buttons, JUMP | SPRINT | SUBSTITUTED, "but the buttons are kept")
	assert_near(stopped.look_yaw, _input(1, Vector2.ZERO, 0, 2.0).look_yaw, 1e-6, "and the yaw")
	var still: PlayerInput = queue.take(9)
	assert_vec_near(still.move, Vector2.ZERO, 1e-6, "and it stays still")
	assert_eq(still.buttons, JUMP | SPRINT | SUBSTITUTED, "with the same buttons")
	assert_eq(queue.substitutions_total, 8, "eight substituted ticks (2 to 9)")


func test_real_input_after_a_long_silence_moves_again_and_restarts_the_count() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 21):
		queue.take(t)
	queue.push(_input(21, Vector2(1, 0)), 0, 21)
	assert_vec_near(queue.take(21).move, Vector2(1, 0), 1e-6, "the real one moves again")
	for t: int in range(22, 28):
		assert_vec_near(queue.take(t).move, Vector2(1, 0), 1e-6, "tick %d: it repeats it" % t)
	assert_vec_near(queue.take(28).move, Vector2.ZERO, 1e-6, "and after 6 ticks it stops again")


func test_a_press_that_starts_during_a_loss_enters_as_an_edge_in_the_next_real_input() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(14, Vector2.ZERO, 0), 0, 14)
	for t: int in range(1, 14):
		queue.take(t)
	assert_eq(queue.take(14).buttons, 0, "tick 14 real, no buttons")
	for t: int in range(15, 18):
		assert_eq(queue.take(t).buttons, SUBSTITUTED, "15-17 lost: \"no buttons\" is repeated")
	queue.push(_input(18, Vector2.ZERO, JUMP), 0, 18)
	assert_eq(queue.take(18).buttons, JUMP,
			"the press arrives in the first real input that carries it")


func test_substitute_of_the_spawn_is_the_neutral_input() -> void:
	var queue := InputQueue.new()
	var neutral: PlayerInput = NetProtocol.neutral_input(100, 1.5)
	queue.reset(100, neutral)
	assert_eq(queue.get_last_consumed(), 100, "the spawn counts as consumed")
	var first: PlayerInput = queue.take(101)
	assert_eq(first.tick, 101, "tick 101")
	assert_vec_near(first.move, Vector2.ZERO, 1e-6, "no movement")
	assert_eq(first.buttons, SUBSTITUTED, "no buttons, and substituted")
	assert_near(first.look_yaw, neutral.look_yaw, 1e-6, "the spawn's yaw")
	assert_near(first.look_pitch, 0.0, 1e-6, "no pitch")
	assert_eq(queue.substitutions_total, 1, "counts as a substitution")


func test_reset_clears_counters_and_slots() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1), 0, 1)
	queue.push(_input(50), 0, 1)
	queue.take(1)
	queue.take(2)
	queue.push(_input(1), 0, 3)
	queue.reset(200, NetProtocol.neutral_input(200, 0.0))
	assert_eq(queue.late_count, 0, "late_count")
	assert_eq(queue.too_early_count, 0, "too_early_count")
	assert_eq(queue.substitutions_total, 0, "substitutions_total")
	assert_eq(queue.pop_min_lead(), NetProtocol.NO_MARGIN, "no lead time")
	assert_eq(queue.get_ack_tick(), 200, "ack = spawn tick")
	assert_eq(queue.get_view_offset_q(1), -1, "empty slots")
	assert_eq(queue.push(_input(201), 0, 201), InputQueue.PushResult.ACCEPTED, "accepts again")


func test_view_offset_q() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(1), 37, 1)
	queue.push(_input(3), 1234, 1)
	assert_eq(queue.get_view_offset_q(1), 37, "received and unconsumed")
	assert_eq(queue.get_view_offset_q(2), -1, "not received")
	queue.take(1)
	queue.take(2)
	queue.take(3)
	assert_eq(queue.get_view_offset_q(1), 37, "real and consumed")
	assert_eq(queue.get_view_offset_q(2), -1, "substituted")
	assert_eq(queue.get_view_offset_q(3), 1234, "another real one")
	assert_eq(queue.get_view_offset_q(500), -1, "a tick that is not in the ring")
	for t: int in range(4, 80):
		queue.take(t)
	assert_eq(queue.get_view_offset_q(1), -1, "already overwritten")


func test_rewind_params_of_real_and_substituted_inputs() -> void:
	var queue: InputQueue = _make_queue()
	assert_eq(queue.get_rewind_params(1), Vector2i(0, 0), "without real inputs: nothing to rewind")
	# The input for tick 1 arrives just in time (lead time 0) and that of 3 with a lead time of 2.
	queue.push(_input(1), 37, 1)
	queue.push(_input(3), 1234, 1)
	assert_eq(queue.get_rewind_params(1), Vector2i(37, 0), "received and unconsumed")
	assert_eq(queue.get_rewind_params(3), Vector2i(1234, 2), "with its lead time")
	queue.take(1)
	assert_eq(queue.get_rewind_params(1), Vector2i(37, 0), "real and consumed")
	queue.take(2)
	assert_eq(queue.get_rewind_params(2), Vector2i(37, 0), "the substituted one uses those of the last real one")
	queue.take(3)
	assert_eq(queue.get_rewind_params(3), Vector2i(1234, 2))
	queue.take(4)
	queue.take(5)
	assert_eq(queue.get_rewind_params(5), Vector2i(1234, 2), "and it keeps using those of the last real one")
	# A late input changes nothing: that tick was already substituted.
	queue.push(_input(4), 5, 6)
	assert_eq(queue.get_rewind_params(4), Vector2i(1234, 2))
	queue.reset(10, NetProtocol.neutral_input(10, 0.0))
	assert_eq(queue.get_rewind_params(11), Vector2i(0, 0), "reset clears the last real ones")


func test_rewind_params_lead_comes_from_the_first_copy() -> void:
	var queue: InputQueue = _make_queue()
	queue.push(_input(5), 100, 3)
	queue.push(_input(5), 999, 5)
	assert_eq(queue.get_rewind_params(5), Vector2i(100, 2), "the first copy wins, with its lead time")


func test_typical_lead_is_the_median_of_the_recent_real_inputs() -> void:
	# R1: a client that advances only the inputs of a hit does not move the usual lead time.
	var queue: InputQueue = _make_queue()
	assert_eq(queue.get_typical_lead(10), 0, "without inputs, that of the last real one (0)")
	for t: int in range(1, 31):
		queue.push(_input(t), 0, t - 2)
		queue.take(t)
	assert_eq(queue.get_typical_lead(30), 2, "usual lead time: 2")
	for t: int in range(31, 37):
		queue.push(_input(t), 0, t - 14)
		queue.take(t)
	assert_eq(queue.get_rewind_params(36).y, 14, "the advanced inputs carry their lead time of 14")
	assert_eq(queue.get_typical_lead(36), 2, "but the usual one stays at 2 (6 out of 36 do not move the median)")
	queue.take(37)
	assert_eq(queue.get_typical_lead(37), 2, "a substituted one has no lead time and does not count")
	# A client that is ahead on all its inputs does move the usual one (the resolver bounds it).
	var early: InputQueue = _make_queue()
	for t: int in range(1, 80):
		early.push(_input(t), 0, t - 14)
		early.take(t)
	assert_eq(early.get_typical_lead(79), 14, "always ahead: 14")
	# Inputs older than the window do not count.
	var window: InputQueue = _make_queue()
	for t: int in range(1, 40):
		window.push(_input(t), 0, t)
		window.take(t)
	for t: int in range(40, 100):
		window.push(_input(t), 0, t - 5)
		window.take(t)
	assert_eq(window.get_typical_lead(99), 5, "the lead time 0 of the first ticks falls outside")


## H3a (docs/habilidades.md, 7.2): get_applied(tick) gives the input that was simulated at that tick, real or
## substitute (also if the real one arrived afterwards, late), and null if it has not been consumed yet or has left the ring.
func test_get_applied_returns_the_input_that_was_simulated() -> void:
	var queue: InputQueue = _make_queue(10)
	assert_null(queue.get_applied(11), "not consumed yet")
	queue.push(_input(11, Vector2(0.0, 1.0), PRIMARY, 0.5, 0.25), 32, 11)
	assert_null(queue.get_applied(11), "received but not consumed")
	queue.take(11)
	var real: PlayerInput = queue.get_applied(11)
	if assert_not_null(real, "the real one"):
		assert_eq(real.buttons, PRIMARY)
		assert_near(real.look_yaw, _input(11, Vector2.ZERO, 0, 0.5).look_yaw, 0.000001, "with its yaw")
		assert_near(real.look_pitch, _input(11, Vector2.ZERO, 0, 0.0, 0.25).look_pitch, 0.000001, "and its pitch")
	# 12 does not arrive: the substitute is applied, and stays so even if the real one arrives late.
	queue.take(12)
	var substituted: PlayerInput = queue.get_applied(12)
	if assert_not_null(substituted, "the substitute"):
		assert_eq(substituted.tick, 12)
		assert_true(substituted.has(SUBSTITUTED), "with its bit")
		assert_eq(substituted.buttons & ~SUBSTITUTED, PRIMARY, "repeats the buttons")
	assert_eq(queue.push(_input(12, Vector2.ZERO, DODGE), 0, 13), InputQueue.PushResult.LATE)
	var after_late: PlayerInput = queue.get_applied(12)
	assert_true(after_late != null and after_late.has(SUBSTITUTED) and not after_late.has(DODGE),
			"the late one does not change what was simulated")
	# Outside the ring, null.
	for tick: int in range(13, 13 + InputQueue.CAPACITY + 1):
		queue.take(tick)
	assert_null(queue.get_applied(11), "it is no longer in the ring")
	assert_not_null(queue.get_applied(13 + InputQueue.CAPACITY), "the last consumed one is")


func test_take_always_returns_the_requested_tick() -> void:
	var queue: InputQueue = _make_queue()
	for t: int in range(1, 200):
		var input: PlayerInput = queue.take(t)
		if input == null or input.tick != t:
			fail("take(%d) did not return an input of that tick" % t)
			return
	assert_eq(queue.substitutions_total, 199, "all substituted")


func test_random_network_conditions_keep_the_invariants() -> void:
	# Property: with loss, delay, reordering and duplicates, on each tick the first copy
	# that arrived in time is applied and, otherwise, a substitute; no tick is applied twice or skipped.
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var queue: InputQueue = _make_queue()
	var inbox: Dictionary = {}
	var sent: Dictionary = {}
	var first_arrival: Dictionary = {}
	var real_expected: int = 0
	var previous_ack: int = 0
	for server_tick: int in range(1, 1201):
		# The client is 3 ticks ahead and sends the last 4 inputs, each packet with its
		# own delay (0 to 5 ticks), with 20% loss and sometimes duplicated.
		var client_tick: int = server_tick + 3
		sent[client_tick] = _input(client_tick, Vector2(rng.randf(), rng.randf()).limit_length(1.0),
				rng.randi() & 0x1FF)
		if not rng.randf() < 0.2:
			var packet: Array = []
			for t: int in range(client_tick - 3, client_tick + 1):
				if sent.has(t):
					packet.append(sent[t])
			_deliver(inbox, server_tick + rng.randi_range(0, 5), packet)
			if rng.randf() < 0.1:
				_deliver(inbox, server_tick + rng.randi_range(0, 7), packet)
		# This tick's packets arrive, before simulating.
		for packet: Array in inbox.get(server_tick, []):
			for pushed: PlayerInput in packet:
				var result: int = queue.push(pushed.duplicate_input(), pushed.tick, server_tick)
				if result == InputQueue.PushResult.ACCEPTED and not first_arrival.has(pushed.tick):
					first_arrival[pushed.tick] = pushed
		inbox.erase(server_tick)
		var ack: int = queue.get_ack_tick()
		if ack < previous_ack:
			fail("the ack went backwards: %d -> %d at tick %d" % [previous_ack, ack, server_tick])
			return
		previous_ack = ack
		if ack < queue.get_last_consumed() or ack > queue.get_last_consumed() + 30:
			fail("ack %d outside [consumed, consumed + 30] at tick %d" % [ack, server_tick])
			return
		var taken: PlayerInput = queue.take(server_tick)
		if taken == null or taken.tick != server_tick:
			fail("take(%d) returned the wrong tick" % server_tick)
			return
		if first_arrival.has(server_tick):
			real_expected += 1
			var expected: PlayerInput = first_arrival[server_tick]
			if taken.buttons != expected.buttons or not taken.move.is_equal_approx(expected.move):
				fail("tick %d did not apply the first copy received" % server_tick)
				return
	assert_eq(queue.substitutions_total, 1200 - real_expected,
			"the substitutions are exactly the ticks with no input in time")
	assert_true(real_expected > 800, "with 20 %% loss and redundancy almost all arrive (%d)"
			% real_expected)
	assert_true(queue.late_count > 0, "with delays of up to 5 ticks there are late ones")
	assert_eq(queue.get_last_consumed(), 1200, "all 1200 ticks were consumed")


# --- No invented edges, with a real PlayerCharacter -------------------------------------------

## Minimal world in a SubViewport with its own physics space: a floor and a character.
func _build_physics_world() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	_viewport.add_child(floor_body)
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	_character = scene.instantiate() as PlayerCharacter
	_character.jumped.connect(func() -> void: _jumped_count += 1)
	_character.landed.connect(func() -> void: _landed_ticks.append(_current_tick))
	_viewport.add_child(_character)
	_jumped_count = 0
	_landed_ticks.clear()
	_current_tick = 0


## What the server does with a tick whose input was lost.
enum Substitute {
	## The real queue: repeats the full mask of the last applied input.
	QUEUE,
	## Control: a "no buttons" input, which is what the discarded design did. It serves to
	## check that the test does detect an invented edge.
	NAIVE_NEUTRAL,
}


## Scene input: neutral while the character settles and JUMP held afterwards.
func _scripted_input(tick: int) -> PlayerInput:
	return _input(tick, Vector2.ZERO, JUMP if tick >= JUMP_HELD_FROM else 0)


## Simulates [param total_ticks] ticks of [method _scripted_input] with the ticks in [param lost]
## lost, one per physics step. Returns the states (tick -> [PlayerState.encode]) and leaves in
## [member _jumped_count] and [member _landed_ticks] what happened.
func _run_scene(total_ticks: int, lost: Array[int], substitute: Substitute) -> Dictionary:
	await _build_physics_world_ready()
	var queue: InputQueue = _make_queue()
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var states: Dictionary = {}
	var last_applied: PlayerInput = NetProtocol.neutral_input(0, 0.0)
	for t: int in range(1, total_ticks + 1):
		await tree.physics_frame
		_current_tick = t
		var input: PlayerInput
		if substitute == Substitute.QUEUE:
			if not lost.has(t):
				queue.push(_scripted_input(t), 0, t)
			input = queue.take(t)
		else:
			if lost.has(t):
				input = last_applied.duplicate_input()
				input.tick = t
				input.buttons = 0
			else:
				input = _scripted_input(t)
		last_applied = input
		_character.simulate(input, dt)
		states[t] = _character.get_state().encode()
	return states


func _build_physics_world_ready() -> void:
	_build_physics_world()
	# Two physics steps so that the space registers the newly added bodies.
	await wait_physics_frames(2)


func _free_physics_world() -> void:
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_character = null
	await wait_process_frames()


func test_substitute_never_invents_edges_with_a_real_character() -> void:
	# Reference: no loss. It jumps once and lands at tick L.
	var no_loss: Array[int] = []
	var reference: Dictionary = await _run_scene(70, no_loss, Substitute.QUEUE)
	if not assert_eq(_jumped_count, 1, "reference: a single jump (held JUMP does not repeat)"):
		return
	if not assert_eq(_landed_ticks.size(), 2, "reference: lands on settling and after the jump"):
		return
	var landing: int = _landed_ticks[1]
	assert_true(landing > JUMP_HELD_FROM + 30 and landing < 65,
			"the jump lasts ~44 ticks (lands at %d)" % landing)
	await _free_physics_world()

	# Design case: JUMP held, inputs 15-17 lost and 18 with JUMP. It does not jump again
	# and the whole trajectory matches the reference's.
	var lost_mid: Array[int] = [15, 16, 17]
	var run_mid: Dictionary = await _run_scene(70, lost_mid, Substitute.QUEUE)
	assert_eq(_jumped_count, 1, "with 15-17 lost: there is still a single jump")
	assert_eq(_character.jump_buffer_ticks, 0, "and no press is left stored")
	for t: int in range(1, 71):
		if run_mid[t] != reference[t]:
			fail("the state of tick %d differs from the reference after losing 15-17" % t)
			break
	await _free_physics_world()

	# Loss just before landing: an invented edge at input 18 of this case (the
	# first real one after the loss) would fall within the jump buffer and jump again.
	var lost_landing: Array[int] = [landing - 5, landing - 4, landing - 3]
	var run_landing: Dictionary = await _run_scene(landing + 15, lost_landing, Substitute.QUEUE)
	assert_eq(_jumped_count, 1, "lost %s: no invented jump on landing" % [lost_landing])
	for t: int in range(1, landing + 16):
		if run_landing[t] != reference[t]:
			fail("the state of tick %d differs from the reference (loss before landing)" % t)
			break
	await _free_physics_world()

	# Control: with the "no buttons" substitute the same loss does invent the edge and jumps twice,
	# so the previous test would have detected the defect.
	await _run_scene(landing + 15, lost_landing, Substitute.NAIVE_NEUTRAL)
	assert_eq(_jumped_count, 2, "control: a substitute with no buttons invents a second jump")
	await _free_physics_world()
