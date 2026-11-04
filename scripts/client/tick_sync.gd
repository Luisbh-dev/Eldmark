class_name TickSync
extends RefCounted
## Client lead over the server (docs/red.md, section 4.2).
##
## On every physics tick the client asks [method next_steps] how many prediction steps
## ([method ClientPrediction.step]) it must take:
## [br]- 1: the normal case.
## [br]- 2: to get ahead (double step).
## [br]- 0: to fall back (null step, one every two ticks).
## [br]- N: hard forward resynchronization.
## [br][br]
## Feedback comes from the server: each snapshot carries [code]input_margin[/code], the minimum lead with
## which inputs arrived since the previous snapshot (0 = just in time, negative = late). The last
## [constant WINDOW_SAMPLES] samples are kept and their minimum is used: if it falls below the target
## margin ([method get_target_margin]) the client must get ahead; if it stays well above, fall back
## gradually. It never jumps backward, because it would regenerate inputs already sent and, since the
## server keeps the first copy, there would be guaranteed mispredictions.
## [br][br]
## After each adjustment, samples are discarded until a snapshot arrives whose [code]input_ack_tick[/code]
## proves the server has already received inputs generated after the adjustment: this way it waits exactly
## the feedback delay, whatever the RTT, and there is no overshoot.

## Margin samples kept (~0.5 s at 30 snapshots per second).
const WINDOW_SAMPLES: int = 15
## Minimum and maximum target margin (ticks).
const MIN_TARGET: int = 1
const MAX_TARGET: int = 4
## Minimum margin (ticks) below which it resynchronizes forward at once.
const RESYNC_BEHIND: int = -8
## Maximum steps taken at once in a hard resynchronization.
const MAX_RESYNC_STEPS: int = 30
## Ticks, after the first one generated after an adjustment, that the server must have received for its
## margins to already reflect the adjustment.
const ACK_WAIT_TICKS: int = 2
## How much the window's minimum must exceed the target margin before starting to fall back.
const SLOW_DOWN_THRESHOLD: int = 2

## Number of adjustments made since [method start] (advances, retreats and resynchronizations).
var adjustments: int = 0

var _target: int = MIN_TARGET
var _window: Array[int] = []
## Pending extra steps (positive, getting ahead) or missing steps (negative, falling back).
var _debt: int = 0
var _slow_toggle: bool = false
var _ignore_until_ack: int = 0


## Starts a new session and returns P0, the first tick with real input:
## [code]spawn_tick + rtt_ticks + target margin + 1[/code]. [param spawn_tick] is the server tick at which
## the player spawned and [param rtt_ticks] the RTT measured during connection.
func start(spawn_tick: int, rtt_ticks: int) -> int:
	_window.clear()
	_debt = 0
	_slow_toggle = false
	_ignore_until_ack = 0
	adjustments = 0
	return spawn_tick + maxi(rtt_ticks, 0) + _target + 1


## Snapshot arrival jitter (ticks; measured by [InterpolationClock]). Sets the target margin:
## [code]clamp(1 + ceil(2 · jitter), 1, 4)[/code].
func set_jitter(jitter_ticks: float) -> void:
	_target = clampi(1 + ceili(2.0 * maxf(jitter_ticks, 0.0)), MIN_TARGET, MAX_TARGET)


## Records the margin of a new snapshot. [param input_ack_tick] is the snapshot's
## [code]input_ack_tick[/code]; [param input_margin] its [code]input_margin[/code]
## ([constant NetProtocol.NO_MARGIN] if the server had no data). Samples with no data or too old
## (earlier than an adjustment) are discarded.
func on_snapshot(input_ack_tick: int, input_margin: int) -> void:
	if input_margin == NetProtocol.NO_MARGIN or input_ack_tick < _ignore_until_ack:
		return
	_window.push_back(input_margin)
	if _window.size() > WINDOW_SAMPLES:
		_window.pop_front()


## Prediction steps to take on this physics tick. [param predicted_tick] is the last predicted tick
## (before taking this tick's steps). It is never negative; at most it is [constant MAX_RESYNC_STEPS].
func next_steps(predicted_tick: int) -> int:
	if _debt == 0 and not _window.is_empty():
		var low: int = _window_min()
		if low <= RESYNC_BEHIND:
			var jump: int = mini(_target - low, MAX_RESYNC_STEPS - 1)
			_after_adjust(predicted_tick + 1 + jump)
			return 1 + jump
		if low < _target:
			_debt = _target - low
		elif _window.size() == WINDOW_SAMPLES and low > _target + SLOW_DOWN_THRESHOLD:
			_debt = -(low - _target)
	if _debt > 0:
		_debt -= 1
		if _debt == 0:
			_after_adjust(predicted_tick + 2)
		return 2
	if _debt < 0:
		_slow_toggle = not _slow_toggle
		if not _slow_toggle:
			return 1
		_debt += 1
		if _debt == 0:
			_after_adjust(predicted_tick + 1)
		return 0
	return 1


## Current target margin (ticks), between [constant MIN_TARGET] and [constant MAX_TARGET].
func get_target_margin() -> int:
	return _target


## Minimum of the margin window, or [constant NetProtocol.NO_MARGIN] if it is empty.
func get_window_min() -> int:
	if _window.is_empty():
		return NetProtocol.NO_MARGIN
	return _window_min()


func _window_min() -> int:
	var low: int = _window[0]
	for sample: int in _window:
		low = mini(low, sample)
	return low


func _after_adjust(first_new_tick: int) -> void:
	_window.clear()
	_ignore_until_ack = first_new_tick + ACK_WAIT_TICKS
	adjustments += 1
