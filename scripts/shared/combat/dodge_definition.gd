class_name DodgeDefinition
extends Resource
## A weapon's dodge (docs/combat.md, section 2). Times in seconds; the catalog converts them
## to ticks and bakes [member speed_curve] into a per-tick speed table.

## Total duration (s).
@export var duration_s: float = 0.45
## Start of invulnerability (s since the start of the dodge), inclusive.
@export var invulnerable_from_s: float = 0.05
## End of invulnerability (s), exclusive.
@export var invulnerable_to_s: float = 0.3
## Distance covered on flat ground (m).
@export var distance_m: float = 4.5
## Shape of the speed profile: x in [0, 1] (fraction of the duration), y relative speed.
## Normalized so that the total distance is [member distance_m].
@export var speed_curve: Curve
## Stamina cost (0-1000).
@export_range(0, 1000) var stamina_cost: int = 300
## Moment (s since the start of the dodge) from which it can be canceled into an attack.
@export var cancel_to_attack_from_s: float = 0.3
