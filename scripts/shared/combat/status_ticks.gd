class_name StatusTicks
extends RefCounted
## A [StatusEffectDefinition] already converted to ticks by [CombatCatalog] (docs/abilities.md,
## sections 2.1 and 4.3).

## Catalog u8 ID (1..n in alphabetical order of the name; 0 = none).
var id: int = 0
## The original [member StatusEffectDefinition.id].
var name: StringName = &""
## [enum StatusEffectDefinition.Kind].
var kind: int = 0
## Predicted: speed scale (SLOW and ROOT; 1 in the others).
var move_speed_scale: float = 1.0

# Server only (not part of the fingerprint).
var duration_ticks: int = 0
## [enum StatusEffectDefinition.Stacking].
var stacking: int = 0
var max_stacks: int = 1
## Ticks between pulses (≥ 1).
var pulse_ticks: int = 0
var pulse_amount: int = 0
var damage_type: int = 0
var magnitude: float = 0.0


## true if it changes speed (it occupies a movement effect slot in [CombatState]).
func is_movement() -> bool:
	return kind == StatusEffectDefinition.Kind.SLOW or kind == StatusEffectDefinition.Kind.ROOT


## true if it deals damage or heals in pulses.
func has_pulses() -> bool:
	return pulse_amount > 0 and (kind == StatusEffectDefinition.Kind.DAMAGE_OVER_TIME \
			or kind == StatusEffectDefinition.Kind.HEAL_OVER_TIME)


## true if it harms whoever carries it (for the icon border and the nameplate order).
func is_harmful() -> bool:
	match kind:
		StatusEffectDefinition.Kind.HEAL_OVER_TIME, StatusEffectDefinition.Kind.DAMAGE_UP:
			return false
		StatusEffectDefinition.Kind.SLOW:
			return move_speed_scale < 1.0
	return true
