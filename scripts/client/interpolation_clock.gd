class_name InterpolationClock
extends RefCounted
## Clock with which the client draws remote players (docs/red.md, section 4.3).
##
## It is independent of [TickSync]: one fixes when to simulate and the other which instant to draw, so
## they do not fight. Everything is measured in whole physics ticks.
## [br][br]
## [b]Local measurement.[/b] With each snapshot, [code]offset = server_tick - local_tick[/code] is computed.
## [code]max_offset[/code] is the maximum over the last [constant WINDOW_TICKS] local ticks (the
## sample that has been delayed the least: a robust estimator of the minimum latency), and jitter is
## the exponential average (α = 0.1) of [code]max_offset - offset[/code].
## [br][br]
## [b]Step down.[/b] That estimator only works if the server clock does not go backwards relative
## to the client's. If the server loses ticks (a stall) or latency rises steadily, the
## offsets drop suddenly: the 2 s maximum would remember the old ones and the render tick would run ahead
## of the data. When everything in the last [constant RECENT_TICKS] ticks is more than
## [constant STEP_DOWN_TICKS] ticks below that maximum, the earlier samples are forgotten.
## [br][br]
## [b]Delay.[/b] [code]clamp(2 · SNAPSHOT_INTERVAL_TICKS + 2 · jitter, 4, 12)[/code] ticks, that is,
## 67 to 200 ms. [method advance] moves the render tick toward
## [code]local_tick + max_offset - delay[/code] at a rate of 1 tick per physics tick, with a
## correction of at most 0.05 ticks per tick (or with a jump, if the error exceeds 10 ticks).
## [br][br]
## [b]No bias.[/b] The pseudocode in section 4.3 compared this tick's target with the
## previous tick's render tick (before adding 1 to it), and the correction converged to a render tick 1
## tick ahead of the target: the effective delay was the delay minus 1 tick, and with the minimum
## of 4 ticks it extrapolated more often. Here it first advances 1 tick and corrects afterwards, so
## the render tick converges exactly to the target (a decision made overnight, see
## docs/informe_noche.md).
## [br][br]
## Remotes are drawn in [code]_process[/code] at the instant
## [code]render_tick + Engine.get_physics_interpolation_fraction()[/code].

## Window (local ticks) of the maximum of offsets: 2 s at 60 ticks per second.
const WINDOW_TICKS: int = 120
## Weight of each sample in the exponential average of the jitter.
const JITTER_ALPHA: float = 0.1
## Below this jitter (ticks) it is considered 0. Without this, the exponential average never reaches
## 0 after a bump and [TickSync]'s target margin ([code]ceil(2 · jitter)[/code]) would
## stay one tick too high forever.
const JITTER_EPSILON: float = 0.001
## Minimum and maximum delay (ticks).
const MIN_DELAY_TICKS: float = 4.0
const MAX_DELAY_TICKS: float = 12.0
## Step down (finding N3). If the server loses ticks, or latency rises steadily, the offsets drop
## suddenly and stay down; the maximum over 120 ticks would remember the old ones
## for 2 s and the render tick would run ahead of the data that exists (it would
## extrapolate 6 ticks and the remote would stand still). So, if the maximum of the full
## window exceeds by more than [constant STEP_DOWN_TICKS] ticks that of the last
## [constant RECENT_TICKS] local ticks, the samples before those last ones are discarded.
const RECENT_TICKS: int = 30
const STEP_DOWN_TICKS: int = 4
## If the render tick strays further than this (ticks) from the target, it jumps to it.
const SNAP_TICKS: float = 10.0
## Fraction of the error corrected on each tick, and limit of that correction (ticks per tick).
const CORRECTION_GAIN: float = 0.1
const MAX_CORRECTION_PER_TICK: float = 0.05

# Samples (local tick, offset) with strictly decreasing offsets: the monotonic queue whose
# first element is the window's maximum. Two parallel 64-bit arrays: server ticks
# are u32 and the offset exceeds 2^31 after 414 days of uptime (a Vector2i does not fit).
var _sample_ticks: PackedInt64Array = PackedInt64Array()
var _sample_offsets: PackedInt64Array = PackedInt64Array()
var _max_offset: int = 0
var _jitter: float = 0.0
var _delay: float = MIN_DELAY_TICKS
var _render_tick: float = 0.0
var _started: bool = false


## Records a snapshot: [param server_tick] is its tick and [param local_tick] the client's physics tick
## at which the packet was read. It is also called with out-of-order snapshots.
func on_snapshot(server_tick: int, local_tick: int) -> void:
	var offset: int = server_tick - local_tick
	while not _sample_ticks.is_empty() and _sample_offsets[_sample_offsets.size() - 1] <= offset:
		_sample_ticks.remove_at(_sample_ticks.size() - 1)
		_sample_offsets.remove_at(_sample_offsets.size() - 1)
	_sample_ticks.append(local_tick)
	_sample_offsets.append(offset)
	while _sample_ticks[0] <= local_tick - WINDOW_TICKS:
		_sample_ticks.remove_at(0)
		_sample_offsets.remove_at(0)
	_drop_samples_before_a_step_down(local_tick)
	_max_offset = _sample_offsets[0]

	_jitter += JITTER_ALPHA * (float(_max_offset - offset) - _jitter)
	if _jitter < JITTER_EPSILON:
		_jitter = 0.0
	_delay = clampf(2.0 * NetProtocol.SNAPSHOT_INTERVAL_TICKS + 2.0 * _jitter,
			MIN_DELAY_TICKS, MAX_DELAY_TICKS)


# If everything in the last RECENT_TICKS ticks is more than STEP_DOWN_TICKS below the window's maximum,
# it is a sustained step and not a bump: the earlier samples are forgotten. The queue is monotonic, so
# the first recent sample is the maximum of the recent ones.
func _drop_samples_before_a_step_down(local_tick: int) -> void:
	var recent: int = 0
	while _sample_ticks[recent] <= local_tick - RECENT_TICKS:
		recent += 1
	if recent > 0 and _sample_offsets[0] - _sample_offsets[recent] > STEP_DOWN_TICKS:
		_sample_ticks = _sample_ticks.slice(recent)
		_sample_offsets = _sample_offsets.slice(recent)


## Advances the clock one physics tick ([param local_tick] is the current local tick) and returns the
## render tick. Until the first snapshot arrives there is nothing to measure with, so it does not start and
## returns 0.
func advance(local_tick: int) -> float:
	if _sample_ticks.is_empty():
		return _render_tick
	var target: float = float(local_tick + _max_offset) - _delay
	if not _started or absf(target - _render_tick) > SNAP_TICKS:
		_render_tick = target
		_started = true
	else:
		var advanced: float = _render_tick + 1.0
		_render_tick = advanced + clampf((target - advanced) * CORRECTION_GAIN,
				-MAX_CORRECTION_PER_TICK, MAX_CORRECTION_PER_TICK)
	return _render_tick


## Render tick (without the physics interpolation fraction) of the last [method advance].
func get_render_tick() -> float:
	return _render_tick


## Current render delay (ticks) relative to the server.
func get_delay_ticks() -> float:
	return _delay


## Snapshot arrival jitter (ticks).
func get_jitter_ticks() -> float:
	return _jitter
