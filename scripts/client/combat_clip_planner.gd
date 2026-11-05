class_name CombatClipPlanner
extends RefCounted
## Picks the clip and the instant of the combat animation (ART-08). It is a pure function of the action
## ([CombatState.Action]), its phase, the combo step and the elapsed time: it touches no nodes, so it
## is tested without a skeleton. [CombatAnimationLayer] calls it every frame and the
## [CombatPoseModifier] sets the pose.
## [br][br]
## [b]Rescaling.[/b] Each phase of an attack takes [code]windup_ticks[/code], [code]active_ticks[/code] or
## [code]recovery_ticks[/code] ticks in the combat data. The span of the clip assigned to that phase
## ([CombatActionAnim]) is played in exactly that time: [member Plan.speed] is the playback speed
## (seconds of clip per real second) that achieves it. That way the blade contact, which the clip
## marks with [member CombatActionAnim.contact_s], falls inside the active window
## ([method contact_tick]).
## [br][br]
## Actions without phases (dodge, block, charge, controls, death) play the first span over the
## duration given by the data (the dodge's) or the resource itself; with
## [member CombatActionAnim.hold_end] they stay on the last pose and with [member CombatActionAnim.loop] they
## repeat.
## [br][br]
## [b]Phase 4[/b] (docs/habilidades.md, section 6.6; provisional, pending the user's eye): an
## ability is animated with the entry named after it ([code]shield_bash[/code]...; with three spans they are
## rescaled to its cast, active and recovery, like an attack), a potion with
## [constant KEY_DRINK], a weapon swap with [constant KEY_SWAP], knocked down with [constant KEY_DOWNED]
## (still) or [constant KEY_DOWNED_CRAWL] (crawling), reviving and finishing with [constant KEY_REVIVE] and
## [constant KEY_EXECUTE], and getting up after being revived with [constant KEY_GET_UP]. Each weapon has its own
## clip set ([method CombatAnimationLayer.clips_for]).

## Keys of the actions that are not attacks (the keys of attacks are their names in the catalog).
const KEY_CHARGE: StringName = &"charge"
const KEY_BLOCK: StringName = &"block"
const KEY_DODGE: StringName = &"dodge"
const KEY_STAGGER: StringName = &"stagger"
## Short stagger (up to [constant SHORT_STAGGER_TICKS] ticks): another hit to the head or chest, alternating.
const KEY_STAGGER_SHORT: StringName = &"stagger_short"
const KEY_STAGGER_HEAD: StringName = &"stagger_head"
## Duration (ticks) up to which a stagger counts as short (0.42 s).
const SHORT_STAGGER_TICKS: int = 25
const KEY_STUN: StringName = &"stun"
const KEY_DEAD: StringName = &"dead"
const KEY_DRINK: StringName = &"drink"
const KEY_SWAP: StringName = &"swap"
const KEY_DOWNED: StringName = &"downed"
const KEY_DOWNED_CRAWL: StringName = &"downed_crawl"
const KEY_REVIVE: StringName = &"revive"
const KEY_EXECUTE: StringName = &"execute"
const KEY_GET_UP: StringName = &"get_up"


## What must be seen at this instant.
class Plan:
	## Key of the entry ([member CombatActionAnim.key]).
	var key: StringName = &""
	## Clip "library/name".
	var animation: StringName = &""
	## Instant of the clip (s).
	var time_s: float = 0.0
	## Seconds of clip per real second in the current span (0 if the span is instantaneous).
	var speed: float = 0.0
	## Phase of the attack ([constant ActionMachine.PHASE_WINDUP]...), or [constant ActionMachine.PHASE_NONE].
	var phase: int = ActionMachine.PHASE_NONE
	var upper_body: bool = false
	var hold: bool = false
	## Weight of the clip's hips and legs, and whether it leaves the left arm to the combat stance (see
	## [CombatActionAnim.lower_weight] and [member CombatActionAnim.keep_left_arm]).
	var lower_weight: float = 0.0
	var keep_left_arm: bool = false
	var blend_in_s: float = 0.06
	var blend_out_s: float = 0.12
	## Span of the clip being played and the real seconds it has to last.
	var from_s: float = 0.0
	var to_s: float = 0.0
	var duration_s: float = 0.0


## Key of the entry of [param action] with weapon [param weapon]: the name of the light attack
## [param combo_index] (0 to 2) or of the heavy one; for an ABILITY, the name of the ability
## [param ability_id] (or [constant KEY_DRINK] if it is a potion); knocked down, [constant KEY_DOWNED_CRAWL]
## if [param moving]; for the rest, the fixed key of the action. Empty if the action is not animated (NONE).
static func key_for(weapon: WeaponTicks, action: int, combo_index: int, ability_id: int = 0,
		moving: bool = false) -> StringName:
	match action:
		CombatState.Action.LIGHT:
			if weapon == null or weapon.light_ids.is_empty():
				return &""
			var attack: AttackTicks = CombatCatalog.attack(
					weapon.light_ids[clampi(combo_index, 0, weapon.light_ids.size() - 1)])
			return attack.name if attack != null else &""
		CombatState.Action.HEAVY:
			var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id) if weapon != null else null
			return heavy.name if heavy != null else &""
		CombatState.Action.CHARGE:
			return KEY_CHARGE
		CombatState.Action.BLOCK:
			return KEY_BLOCK
		CombatState.Action.DODGE:
			return KEY_DODGE
		CombatState.Action.STAGGER:
			return KEY_STAGGER
		CombatState.Action.STUN:
			return KEY_STUN
		CombatState.Action.DEAD:
			return KEY_DEAD
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(ability_id)
			if ability == null:
				return &""
			return KEY_DRINK if ability.is_consumable() else ability.name
		CombatState.Action.SWAP:
			return KEY_SWAP
		CombatState.Action.DOWNED:
			return KEY_DOWNED_CRAWL if moving else KEY_DOWNED
		CombatState.Action.REVIVE:
			return KEY_REVIVE
		CombatState.Action.EXECUTE:
			return KEY_EXECUTE
	return &""


## Key of the stagger (ART-50): the short ones ([param control_ticks] from 1 to [constant SHORT_STAGGER_TICKS]) alternate
## between the chest hit and the head hit according to [param variant] (even or odd) if the clip set has the
## entries; the long ones and those of unknown duration (a remote) use [constant KEY_STAGGER].
static func stagger_key(clips: CombatClipSet, control_ticks: int, variant: int) -> StringName:
	if clips == null or control_ticks <= 0 or control_ticks > SHORT_STAGGER_TICKS:
		return KEY_STAGGER
	var wanted: StringName = KEY_STAGGER_HEAD if (variant & 1) == 1 else KEY_STAGGER_SHORT
	return wanted if clips.find(wanted) != null else KEY_STAGGER


## Ability from the action byte of a remote: the one in slot [param slot] (0-2) of weapon
## [param weapon], or the first potion if [param slot] is 3 (the two consumables are animated the same).
static func ability_of_slot(weapon: WeaponTicks, slot: int) -> int:
	if slot == 3:
		var consumables: PackedInt32Array = CombatCatalog.consumable_ids()
		return consumables[0] if not consumables.is_empty() else 0
	return weapon.ability_id(slot) if weapon != null else 0


## The plan for [param action] in phase [param phase] when it has [param phase_elapsed_ticks]
## ticks (with fraction) in it. [param combo_index] only matters for light attacks;
## [param control_ticks] is the duration of the stagger or stun if known (0 = the
## resource's); [param ability_id], the ability of an ABILITY; [param moving], whether a knocked-down
## character crawls. Returns null if the action has no animation (or there is no entry for it).
static func plan(clips: CombatClipSet, weapon: WeaponTicks, action: int, phase: int,
		combo_index: int, phase_elapsed_ticks: float, control_ticks: int = 0, ability_id: int = 0,
		moving: bool = false, variant: int = 0) -> Plan:
	if clips == null or action == CombatState.Action.NONE:
		return null
	var key: StringName = key_for(weapon, action, combo_index, ability_id, moving)
	if key.is_empty():
		return null
	if action == CombatState.Action.STAGGER:
		key = stagger_key(clips, control_ticks, variant)
	return plan_entry(clips, key, weapon, action, phase, phase_elapsed_ticks, control_ticks, ability_id)


## The plan of the entry [param key] (already chosen) for [param action]: see [method plan]. The layer also
## uses it for [constant KEY_GET_UP], which is not the key of any action.
static func plan_entry(clips: CombatClipSet, key: StringName, weapon: WeaponTicks, action: int,
		phase: int, phase_elapsed_ticks: float, control_ticks: int = 0, ability_id: int = 0) -> Plan:
	if clips == null:
		return null
	var entry: CombatActionAnim = clips.find(key)
	if entry == null:
		return null
	var tick_rate: float = float(Engine.physics_ticks_per_second)
	var segment: CombatClipSegment
	var phase_ticks: float
	var used_phase: int = ActionMachine.PHASE_NONE
	var ability: AbilityTicks = CombatCatalog.ability(ability_id) \
			if action == CombatState.Action.ABILITY else null
	if entry.is_attack() and (action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY):
		var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(key))
		if attack == null:
			return null
		used_phase = clampi(phase, ActionMachine.PHASE_WINDUP, ActionMachine.PHASE_RECOVERY)
		segment = entry.segment_for_phase(used_phase)
		phase_ticks = float(_phase_length_ticks(attack, used_phase))
	elif entry.is_attack() and ability != null:
		used_phase = clampi(phase, ActionMachine.PHASE_WINDUP, ActionMachine.PHASE_RECOVERY)
		segment = entry.segment_for_phase(used_phase)
		phase_ticks = float(_ability_phase_ticks(ability, used_phase))
	else:
		segment = entry.windup
		phase_ticks = _action_length_ticks(entry, weapon, action, control_ticks)
	if segment == null:
		return null
	var result := Plan.new()
	result.key = key
	result.animation = segment.animation
	result.phase = used_phase
	result.upper_body = entry.upper_body
	result.hold = entry.hold_end
	result.lower_weight = entry.lower_weight_for_phase(used_phase)
	result.keep_left_arm = entry.keep_left_arm
	result.blend_in_s = entry.blend_in_s
	result.blend_out_s = entry.blend_out_s
	result.from_s = segment.from_s
	result.to_s = segment.to_s
	result.duration_s = phase_ticks / tick_rate
	var progress: float = 1.0
	if phase_ticks > 0.0:
		if entry.loop:
			progress = fposmod(phase_elapsed_ticks, phase_ticks) / phase_ticks
		else:
			progress = clampf(phase_elapsed_ticks / phase_ticks, 0.0, 1.0)
		result.speed = segment.length_s() / result.duration_s
	result.time_s = lerpf(segment.from_s, segment.to_s, progress)
	# Held pose that breathes (the heavy attack's charge): it sways back along the span and returns.
	if entry.hold_end and entry.sway_s > 0.0 and phase_ticks > 0.0 and phase_elapsed_ticks > phase_ticks:
		var excess_s: float = (phase_elapsed_ticks - phase_ticks) / tick_rate
		var sway: float = 0.5 - 0.5 * cos(TAU * entry.sway_hz * excess_s)
		result.time_s = maxf(segment.from_s, segment.to_s - entry.sway_s * sway)
	return result


## Ticks (from the start of the action) at which the clip reaches [member CombatActionAnim.contact_s]
## with the rescaling of [param attack]; -1 if the entry marks no contact or is not an attack.
## It must fall inside the window of the active hit ([method AttackTicks.active_from] to
## [method AttackTicks.active_to]) with a one-tick margin.
static func contact_tick(entry: CombatActionAnim, attack: AttackTicks) -> float:
	if entry == null or attack == null or not entry.is_attack() or entry.contact_s < 0.0:
		return -1.0
	var segment: CombatClipSegment = entry.active
	var length: float = segment.length_s()
	if length <= 0.0:
		return -1.0
	var progress: float = (entry.contact_s - segment.from_s) / length
	return float(attack.active_from()) + progress * float(attack.active_ticks)


## Tick (from the start of the action) at which phase [param phase] of [param attack] begins.
static func phase_start_ticks(attack: AttackTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return attack.windup_ticks
		ActionMachine.PHASE_RECOVERY:
			return attack.windup_ticks + attack.active_ticks
	return 0


## Tick (from the start of the ability) at which phase [param phase] of [param ability] begins.
static func ability_phase_start_ticks(ability: AbilityTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return ability.cast_ticks
		ActionMachine.PHASE_RECOVERY:
			return ability.cast_ticks + ability.active_ticks
	return 0


static func _ability_phase_ticks(ability: AbilityTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return ability.active_ticks
		ActionMachine.PHASE_RECOVERY:
			return ability.recovery_ticks
	return ability.cast_ticks


static func _phase_length_ticks(attack: AttackTicks, phase: int) -> int:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return attack.active_ticks
		ActionMachine.PHASE_RECOVERY:
			return attack.recovery_ticks
	return attack.windup_ticks


# Duration (ticks) of the single span of an action without phases: the dodge lasts what the weapon says, the
# controls last as long as the control does if known; the rest, what the resource says.
static func _action_length_ticks(entry: CombatActionAnim, weapon: WeaponTicks, action: int,
		control_ticks: int) -> float:
	if action == CombatState.Action.DODGE and weapon != null and weapon.dodge != null:
		return float(weapon.dodge.duration_ticks)
	if (action == CombatState.Action.STAGGER or action == CombatState.Action.STUN) \
			and control_ticks > 0:
		return float(control_ticks)
	var data: CombatTables = CombatCatalog.tables()
	match action:
		CombatState.Action.SWAP:
			return float(data.swap_ticks)
		CombatState.Action.REVIVE:
			return float(data.revive_ticks)
		CombatState.Action.EXECUTE:
			return float(data.execute_ticks)
	return entry.duration_s * float(Engine.physics_ticks_per_second)
