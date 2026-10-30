class_name StatusTicks
extends RefCounted
## Un [StatusEffectDefinition] ya convertido a ticks por [CombatCatalog] (docs/habilidades.md,
## secciones 2.1 y 4.3).

## ID u8 del catálogo (1..n por orden alfabético del nombre; 0 = ninguno).
var id: int = 0
## El [member StatusEffectDefinition.id] original.
var name: StringName = &""
## [enum StatusEffectDefinition.Kind].
var kind: int = 0
## Predicho: escala de la velocidad (SLOW y ROOT; 1 en los demás).
var move_speed_scale: float = 1.0

# Solo servidor (no entran en la huella).
var duration_ticks: int = 0
## [enum StatusEffectDefinition.Stacking].
var stacking: int = 0
var max_stacks: int = 1
## Ticks entre pulsos (≥ 1).
var pulse_ticks: int = 0
var pulse_amount: int = 0
var damage_type: int = 0
var magnitude: float = 0.0


## true si cambia la velocidad (ocupa una ranura de efecto de movimiento en [CombatState]).
func is_movement() -> bool:
	return kind == StatusEffectDefinition.Kind.SLOW or kind == StatusEffectDefinition.Kind.ROOT


## true si hace daño o cura a pulsos.
func has_pulses() -> bool:
	return pulse_amount > 0 and (kind == StatusEffectDefinition.Kind.DAMAGE_OVER_TIME \
			or kind == StatusEffectDefinition.Kind.HEAL_OVER_TIME)


## true si perjudica a quien lo lleva (para el borde de los iconos y el orden de las placas).
func is_harmful() -> bool:
	match kind:
		StatusEffectDefinition.Kind.HEAL_OVER_TIME, StatusEffectDefinition.Kind.DAMAGE_UP:
			return false
		StatusEffectDefinition.Kind.SLOW:
			return move_speed_scale < 1.0
	return true
