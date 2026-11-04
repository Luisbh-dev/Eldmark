class_name ProjectileTicks
extends RefCounted
## A [ProjectileDefinition] already resolved by [CombatCatalog] (docs/habilidades.md, section 2.1).
## It goes in full into the prediction fingerprint.

## Catalog u16 ID (1..n in alphabetical order of the name; 0 = none).
var id: int = 0
## The original [member ProjectileDefinition.id].
var name: StringName = &""
## Gravity (m/s², downward).
var gravity: float = 0.0
var radius_m: float = 0.0
## Ticks of life (≥ 1): it expires when [code]n + 1 >= lifetime_ticks[/code].
var lifetime_ticks: int = 0
