class_name ProjectileTicks
extends RefCounted
## Un [ProjectileDefinition] ya resuelto por [CombatCatalog] (docs/habilidades.md, sección 2.1).
## Entra entero en la huella de predicción.

## ID u16 del catálogo (1..n por orden alfabético del nombre; 0 = ninguno).
var id: int = 0
## El [member ProjectileDefinition.id] original.
var name: StringName = &""
## Gravedad (m/s², hacia abajo).
var gravity: float = 0.0
var radius_m: float = 0.0
## Ticks de vida (≥ 1): caduca cuando [code]n + 1 >= lifetime_ticks[/code].
var lifetime_ticks: int = 0
