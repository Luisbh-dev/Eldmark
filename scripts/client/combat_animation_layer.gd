class_name CombatAnimationLayer
extends RefCounted
## Combat animation layer of a character (ART-08), above the locomotion. It reads the action
## in progress, picks the clip with [CombatClipPlanner] and keeps up to two [Slot]s: the current clip and the
## previous one, which fades out while the new one comes in. The [CombatPoseModifier] applies them to the skeleton
## already carrying the locomotion pose.
## [br][br]
## [b]Two sources of the action[/b]:
## [br]- [method update_local]: the local player (and the sandbox) reads its [CombatState] and the simulation
## tick. The clip time is a function of the state ([code]tick - action_tick[/code] plus the
## interpolation fraction), so a reconciliation that replays ticks does not restart anything as long as
## the key [code](action, action_id, action_tick)[/code] is the same; if the server imposes another
## action (a stagger), the key changes and there is a crossfade to the new clip.
## [br]- [method update_remote]: a remote only brings the [code]action[/code] byte of its record (bits
## 0-3 the action, 4-5 the phase, 6-7 the combo step or, in dodges and crowd control, the restart
## counter; see [ActionWire]). The time is counted in real time from the moment each phase is seen
## to begin, and every change of phase (or of counter: a second dodge or a second
## stagger in a row) resets the clip to the start of its segment, so that the contact still
## lands in the active window with snapshot precision.
## [br][br]
## With no action, the current clip fades out ([member CombatActionAnim.blend_out_s]) and the layer becomes
## inactive.
## [br][br]
## [b]Hitstop[/b] (ART-09, animation only): [method start_hitstop] freezes the current clip for about 50 to 80 ms
## when a hit connects. The simulation time and the plan are not touched: an offset accumulates ([member
## _lag_s], clip seconds) that is subtracted from the clip time while the stop lasts and recovered afterward
## by speeding the clip up (to 1.5x) during the recovery, so the action ends on time. Changing clip cancels it.
## [br][br]
## [b]Phase 4[/b] (docs/abilities.md, section 6.6, provisional): each weapon animates with its own clip set
## ([method clips_for]: [code]data/animation/<weapon>_clips.tres[/code], or the default one if it has none);
## the remote gives its active weapon (weapon pair and slot bit of its record). An ABILITY comes from
## the input of its ability (the remote's, by the slot in the action byte); a knocked-down character crawls if it
## moves, and when going from knocked down to nothing (they were lifted up) [constant CombatClipPlanner.KEY_GET_UP]
## is seen once.

## Clip in progress (or outgoing) with its weight.
class Slot:
	var key: StringName = &""
	var animation_name: StringName = &""
	var animation: Animation = null
	var time_s: float = 0.0
	var speed: float = 0.0
	var weight: float = 0.0
	var target: float = 1.0
	var upper_body: bool = false
	var hold: bool = false
	## Hips and legs weight with [member upper_body] and the left arm reserved (see [CombatActionAnim]).
	var lower_weight: float = 0.0
	## Smoothed [member lower_weight] (changes with the phase over 0.08 s) used by the [CombatPoseModifier].
	var lower_current: float = 0.0
	var keep_left_arm: bool = false
	var blend_in_s: float = 0.06
	var blend_out_s: float = 0.12
	var length_s: float = 0.0

## Directory of the per-weapon clip sets.
const CLIPS_DIR: String = "res://data/animation"
## Meters a knocked-down character advances per cycle of the crawl clip (ART-51): the cycle runs at the pace of the real
## speed, so the hands and knees do not skate.
const CRAWL_CYCLE_METERS: float = 1.2
## Seconds the legs' weight takes to move to that of the next phase of an attack.
const LOWER_BLEND_S: float = 0.08

## Default clip set (the one for weapons without their own set).
var clips: CombatClipSet = null
## How much movement the input asks for (0 = none, 1 = full walk): with it the legs of an attack go back to
## the locomotion ([member Slot.lower_weight], ART-46). Set by the [CharacterAnimator] every frame.
var move_request: float = 0.0
## Speed (m/s) of a knocked-down character who is crawling: sets the pace of its clip (ART-51).
var crawl_speed: float = 0.0
var _crawl_cycles: float = 0.0
var _weapon: WeaponTicks = null
# Getting up after being lifted: whether it is being shown and the time (ticks) it has been running.
var _was_downed: bool = false
var _getting_up: bool = false
var _get_up_elapsed: float = 0.0
# Clip sets already loaded by weapon name (null = it has none: the default one is used).
static var _weapon_clips: Dictionary[StringName, CombatClipSet] = {}
var _current: Slot = null
var _previous: Slot = null
var _plan: CombatClipPlanner.Plan = null
# Hitstop: seconds of stop remaining and accumulated offset of the current clip (clip seconds).
var _hitstop_left: float = 0.0
var _lag_s: float = 0.0
## Extra speed (fraction of normal) with which the clip recovers the hitstop offset.
const HITSTOP_CATCHUP: float = 0.5
# Tracking of a remote's action byte.
var _remote_action: int = -1
var _remote_step: int = -1
var _remote_phase: int = -1
var _remote_elapsed: float = 0.0
# Restart counter of the byte (it varies between consecutive staggers: it alternates the chest and head hit).
var _remote_restart_counter: int = 0
# true while the weapon's hit is active (the sword trail; see [method is_swing_active]).
var _swing_active: bool = false


func _init(clip_set: CombatClipSet = null) -> void:
	clips = clip_set
	_weapon = CombatCatalog.weapon(CombatCatalog.default_weapon_id())


# --- Input ------------------------------------------------------------------------------------

## Clip set of weapon [param weapon_id]: [code]data/animation/<weapon>_clips.tres[/code] if it exists and,
## if not, [param fallback].
static func clips_for(weapon_id: int, fallback: CombatClipSet) -> CombatClipSet:
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	if weapon == null:
		return fallback
	if not _weapon_clips.has(weapon.name):
		var path: String = "%s/%s_clips.tres" % [CLIPS_DIR, weapon.name]
		_weapon_clips[weapon.name] = load(path) as CombatClipSet if ResourceLoader.exists(path) else null
	var found: CombatClipSet = _weapon_clips[weapon.name]
	return found if found != null else fallback


## Updates the layer with the local character's combat state at simulation tick [param tick],
## with [param fraction] (0 to 1) of the physics interpolation, and advances the weights by
## [param delta] seconds. [param moving]: whether it is moving (a knocked-down character crawls).
func update_local(state: CombatState, tick: int, fraction: float, delta: float,
		moving: bool = false) -> void:
	var plan: CombatClipPlanner.Plan = null
	_swing_active = ActionMachine.is_attack_active(state, tick)
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	if weapon == null:
		weapon = _weapon
	var set_for_weapon: CombatClipSet = clips_for(state.weapon_id, clips)
	if state.action != CombatState.Action.NONE:
		var phase: int = ActionMachine.phase(state, tick)
		var combo: int = weapon.light_index(state.action_id) \
				if state.action == CombatState.Action.LIGHT else 0
		var elapsed: float = float(tick - state.action_tick) + fraction
		var in_phase: float = elapsed
		if phase != ActionMachine.PHASE_NONE:
			var attack: AttackTicks = CombatCatalog.attack(state.action_id)
			if attack != null and (state.action == CombatState.Action.LIGHT
					or state.action == CombatState.Action.HEAVY):
				in_phase = elapsed - float(CombatClipPlanner.phase_start_ticks(attack, phase))
			elif state.action == CombatState.Action.ABILITY:
				var ability: AbilityTicks = CombatCatalog.ability(state.action_id)
				if ability != null:
					in_phase = elapsed - float(CombatClipPlanner.ability_phase_start_ticks(ability, phase))
		var control_ticks: int = maxi(state.cc_until_tick - state.action_tick, 0)
		var ability_id: int = state.action_id if state.action == CombatState.Action.ABILITY else 0
		plan = CombatClipPlanner.plan(set_for_weapon, weapon, state.action, phase, combo,
				maxf(in_phase, 0.0), control_ticks, ability_id, moving, state.action_tick)
	plan = _with_get_up(plan, state.action, set_for_weapon, weapon,
			float(tick - state.action_tick) + fraction, delta, true)
	apply_plan(plan, delta)


## Updates the layer with the [code]action[/code] byte of a remote's drawn record
## (see [ActionWire]) and advances [param delta] real seconds. [param weapon_id] is the weapon it holds in
## its hands (0 = the default one) and [param moving], whether it is moving (a knocked-down character crawls).
func update_remote(action_byte: int, delta: float, weapon_id: int = 0, moving: bool = false) -> void:
	var action: int = action_byte & 15
	var phase: int = (action_byte >> 4) & 3
	var step: int = ActionWire.step_of(action_byte)
	_swing_active = (action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY) 			and phase == ActionMachine.PHASE_ACTIVE
	var combo: int = step if action == CombatState.Action.LIGHT else 0
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id) if weapon_id != 0 else null
	if weapon == null:
		weapon = _weapon
	var set_for_weapon: CombatClipSet = clips_for(weapon.id if weapon != null else 0, clips)
	if action == CombatState.Action.NONE or action > CombatState.Action.EXECUTE:
		_remote_action = -1
		_remote_step = -1
		_remote_phase = -1
		_remote_elapsed = 0.0
		var none_action: int = CombatState.Action.NONE if action == CombatState.Action.NONE else -1
		apply_plan(_with_get_up(null, none_action, set_for_weapon, weapon, 0.0, delta, false), delta)
		return
	# Every change of action, combo step (or restart counter) or phase starts its segment
	# from the beginning.
	if action != _remote_action or step != _remote_step or phase != _remote_phase:
		_remote_elapsed = 0.0
	else:
		_remote_elapsed += delta
	_remote_action = action
	_remote_step = step
	_remote_phase = phase
	_remote_restart_counter = step
	var used_phase: int = phase if (action == CombatState.Action.LIGHT
			or action == CombatState.Action.HEAVY or action == CombatState.Action.ABILITY) \
			else ActionMachine.PHASE_NONE
	var ability_id: int = CombatClipPlanner.ability_of_slot(weapon, step) \
			if action == CombatState.Action.ABILITY else 0
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(set_for_weapon, weapon, action,
			used_phase, combo, _remote_elapsed * float(Engine.physics_ticks_per_second), 0, ability_id,
			moving, _remote_restart_counter)
	plan = _with_get_up(plan, action, set_for_weapon, weapon, 0.0, delta, false)
	apply_plan(plan, delta)


## Applies this frame's plan ([param plan] null = no action): switches clip with a crossfade if
## needed, sets the time and advances the weights by [param delta] seconds.
func apply_plan(plan: CombatClipPlanner.Plan, delta: float) -> void:
	_plan = plan
	if plan != null:
		if _current == null or _current.key != plan.key:
			_start_slot(plan)
		else:
			_current.target = 1.0
		if _current.animation_name != plan.animation:
			_current.animation_name = plan.animation
			_current.animation = _animation_of(plan.animation)
			_current.length_s = _current.animation.length if _current.animation != null else 0.0
		_current.time_s = _hitstop_time(plan, delta)
		_current.speed = plan.speed
		_current.hold = plan.hold
		_current.lower_weight = plan.lower_weight
		_current.lower_current = move_toward(_current.lower_current, plan.lower_weight, delta / LOWER_BLEND_S)
		if plan.key == CombatClipPlanner.KEY_DOWNED_CRAWL and _current.length_s > 0.0:
			# The crawl advances at the pace of the real speed (ART-51), not that of the clock.
			_crawl_cycles = fposmod(_crawl_cycles + delta * crawl_speed / CRAWL_CYCLE_METERS, 1.0)
			_current.time_s = lerpf(plan.from_s, plan.to_s, _crawl_cycles)
			_current.speed = plan.speed * crawl_speed / CRAWL_CYCLE_METERS * plan.duration_s
	elif _current != null:
		_current.target = 0.0
		# Keeps advancing while it fades out, without going past the end of the clip.
		_current.time_s = minf(_current.time_s + _current.speed * delta, _current.length_s)
	_advance_weights(delta)


# --- Hitstop -----------------------------------------------------------------------------------

## Freezes the current clip for [param seconds] (animation only). If a stop is already in progress, it keeps the longer one.
## It does nothing without a combat clip running (there is nothing to freeze).
func start_hitstop(seconds: float) -> void:
	if _current == null or seconds <= 0.0:
		return
	_hitstop_left = maxf(_hitstop_left, seconds)


## true while the clip is frozen by the hitstop.
func is_in_hitstop() -> bool:
	return _hitstop_left > 0.0


## Offset (clip seconds) the current clip carries because of the hitstop and has not yet recovered.
func get_hitstop_lag() -> float:
	return _lag_s


# Clip time with the hitstop applied: frozen while it lasts, and recovering the offset afterward.
func _hitstop_time(plan: CombatClipPlanner.Plan, delta: float) -> float:
	if _hitstop_left > 0.0:
		var frozen: float = minf(delta, _hitstop_left)
		_hitstop_left -= frozen
		_lag_s += plan.speed * frozen
		if plan.hold:
			_lag_s = 0.0
	elif _lag_s > 0.0:
		_lag_s = maxf(_lag_s - plan.speed * delta * HITSTOP_CATCHUP, 0.0)
	return maxf(plan.time_s - _lag_s, 0.0)


# --- Output -----------------------------------------------------------------------------------

## The clips to apply now, from the outgoing to the current one (with weight greater than 0).
func get_slots() -> Array[Slot]:
	var slots: Array[Slot] = []
	if _previous != null and _previous.weight > 0.0:
		slots.append(_previous)
	if _current != null and _current.weight > 0.0:
		slots.append(_current)
	return slots


## The plan of the last frame (null with no action).
func get_plan() -> CombatClipPlanner.Plan:
	return _plan


## Current clip (or null).
func get_current() -> Slot:
	return _current


## Clip that is fading out (or null).
func get_previous() -> Slot:
	return _previous


## Weight (0 to 1) of the full-body clip being shown (dodge, death, knocked down, stagger...): the combat
## stance steps aside in the meantime ([ArmedStanceModifier]).
func get_full_body_weight() -> float:
	var weight: float = 0.0
	for slot: Slot in get_slots():
		if not slot.upper_body:
			weight = maxf(weight, slot.weight)
	return clampf(weight, 0.0, 1.0)


## Weight (0 to 1) with which the clips in progress reserve the left arm for the combat stance (sword attacks).
func get_left_arm_reserved() -> float:
	var weight: float = 0.0
	for slot: Slot in get_slots():
		if slot.keep_left_arm:
			weight = maxf(weight, slot.weight)
	return clampf(weight, 0.0, 1.0)


## true if any clip has weight.
func is_active() -> bool:
	return not get_slots().is_empty()


## true while the weapon's hit (light or heavy attack) is in its active phase: what launches the trail.
## It is the same criterion for the local player ([method ActionMachine.is_attack_active], the one behind
## [signal CombatFeedback.swing_active_changed]) and for remotes (the active phase of the action byte).
func is_swing_active() -> bool:
	return _swing_active


## Forgets everything (for example, after respawning or switching character).
func reset() -> void:
	_current = null
	_previous = null
	_plan = null
	_was_downed = false
	_getting_up = false
	_get_up_elapsed = 0.0
	_remote_action = -1
	_remote_step = -1
	_remote_phase = -1
	_remote_elapsed = 0.0
	_remote_restart_counter = 0
	_swing_active = false
	_crawl_cycles = 0.0
	_hitstop_left = 0.0
	_lag_s = 0.0


# --- Internal ---------------------------------------------------------------------------------

# Getting up: when the action goes from DOWNED to NONE (they were lifted up), while it stays at NONE and until
# its clip ends, the plan is that of KEY_GET_UP. [param elapsed_ticks] is how long it has been at NONE if it
# is known (the local one, from its action_tick); if not (the remote), it is counted here with [param delta].
func _with_get_up(plan: CombatClipPlanner.Plan, action: int, set_for_weapon: CombatClipSet,
		weapon: WeaponTicks, elapsed_ticks: float, delta: float, exact: bool) -> CombatClipPlanner.Plan:
	if action == CombatState.Action.DOWNED:
		_was_downed = true
		_getting_up = false
		return plan
	if action != CombatState.Action.NONE:
		_was_downed = false
		_getting_up = false
		return plan
	if _was_downed:
		_was_downed = false
		_getting_up = true
		_get_up_elapsed = 0.0
	if not _getting_up:
		return plan
	if exact:
		_get_up_elapsed = maxf(elapsed_ticks, 0.0)
	else:
		_get_up_elapsed += delta * float(Engine.physics_ticks_per_second)
	var entry: CombatActionAnim = set_for_weapon.find(CombatClipPlanner.KEY_GET_UP) \
			if set_for_weapon != null else null
	if entry == null or _get_up_elapsed >= entry.duration_s * float(Engine.physics_ticks_per_second):
		_getting_up = false
		return plan
	return CombatClipPlanner.plan_entry(set_for_weapon, CombatClipPlanner.KEY_GET_UP, weapon,
			CombatState.Action.NONE, ActionMachine.PHASE_NONE, _get_up_elapsed)

# Starts a new clip: the current one becomes the outgoing one (if it was visible) and the new one comes in from 0.
func _start_slot(plan: CombatClipPlanner.Plan) -> void:
	_hitstop_left = 0.0
	_lag_s = 0.0
	if _current != null and _current.weight > 0.01:
		_previous = _current
		_previous.target = 0.0
	var slot := Slot.new()
	slot.key = plan.key
	slot.upper_body = plan.upper_body
	slot.lower_weight = plan.lower_weight
	slot.lower_current = plan.lower_weight
	slot.keep_left_arm = plan.keep_left_arm
	slot.blend_in_s = plan.blend_in_s
	slot.blend_out_s = plan.blend_out_s
	slot.target = 1.0
	slot.weight = 0.0
	_current = slot


func _advance_weights(delta: float) -> void:
	if _previous != null:
		_previous.weight = move_toward(_previous.weight, 0.0, delta / maxf(_previous.blend_out_s, 0.001))
		if _previous.weight <= 0.0:
			_previous = null
	if _current != null:
		var rate: float = _current.blend_in_s if _current.target > _current.weight \
				else _current.blend_out_s
		_current.weight = move_toward(_current.weight, _current.target, delta / maxf(rate, 0.001))
		if _current.weight <= 0.0 and _current.target <= 0.0:
			_current = null


func _animation_of(animation_name: StringName) -> Animation:
	return clips.get_animation(animation_name) if clips != null else null
