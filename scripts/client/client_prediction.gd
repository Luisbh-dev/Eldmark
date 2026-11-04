class_name ClientPrediction
extends RefCounted
## Local player prediction and reconciliation with the server (docs/networking.md, section 6).
##
## The client simulates its own character ahead of the server with the same quantized inputs
## that travel over the network; for each tick it stores the input and the resulting state in two
## rings of [constant HISTORY_SIZE] slots indexed by [code]tick % HISTORY_SIZE[/code] with the
## tick as a label. When the server's own state arrives for a tick, it is compared with the
## one predicted for that tick with [method PlayerState.equals_exact]:
## [br]- If it matches, nothing needs to be done.
## [br]- If not, the server's state is restored and the stored inputs are simulated again
## up to the last predicted tick, with [member PlayerCharacter.events_enabled] set to false. The body is
## corrected at once and the visible difference is spread by [CorrectionSmoother]; if the error exceeds
## [constant SNAP_DISTANCE] or there is a teleport, it snaps directly.
## [br][br]
## [b]Hook before simulating.[/b] [member before_simulate] is called with the tick about to be simulated
## right before each [method PlayerCharacter.simulate]: on spawn, on every step, and also on
## every tick of the replays. It is where [FortressView] puts the fort gate's layer that it had at
## that tick (docs/fortress.md, section 3.2), so that client and server simulate each tick with the same
## world even if reconciliation replays past ticks.
## [br][br]
## [b]Steps taken.[/b] [signal stepped] fires after [b]each[/b] [method step] (a physics tick can take 0,
## 1, 2 or more steps), never during reconciliation replays or the neutral advance of
## [method start]. It is where [ProjectileWorld] checks the commitment of a shot and creates the predicted
## arrow (docs/abilities.md, section 6.2): checking once per physics tick would miss the steps in between.
## [br][br]
## Everything that simulates must be called inside the physics tick and with
## [code]delta = 1 / Engine.physics_ticks_per_second[/code] ([method PlayerCharacter.simulate]).

## A prediction step was taken: [param input] is the input of tick [param tick] and [param state] the
## resulting state (the one stored in the ring: it must not be modified). Only in [method step].
signal stepped(tick: int, input: PlayerInput, state: PlayerState)

## What [method on_server_state] did with the received state.
enum Result {
	## State repeated or older than the last reconciled one: nothing was done.
	IGNORED,
	## It matched the predicted one exactly.
	MATCH,
	## It differed: the inputs were replayed from that tick and the error went to the smoother.
	CORRECTED,
	## The state was restored without comparing (it arrived ahead of what was predicted or is no longer in
	## the ring).
	HARD_RESET,
}

## Slots of each ring (a bit over 4 s at 60 ticks per second).
const HISTORY_SIZE: int = 256
## Error (m) beyond which it snaps directly instead of smoothing.
const SNAP_DISTANCE: float = 3.0
## Corrections smaller than this (m) are not counted in the statistics.
const CORRECTION_REPORT_DISTANCE: float = 0.001

## Hook called with the tick (int) about to be simulated, before each simulate() (also in the
## replays). Empty = none.
var before_simulate: Callable = Callable()

var _character: PlayerCharacter = null
var _controller: LocalPlayerController = null
var _smoother: CorrectionSmoother = null
var _dt: float = 1.0 / 60.0

var _started: bool = false
var _predicted_tick: int = 0
var _first_real_tick: int = 0
var _last_reconciled: int = 0
var _replaying: bool = false

# Rings: the label of each slot is the tick it holds (-1 = empty).
var _input_ticks: PackedInt64Array = PackedInt64Array()
var _inputs: Array[PlayerInput] = []
var _state_ticks: PackedInt64Array = PackedInt64Array()
var _states: Array[PlayerState] = []

# The server's substitution rule during a replay (see _input_or_substitute).
var _sub_last_applied: PlayerInput = null
var _sub_last_real_tick: int = 0

# Statistics (see get_stats).
var _matches: int = 0
var _ignored: int = 0
var _replays: int = 0
var _corrections: int = 0
var _resimulated_ticks: int = 0
var _last_correction: float = 0.0
var _max_correction: float = 0.0
var _hard_resets: int = 0


func _init() -> void:
	_clear_rings()


## Connects the prediction to the local character, its controller (which generates the inputs with
## [method LocalPlayerController.build_input], with [code]auto_step = false[/code]) and the
## correction smoother. [param delta] is the fixed physics step.
func setup(character: PlayerCharacter, controller: LocalPlayerController,
		smoother: CorrectionSmoother, delta: float) -> void:
	_character = character
	_controller = controller
	_smoother = smoother
	_dt = delta


## Starts the prediction with the server's spawn state ([param spawn_state], the state
## after simulating [param spawn_tick]). Up to [param first_real_tick] (exclusive) it advances with neutral
## inputs, which is what the server substitutes while no real one reaches it, so the two
## states match bit for bit from the first tick.
func start(spawn_tick: int, spawn_state: PlayerState, first_real_tick: int) -> void:
	_clear_rings()
	_reset_stats()
	_replaying = false
	_character.set_state(spawn_state)
	_character.reset_physics_interpolation()
	if _smoother != null:
		_smoother.clear()
	_store(spawn_tick, null, spawn_state.duplicate_state())
	_predicted_tick = spawn_tick
	_first_real_tick = first_real_tick
	_last_reconciled = spawn_tick - 1

	# The server substitutes these ticks (no real input ever reaches it): they carry the
	# substituted-input mark, like its own.
	var neutral: PlayerInput = NetProtocol.neutral_input(0, spawn_state.yaw)
	neutral.buttons |= PlayerInput.SUBSTITUTED
	var events_were_enabled: bool = _character.events_enabled
	_character.events_enabled = false
	for tick: int in range(spawn_tick + 1, first_real_tick):
		var input: PlayerInput = neutral.duplicate_input()
		input.tick = tick
		_notify_before_simulate(tick)
		_character.simulate(input, _dt)
		_store(tick, input, _character.get_state())
		_predicted_tick = tick
	_character.events_enabled = events_were_enabled
	_started = true


## true once [method start] has been called.
func is_started() -> bool:
	return _started


## One prediction step: builds the next tick's input with the controller (already
## quantized and with the accumulated presses), simulates the character, stores input and state and
## returns the input. Returns null if the prediction has not started.
func step() -> PlayerInput:
	if not _started:
		return null
	var tick: int = _predicted_tick + 1
	var input: PlayerInput = _controller.build_input(tick)
	_notify_before_simulate(tick)
	_character.simulate(input, _dt)
	var state: PlayerState = _character.get_state()
	_store(tick, input, state)
	_predicted_tick = tick
	stepped.emit(tick, input, state)
	return input


## Compares the own state the server sends for [param server_tick] with the predicted one and, if
## they differ, restores it and replays the inputs up to the last predicted tick. [param teleported]
## indicates that the teleport counter changed: then it is never smoothed. Returns a
## [enum Result].
func on_server_state(server_tick: int, state: PlayerState, teleported: bool) -> int:
	if not _started or state == null or server_tick <= _last_reconciled:
		_ignored += 1
		return Result.IGNORED
	_last_reconciled = server_tick
	if server_tick > _predicted_tick or not _has_state(server_tick):
		hard_reset(server_tick, state)
		return Result.HARD_RESET
	if not teleported and _states[_slot(server_tick)].equals_exact(state):
		_matches += 1
		return Result.MATCH

	var before: Vector3 = _character.global_position
	_character.set_state(state)
	_states[_slot(server_tick)] = state.duplicate_state()
	_replay_from(server_tick)
	var error: Vector3 = before - _character.global_position
	if teleported or error.length() > SNAP_DISTANCE:
		if _smoother != null:
			_smoother.clear()
		_character.reset_physics_interpolation()
	elif not error.is_zero_approx() and _smoother != null:
		_smoother.add_offset(error)
	_replays += 1
	_record_correction(error.length())
	return Result.CORRECTED


## Restores [param state] as the state of tick [param tick] without comparing and without smoothing. If
## [param tick] is not earlier than the last predicted one, it becomes the last predicted one (so
## [TickSync] recovers its lead); if it is, the inputs are replayed up to the last predicted one.
## It always ends with the smoother at zero and physics interpolation reset.
func hard_reset(tick: int, state: PlayerState) -> void:
	if not _started:
		return
	_last_reconciled = maxi(_last_reconciled, tick)
	_character.set_state(state)
	_store_state(tick, state.duplicate_state())
	if tick >= _predicted_tick:
		_predicted_tick = tick
	else:
		_replay_from(tick)
	if _smoother != null:
		_smoother.clear()
	_character.reset_physics_interpolation()
	_hard_resets += 1


## Last predicted tick (that of the last [method step]).
func get_predicted_tick() -> int:
	return _predicted_tick


## First tick with real input (P0); earlier ones were predicted with neutral input.
func get_first_real_tick() -> int:
	return _first_real_tick


## Input of tick [param tick], or null if it is no longer in the ring (or never existed: the spawn
## tick). It is the stored object: it must not be modified.
func get_input(tick: int) -> PlayerInput:
	var slot: int = _slot(tick)
	if _input_ticks[slot] != tick:
		return null
	return _inputs[slot]


## State predicted for [param tick], or null if it is no longer in the ring. It is the stored object: it
## must not be modified.
func get_predicted_state(tick: int) -> PlayerState:
	var slot: int = _slot(tick)
	if _state_ticks[slot] != tick:
		return null
	return _states[slot]


## true while inputs are being replayed (reconciliation or [method hard_reset]).
func is_replaying() -> bool:
	return _replaying


## Statistics since [method start]:
## [br]- [code]matches[/code]: server states that matched exactly.
## [br]- [code]ignored[/code]: repeated or old states that were ignored.
## [br]- [code]replays[/code]: times inputs had to be replayed because of a difference.
## [br]- [code]corrections[/code]: of those, the ones larger than [constant CORRECTION_REPORT_DISTANCE].
## [br]- [code]resimulated_ticks[/code]: ticks simulated again (replays and hard resets).
## [br]- [code]last_correction[/code] and [code]max_correction[/code] (m): last and largest correction
## above [constant CORRECTION_REPORT_DISTANCE].
## [br]- [code]hard_resets[/code]: times the state was restored without comparing.
func get_stats() -> Dictionary:
	return {
		"matches": _matches,
		"ignored": _ignored,
		"replays": _replays,
		"corrections": _corrections,
		"resimulated_ticks": _resimulated_ticks,
		"last_correction": _last_correction,
		"max_correction": _max_correction,
		"hard_resets": _hard_resets,
	}


# Simulates the ticks (from_tick, last predicted] again starting from the state the
# character already has (that of tick from_tick). Without jump or landing events, and storing the new
# states in the ring. The inputs are the stored ones and, where there are none, the substitutes.
func _replay_from(from_tick: int) -> void:
	_replaying = true
	var events_were_enabled: bool = _character.events_enabled
	_character.events_enabled = false
	_begin_substitution(from_tick)
	for tick: int in range(from_tick + 1, _predicted_tick + 1):
		_notify_before_simulate(tick)
		_character.simulate(_input_or_substitute(tick), _dt)
		_store_state(tick, _character.get_state())
	_character.events_enabled = events_were_enabled
	_replaying = false
	_resimulated_ticks += maxi(_predicted_tick - from_tick, 0)


# Prepares the substitution rule for a replay that starts from the state of from_tick: the last
# applied input is the one stored for that tick or, if it is gone, a neutral one with the state's
# buttons (prev_buttons) and no movement.
func _begin_substitution(from_tick: int) -> void:
	var known: PlayerInput = get_input(from_tick)
	if known != null:
		_sub_last_applied = known
		_sub_last_real_tick = from_tick
		return
	var base: PlayerInput = NetProtocol.neutral_input(from_tick, _character.yaw)
	base.buttons = _character.prev_buttons
	_sub_last_applied = base
	_sub_last_real_tick = from_tick - NetProtocol.REPEAT_MOVE_TICKS - 1


# The input stored for the tick if its label matches and, if not, the substitute the server would
# apply (docs/networking.md, 8.2): it repeats the last applied one with all its buttons and the
# PlayerInput.SUBSTITUTED mark, and sets movement to 0 if more than REPEAT_MOVE_TICKS ticks have
# passed since the last real one. Only needed after a hard_reset (gaps in the ring); in a normal
# reconciliation they are all there.
func _input_or_substitute(tick: int) -> PlayerInput:
	var stored: PlayerInput = get_input(tick)
	if stored != null:
		_sub_last_applied = stored
		_sub_last_real_tick = tick
		return stored
	var input: PlayerInput = _sub_last_applied.duplicate_input()
	input.tick = tick
	input.buttons |= PlayerInput.SUBSTITUTED
	if tick - _sub_last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
		input.move = Vector2.ZERO
	_sub_last_applied = input
	return input


# Notifies before_simulate of the tick about to be simulated.
func _notify_before_simulate(tick: int) -> void:
	if before_simulate.is_valid():
		before_simulate.call(tick)


func _record_correction(distance: float) -> void:
	if distance <= CORRECTION_REPORT_DISTANCE:
		return
	_corrections += 1
	_last_correction = distance
	_max_correction = maxf(_max_correction, distance)


func _has_state(tick: int) -> bool:
	return _state_ticks[_slot(tick)] == tick


# Stores the input (if not null) and the state of a tick. A tick without input (the spawn one)
# does not overwrite the input slot: its label, from another tick, makes get_input() return null.
func _store(tick: int, input: PlayerInput, state: PlayerState) -> void:
	var slot: int = _slot(tick)
	if input != null:
		_input_ticks[slot] = tick
		_inputs[slot] = input
	_state_ticks[slot] = tick
	_states[slot] = state


func _store_state(tick: int, state: PlayerState) -> void:
	_store(tick, null, state)


func _slot(tick: int) -> int:
	return posmod(tick, HISTORY_SIZE)


func _clear_rings() -> void:
	_input_ticks.resize(HISTORY_SIZE)
	_input_ticks.fill(-1)
	_state_ticks.resize(HISTORY_SIZE)
	_state_ticks.fill(-1)
	_inputs.clear()
	_inputs.resize(HISTORY_SIZE)
	_states.clear()
	_states.resize(HISTORY_SIZE)


func _reset_stats() -> void:
	_matches = 0
	_ignored = 0
	_replays = 0
	_corrections = 0
	_resimulated_ticks = 0
	_last_correction = 0.0
	_max_correction = 0.0
	_hard_resets = 0
