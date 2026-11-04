class_name StatusEffectDefinition
extends Resource
## A status effect with a duration (docs/habilidades.md, section 2.1): damage or healing over time,
## slow, root, more damage or less mitigation. Times in seconds; the catalog converts them
## to ticks.
## [br][br]
## Only [member id], [member kind] and [member move_speed_scale] go into the prediction fingerprint:
## slow and root live in [CombatState] (the movement effect slots, imposed by
## the server) and change the speed that client and server simulate. The rest is applied by the server.

## Kind of effect.
enum Kind { DAMAGE_OVER_TIME, HEAL_OVER_TIME, SLOW, ROOT, DAMAGE_UP, MITIGATION_DOWN }
## What happens when applying an effect that is already present: renew the duration, add a stack (up to
## [member max_stacks]) or keep the strongest.
enum Stacking { REFRESH, STACK, STRONGEST }

## Unique identifier (the catalog assigns it a u8 ID in alphabetical order).
@export var id: StringName
## [enum Kind].
@export var kind: int = Kind.DAMAGE_OVER_TIME
## Duration (s). With pulses, an exact multiple of [member pulse_every_s] in ticks.
@export var duration_s: float = 1.0
## [enum Stacking].
@export var stacking: int = Stacking.REFRESH
## Maximum stacks (1-255).
@export var max_stacks: int = 1
## Predicted: speed scale in SLOW (0 < x <= 1, or > 1 if it speeds up); 0 in ROOT.
@export var move_speed_scale: float = 1.0
## Server only: one pulse every so many seconds (damage or healing over time).
@export var pulse_every_s: float = 1.0
## Server only: damage or healing of each pulse per stack (0 = no pulses).
@export var pulse_amount: int = 0
## Server only: damage type of the pulses ([enum DamageFormula.DamageType]).
@export var damage_type: int = 0
## Server only: fraction of DAMAGE_UP (+) or MITIGATION_DOWN (−).
@export var magnitude: float = 0.0
