class_name CombatActionAnim
extends Resource
## How a combat action is animated (ART-07/ART-08): which clip and which segments of it. It is identified
## by [member key], which is the name of an attack from the catalog ([code]sword_light_1[/code],
## [code]sword_heavy[/code]...) or of a non-attack action ([code]charge[/code],
## [code]block[/code], [code]dodge[/code], [code]stagger[/code], [code]stun[/code],
## [code]dead[/code]); see [method CombatClipPlanner.key_for].
## [br][br]
## [b]Attacks[/b]: three segments, one per phase. [member windup], [member active] and [member recovery] are
## rescaled to the duration of the attack's windup, active hit and recovery in the combat
## data. [member contact_s] is the second of the clip, inside [member active], at which
## the blade hits the target: the test checks that it falls inside the active window.
## [br][br]
## [b]Other actions[/b]: only [member windup], which plays for [member duration_s] (or
## for as long as the action lasts, if the data says so: dodge and crowd control) and, with [member hold_end],
## stays on the last pose while the action continues (block, charge, death).

## Key of the action (see the class description).
@export var key: StringName = &""
## true: the clip applies only to the upper body (spine, arms and head), so
## that you can attack or block while walking; false: the whole body (dodge, death).
@export var upper_body: bool = false
## Windup segment (or the only segment in actions without phases).
@export var windup: CombatClipSegment
## Active hit segment (attacks only).
@export var active: CombatClipSegment
## Recovery segment (attacks only).
@export var recovery: CombatClipSegment
## Second of the [member active] clip at which the blade hits the target (-1 = not applicable).
@export var contact_s: float = -1.0
## Duration (s) of the playback of [member windup] in actions without phases and without a duration
## of their own in the combat data.
@export var duration_s: float = 0.0
## Stays on the last pose for as long as the action lasts (block, charge, death).
@export var hold_end: bool = false
## Repeats the segment for as long as the action lasts (crawling while knocked down).
@export var loop: bool = false
## With [member upper_body] (ART-46): how much the hips and legs take from the clip (0 to 1) when the input does not
## ask for movement. Attacks set 1: with the feet planted the whole body comes from the clip; as soon as the
## input asks to walk (the attack's lunge does not count), the legs go back to the locomotion. No effect with
## [code]upper_body = false[/code] (the clip is already full-body).
@export_range(0.0, 1.0) var lower_weight: float = 0.0
## Hips and legs weight specific to each phase of an attack (windup, hit, recovery); -1 = the one from
## [member lower_weight]. Useful when a segment of the clip does not have the feet on the ground (the jump of the third light attack).
@export_range(-1.0, 1.0) var lower_weight_windup: float = -1.0
@export_range(-1.0, 1.0) var lower_weight_active: float = -1.0
@export_range(-1.0, 1.0) var lower_weight_recovery: float = -1.0
## true (ART-46): the clip does not touch the left arm (shoulder, arm, hand and fingers): the combat stance sets it
## ([ArmedStanceModifier], ART-45), so the shield does not leave the front of the chest during sword attacks.
@export var keep_left_arm: bool = false
## With [member hold_end] (ART-07): the held pose sways this much time (s) backward through the clip and returns, at
## [member sway_hz] cycles per second, so that a hit's charge is not a frozen frame.
@export var sway_s: float = 0.0
@export var sway_hz: float = 1.2
## Seconds the layer takes to fade in when the action starts and to fade out when it ends.
@export var blend_in_s: float = 0.06
@export var blend_out_s: float = 0.12


## Segment that corresponds to phase [param phase] ([constant ActionMachine.PHASE_WINDUP]...). Actions
## without phases always use [member windup].
func segment_for_phase(phase: int) -> CombatClipSegment:
	match phase:
		ActionMachine.PHASE_ACTIVE:
			return active if active != null else windup
		ActionMachine.PHASE_RECOVERY:
			return recovery if recovery != null else windup
	return windup


## Hips and legs weight for phase [param phase] ([constant ActionMachine.PHASE_WINDUP]...).
func lower_weight_for_phase(phase: int) -> float:
	var override: float = -1.0
	match phase:
		ActionMachine.PHASE_WINDUP:
			override = lower_weight_windup
		ActionMachine.PHASE_ACTIVE:
			override = lower_weight_active
		ActionMachine.PHASE_RECOVERY:
			override = lower_weight_recovery
	return override if override >= 0.0 else lower_weight


## true if it is an attack animation (it has the three segments).
func is_attack() -> bool:
	return windup != null and active != null and recovery != null
