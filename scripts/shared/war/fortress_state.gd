class_name FortressState
extends RefCounted
## State of a capturable fort and its state machine (docs/fuerte.md, sections 1.3 to 1.5). Pure,
## in ticks and without nodes: the server advances it with [method advance] every tick and the
## client rebuilds it from the OBJECT_STATE fields ([FortressFields]) and the capture formula
## ([method progress_at]).
## [br][br]
## [b]Phases[/b] ([enum Phase]): [code]GARRISONED[/code] (the captain lives, the circle is
## inactive), [code]VULNERABLE[/code] (the captain has died and the circle is active),
## [code]CAPTURING[/code] (a realm is capturing) and [code]CONSOLIDATING[/code] (just captured:
## circle inactive until the new owner's garrison arrives). The owner [member owner] is 0 while the
## fort is neutral (held by the Hollow).
## [br][br]
## [b]Integer progress[/b] (section 1.3). The maximum is [member progress_max] (the capture ticks
## times [constant PROGRESS_PER_CAPTURE_TICK]) and the rates, in units per tick, are
## [code]12 / 16 / 20 / 24[/code] with 1 / 2 / 3 / 4 or more attackers
## ([method rate_for_count]), [constant EMPTY_DECAY_RATE] with the circle empty past the delay and
## [constant FOREIGN_DECAY_RATE] when inside there are only those who do not capture. The capture
## travels as a formula, [code]progress(t) = clamp(p0 + rate · (t − t0), 0, P)[/code]
## ([method progress_at]), which is re-anchored ([code]p0[/code], [code]t0[/code] and
## [code]rate[/code]) every time the rate changes. A new rate decided at tick [code]s[/code] applies
## from [code]s[/code]: the progress at tick [code]s + 1[/code] is that of [code]s[/code] plus that
## rate.
## [br][br]
## [b]Effects that are not part of the state[/b]: whoever uses it (the server controller) looks at
## the differences after each call to create or remove NPCs, move the gate's collision, repeat
## notices and send OBJECT_STATE ([method changed_fields_since]). Repairing the gate while the
## opening is occupied is deferred there: the state only tracks health.
## [br][br]
## Shared: depends on neither the client nor the server.

enum Phase { GARRISONED, VULNERABLE, CAPTURING, CONSOLIDATING }

## Progress units per capture tick of the definition (30 s -> 1800 ticks -> 21,600).
const PROGRESS_PER_CAPTURE_TICK: int = 12
## Rate with the circle empty past the delay (one third of a single attacker's).
const EMPTY_DECAY_RATE: int = -4
## Rate when inside there are only those who do not capture (owner or another realm).
const FOREIGN_DECAY_RATE: int = -24
## Minimum ticks between two "fort under attack" notices (60 s).
const ATTACK_NOTICE_INTERVAL_TICKS: int = 3600
## Minimum ticks between two "capture contested" notices (10 s).
const CONTESTED_NOTICE_INTERVAL_TICKS: int = 600
## How many ticks apart the server recounts presence (between recounts the last one is kept).
const PRESENCE_RECOUNT_TICKS: int = 6
## Value of tick fields meaning "never" or "none".
const NO_TICK: int = -1

## Owning realm (network code; 0 = neutral, the Hollow).
var owner: int = 0
## Current phase ([enum Phase]).
var phase: int = Phase.GARRISONED
## Tick at which the phase began.
var phase_tick: int = 0
## true if the captain (the owner's or the Hollow's) is alive.
var captain_alive: bool = true
## Tick at which the captain respawns in the VULNERABLE phase ([constant NO_TICK] if none).
var captain_respawn_tick: int = NO_TICK
## Garrison guards alive (counted by whoever creates them, with [method set_guards_alive]).
var guards_alive: int = 0
## Tick at which the dead guards respawn ([constant NO_TICK] if none is pending).
var guards_respawn_tick: int = NO_TICK
## Current and maximum health of the gate.
var gate_health: int = 0
var gate_max: int = 0
## Tick of the last hit on the gate ([constant NO_TICK] if it has not been touched since the last
## repair).
var gate_last_damage_tick: int = NO_TICK
## Realm that is capturing (0 if nobody).
var capture_realm: int = 0
## Capture formula: anchor tick, rate (units per tick, can be negative) and progress at that tick.
var capture_start_tick: int = 0
var capture_rate: int = 0
var capture_progress_at_start: int = 0
## true if the capture (or the circle) is contested: inside there is more than one side.
var contested: bool = false
## Tick since which the circle has been empty during a capture ([constant NO_TICK] if it is not).
var empty_since_tick: int = NO_TICK
## The fort counts as under attack until this tick (it cannot be respawned at).
var under_attack_until_tick: int = 0
## Last "fort under attack" and "capture contested" notice ([constant NO_TICK] if none).
var last_attack_notice_tick: int = NO_TICK
var last_contested_notice_tick: int = NO_TICK
## Players present in the circle from each realm (positions 0 to 3), for the interface.
var presence: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## Maximum capture progress ([constant PROGRESS_PER_CAPTURE_TICK] times the capture ticks).
var progress_max: int = 0
## Tick of the last reset to neutral (or of creation), from which the periodic reset counts.
var last_reset_tick: int = 0
## Factor (1 = normal) by which the positive capture rate is multiplied: it is the
## [code]fort_capture_speed[/code] debug command. It does not travel over the network: the client
## only sees the already multiplied rate in [member capture_rate]. Decay is not multiplied.
var capture_rate_multiplier: int = 1

# Definition constants in ticks, copied when the state is created so that the interface methods
# (which do not receive the definition) have them.
var _captain_respawn_ticks: int = 0
var _under_attack_ticks: int = 0
var _gate_repair_ticks: int = 0
# Largest number of guards there has been in the current garrison: the missing ones are those that
# respawn.
var _guards_expected: int = 0


## State of a newly created fort: neutral, guarded by the Hollow and its captain, with the gate
## intact and no capture.
static func initial(def: FortressDefinition, tick: int) -> FortressState:
	var state := FortressState.new()
	state._configure(def)
	state.phase_tick = tick
	state.capture_start_tick = tick
	state.last_reset_tick = tick
	state.gate_health = def.gate_health
	state.gate_max = def.gate_health
	return state


## Capture rate (units per tick) with [param count] attackers inside: 12, 16, 20 and 24 with 1, 2,
## 3 and 4 or more; 0 if there are none.
static func rate_for_count(count: int) -> int:
	match count:
		0:
			return 0
		1:
			return 12
		2:
			return 16
		3:
			return 20
	return 24 if count > 3 else 0


## Advances to tick [param tick] with the current presence ([param presence_counts]: the count per
## realm, positions 0 to 3, from [method FortressPresence.count]). It is called every tick, so that
## transitions land on the exact tick; the count is taken every
## [constant PRESENCE_RECOUNT_TICKS] ticks and repeated in between. Returns the ids of the
## [WarEvents] emitted, in order.
func advance(def: FortressDefinition, tick: int, presence_counts: PackedInt32Array) -> PackedInt32Array:
	_set_presence(presence_counts)
	var reset_ticks: int = def.reset_to_neutral_ticks()
	if reset_ticks > 0 and tick - last_reset_tick >= reset_ticks:
		return reset_to_neutral(def, tick)
	_arm_guards_timer(def, tick)
	match phase:
		Phase.VULNERABLE:
			return _advance_vulnerable(def, tick)
		Phase.CAPTURING:
			return _advance_capturing(def, tick)
		Phase.CONSOLIDATING:
			if tick - phase_tick >= def.consolidation_ticks():
				_enter_garrisoned(tick)
	return PackedInt32Array()


## The captain dies at tick [param tick], at the hands of realm [param killer_realm]. If it was
## guarding the fort, it becomes VULNERABLE (the circle activates and the captain will respawn
## after [member FortressDefinition.captain_respawn_s] if nobody captures) and returns
## [constant WarEvents.CAPTAIN_DOWN]; in any other phase it does nothing.
func on_captain_died(tick: int, _killer_realm: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	if phase != Phase.GARRISONED or not captain_alive:
		return events
	captain_alive = false
	phase = Phase.VULNERABLE
	phase_tick = tick
	captain_respawn_tick = tick + _captain_respawn_ticks
	events.append(WarEvents.CAPTAIN_DOWN)
	return events


## The captain returns ahead of schedule: the Hollow's "full respawn" (docs/fuerte.md, 4.3)
## includes the Ford Captain when the fort is still neutral and with no players nearby. It only
## does something in the VULNERABLE phase (not while someone is capturing): it returns to
## GARRISONED with the captain alive. Returns true if the captain has respawned.
func respawn_captain(tick: int) -> bool:
	if phase != Phase.VULNERABLE:
		return false
	_enter_garrisoned(tick)
	return true


## The gate takes [param amount] damage from realm [param attacker_realm] at tick [param tick].
## It subtracts health (down to 0), records the hit (the gate is repaired after a while without
## damage and the fort counts as under attack) and returns the notices:
## [constant WarEvents.UNDER_ATTACK] (at most one per minute) and [constant WarEvents.GATE_BROKEN]
## if this hit breaks it. An already broken gate or a non-positive damage do nothing.
func on_gate_damaged(tick: int, amount: int, attacker_realm: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	if amount <= 0 or gate_health <= 0:
		return events
	gate_health = maxi(gate_health - amount, 0)
	gate_last_damage_tick = tick
	_mark_under_attack(tick)
	if claim_attack_notice(tick):
		events.append(WarEvents.UNDER_ATTACK)
	if gate_health == 0:
		events.append(WarEvents.GATE_BROKEN)
	return events


## A fort defender takes damage from realm [param attacker_realm] at tick [param tick]: the fort
## counts as under attack for another [member FortressDefinition.under_attack_s]. It returns no
## notices; whoever wants the "fort under attack" one requests it with [method claim_attack_notice].
func on_defender_damaged(tick: int, _attacker_realm: int) -> void:
	_mark_under_attack(tick)


## Grants the "fort under attack" notice if at least a minute has passed since the last one, and
## records it. [method on_gate_damaged] already uses it for hits on the gate; the controller calls
## it for hits on defenders.
func claim_attack_notice(tick: int) -> bool:
	if last_attack_notice_tick != NO_TICK and tick - last_attack_notice_tick < ATTACK_NOTICE_INTERVAL_TICKS:
		return false
	last_attack_notice_tick = tick
	return true


## Says how many garrison guards are alive ([param count]). The largest number ever given is that
## of the full garrison; if some are missing, [method advance] arms the respawn timer
## ([method guards_respawn_due]).
func set_guards_alive(count: int) -> void:
	guards_alive = maxi(count, 0)
	_guards_expected = maxi(_guards_expected, guards_alive)
	if guards_alive >= _guards_expected:
		guards_respawn_tick = NO_TICK


## true if at tick [param tick] it is time to replenish the missing guards: the phase is
## GARRISONED or VULNERABLE and [member FortressDefinition.guard_respawn_s] has passed since it was
## noticed that they were missing. Whoever creates them then calls [method set_guards_alive] with
## the total.
func guards_respawn_due(tick: int) -> bool:
	if phase != Phase.GARRISONED and phase != Phase.VULNERABLE:
		return false
	return guards_respawn_tick != NO_TICK and guards_alive < _guards_expected \
			and tick >= guards_respawn_tick


## Returns the fort to neutral at tick [param tick] (periodic reset or [code]fort_reset[/code]
## command): GARRISONED with no owner, with the Hollow and the Ford Captain, the gate intact and
## the capture at zero. Players inside are not moved. Returns [constant WarEvents.FORT_RESET].
func reset_to_neutral(def: FortressDefinition, tick: int) -> PackedInt32Array:
	_configure(def)
	owner = 0
	phase = Phase.GARRISONED
	phase_tick = tick
	captain_alive = true
	captain_respawn_tick = NO_TICK
	guards_alive = 0
	guards_respawn_tick = NO_TICK
	_guards_expected = 0
	gate_health = def.gate_health
	gate_max = def.gate_health
	gate_last_damage_tick = NO_TICK
	_clear_capture(tick)
	under_attack_until_tick = tick
	last_attack_notice_tick = NO_TICK
	last_contested_notice_tick = NO_TICK
	last_reset_tick = tick
	return PackedInt32Array([WarEvents.FORT_RESET])


## Capture progress (0 to [member progress_max]) at tick [param tick] (may be fractional: the
## client evaluates it at its draw tick). It is the formula
## [code]clamp(p0 + rate · (t − t0), 0, P)[/code], rounded down.
func progress_at(tick: float) -> int:
	var value: float = float(capture_progress_at_start) + float(capture_rate) * (tick - float(capture_start_tick))
	return clampi(floori(value), 0, progress_max)


## [FortressFields] fields whose value differs from that of [param other], in id order. This is
## what goes into an OBJECT_STATE after advancing the state from a copy
## ([method duplicate_state]).
func changed_fields_since(other: FortressState) -> PackedInt32Array:
	var changed := PackedInt32Array()
	for field_id: int in FortressFields.all_ids():
		if FortressFields.get_value(self, field_id) != FortressFields.get_value(other, field_id):
			changed.append(field_id)
	return changed


## Independent copy (to compare before and after advancing, or to keep history).
func duplicate_state() -> FortressState:
	var copy := FortressState.new()
	copy.copy_from(self)
	return copy


## Copies all of [param other]'s state into this one.
func copy_from(other: FortressState) -> void:
	owner = other.owner
	phase = other.phase
	phase_tick = other.phase_tick
	captain_alive = other.captain_alive
	captain_respawn_tick = other.captain_respawn_tick
	guards_alive = other.guards_alive
	guards_respawn_tick = other.guards_respawn_tick
	gate_health = other.gate_health
	gate_max = other.gate_max
	gate_last_damage_tick = other.gate_last_damage_tick
	capture_realm = other.capture_realm
	capture_start_tick = other.capture_start_tick
	capture_rate = other.capture_rate
	capture_progress_at_start = other.capture_progress_at_start
	contested = other.contested
	empty_since_tick = other.empty_since_tick
	under_attack_until_tick = other.under_attack_until_tick
	last_attack_notice_tick = other.last_attack_notice_tick
	last_contested_notice_tick = other.last_contested_notice_tick
	presence = other.presence.duplicate()
	progress_max = other.progress_max
	last_reset_tick = other.last_reset_tick
	capture_rate_multiplier = other.capture_rate_multiplier
	_captain_respawn_ticks = other._captain_respawn_ticks
	_under_attack_ticks = other._under_attack_ticks
	_gate_repair_ticks = other._gate_repair_ticks
	_guards_expected = other._guards_expected


## true if the capture circle is active (VULNERABLE or CAPTURING): only then does presence count.
func is_circle_active() -> bool:
	return phase == Phase.VULNERABLE or phase == Phase.CAPTURING


## true if the gate is broken (health 0).
func is_gate_broken() -> bool:
	return gate_health <= 0


## true if at tick [param tick] it is time to repair the gate: it is damaged and
## [member FortressDefinition.gate_repair_after_s] has passed since the last hit. Whoever repairs
## it (not while someone occupies the opening) calls [method repair_gate].
func gate_repair_due(tick: int) -> bool:
	return gate_health < gate_max and gate_last_damage_tick != NO_TICK \
			and tick - gate_last_damage_tick >= _gate_repair_ticks


## Fully repairs the gate.
func repair_gate() -> void:
	gate_health = gate_max
	gate_last_damage_tick = NO_TICK


## Realm that accompanies notice [param event_id] in the ENTITY_EVENT: the capturer in "capture
## started" and "capture contested", the owner in "fort captured", 0 in "fort reset" and
## [param caller_realm] (the realm that struck the blow or killed the captain) in the others.
func event_realm(event_id: int, caller_realm: int = 0) -> int:
	match event_id:
		WarEvents.CAPTURE_STARTED, WarEvents.CAPTURE_CONTESTED:
			return capture_realm
		WarEvents.FORT_CAPTURED:
			return owner
		WarEvents.FORT_RESET:
			return 0
	return caller_realm


# --- Internal ---------------------------------------------------------------------------------

# Copies from the definition what the methods that do not receive it need.
func _configure(def: FortressDefinition) -> void:
	progress_max = def.capture_ticks() * PROGRESS_PER_CAPTURE_TICK
	_captain_respawn_ticks = def.captain_respawn_ticks()
	_under_attack_ticks = def.under_attack_ticks()
	_gate_repair_ticks = def.gate_repair_after_ticks()


func _set_presence(counts: PackedInt32Array) -> void:
	for realm: int in FortressFields.PRESENCE_REALMS:
		presence[realm] = counts[realm] if realm < counts.size() else 0


func _presence_of(realm: int) -> int:
	return presence[realm] if realm >= 0 and realm < presence.size() else 0


# Realms (codes 1 to 3) with players inside that are not the owner: the attackers in the table.
func _attacker_realms() -> Array[int]:
	var attackers: Array[int] = []
	for realm: int in range(1, FortressFields.PRESENCE_REALMS):
		if realm != owner and presence[realm] > 0:
			attackers.append(realm)
	return attackers


# true if there are players of the owner inside (with a neutral fort, never).
func _owner_present() -> bool:
	return owner != 0 and _presence_of(owner) > 0


func _mark_under_attack(tick: int) -> void:
	under_attack_until_tick = maxi(under_attack_until_tick, tick + _under_attack_ticks)


# Arms the guards' respawn timer the first time they are noticed missing.
func _arm_guards_timer(def: FortressDefinition, tick: int) -> void:
	if guards_respawn_tick == NO_TICK and guards_alive < _guards_expected \
			and (phase == Phase.GARRISONED or phase == Phase.VULNERABLE):
		guards_respawn_tick = tick + def.guard_respawn_ticks()


# Marks the contest. Returns true if the "capture contested" notice is due: only on entering the
# contest (not while it continues) and with at least 10 s between notices.
func _contest(tick: int) -> bool:
	if contested:
		return false
	contested = true
	if last_contested_notice_tick == NO_TICK \
			or tick - last_contested_notice_tick >= CONTESTED_NOTICE_INTERVAL_TICKS:
		last_contested_notice_tick = tick
		return true
	return false


func _enter_garrisoned(tick: int) -> void:
	phase = Phase.GARRISONED
	phase_tick = tick
	captain_alive = true
	captain_respawn_tick = NO_TICK
	contested = false
	_clear_capture(tick)


func _clear_capture(tick: int) -> void:
	capture_realm = 0
	capture_start_tick = tick
	capture_rate = 0
	capture_progress_at_start = 0
	contested = false
	empty_since_tick = NO_TICK


func _advance_vulnerable(_def: FortressDefinition, tick: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	if captain_respawn_tick != NO_TICK and tick >= captain_respawn_tick:
		_enter_garrisoned(tick)
		return events
	var attackers: Array[int] = _attacker_realms()
	var owner_here: bool = _owner_present()
	if attackers.size() == 1 and not owner_here:
		contested = false
		_start_capture(tick, attackers[0])
		events.append(WarEvents.CAPTURE_STARTED)
	elif attackers.size() >= 2 or (attackers.size() == 1 and owner_here):
		if _contest(tick):
			events.append(WarEvents.CAPTURE_CONTESTED)
	else:
		contested = false
	return events


# Starts (or changes the capturer of) the capture by realm [param realm] with progress 0.
func _start_capture(tick: int, realm: int) -> void:
	if phase != Phase.CAPTURING:
		phase = Phase.CAPTURING
		phase_tick = tick
	capture_realm = realm
	capture_start_tick = tick
	capture_progress_at_start = 0
	capture_rate = rate_for_count(_presence_of(realm)) * maxi(capture_rate_multiplier, 1)
	contested = false
	empty_since_tick = NO_TICK


func _advance_capturing(def: FortressDefinition, tick: int) -> PackedInt32Array:
	var events := PackedInt32Array()
	var progress: int = progress_at(tick)
	if progress >= progress_max:
		_complete_capture(tick)
		events.append(WarEvents.FORT_CAPTURED)
		return events

	var captors: int = _presence_of(capture_realm)
	var others: int = 0
	for realm: int in range(1, FortressFields.PRESENCE_REALMS):
		if realm != capture_realm:
			others += presence[realm]
	var new_rate: int = capture_rate
	if captors > 0 and others == 0:
		# Only the capturer: it advances according to how many there are.
		contested = false
		empty_since_tick = NO_TICK
		new_rate = rate_for_count(captors) * maxi(capture_rate_multiplier, 1)
	elif captors > 0:
		# The capturer and someone else (the owner or another realm): it freezes.
		empty_since_tick = NO_TICK
		if _contest(tick):
			events.append(WarEvents.CAPTURE_CONTESTED)
		new_rate = 0
	elif others > 0:
		# Without the capturer and with others inside: the capture drops back quickly.
		contested = false
		empty_since_tick = NO_TICK
		new_rate = FOREIGN_DECAY_RATE
	else:
		# Nobody: after the delay, the capture decays slowly.
		contested = false
		if empty_since_tick == NO_TICK:
			empty_since_tick = tick
		new_rate = EMPTY_DECAY_RATE if tick - empty_since_tick >= def.decay_after_empty_ticks() else 0
	if new_rate != capture_rate:
		capture_progress_at_start = progress
		capture_start_tick = tick
		capture_rate = new_rate

	# With the capture at zero and not advancing: the only realm that is not the owner and is inside
	# takes it; if there is not exactly one (nobody, or several, or the owner with it), it returns to
	# VULNERABLE.
	if progress <= 0 and new_rate <= 0:
		var attackers: Array[int] = _attacker_realms()
		if attackers.size() == 1 and not _owner_present():
			_start_capture(tick, attackers[0])
			events.append(WarEvents.CAPTURE_STARTED)
		else:
			_fall_back_to_vulnerable(tick)
	return events


# The capture has dropped to zero: the fort returns to VULNERABLE and the captain gets a new
# deadline to respawn.
func _fall_back_to_vulnerable(tick: int) -> void:
	phase = Phase.VULNERABLE
	phase_tick = tick
	captain_respawn_tick = tick + _captain_respawn_ticks
	var was_contested: bool = contested
	_clear_capture(tick)
	contested = was_contested


# Capture complete: the capturer is the new owner, the gate is repaired, the previous owner's
# defenders are removed and consolidation begins.
func _complete_capture(tick: int) -> void:
	owner = capture_realm
	phase = Phase.CONSOLIDATING
	phase_tick = tick
	captain_alive = false
	captain_respawn_tick = NO_TICK
	guards_alive = 0
	guards_respawn_tick = NO_TICK
	_guards_expected = 0
	gate_health = gate_max
	gate_last_damage_tick = NO_TICK
	_clear_capture(tick)
