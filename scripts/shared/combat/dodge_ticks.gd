class_name DodgeTicks
extends RefCounted
## A [DodgeDefinition] already converted to ticks by [CombatCatalog].
## [br][br]
## [member speeds] is the baked curve: the speed (m/s) imposed on each tick of the
## dodge (index = tick - action_tick), rounded to f32 and normalized so that the sum of
## [code]speeds[i] / 60[/code] is [member distance_m].

var duration_ticks: int = 0
## Ticks [from, to) relative to the start of the dodge during which no damage is taken.
var invulnerable_from_ticks: int = 0
var invulnerable_to_ticks: int = 0
var distance_m: float = 0.0
var stamina_cost: int = 0
## Tick (since the start of the dodge) from which it can be canceled into an attack.
var cancel_to_attack_from_ticks: int = 0
var speeds: PackedFloat32Array = PackedFloat32Array()


## Forced speed (m/s) at tick [param relative_tick] of the dodge.
func speed_at(relative_tick: int) -> float:
	if relative_tick < 0 or speeds.is_empty():
		return 0.0
	return speeds[mini(relative_tick, speeds.size() - 1)]
