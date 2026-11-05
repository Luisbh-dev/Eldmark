class_name InputQueue
extends RefCounted
## A player's input queue (docs/networking.md, sections 4.1, 8.2 and 12).
## [br][br]
## A ring of [constant CAPACITY] slots indexed by tick, with the tick as label. The server
## calls [method push] with each input that arrives and [method take] once per tick: the input
## of tick T is applied exactly on tick T, and if it has not arrived it is substituted. One input per
## player and tick: sending more does not make it run faster, and the server never waits for an input.
## [br][br]
## [b]The substitute never invents edges.[/b] It repeats the full button mask of the last
## applied input, so a button held through a loss (JUMP, PRIMARY, DODGE) does not
## reappear as a new press when the next real input arrives, because
## [member PlayerCharacter.prev_buttons] already contains it. After
## [constant NetProtocol.REPEAT_MOVE_TICKS] ticks without real inputs the movement goes to 0 (a
## client that left silently stands still) and the buttons are kept.
## [br][br]
## [b]The substitute carries [constant PlayerInput.SUBSTITUTED].[/b] The combat action machine
## (docs/combat.md, section 3.2) respects it: a repeated input does not count as a held press,
## does not turn a light attack into a charge, does not launch the heavy attack on reaching maximum charge and does not open
## parry windows, so no packet loss invents a heavy attack or a parry.

## Result of [method push].
enum PushResult {
	## First copy of an input within the window: it is stored.
	ACCEPTED,
	## Redundant copy (or older than what was already consumed): ignored.
	DUPLICATE,
	## Arrived late: that tick had already been substituted. Counted once and not applied.
	LATE,
	## Too far ahead of the server: discarded.
	TOO_EARLY,
}

## Ticks that [method get_typical_lead] looks back (fewer than [constant CAPACITY]: the oldest slots
## may already be overwritten).
const LEAD_WINDOW_TICKS: int = 60

## Slots of the ring. Greater than the acceptance window
## ([constant NetProtocol.MAX_INPUT_LEAD_TICKS] + 1), so two accepted ticks never share a
## slot.
const CAPACITY: int = 64

## State of a ring slot.
enum SlotState { EMPTY, RECEIVED, CONSUMED_REAL, SUBSTITUTED, LATE_SEEN }

## Inputs that arrived late (that tick had already been substituted). Each counts once.
var late_count: int = 0
## Inputs discarded for arriving too far ahead.
var too_early_count: int = 0
## Inputs substituted since [method reset] (those that did not arrive in time).
var substitutions_total: int = 0

var _slots: Array[Slot] = []
var _last_consumed: int = 0
var _last_real_tick: int = 0
var _last_applied: PlayerInput = PlayerInput.new()
# view_offset_q and lead of the last real input consumed (for the rewind of a tick whose
# input was substituted).
var _last_real_view_offset_q: int = 0
var _last_real_lead: int = 0
# Minimum lead since the last call to pop_min_lead(); _has_lead says whether there is data.
var _min_lead: int = 0
var _has_lead: bool = false


## A ring slot.
class Slot:
	var tick: int = -1
	var state: int = SlotState.EMPTY
	var input: PlayerInput = null
	var view_offset_q: int = -1
	## Lead with which the first copy arrived (the input's tick minus the one the server was
	## about to simulate); 0 in substituted ones.
	var lead: int = 0


	func set_input(new_tick: int, new_state: int, new_input: PlayerInput,
			new_view_offset_q: int, new_lead: int = 0) -> void:
		tick = new_tick
		state = new_state
		input = new_input
		view_offset_q = new_view_offset_q
		lead = new_lead


func _init() -> void:
	_slots.resize(CAPACITY)
	for i: int in CAPACITY:
		_slots[i] = Slot.new()


## Leaves the queue ready for a player who appears after simulating tick [param spawn_tick]: that
## tick counts as consumed and [param neutral] (the spawn's neutral input, already quantized) is the
## last one applied. Resets the counters to 0.
func reset(spawn_tick: int, neutral: PlayerInput) -> void:
	for slot: Slot in _slots:
		slot.set_input(-1, SlotState.EMPTY, null, -1)
	_last_consumed = spawn_tick
	_last_real_tick = spawn_tick
	_last_real_view_offset_q = 0
	_last_real_lead = 0
	_last_applied = neutral.duplicate_input()
	late_count = 0
	too_early_count = 0
	substitutions_total = 0
	_min_lead = 0
	_has_lead = false


## Stores [param input] (with its [param view_offset_q]) if it falls within the window
## (last consumed, [param next_tick] + [constant NetProtocol.MAX_INPUT_LEAD_TICKS]].
## [param next_tick] is the tick the server will simulate next.
## [br][br]
## The first copy of each tick wins even if the second is different. The lead is only measured
## with the first copy ([code]input.tick - next_tick[/code]: 0 is just in time, negative is
## late); also for inputs that are too early, which are discarded but count toward the
## measurement (saturated at 127). Limits the buttons to [constant NetProtocol.VALID_BUTTONS] (on
## [param input] itself).
func push(input: PlayerInput, view_offset_q: int, next_tick: int) -> PushResult:
	var t: int = input.tick
	if t > next_tick + NetProtocol.MAX_INPUT_LEAD_TICKS or t > _last_consumed + CAPACITY:
		too_early_count += 1
		# The lead is also recorded (saturated at 127): if the server has lost ticks and the
		# client is far ahead, it is the only way for TickSync to find out and fall back.
		_note_lead(t - next_tick)
		return PushResult.TOO_EARLY
	var slot: Slot = _slot(t)
	if t <= _last_consumed:
		if slot.tick == t and slot.state == SlotState.SUBSTITUTED:
			slot.state = SlotState.LATE_SEEN
			late_count += 1
			_note_lead(t - next_tick)
			return PushResult.LATE
		return PushResult.DUPLICATE
	if slot.tick == t and slot.state == SlotState.RECEIVED:
		return PushResult.DUPLICATE
	input.buttons &= NetProtocol.VALID_BUTTONS
	slot.set_input(t, SlotState.RECEIVED, input, view_offset_q, t - next_tick)
	_note_lead(t - next_tick)
	return PushResult.ACCEPTED


## The input the server applies on tick [param tick]: the real one if it arrived and, if not, the
## substitute (the last one applied with this tick, with the bit [constant PlayerInput.SUBSTITUTED] and with
## movement at 0 after [constant NetProtocol.REPEAT_MOVE_TICKS] ticks without real inputs).
## Never returns null. It must be called with consecutive ticks.
func take(tick: int) -> PlayerInput:
	var slot: Slot = _slot(tick)
	var input: PlayerInput
	if slot.tick == tick and slot.state == SlotState.RECEIVED:
		input = slot.input
		slot.state = SlotState.CONSUMED_REAL
		_last_real_tick = tick
		_last_real_view_offset_q = slot.view_offset_q
		_last_real_lead = slot.lead
	else:
		input = _last_applied.duplicate_input()
		input.tick = tick
		input.buttons |= PlayerInput.SUBSTITUTED
		if tick - _last_real_tick > NetProtocol.REPEAT_MOVE_TICKS:
			input.move = Vector2.ZERO
		slot.set_input(tick, SlotState.SUBSTITUTED, input, -1)
		substitutions_total += 1
	_last_applied = input
	_last_consumed = tick
	return input


## The input that was applied on tick [param tick] with [method take]: the real or the substituted one (with
## [constant PlayerInput.SUBSTITUTED]; if the real one arrived later, late, it is still the substitute, which is
## the one that was simulated). null if that tick has not been consumed yet or is no longer in the ring
## ([constant CAPACITY] ticks). Used by projectile aiming (docs/abilities.md, section
## 4.4: yaw, pitch and [constant PlayerInput.AIM_LEFT] of the shot) and by the downed system (H3b, H3c). It must not be
## modified: it is the same one that was simulated.
func get_applied(tick: int) -> PlayerInput:
	if tick > _last_consumed:
		return null
	var slot: Slot = _slot(tick)
	if slot.tick != tick:
		return null
	match slot.state:
		SlotState.CONSUMED_REAL, SlotState.SUBSTITUTED, SlotState.LATE_SEEN:
			return slot.input
	return null


## Value of the snapshot's [code]input_ack_tick[/code]: the highest contiguous tick received starting from
## the last consumed or, if there is none, the last consumed. It never gets stuck after a
## substituted input.
func get_ack_tick() -> int:
	var t: int = _last_consumed
	while t < _last_consumed + NetProtocol.MAX_INPUT_LEAD_TICKS:
		var slot: Slot = _slot(t + 1)
		if slot.tick != t + 1 or slot.state != SlotState.RECEIVED:
			break
		t += 1
	return t


## Minimum lead of the first copies (and of late ones) since the previous call, and
## resets it. [constant NetProtocol.NO_MARGIN] if there is no data. Saturated to [-127, 127] so that
## -128 only means "no data"; whoever writes it into the snapshot saturates it anyway.
func pop_min_lead() -> int:
	if not _has_lead:
		return NetProtocol.NO_MARGIN
	var lead: int = _min_lead
	_has_lead = false
	return lead


## [code]view_offset_q[/code] of the real input of tick [param tick], or -1 if it was substituted (or
## is no longer in the ring). Used by the phase 3 rewind.
func get_view_offset_q(tick: int) -> int:
	var slot: Slot = _slot(tick)
	if slot.tick != tick:
		return -1
	if slot.state == SlotState.RECEIVED or slot.state == SlotState.CONSUMED_REAL:
		return slot.view_offset_q
	return -1


## Rewind parameters of a hit whose input is from tick [param tick] (docs/combat.md,
## section 4.3): a [Vector2i] with [code]x = view_offset_q[/code] and [code]y = lead[/code] (the
## lead with which that input arrived). If the tick's input was real they are its own; if it was
## substituted (or is no longer in the ring), those of the last real input consumed; and
## [code](0, 0)[/code] if the player has not sent any yet.
func get_rewind_params(tick: int) -> Vector2i:
	var slot: Slot = _slot(tick)
	if slot.tick == tick and (slot.state == SlotState.RECEIVED \
			or slot.state == SlotState.CONSUMED_REAL):
		return Vector2i(slot.view_offset_q, slot.lead)
	return Vector2i(_last_real_view_offset_q, _last_real_lead)


## The client's [i]usual[/i] lead: the median of the first-copy leads of the real inputs
## (received or already consumed) of the [constant LEAD_WINDOW_TICKS] ticks up to [param tick], this one
## included; that of the last real input if there is none. Substituted ones do not count (they have no
## lead). The rewind (docs/combat.md, 4.3) uses it to bound the lead of a hit's input,
## which the client chooses: sending only its hit's inputs ahead of time does not move the median.
func get_typical_lead(tick: int) -> int:
	var leads := PackedInt32Array()
	for age: int in LEAD_WINDOW_TICKS:
		var t: int = tick - age
		var slot: Slot = _slot(t)
		if slot.tick == t and (slot.state == SlotState.RECEIVED \
				or slot.state == SlotState.CONSUMED_REAL):
			leads.append(slot.lead)
	if leads.is_empty():
		return _last_real_lead
	leads.sort()
	@warning_ignore("integer_division")
	return leads[leads.size() / 2]


## Tick of the last [b]real[/b] input consumed (not substituted or repeated by the server); the spawn's
## if none has arrived yet. The fortress uses it to not count in the circle whoever has gone
## 60 s without sending inputs.
func get_last_real_tick() -> int:
	return _last_real_tick


## Last tick consumed with [method take] (or the spawn's).
func get_last_consumed() -> int:
	return _last_consumed


func _slot(tick: int) -> Slot:
	return _slots[tick & (CAPACITY - 1)]


func _note_lead(lead: int) -> void:
	var saturated: int = clampi(lead, -127, 127)
	if not _has_lead or saturated < _min_lead:
		_min_lead = saturated
	_has_lead = true
